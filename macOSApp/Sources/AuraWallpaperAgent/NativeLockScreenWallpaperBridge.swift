import AuraWallpaperCore
import Darwin
import Foundation
import OSLog

/// Client for the optional native bridge. The agent stays linkable and
/// runnable on macOS 13–25 because it only speaks JSON-lines over pipes; the
/// process that imports Apple's private Wallpaper framework is launched only
/// when a modern Lock Screen operation is actually requested.
final class NativeLockScreenWallpaperBridge {
    private enum State {
        case stopped
        case starting
        case preparing
        case ready
        case failed
    }

    private struct PendingRequest {
        let action: NativeLockScreenBridgeAction
        let generation: UInt64
        let completion: ((Bool) -> Void)?
    }

    private static let logger = Logger(
        subsystem: "com.auraflow.wallpaper",
        category: "native-lock-screen-client"
    )
    private static let requestTimeout: TimeInterval = 5.0

    private let executableURL: URL?
    private let ioQueue = DispatchQueue(
        label: "com.auraflow.native-lock-screen-bridge-client"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var state: State = .stopped
    private var generation: UInt64 = 0
    private var pending: [String: PendingRequest] = [:]
    private var requestTimeouts: [String: DispatchWorkItem] = [:]
    private var preparationWaiters: [(Bool) -> Void] = []

    init(executableURL: URL?) {
        self.executableURL = executableURL
    }

    var isReady: Bool {
        ioQueue.sync {
            if case .ready = state { return true }
            return false
        }
    }

    func prepare(completion: @escaping (Bool) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else {
                Self.completeOnMain(completion, succeeded: false)
                return
            }
            self.ensureReady { succeeded in
                Self.completeOnMain(completion, succeeded: succeeded)
            }
        }
    }

    func showForLockTransition(completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else {
                if let completion {
                    Self.completeOnMain(completion, succeeded: false)
                }
                return
            }
            // A lock notification can arrive while the asynchronous prepare
            // request is still in flight. Queue show behind the readiness
            // handshake instead of sending it to an empty bridge state.
            self.ensureReady { [weak self] prepared in
                guard let self, prepared else {
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
    }

    func resumeAfterPause() {
        sendWhenReady(.resume)
    }

    func pause() {
        sendWhenReady(.pause)
    }

    func hideAfterUnlock() {
        sendWhenReady(.hide)
    }

    func shutdown() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning == true else {
                self.closeTransport(finalState: .stopped, terminateProcess: false)
                return
            }
            _ = self.send(.shutdown, completion: nil)
        }
    }

    private func ensureReady(_ continuation: @escaping (Bool) -> Void) {
        switch state {
        case .ready:
            continuation(true)
        case .starting, .preparing:
            preparationWaiters.append(continuation)
        case .stopped, .failed:
            guard startIfNeeded() else {
                continuation(false)
                return
            }
            preparationWaiters.append(continuation)
            state = .preparing
            guard send(.prepare, completion: nil) else {
                failTransport(reason: "Could not send the bridge prepare request.")
                return
            }
        }
    }

