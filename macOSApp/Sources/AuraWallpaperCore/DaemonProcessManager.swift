import Darwin
import Foundation

struct DaemonProcessIdentity: Codable, Equatable {
    var executablePath: String
    var startTimeMicros: Int64
}

/// Result of verifying the process represented by the persisted daemon PID.
///
/// A PID is not sufficient evidence of ownership: the operating system can
/// reuse it after AuraFlow exits. Callers that expose daemon state should
/// treat only `.owned` as a running AuraFlow process.
public enum DaemonProcessStatus: Equatable, Sendable {
    case noPID
    case owned
    case stalePID
    case identityMismatch
    case unknown

    public var isOwned: Bool {
        self == .owned
    }
}

struct DaemonProcessResourceMetrics: Equatable, Sendable {
    let cpuPercent: Double?
    let memoryMB: Double?
    let virtualMemoryMB: Double?
    let threadCount: Int?
}

/// Owns PID persistence, process identity validation, and daemon termination.
///
/// `WallpaperRuntimeStore` exposes the durable URLs and config state, while
/// this component owns all decisions that can signal an operating-system
/// process. An identity mismatch is never treated as a successful stop.
public final class DaemonProcessManager {
    private enum ProcessPresence: Equatable {
        case alive
        case exited
        case unknown
    }

    private enum IdentityStatus {
        case matched
        case alreadyExited
        case mismatch
        case unavailable
    }

    private struct ResourceSample {
        let totalCPUTime: UInt64
        let sampledAt: TimeInterval
        let startTimeMicros: Int64
    }

