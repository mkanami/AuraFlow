import AuraTerminalPTYKit
import Foundation

public final class TerminalPTYSession {
    public typealias DataHandler = (Data) -> Void
    public typealias ExitHandler = (Int32) -> Void

    public private(set) var childPID: pid_t?
    public private(set) var masterFileDescriptor: Int32?

    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-pty", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var exitHandler: ExitHandler?
    private var didFinish = false

    public init() {}

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
        stop()
        let executable = try resolveExecutable(for: command)
        let arguments = [executable] + command.arguments
        let environment = mergedEnvironment(command.environment, columns: columns, rows: rows)
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

        childPID = child
        masterFileDescriptor = master
        exitHandler = onExit
        didFinish = false
        installReadSource(onData: onData)
        return child
    }

    public func resize(columns: Int, rows: Int) throws {
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

    public func stop() {
        readSource?.cancel()
        readSource = nil
        if let childPID {
            _ = aura_terminal_pty_terminate(childPID, SIGTERM)
            var status: Int32 = 0
            var reaped = false
            for _ in 0..<20 {
                if waitpid(childPID, &status, WNOHANG) == childPID {
                    reaped = true
                    break
                }
                usleep(50_000)
            }
            if !reaped {
                _ = aura_terminal_pty_terminate(childPID, SIGKILL)
                _ = waitpid(childPID, &status, 0)
            }
        }
        if let masterFileDescriptor {
            _ = aura_terminal_pty_close(masterFileDescriptor)
        }
        self.masterFileDescriptor = nil
        self.childPID = nil
        exitHandler = nil
        didFinish = true
    }

    private func installReadSource(onData: @escaping DataHandler) {
        guard let masterFileDescriptor else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
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
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if let masterFileDescriptor = self.masterFileDescriptor {
                _ = aura_terminal_pty_close(masterFileDescriptor)
            }
        }
        source.resume()
        readSource = source
    }

    private func finish(status: Int32) {
        guard !didFinish else { return }
        didFinish = true
        readSource?.cancel()
        readSource = nil
        let callback = exitHandler
        exitHandler = nil
        if let childPID {
            var childStatus: Int32 = 0
            _ = waitpid(childPID, &childStatus, 0)
        }
        if let masterFileDescriptor {
            _ = aura_terminal_pty_close(masterFileDescriptor)
        }
        self.masterFileDescriptor = nil
        self.childPID = nil
        callback?(status)
    }

    private func mergedEnvironment(_ overrides: [String: String], columns: Int, rows: Int) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["COLUMNS"] = String(columns)
        environment["LINES"] = String(rows)
        environment["AURAFLOW_TERMINAL_WALLPAPER"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private func nulSeparatedBlob(_ values: [String]) -> Data {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data
    }

    private func resolveExecutable(for command: TerminalCommandConfiguration) throws -> String {
        if let catalogItemID = command.catalogItemID,
           let catalogItem = TerminalWallpaperCatalog.item(id: catalogItemID) {
            if let executable = catalogItem.resolvedExecutable() {
                return executable
            }
            throw TerminalPTYError.executableNotFound(catalogItem.title)
        }
        let value = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TerminalPTYError.invalidCommand }
        if value.lowercased().hasSuffix(".app") {
            throw TerminalPTYError.guiApplicationNotSupported
        }
        guard let executable = TerminalExecutableLocator.resolve(value) else {
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
        }
    }
}