    private func sendWhenReady(_ action: NativeLockScreenBridgeAction) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureReady { [weak self] succeeded in
                guard let self, succeeded else { return }
                _ = self.send(action, completion: nil)
            }
        }
    }

    private func startIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
              let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            state = .failed
            reportFailure("Native Lock Screen bridge executable is unavailable.")
            return false
        }
        if process?.isRunning == true {
            return true
        }

        // An exited process may not have delivered its termination callback
        // yet. Invalidate its generation before creating a replacement.
        if process != nil {
            closeTransport(finalState: .stopped, terminateProcess: false)
        }
        generation &+= 1
        let processGeneration = generation
        state = .starting

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let bridgeProcess = Process()
        bridgeProcess.executableURL = executableURL
        bridgeProcess.standardInput = inputPipe
        bridgeProcess.standardOutput = outputPipe
        bridgeProcess.standardError = Pipe()
        bridgeProcess.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { [weak self] in
                self?.handleTransportClosed(generation: processGeneration)
            }
        }

        do {
            try bridgeProcess.run()
        } catch {
            state = .failed
            Self.logger.error(
                "Could not launch native bridge: \(error.localizedDescription, privacy: .public)"
            )
            reportFailure(
                "Could not launch native Lock Screen bridge: \(error.localizedDescription)"
            )
            return false
        }

        process = bridgeProcess
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)
        output?.readabilityHandler = { [weak self] handle in
            do {
                guard let data = try handle.read(upToCount: 64 * 1024),
                      !data.isEmpty
                else {
                    self?.ioQueue.async { [weak self] in
                        self?.handleTransportClosed(generation: processGeneration)
                    }
                    return
                }
                self?.ioQueue.async { [weak self] in
                    self?.consume(data, generation: processGeneration)
                }
            } catch {
                self?.ioQueue.async { [weak self] in
                    self?.handleTransportClosed(generation: processGeneration)
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
        guard let input,
              let process,
              process.isRunning
        else {
            if process != nil {
                failTransport(reason: "Native bridge process is no longer running.")
            }
            return false
        }
        let request = NativeLockScreenBridgeRequest(action: action)
        guard let encoded = try? encoder.encode(request) else { return false }
        var line = encoded
        line.append(0x0A)

        let requestGeneration = generation
        pending[request.id] = PendingRequest(
            action: action,
            generation: requestGeneration,
            completion: completion
        )
        let timeout = DispatchWorkItem { [weak self] in
            self?.ioQueue.async { [weak self] in
                self?.handleRequestTimeout(
                    requestID: request.id,
                    generation: requestGeneration
                )
            }
        }
        requestTimeouts[request.id] = timeout

        do {
            try input.write(contentsOf: line)
        } catch {
            timeout.cancel()
            requestTimeouts.removeValue(forKey: request.id)
            pending.removeValue(forKey: request.id)
            failTransport(reason: "Could not write to the native bridge.")
            return false
        }
        ioQueue.asyncAfter(
            deadline: .now() + Self.requestTimeout,
            execute: timeout
        )
        return true
    }

    private func consume(_ data: Data, generation responseGeneration: UInt64) {
        guard responseGeneration == generation else { return }
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

            requestTimeouts.removeValue(forKey: response.id)?.cancel()
            guard let request = pending.removeValue(forKey: response.id),
                  request.generation == responseGeneration
            else {
                continue
            }
            if !response.succeeded {
                Self.logger.error(
                    "Native bridge request failed action=\(request.action.rawValue, privacy: .public) reason=\(response.errorDescription ?? "unknown", privacy: .public)"
                )
            }
            if response.action == .prepare {
                state = response.succeeded ? .ready : .failed
                let waiters = preparationWaiters
                preparationWaiters.removeAll()
                for waiter in waiters {
                    waiter(response.succeeded)
                }
            } else if response.action == .shutdown {
                closeTransport(finalState: .stopped, terminateProcess: false)
            }
            if let completion = request.completion {
                Self.completeOnMain(
                    completion,
                    succeeded: response.succeeded
                )
            }
            if !response.succeeded {
                failTransport(
                    reason: response.errorDescription
                        ?? "Native Lock Screen bridge rejected the request."
                )
            }
        }
    }

    private func handleRequestTimeout(
        requestID: String,
        generation requestGeneration: UInt64
    ) {
        guard requestGeneration == generation,
              let request = pending[requestID],
              request.generation == requestGeneration
        else {
            return
        }
        Self.logger.error(
            "Native bridge request timed out action=\(request.action.rawValue, privacy: .public)"
        )
        failTransport(reason: "Native Lock Screen bridge timed out.")
    }

    private func handleTransportClosed(generation closedGeneration: UInt64) {
        guard closedGeneration == generation else { return }
        failTransport(reason: "Native Lock Screen bridge terminated unexpectedly.")
    }

    private func failTransport(reason: String) {
        Self.logger.error("Native bridge transport failed: \(reason, privacy: .public)")
        reportFailure(reason)
        closeTransport(finalState: .failed, terminateProcess: true)
    }

    private func reportFailure(_ reason: String) {
        guard let onFailure else { return }
        DispatchQueue.main.async {
            onFailure(reason)
        }
    }

    private func closeTransport(finalState: State, terminateProcess: Bool) {
        let processToStop = process
        let processID = processToStop?.processIdentifier
        generation &+= 1
        output?.readabilityHandler = nil
        for timeout in requestTimeouts.values {
            timeout.cancel()
        }
        requestTimeouts.removeAll()
        let completions = pending.values.compactMap(\.completion)
        pending.removeAll()
        let waiters = preparationWaiters
        preparationWaiters.removeAll()
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: true)
        state = finalState

        if terminateProcess,
           let processToStop,
           processToStop.isRunning,
           let processID {
            processToStop.terminate()
            let expectedURL = executableURL
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                guard processToStop.isRunning,
                      let expectedURL,
                      Self.processPath(processID) == expectedURL.path
                else {
                    return
                }
                kill(processID, SIGKILL)
            }
        }

        for completion in completions {
            Self.completeOnMain(completion, succeeded: false)
        }
        for waiter in waiters {
            waiter(false)
        }
    }

    private static func processPath(_ processID: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 4_096)
        let length = proc_pidpath(
            processID,
            &buffer,
            UInt32(buffer.count)
        )
        guard length > 0 else { return nil }
        return String(cString: buffer)
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