    private final class ResourceSampleStore: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Int: ResourceSample] = [:]

        func cpuPercent(
            pid: Int,
            totalCPUTime: UInt64,
            startTimeMicros: Int64,
            sampledAt: TimeInterval
        ) -> Double? {
            lock.lock()
            defer { lock.unlock() }

            let previous = samples.updateValue(
                ResourceSample(
                    totalCPUTime: totalCPUTime,
                    sampledAt: sampledAt,
                    startTimeMicros: startTimeMicros
                ),
                forKey: pid
            )

            if let previous,
               previous.startTimeMicros == startTimeMicros,
               totalCPUTime >= previous.totalCPUTime
            {
                let elapsed = sampledAt - previous.sampledAt
                if elapsed > 0.01 {
                    let cpuSeconds = Double(totalCPUTime - previous.totalCPUTime) / 1_000_000_000.0
                    return max(0.0, (cpuSeconds / elapsed) * 100.0)
                }
            }

            // The first refresh has no previous sample yet. Return a useful
            // lifetime average instead of showing n/a until the next poll.
            let processLifetime = sampledAt - (Double(startTimeMicros) / 1_000_000.0)
            guard processLifetime > 0 else { return 0.0 }
            let cpuSeconds = Double(totalCPUTime) / 1_000_000_000.0
            return max(0.0, (cpuSeconds / processLifetime) * 100.0)
        }
    }

    private static let resourceSamples = ResourceSampleStore()

    private let store: WallpaperRuntimeStore
    private let expectedExecutablePaths: Set<String>
    private let usesExplicitExecutablePaths: Bool

    public init(
        store: WallpaperRuntimeStore,
        expectedExecutableURL: URL? = nil,
        additionalExpectedExecutableURLs: [URL] = []
    ) {
        self.store = store
        self.usesExplicitExecutablePaths =
            expectedExecutableURL != nil || !additionalExpectedExecutableURLs.isEmpty
        var expectedURLs = additionalExpectedExecutableURLs
        if let expectedExecutableURL {
            expectedURLs.append(expectedExecutableURL)
        } else if additionalExpectedExecutableURLs.isEmpty {
            expectedURLs = Self.defaultExpectedExecutableURLs(for: store)
        }
        self.expectedExecutablePaths = Set(
            expectedURLs.map(Self.normalizedExecutablePath)
        )
    }

    public var currentPID: Int? {
        store.loadPID()
    }

    /// Verifies both liveness and the identity recorded when the PID was
    /// persisted. A live but unrelated process is never reported as owned.
    public var processStatus: DaemonProcessStatus {
        processStatus(for: store.loadPID())
    }

    public var isRunning: Bool {
        processStatus.isOwned
    }

    /// Stops helper instances that still point at an AuraFlow-owned
    /// executable but are no longer represented by the persisted PID.
    ///
    /// A failed migration or an older app instance can leave one such helper
    /// behind. It must not be allowed to keep observing the shared command
    /// file and mutate the Lock Screen alongside the current agent.
    @discardableResult
    public func terminateOrphanedProcesses(
        timeout: TimeInterval = 1.0
    ) -> [Int] {
        let persistedPID = store.loadPID()
        let orphanedPIDs = Self.runningProcessIDs()
            .filter { pid in
                pid != persistedPID
                    && expectedExecutablePaths.contains(
                        Self.normalizedExecutablePath(
                            Self.processExecutablePath(for: pid) ?? ""
                        )
                    )
            }

        var terminatedPIDs: [Int] = []
        for pid in orphanedPIDs {
            guard terminateOrphanedProcess(pid, timeout: timeout) else {
                continue
            }
            terminatedPIDs.append(pid)
        }
        return terminatedPIDs
    }

    public func isRunning(pid: Int?) -> Bool {
        processStatus(for: pid).isOwned
    }

    /// Reads resource usage for an already verified AuraFlow process. The
    /// caller still receives nil when macOS refuses a particular proc query,
    /// but a live owned process normally provides all four values.
    func resourceMetrics(for pid: Int) -> DaemonProcessResourceMetrics? {
        guard processStatus(for: pid).isOwned,
              let taskInfo = Self.taskInfo(for: pid),
              let startTimeMicros = Self.processStartTimeMicros(for: pid)
        else {
            return nil
        }

        let totalCPUTime = taskInfo.pti_total_user &+ taskInfo.pti_total_system
        let sampledAt = Date().timeIntervalSince1970
        return DaemonProcessResourceMetrics(
            cpuPercent: Self.resourceSamples.cpuPercent(
                pid: pid,
                totalCPUTime: totalCPUTime,
                startTimeMicros: startTimeMicros,
                sampledAt: sampledAt
            ),
            memoryMB: Double(taskInfo.pti_resident_size) / 1_048_576.0,
            virtualMemoryMB: Double(taskInfo.pti_virtual_size) / 1_048_576.0,
            threadCount: Int(taskInfo.pti_threadnum)
        )
    }

    public func processStatus(for pid: Int?) -> DaemonProcessStatus {
        guard let pid, pid > 0 else {
            return .noPID
        }

        guard store.loadPID() == pid else {
            return Self.processPresence(pid: pid) == .exited
                ? .stalePID
                : .identityMismatch
        }

        switch Self.processPresence(pid: pid) {
        case .exited:
            return .stalePID
        case .unknown:
            return .unknown
        case .alive:
            break
        }

        guard let actual = processIdentity(for: pid) else {
            // An identity that cannot be read is not proof that the process
            // is foreign; it is simply not safe to call it AuraFlow-owned.
            return .unknown
        }
        if let expected = loadIdentity() {
            return expected == actual ? .owned : .identityMismatch
        }

        // Native helpers from versions before identity persistence can still
        // be managed when proc_pidpath matches a path explicitly owned by
        // AuraFlow: the current helper, an old app-bundle helper, or the path
        // captured from AuraFlow's LaunchAgent before migration.
        guard !expectedExecutablePaths.isEmpty else { return .unknown }
        if expectedExecutablePaths.contains(
            Self.normalizedExecutablePath(actual.executablePath)
        ) {
            return .owned
        }
        return usesExplicitExecutablePaths ? .identityMismatch : .unknown
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
        switch processPresence(pid: pid) {
        case .alive:
            return true
        case .exited, .unknown:
            return false
        }
    }

    private static func processPresence(pid: Int?) -> ProcessPresence {
        guard let pid, pid > 0 else {
            return .exited
        }

        let result = kill(pid_t(pid), 0)
        if result == -1 {
            // EPERM means the process exists but cannot be inspected by this
            // caller. Do not collapse that into a stale PID.
            return errno == ESRCH ? .exited : .unknown
        }

        var processInfo = proc_bsdinfo()
        let infoSize = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        if infoSize == Int32(MemoryLayout<proc_bsdinfo>.size) {
            return processInfo.pbi_status == UInt32(SZOMB) ? .exited : .alive
        }

        var executablePath = [Int8](repeating: 0, count: 4_096)
        return proc_pidpath(
            pid_t(pid),
            &executablePath,
            UInt32(executablePath.count)
        ) > 0 ? .alive : .unknown
    }

    private func terminateOrphanedProcess(
        _ pid: Int,
        timeout: TimeInterval
    ) -> Bool {
        // The executable path was resolved immediately before this call and
        // matched one of the exact AuraFlow helper paths. Re-check it before
        // every signal so PID reuse cannot turn cleanup into a foreign-process
        // kill.
        guard let executablePath = Self.processExecutablePath(for: pid),
              expectedExecutablePaths.contains(
                  Self.normalizedExecutablePath(executablePath)
              )
        else {
            return false
        }

        kill(pid_t(pid), SIGTERM)
        guard !Self.isProcessAlive(pid: pid)
            || Self.waitForExit(pid: pid, timeout: max(timeout, 0.2))
        else {
            guard let currentPath = Self.processExecutablePath(for: pid),
                  expectedExecutablePaths.contains(
                      Self.normalizedExecutablePath(currentPath)
                  )
            else {
                return false
            }
            kill(pid_t(pid), SIGKILL)
            return Self.waitForExit(pid: pid, timeout: 1.0)
        }
        return true
    }

    private static func runningProcessIDs() -> [Int] {
        let requiredBytes = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else { return [] }

        let capacity = Int(requiredBytes) / MemoryLayout<Int32>.stride + 16
        var pids = [Int32](repeating: 0, count: capacity)
        let returnedBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard returnedBytes > 0 else { return [] }
        let returnedCount = min(
            Int(returnedBytes) / MemoryLayout<Int32>.stride,
            pids.count
        )
        return pids.prefix(returnedCount)
            .map(Int.init)
            .filter { $0 > 0 }
    }

    private static func processExecutablePath(for pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var path = [Int8](repeating: 0, count: 4_096)
        guard proc_pidpath(
            pid_t(pid),
            &path,
            UInt32(path.count)
        ) > 0
        else {
            return nil
        }
        return String(cString: path)
    }

    private static func taskInfo(for pid: Int) -> proc_taskinfo? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let infoSize = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_taskinfo>.stride)
        )
        guard infoSize == Int32(MemoryLayout<proc_taskinfo>.stride) else {
            return nil
        }
        return info
    }

    private static func processStartTimeMicros(for pid: Int) -> Int64? {
        guard pid > 0 else { return nil }
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
        return Int64(processInfo.pbi_start_tvsec) * 1_000_000
            + Int64(processInfo.pbi_start_tvusec)
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
        guard !expectedExecutablePaths.isEmpty else {
            return .mismatch
        }
        return expectedExecutablePaths.contains(
            Self.normalizedExecutablePath(actual.executablePath)
        )
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
        let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return DaemonProcessIdentity(
            executablePath: String(decoding: pathBytes, as: UTF8.self),
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

    private static func normalizedExecutablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedExecutablePath(_ path: String) -> String {
        normalizedExecutablePath(URL(fileURLWithPath: path))
    }

    private static func defaultExpectedExecutableURLs(
        for store: WallpaperRuntimeStore
    ) -> [URL] {
        var urls = [
            store.appSupportURL
                .appendingPathComponent("Runtime/AuraWallpaperAgent")
        ]
        if let launchAgentURL = store.loadLaunchAgentExecutableURL() {
            urls.append(launchAgentURL)
        }
        urls.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/AuraWallpaperAgent")
        )
        if let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent()
        {
            urls.append(executableDirectory.appendingPathComponent("AuraWallpaperAgent"))
        }
        return urls
    }
}
