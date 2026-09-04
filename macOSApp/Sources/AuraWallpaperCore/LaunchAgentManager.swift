import Darwin
import Foundation

/// Owns LaunchAgent plist generation and launchctl orchestration.
///
/// `WallpaperRuntimeStore` supplies the durable config/PID facade and keeps
/// the existing public API. This component owns the state transition around
/// bootout, plist replacement, bootstrap, and rollback.
public final class LaunchAgentManager {
    private static let label = "com.andrijvergeles.auraflow"

    private let store: WallpaperRuntimeStore
    private let launchAgentURL: URL
    private let launchctlRunner: LaunchctlRunner
    private let launchAgentFileRemover: (URL) throws -> Void
    private let launchAgentFileWriter: (Data, URL) throws -> Void

    public init(
        store: WallpaperRuntimeStore,
        launchAgentURL: URL? = nil,
        launchctlRunner: LaunchctlRunner? = nil,
        launchAgentFileRemover: ((URL) throws -> Void)? = nil,
        launchAgentFileWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.store = store
        self.launchAgentURL = launchAgentURL ?? store.launchAgentURL
        self.launchctlRunner = launchctlRunner ?? Self.executeLaunchctl
        self.launchAgentFileRemover = launchAgentFileRemover ?? {
            try FileManager.default.removeItem(at: $0)
        }
        self.launchAgentFileWriter = launchAgentFileWriter ?? { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    public func launchAgentPlistExists() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func launchAgentStatus() -> LaunchAgentStatus {
        let plistExists = launchAgentPlistExists()
        let result = launchctlRunner(["print", serviceName])
        let serviceLoaded = result.succeeded
        let serviceRunning = serviceLoaded
            && result.output
                .split(whereSeparator: \.isNewline)
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "state = running" {
                        return true
                    }
                    guard trimmed.hasPrefix("pid = "),
                          let pid = Int(
                              trimmed.dropFirst("pid = ".count)
                                  .trimmingCharacters(in: .whitespaces)
                          )
                    else {
                        return false
                    }
                    return pid > 0
                }
        return LaunchAgentStatus(
            plistExists: plistExists,
            serviceLoaded: serviceLoaded,
            serviceRunning: serviceRunning
        )
    }

    public func launchAgentEnabled() -> Bool {
        launchAgentStatus().enabled
    }

    public func enableLaunchAgent(
        helperPath: String,
        nativeBridgePath: String? = nil
    ) throws {
        try store.ensureDirectories()
        let expectedArguments = launchAgentProgramArguments(
            helperPath: helperPath,
            configPath: store.configURL.path,
            nativeBridgePath: nativeBridgePath
        )
        let expectedPlist = try launchAgentPlistData(
            programArguments: expectedArguments
        )
        let previousPlistExists = launchAgentPlistExists()
        let previousPlistData = try? Data(contentsOf: launchAgentURL)
        let currentPlistMatches = launchAgentPlistMatches(
            expectedProgramArguments: expectedArguments
        )
        let currentLaunchAgent = launchAgentStatus()
        let previousServiceLoaded = currentLaunchAgent.serviceLoaded

        // An unchanged plist and a loaded service need no migration. This is
        // the common path during every normal GUI launch and avoids restarting
        // playback merely because the controller was reconstructed.
        if currentPlistMatches,
           currentLaunchAgent.enabled {
            return
        }

        if !currentPlistMatches || currentLaunchAgent.serviceLoaded {
            let previousPID = store.loadPID()
            let bootout = launchctlRunner(["bootout", serviceName])
            guard bootout.succeeded || bootout.isServiceNotLoaded else {
                throw WallpaperRuntimeError.unavailable(
                    "Could not stop the existing AuraFlow LaunchAgent: \(bootout.output)"
                )
            }
            do {
                if let previousPID,
                   !DaemonProcessManager.waitForExit(pid: previousPID, timeout: 2.0) {
                    // launchctl normally waits for the job, but older agents can
                    // delay their termination handler. Never bootstrap a new job
                    // while the old process can still mutate shared runtime files.
                    guard DaemonProcessManager(
                        store: store,
                        expectedExecutableURL: URL(fileURLWithPath: helperPath)
                    ).terminate(timeout: 1.0).succeeded,
                    DaemonProcessManager.waitForExit(pid: previousPID, timeout: 1.0)
                    else {
                        throw WallpaperRuntimeError.unavailable(
                            "The existing AuraFlow wallpaper agent did not stop during migration."
                        )
                    }
                }
                try launchAgentFileWriter(expectedPlist, launchAgentURL)
                try bootstrapExpectedLaunchAgent()
            } catch let primaryError {
                throw rollbackEnableFailure(
                    primaryError: primaryError,
                    previousPlistData: previousPlistData,
                    previousPlistExists: previousPlistExists,
                    previousServiceLoaded: previousServiceLoaded
                )
            }
            return
        }

        do {
            try launchAgentFileWriter(expectedPlist, launchAgentURL)
            try bootstrapExpectedLaunchAgent()
        } catch let primaryError {
            throw rollbackEnableFailure(
                primaryError: primaryError,
                previousPlistData: previousPlistData,
                previousPlistExists: previousPlistExists,
                previousServiceLoaded: previousServiceLoaded
            )
        }
    }

    public func disableLaunchAgent() throws {
        let previousPlistData = try? Data(contentsOf: launchAgentURL)
        let bootout = launchctlRunner(["bootout", serviceName])
        guard bootout.succeeded || bootout.isServiceNotLoaded else {
            throw WallpaperRuntimeError.unavailable(
                "Could not unload the AuraFlow LaunchAgent: \(bootout.output)"
            )
        }
        do {
            try launchAgentFileRemover(launchAgentURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            var rollbackFailures: [String] = []
            if let previousPlistData {
                do {
                    try launchAgentFileWriter(previousPlistData, launchAgentURL)
                } catch {
                    rollbackFailures.append(
                        "restore plist: \(error.localizedDescription)"
                    )
                }
            } else {
                rollbackFailures.append(
                    "restore plist: previous plist could not be read"
                )
            }

            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                let restoreBootstrap = launchctlRunner([
                    "bootstrap",
                    "gui/\(getuid())",
                    launchAgentURL.path
                ])
                if !restoreBootstrap.succeeded {
                    rollbackFailures.append(
                        "restore LaunchAgent: \(restoreBootstrap.output)"
                    )
                }
            } else {
                rollbackFailures.append("restore LaunchAgent: plist is missing")
            }

            throw WallpaperRuntimeError.launchAgentDisableFailed(
                removalError: error.localizedDescription,
                rollbackFailures: rollbackFailures
            )
        }
    }

    private func bootstrapExpectedLaunchAgent() throws {
        let bootstrap = launchctlRunner([
            "bootstrap",
            "gui/\(getuid())",
            launchAgentURL.path
        ])
        guard bootstrap.succeeded else {
            throw LaunchAgentManagerError.bootstrapFailed(output: bootstrap.output)
        }
    }

    private func rollbackEnableFailure(
        primaryError: Error,
        previousPlistData: Data?,
        previousPlistExists: Bool,
        previousServiceLoaded: Bool
    ) -> WallpaperRuntimeError {
        let rollbackFailures = restorePreviousLaunchAgent(
            previousPlistData: previousPlistData,
            previousPlistExists: previousPlistExists,
            previousServiceLoaded: previousServiceLoaded
        )
        let rollbackDescription = rollbackFailures.isEmpty
            ? ""
            : "; rollback failed: " + rollbackFailures.joined(separator: "; ")

        return .unavailable(
            "Could not start the AuraFlow LaunchAgent: "
                + primaryError.localizedDescription
                + rollbackDescription
        )
    }

    private func restorePreviousLaunchAgent(
        previousPlistData: Data?,
        previousPlistExists: Bool,
        previousServiceLoaded: Bool
    ) -> [String] {
        var rollbackFailures: [String] = []
        var plistRestored = false

        if let previousPlistData {
            do {
                try launchAgentFileWriter(previousPlistData, launchAgentURL)
                plistRestored = true
            } catch {
                rollbackFailures.append(
                    "restore plist: \(error.localizedDescription)"
                )
            }
        } else if previousPlistExists {
            rollbackFailures.append("restore plist: previous plist could not be read")
        } else {
            do {
                try launchAgentFileRemover(launchAgentURL)
            } catch CocoaError.fileNoSuchFile {
                // The failed write did not leave a plist behind.
            } catch {
                rollbackFailures.append(
                    "remove failed plist: \(error.localizedDescription)"
                )
            }
        }

        guard previousServiceLoaded else {
            return rollbackFailures
        }

        guard plistRestored else {
            rollbackFailures.append("restore LaunchAgent: plist could not be restored")
            return rollbackFailures
        }

        let restoreBootstrap = launchctlRunner([
            "bootstrap",
            "gui/\(getuid())",
            launchAgentURL.path
        ])
        if !restoreBootstrap.succeeded {
            rollbackFailures.append(
                "restore LaunchAgent: \(restoreBootstrap.output)"
            )
        }
        return rollbackFailures
    }

    private var serviceName: String {
        "gui/\(getuid())/\(Self.label)"
    }

    private func launchAgentProgramArguments(
        helperPath: String,
        configPath: String,
        nativeBridgePath: String?
    ) -> [String] {
        var arguments = [helperPath, "--config", configPath]
        if let nativeBridgePath {
            arguments.append(contentsOf: ["--native-bridge-path", nativeBridgePath])
        }
        return arguments
    }

    private func launchAgentPlistData(programArguments: [String]) throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private func launchAgentPlistMatches(
        expectedProgramArguments: [String]
    ) -> Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              plist["Label"] as? String == Self.label,
              plist["ProgramArguments"] as? [String] == expectedProgramArguments,
              plist["RunAtLoad"] as? Bool == true,
              plist["KeepAlive"] as? Bool == false
        else {
            return false
        }
        return true
    }

    static func executeLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile()
                    + errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return LaunchctlResult(
                succeeded: task.terminationStatus == 0,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                terminationStatus: task.terminationStatus
            )
        } catch {
            return LaunchctlResult(
                succeeded: false,
                output: error.localizedDescription,
                terminationStatus: -1
            )
        }
    }
}

private enum LaunchAgentManagerError: LocalizedError {
    case bootstrapFailed(output: String)

    var errorDescription: String? {
        switch self {
        case let .bootstrapFailed(output):
            output.isEmpty ? "launchctl bootstrap failed." : output
        }
    }
}
