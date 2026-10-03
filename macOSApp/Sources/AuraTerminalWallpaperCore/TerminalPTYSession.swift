import AuraTerminalPTYKit
import Foundation

public final class TerminalPTYSession {
    public typealias DataHandler = (Data) -> Void
    public typealias ExitHandler = (Int32) -> Void

    private var runningPID: pid_t?
    private var masterDescriptor: Int32?
    private var paused = false
    public var childPID: pid_t? {
        stateLock.lock(); defer { stateLock.unlock() }; return runningPID
    }
    public var masterFileDescriptor: Int32? {
        stateLock.lock(); defer { stateLock.unlock() }; return masterDescriptor
    }
    public var isPaused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return paused
    }

    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-pty", qos: .userInitiated)
    private let stateLock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var readSource: DispatchSourceRead?
    private var exitHandler: ExitHandler?
    private var didFinish = false
    private let inheritedEnvironment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        inheritedEnvironment = environment
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(
        command: TerminalCommandConfiguration,
        columns: Int,
        rows: Int,
        onData: @escaping DataHandler,
        onExit: @escaping ExitHandler
    ) throws -> pid_t {
        stateLock.lock()
        defer { stateLock.unlock() }
        stop()
        let searchEnvironment = TerminalProcessEnvironment.make(
            inherited: inheritedEnvironment,
            overrides: command.environment,
            executable: command.executable,
            columns: columns,
            rows: rows
        )
        let executable = try resolveExecutable(for: command, environment: searchEnvironment)
        let arguments = [executable] + command.arguments
        let environment = TerminalProcessEnvironment.make(
            inherited: inheritedEnvironment,
            overrides: command.environment,
            executable: executable,
            columns: columns,
            rows: rows
        )
        let argumentBlob = nulSeparatedBlob(arguments)
        let environmentBlob = nulSeparatedBlob(environment.map { "\($0.key)=\($0.value)" }.sorted())
        var child: pid_t = 0
        var master: Int32 = -1
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let result = executable.withCString { executablePointer in
            argumentBlob.withUnsafeBytes { argumentBytes in
                environmentBlob.withUnsafeBytes { environmentBytes in
                    aura_terminal_pty_spawn(
                        executablePointer,
                        argumentBytes.bindMemory(to: UInt8.self).baseAddress,
                        arguments.count,
                        environmentBytes.bindMemory(to: UInt8.self).baseAddress,
                        environment.count,
                        command.workingDirectory,
                        UInt16(min(max(columns, 1), Int(UInt16.max))),
                        UInt16(min(max(rows, 1), Int(UInt16.max))),
                        &child,
                        &master,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
        }

        guard result == 0 else {
            let message = String(cString: errorBuffer)
            throw TerminalPTYError.spawnFailed(message.isEmpty ? "forkpty failed" : message)
        }

        runningPID = child
        paused = false
        masterDescriptor = master
        exitHandler = onExit
        didFinish = false
        installReadSource(onData: onData)
        return child
    }

    public func resize(columns: Int, rows: Int) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let masterFileDescriptor, let childPID else {
            throw TerminalPTYError.notRunning
        }
        guard aura_terminal_pty_resize(
            masterFileDescriptor,
            childPID,
            UInt16(min(max(columns, 1), Int(UInt16.max))),
            UInt16(min(max(rows, 1), Int(UInt16.max)))
        ) == 0 else {
            throw TerminalPTYError.resizeFailed
        }
    }

    public func setPaused(_ paused: Bool) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let childPID else { throw TerminalPTYError.notRunning }
        guard paused != isPaused else { return }
        let signalNumber = paused ? SIGSTOP : SIGCONT
        let result = aura_terminal_pty_terminate(childPID, signalNumber)
        guard result == 0 || errno == ESRCH else {
            throw TerminalPTYError.pauseFailed
        }
        self.paused = paused
    }

    public func writeInput(_ data: Data) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let descriptor = masterDescriptor, !didFinish else { throw TerminalPTYError.notRunning }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw TerminalPTYError.inputWriteFailed }
            }
        }
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        readSource?.cancel()
        readSource = nil
        if let childPID {
            if isPaused {
                _ = aura_terminal_pty_terminate(childPID, SIGCONT)
            }
            _ = aura_terminal_pty_terminate(childPID, SIGTERM)
            var status: Int32 = 0
            var reaped = false
            for _ in 0..<20 {
                let result = waitpid(childPID, &status, WNOHANG)
                if result == childPID || (result == -1 && errno == ECHILD) {
                    reaped = true
                    break
                }
                usleep(50_000)
            }
            if !reaped {
                _ = aura_terminal_pty_terminate(childPID, SIGKILL)
                // Reaping must never hold the UI/shutdown queue indefinitely.
                DispatchQueue.global(qos: .utility).async {
                    var exitStatus: Int32 = 0
                    _ = waitpid(childPID, &exitStatus, 0)
                }
            }
        }
        masterDescriptor = nil
        runningPID = nil
        paused = false
        exitHandler = nil
        didFinish = true
    }

    private func installReadSource(onData: @escaping DataHandler) {
        guard let masterFileDescriptor else { return }
        let sourceGeneration = generation
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // Bound each drain so stop/resize can acquire the state lock even
            // if a child produces bytes faster than they can be consumed.
            for _ in 0..<16 {
                self.stateLock.lock()
                defer { self.stateLock.unlock() }
                guard self.generation == sourceGeneration, !self.didFinish else { return }
                let count = read(masterFileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    onData(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    self.finish(status: 0)
                }
                break
            }
        }
        source.setCancelHandler {
            // The source owns this exact descriptor. Never close a new
            // session's descriptor or close the old one twice after reuse.
            _ = aura_terminal_pty_close(masterFileDescriptor)
        }
        source.resume()
        readSource = source
    }

    private func finish(status: Int32) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        readSource?.cancel()
        readSource = nil
        let callback = exitHandler
        exitHandler = nil
        if let childPID {
            DispatchQueue.global(qos: .utility).async {
                var childStatus: Int32 = 0
                _ = waitpid(childPID, &childStatus, 0)
            }
        }
        masterDescriptor = nil
        runningPID = nil
        paused = false
        callback?(status)
    }

    private func nulSeparatedBlob(_ values: [String]) -> Data {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data
    }

    private func resolveExecutable(for command: TerminalCommandConfiguration, environment: [String: String]) throws -> String {
        if let catalogItemID = command.catalogItemID,
           let catalogItem = TerminalWallpaperCatalog.item(id: catalogItemID) {
            // The app may have found a reviewed command in a user package
            // directory or via Spotlight. Keep that verified absolute path,
            // while rejecting unrelated executable hints under a catalog ID.
            let value = command.executable
            let name = URL(fileURLWithPath: value).lastPathComponent
            let names = catalogItem.executableCandidates.map { URL(fileURLWithPath: $0).lastPathComponent }
            if value.hasPrefix("/"), names.contains(name),
               let executable = TerminalExecutableLocator.resolve(value, environment: environment) {
                return executable
            }
            if let executable = catalogItem.resolvedExecutable(environment: environment) {
                return executable
            }
            throw TerminalPTYError.executableNotFound(catalogItem.title)
        }
        let value = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TerminalPTYError.invalidCommand }
        if value.lowercased().hasSuffix(".app") {
            throw TerminalPTYError.guiApplicationNotSupported
        }
        guard let executable = TerminalExecutableLocator.resolve(value, environment: environment) else {
            throw TerminalPTYError.executableNotFound(value)
        }
        return executable
    }
}

public enum TerminalPTYError: LocalizedError, Equatable {
    case invalidCommand
    case executableNotFound(String)
    case spawnFailed(String)
    case guiApplicationNotSupported
    case notRunning
    case resizeFailed
    case pauseFailed
    case inputWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "Enter an executable command."
        case .executableNotFound(let path):
            return "Executable not found or not executable: \(path)"
        case .spawnFailed(let message):
            return "Could not start terminal process: \(message)"
        case .guiApplicationNotSupported:
            return "A GUI .app cannot be rendered as a terminal wallpaper. Choose a command-line executable or TUI app."
        case .notRunning:
            return "Terminal process is not running."
        case .resizeFailed:
            return "Could not resize the terminal PTY."
        case .pauseFailed:
            return "Could not pause or resume the terminal process."
        case .inputWriteFailed:
            return "Could not send the native speed key to the terminal process."
        }
    }
}
