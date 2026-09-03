import Darwin
import Foundation

struct DaemonProcessIdentity: Codable, Equatable {
    var executablePath: String
    var startTimeMicros: Int64
}

/// Owns PID persistence, process identity validation, and daemon termination.
///
/// `WallpaperRuntimeStore` exposes the durable URLs and config state, while
/// this component owns all decisions that can signal an operating-system
/// process. An identity mismatch is never treated as a successful stop.
public final class DaemonProcessManager {
    private enum IdentityStatus {
        case matched
        case alreadyExited
        case mismatch
        case unavailable
    }

    private let store: WallpaperRuntimeStore
    private let expectedExecutableURL: URL?

    public init(
        store: WallpaperRuntimeStore,
        expectedExecutableURL: URL? = nil
    ) {
        self.store = store
        self.expectedExecutableURL = expectedExecutableURL?.standardizedFileURL
    }

    public var currentPID: Int? {
        store.loadPID()
    }

    public var isRunning: Bool {
        Self.isProcessAlive(pid: store.loadPID())
    }

    public func isRunning(pid: Int?) -> Bool {
        Self.isProcessAlive(pid: pid)
    }

    public func recordPID(_ pid: Int32 = getpid()) throws {
        try store.ensureDirectories()
        if let identity = processIdentityWithRetry(for: Int(pid)) {
            let data = try JSONEncoder().encode(identity)
            try data.write(to: store.daemonIdentityURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: store.daemonIdentityURL)
        }
        try "\(pid)\n".write(to: store.pidURL, atomically: true, encoding: .utf8)
    }

    public func ownsRuntimeProcess(_ pid: Int32 = getpid()) -> Bool {
        guard store.loadPID() == Int(pid),
              let expected = loadIdentity(),
              let actual = processIdentity(for: Int(pid))
        else {
            return false
        }
        return expected == actual
    }

    @discardableResult
    public func terminate(timeout: TimeInterval = 1.0) -> DaemonTerminationResult {
        guard let pid = store.loadPID() else {
            clearRuntimeMetadata()
            return .alreadyExited
        }

        switch identityStatus(for: pid) {
        case .alreadyExited:
            clearRuntimeMetadata()
            return .alreadyExited
        case .mismatch, .unavailable:
            // The PID may have been reused. Remove AuraFlow metadata, but
            // never signal a process whose identity cannot be confirmed.
            clearRuntimeMetadata()
            return .identityMismatch
        case .matched:
            break
        }

        kill(pid_t(pid), SIGTERM)
        let deadline = Date().addingTimeInterval(max(timeout, 0.2))
        while Date() < deadline {
            if !Self.isProcessAlive(pid: pid) {
                clearRuntimeMetadata()
                return .terminated
            }
            switch identityStatus(for: pid) {
            case .matched:
                break
            case .alreadyExited:
                clearRuntimeMetadata()
                return .alreadyExited
            case .mismatch:
                clearRuntimeMetadata()
                return .identityMismatch
            case .unavailable:
                // A process that accepted SIGTERM can briefly lose its procfs
                // identity before launchd reaps it. Keep waiting without
                // sending another unverified signal.
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        switch identityStatus(for: pid) {
        case .matched:
            break
        case .alreadyExited:
            clearRuntimeMetadata()
            return .alreadyExited
        case .mismatch, .unavailable:
            clearRuntimeMetadata()
            return .identityMismatch
        }

        kill(pid_t(pid), SIGKILL)
        let killDeadline = Date().addingTimeInterval(1.0)
        while Date() < killDeadline {
            if !Self.isProcessAlive(pid: pid) {
                clearRuntimeMetadata()
                return .terminated
            }
            switch identityStatus(for: pid) {
            case .matched:
                break
            case .alreadyExited:
                clearRuntimeMetadata()
                return .alreadyExited
            case .mismatch:
                clearRuntimeMetadata()
                return .identityMismatch
            case .unavailable:
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .failed
    }

    public func waitForExit(timeout: TimeInterval = 1.0) -> Bool {
        Self.waitForExit(pid: store.loadPID(), timeout: timeout)
    }

    public static func waitForExit(pid: Int?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while Date() < deadline {
            if !isProcessAlive(pid: pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isProcessAlive(pid: pid)
    }

    public static func isProcessAlive(pid: Int?) -> Bool {
        guard let pid, pid > 0, kill(pid_t(pid), 0) == 0 else {
            return false
        }

        var processInfo = proc_bsdinfo()
        let infoSize = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            var executablePath = [Int8](repeating: 0, count: 4_096)
            return proc_pidpath(
                pid_t(pid),
                &executablePath,
                UInt32(executablePath.count)
            ) > 0
        }
        return processInfo.pbi_status != UInt32(SZOMB)
    }

    private func clearRuntimeMetadata() {
        store.removePID()
        store.markPaused(false)
    }

    private func identityStatus(for pid: Int) -> IdentityStatus {
        guard Self.isProcessAlive(pid: pid) else {
            return .alreadyExited
        }
        guard let actual = processIdentity(for: pid) else {
            if reapExitedChildProcess(pid) {
                return .alreadyExited
            }
            return .unavailable
        }
        if let expected = loadIdentity() {
            return expected == actual ? .matched : .mismatch
        }
        guard let expectedExecutableURL else {
            return .mismatch
        }
        return actual.executablePath == expectedExecutableURL.path
            ? .matched
            : .mismatch
    }

    private func reapExitedChildProcess(_ pid: Int) -> Bool {
        var status: Int32 = 0
        return waitpid(pid_t(pid), &status, WNOHANG) == pid_t(pid)
    }

    private func loadIdentity() -> DaemonProcessIdentity? {
        guard let data = try? Data(contentsOf: store.daemonIdentityURL) else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonProcessIdentity.self, from: data)
    }

    private func processIdentity(for pid: Int) -> DaemonProcessIdentity? {
        guard pid > 0 else { return nil }
        var path = [Int8](repeating: 0, count: 4_096)
        guard proc_pidpath(pid_t(pid), &path, UInt32(path.count)) > 0 else {
            return nil
        }

        var processInfo = proc_bsdinfo()
        let infoSize = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.stride)
        )
        guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            return nil
        }

        let startTimeMicros = Int64(processInfo.pbi_start_tvsec) * 1_000_000
            + Int64(processInfo.pbi_start_tvusec)
        return DaemonProcessIdentity(
            executablePath: String(cString: path),
            startTimeMicros: startTimeMicros
        )
    }

    private func processIdentityWithRetry(for pid: Int) -> DaemonProcessIdentity? {
        for attempt in 0..<50 {
            if let identity = processIdentity(for: pid) {
                return identity
            }
            if attempt < 49 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return nil
    }
}
