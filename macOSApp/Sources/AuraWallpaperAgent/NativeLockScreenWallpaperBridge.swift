import AuraWallpaperCore
import Foundation
import OSLog

/// Client for the optional native bridge. The agent stays linkable and
/// runnable on macOS 13–25 because it only speaks JSON-lines over pipes; the
/// process that imports Apple's private Wallpaper framework is launched only
/// when a modern Lock Screen operation is actually requested.
final class NativeLockScreenWallpaperBridge {
    private static let logger = Logger(
        subsystem: "com.auraflow.wallpaper",
        category: "native-lock-screen-client"
    )

    private let executableURL: URL?
    private let ioQueue = DispatchQueue(
        label: "com.auraflow.native-lock-screen-bridge-client"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: (Bool) -> Void] = [:]
    private var ready = false

    init(executableURL: URL?) {
        self.executableURL = executableURL
    }

    var isReady: Bool {
        ioQueue.sync { ready }
    }

    func prepare(completion: @escaping (Bool) -> Void) {
        ioQueue.async { [weak self] in
            guard let self,
                  self.startIfNeeded()
            else {
                Self.completeOnMain(completion, succeeded: false)
                return
            }
            guard self.send(.prepare, completion: completion) else {
                Self.completeOnMain(completion, succeeded: false)
                return
            }
        }
    }

    func showForLockTransition(completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self,
                  self.startIfNeeded()
            else {
                if let completion {
                    Self.completeOnMain(completion, succeeded: false)
                }
                return
            }
            guard self.send(.show, completion: completion) else {
                if let completion {
                    Self.completeOnMain(completion, succeeded: false)
                }
                return
            }
        }
    }

    func resumeAfterPause() {
        sendWithoutResponse(.resume)
    }

    func pause() {
        sendWithoutResponse(.pause)
    }

    func hideAfterUnlock() {
        sendWithoutResponse(.hide)
    }

    func shutdown() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning == true else {
                self.resetTransport()
                return
            }
            _ = self.send(.shutdown, completion: nil)
        }
    }

    private func sendWithoutResponse(_ action: NativeLockScreenBridgeAction) {
        ioQueue.async { [weak self] in
            guard let self,
                  self.process?.isRunning == true
            else {
                return
            }
            _ = self.send(action, completion: nil)
        }
    }

    private func startIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
              let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            return false
        }
        if process?.isRunning == true {
            return true
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let bridgeProcess = Process()
        bridgeProcess.executableURL = executableURL
        bridgeProcess.standardInput = inputPipe
        bridgeProcess.standardOutput = outputPipe
        bridgeProcess.standardError = Pipe()
        bridgeProcess.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { [weak self] in
                self?.handleTransportClosed()
            }
        }

        do {
            try bridgeProcess.run()
        } catch {
            Self.logger.error(
                "Could not launch native bridge: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        process = bridgeProcess
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)
        ready = false
        output?.readabilityHandler = { [weak self] handle in
            do {
                guard let data = try handle.read(upToCount: 64 * 1024),
                      !data.isEmpty
                else {
                    self?.ioQueue.async { [weak self] in
                        self?.handleTransportClosed()
                    }
                    return
                }
                self?.ioQueue.async { [weak self] in
                    self?.consume(data)
                }
            } catch {
                self?.ioQueue.async { [weak self] in
                    self?.handleTransportClosed()
                }
            }
        }
        return true
    }

    @discardableResult
    private func send(
        _ action: NativeLockScreenBridgeAction,
        completion: ((Bool) -> Void)?
    ) -> Bool {
        guard let input else { return false }
        let request = NativeLockScreenBridgeRequest(action: action)
        guard let encoded = try? encoder.encode(request) else { return false }
        var line = encoded
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            handleTransportClosed()
            return false
        }
        if let completion {
            pending[request.id] = completion
        }
        return true
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let response = try? decoder.decode(
                      NativeLockScreenBridgeResponse.self,
                      from: line
                  )
            else {
                continue
            }
            if response.action == .prepare {
                ready = response.succeeded
            }
            if let completion = pending.removeValue(forKey: response.id) {
                Self.completeOnMain(
                    completion,
                    succeeded: response.succeeded
                )
            }
        }
    }

    private func handleTransportClosed() {
        output?.readabilityHandler = nil
        let completions = pending.values
        pending.removeAll()
        ready = false
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: true)
        for completion in completions {
            Self.completeOnMain(completion, succeeded: false)
        }
    }

    private func resetTransport() {
        output?.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: true)
        pending.removeAll()
        ready = false
    }

    private static func completeOnMain(
        _ completion: @escaping (Bool) -> Void,
        succeeded: Bool
    ) {
        DispatchQueue.main.async {
            completion(succeeded)
        }
    }
}
