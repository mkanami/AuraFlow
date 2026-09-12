import Darwin
import Foundation
import Security

/// Errors produced while asking a running native bridge to describe its
/// runtime capabilities. This probe is deliberately synchronous and bounded:
/// it is used only during the small startup preflight, never for wallpaper
/// operations. The bridge itself remains responsible for the async JSON
/// transport used by the wallpaper agent.
public enum NativeLockScreenBridgeRuntimeProbeError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed(String)
    case writeFailed(String)
    case timedOut
    case processExited(String)
    case invalidResponse(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not launch native bridge: \(reason)"
        case .writeFailed(let reason):
            return "Could not send native bridge capability request: \(reason)"
        case .timedOut:
            return "Native bridge capability handshake timed out."
        case .processExited(let diagnostics):
            if diagnostics.isEmpty {
                return "Native bridge exited before completing its capability handshake."
            }
            return "Native bridge exited before completing its capability handshake: \(diagnostics)"
        case .invalidResponse(let reason):
            return "Native bridge returned an invalid capability response: \(reason)"
        case .rejected(let reason):
            return "Native bridge rejected its capability handshake: \(reason)"
        }
    }
}

public enum NativeLockScreenBridgeCodeSignatureVerifier {
    /// Checks the code object itself rather than trusting that the bridge
    /// merely managed to launch. Ad-hoc signatures are accepted for local
    /// development; release packaging still applies its Developer ID policy.
    public static func isValid(at executableURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
    }
}

public enum NativeLockScreenBridgeRuntimeProbe {
    public static let defaultTimeout: TimeInterval = 1.5
    private static let maxResponseSize = 64 * 1024

    public static func verify(
        executableURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) throws -> NativeLockScreenBridgeRuntimeCapabilities {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw NativeLockScreenBridgeRuntimeProbeError.launchFailed(
                error.localizedDescription
            )
        }

        defer {
            terminate(process)
        }

        let request = NativeLockScreenBridgeRequest(action: .capabilities)
        do {
            var requestData = try JSONEncoder().encode(request)
            requestData.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: requestData)
        } catch {
            throw NativeLockScreenBridgeRuntimeProbeError.writeFailed(
                error.localizedDescription
            )
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var responseBuffer = Data()
        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor

        while Date() < deadline {
            let remainingMilliseconds = max(
                1,
                Int((deadline.timeIntervalSinceNow * 1_000).rounded(.up))
            )
            var descriptor = pollfd(
                fd: outputDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = withUnsafeMutablePointer(to: &descriptor) {
                Darwin.poll($0, 1, Int32(remainingMilliseconds))
            }

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw NativeLockScreenBridgeRuntimeProbeError.invalidResponse(
                    "poll failed with errno \(errno)."
                )
            }
            if pollResult == 0 {
                throw NativeLockScreenBridgeRuntimeProbeError.timedOut
            }

            let data = outputPipe.fileHandleForReading.availableData
            guard !data.isEmpty else {
                throw NativeLockScreenBridgeRuntimeProbeError.processExited(
                    diagnostics(from: errorPipe)
                )
            }
            guard responseBuffer.count <= Self.maxResponseSize - data.count else {
                throw NativeLockScreenBridgeRuntimeProbeError.invalidResponse(
                    "capability response exceeded \(Self.maxResponseSize) bytes."
                )
            }
            responseBuffer.append(data)

            while let newline = responseBuffer.firstIndex(of: 0x0A) {
                let line = responseBuffer.prefix(upTo: newline)
                responseBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }

                let response: NativeLockScreenBridgeResponse
                do {
                    response = try JSONDecoder().decode(
                        NativeLockScreenBridgeResponse.self,
                        from: line
                    )
                } catch {
                    throw NativeLockScreenBridgeRuntimeProbeError.invalidResponse(
                        error.localizedDescription
                    )
                }

                guard response.id == request.id,
                      response.action == .capabilities
                else {
                    throw NativeLockScreenBridgeRuntimeProbeError.invalidResponse(
                        "response id or action did not match the request."
                    )
                }
                guard response.succeeded else {
                    throw NativeLockScreenBridgeRuntimeProbeError.rejected(
                        response.errorDescription ?? "unknown reason"
                    )
                }
                guard let capabilities = response.capabilities else {
                    throw NativeLockScreenBridgeRuntimeProbeError.invalidResponse(
                        "capability payload is missing."
                    )
                }
                guard capabilities.isCompatible else {
                    throw NativeLockScreenBridgeRuntimeProbeError.rejected(
                        "reported capabilities are incompatible with this client."
                    )
                }
                return capabilities
            }
        }

        throw NativeLockScreenBridgeRuntimeProbeError.timedOut
    }

    private static func diagnostics(from errorPipe: Pipe) -> String {
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
