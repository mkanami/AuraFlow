import Darwin
import Foundation

/// An installation owns its process group, including download/build children.
/// Cancellation is scoped to that group; draining and cleanup stay off-main.
final class TerminalInstallCommandOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var child: pid_t = 0
    private var cancelled = false

    func run(executable: String, arguments: [String], environment: [String: String]) async throws -> (code: Int32, output: String) {
        try await withCheckedThrowingContinuation { completion in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let pipe = Pipe()
                var actions: posix_spawn_file_actions_t?
                var attributes: posix_spawnattr_t?
                posix_spawn_file_actions_init(&actions)
                posix_spawnattr_init(&attributes)
                defer {
                    posix_spawn_file_actions_destroy(&actions)
                    posix_spawnattr_destroy(&attributes)
                    try? pipe.fileHandleForReading.close()
                }
                posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
                posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
                posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
                posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
                posix_spawnattr_setpgroup(&attributes, 0)
                let argv = ([executable] + arguments).map { strdup($0) } + [nil]
                let envp = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                    .map { strdup("\($0.key)=\($0.value)") } + [nil]
                defer { for pointer in argv + envp { free(pointer) } }
                var pid: pid_t = 0
                lock.lock()
                if cancelled {
                    lock.unlock()
                    try? pipe.fileHandleForWriting.close()
                    completion.resume(throwing: CancellationError())
                    return
                }
                let result = argv.withUnsafeBufferPointer { args in
                    envp.withUnsafeBufferPointer { env in
                        posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
                    }
                }
                if result == 0 { child = pid }
                lock.unlock()
                try? pipe.fileHandleForWriting.close()
                guard result == 0 else {
                    completion.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(result)))
                    return
                }
                var output = Data()
                while true {
                    let bytes = pipe.fileHandleForReading.readData(ofLength: 4096)
                    if bytes.isEmpty { break }
                    output.append(bytes)
                    if output.count > 16_384 { output = output.suffix(16_384) }
                }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
                lock.lock()
                child = 0
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { completion.resume(throwing: CancellationError()) }
                else {
                    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    completion.resume(returning: (code, String(decoding: output, as: UTF8.self)))
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pid = child
        if pid > 0 { kill(-pid, SIGINT) }
        lock.unlock()
        guard pid > 0 else { return }
        for (delay, signal) in [(0.5, SIGTERM), (1.0, SIGKILL)] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if child == pid { kill(-pid, signal) }
            }
        }
    }
}
