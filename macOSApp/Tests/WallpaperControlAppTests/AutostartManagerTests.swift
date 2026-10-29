import Foundation
import Testing
@testable import AuraWallpaperCore

private enum AutostartTestFailure: Error {
    case unexpectedError(Error)
}

@Test func loginPreferenceSurvivesWaitingAndMissingLaunchServices() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutostartIntent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var loaded = false
    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { _ in LaunchctlResult(succeeded: loaded, output: "state = waiting") })
    var config = store.loadConfig(); config.autostart = true
    try store.saveConfig(config)
    #expect(store.status().autostart == true)
    #expect(store.status().autostart_service_loaded == false)
    loaded = true
    #expect(store.status().autostart == true)
    #expect(store.status().autostart_service_running == false)
    #expect(store.loadConfig().autostart == true)
}

@Test func savedAutostartRepairsMissingRegistrationWithoutChangingPreference() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutostartMissing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var calls: [[String]] = []
    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            calls.append(arguments)
            return LaunchctlResult(succeeded: arguments.first != "print", output: "")
        })
    try store.ensureDirectories()
    let video = root.appendingPathComponent("wallpaper.mp4")
    try Data("video".utf8).write(to: video)
    try store.saveConfig(ControlConfig(video_path: video.path, playback_speed: 1, autostart: true))
    try AutostartManager(store: store, helperURL: root.appendingPathComponent("AuraWallpaperAgent"))
        .migrateExistingLaunchAgentIfNeeded()
    #expect(store.launchAgentPlistExists())
    #expect(calls.contains { $0.first == "bootstrap" })
    #expect(store.loadConfig().autostart == true)
}

@Test func autostartMigrationIgnoresForeignPIDLeftByPreviousBoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutostartStalePID-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            if arguments.first == "print" { return LaunchctlResult(succeeded: false, output: "not loaded") }
            return LaunchctlResult(succeeded: true)
        })
    try store.ensureDirectories()
    // This process is alive, but has neither Aura's executable nor its saved
    // start-time identity. It must not block migration of the login service.
    try String(getpid()).write(to: store.pidURL, atomically: true, encoding: .utf8)
    try store.enableLaunchAgent(helperPath: root.appendingPathComponent("AuraWallpaperAgent").path)
    #expect(store.launchAgentPlistExists())
}

@Test func replacingHelperForcesLoginJobRestartEvenWhileOldPIDIsBeingReaped() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutostartReplacement-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var calls: [[String]] = []
    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            calls.append(arguments)
            return LaunchctlResult(succeeded: true, output: "state = running\n    pid =   123  ")
        })
    let helper = root.appendingPathComponent("AuraWallpaperAgent").path
    try store.enableLaunchAgent(helperPath: helper)
    #expect(store.launchAgentStatus().pid == 123)
    calls.removeAll()
    try store.enableLaunchAgent(helperPath: helper, restartLoadedService: true)
    #expect(calls == [["print", "gui/\(getuid())/com.andrijvergeles.auraflow"],
        ["kickstart", "-k", "gui/\(getuid())/com.andrijvergeles.auraflow"]])
}

private func makeConfigDirectoryUnavailable(_ appSupportURL: URL) {
    try? FileManager.default.removeItem(at: appSupportURL)
    FileManager.default.createFile(atPath: appSupportURL.path, contents: Data("blocked".utf8))
}

@Test func enableRollbackFailureIncludesPrimaryAndRollbackErrors() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowAutostartEnableRollback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let appSupportURL = root.appendingPathComponent("Support", isDirectory: true)
    let launchAgentURL = root.appendingPathComponent("LaunchAgents/agent.plist")
    var bootstrapFailed = false
    let store = WallpaperRuntimeStore(
        appSupportURL: appSupportURL,
        launchAgentURL: launchAgentURL,
        launchctlRunner: { arguments in
            if arguments.first == "bootstrap" {
                bootstrapFailed = true
                makeConfigDirectoryUnavailable(appSupportURL)
                return LaunchctlResult(
                    succeeded: false,
                    output: "bootstrap denied",
                    terminationStatus: 1
                )
            }
            return LaunchctlResult(succeeded: true)
        }
    )
    try store.ensureDirectories()
    let videoURL = root.appendingPathComponent("wallpaper.mp4")
    FileManager.default.createFile(atPath: videoURL.path, contents: Data("video".utf8))
    try store.saveConfig(
        ControlConfig(
            video_path: videoURL.path,
            playback_speed: 1.0,
            autostart: false
        )
    )

    let manager = AutostartManager(
        store: store,
        helperURL: root.appendingPathComponent("AuraWallpaperAgent")
    )

    do {
        try manager.setEnabled(true)
        Issue.record("Expected enable to fail")
    } catch let error as AutostartManagerError {
        guard case let .configurationRollbackFailed(
            operation,
            primaryError,
            rollbackError
        ) = error else {
            Issue.record("Expected a configuration rollback failure")
            return
        }
        #expect(bootstrapFailed)
        #expect(operation == .enable)
        #expect(primaryError.localizedDescription.contains("bootstrap denied"))
        #expect(!rollbackError.localizedDescription.isEmpty)
        #expect(error.localizedDescription.contains("rollback failed"))
        #expect(error.localizedDescription.contains("bootstrap denied"))
    } catch {
        throw AutostartTestFailure.unexpectedError(error)
    }
}

@Test func disableRollbackFailureIncludesPrimaryAndRollbackErrors() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowAutostartDisableRollback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let appSupportURL = root.appendingPathComponent("Support", isDirectory: true)
    let launchAgentURL = root.appendingPathComponent("LaunchAgents/agent.plist")
    var bootoutFailed = false
    let store = WallpaperRuntimeStore(
        appSupportURL: appSupportURL,
        launchAgentURL: launchAgentURL,
        launchctlRunner: { arguments in
            if arguments.first == "bootout" {
                bootoutFailed = true
                makeConfigDirectoryUnavailable(appSupportURL)
                return LaunchctlResult(
                    succeeded: false,
                    output: "bootout denied",
                    terminationStatus: 1
                )
            }
            return LaunchctlResult(succeeded: true)
        }
    )
    try store.ensureDirectories()
    let videoURL = root.appendingPathComponent("wallpaper.mp4")
    FileManager.default.createFile(atPath: videoURL.path, contents: Data("video".utf8))
    try store.saveConfig(
        ControlConfig(
            video_path: videoURL.path,
            playback_speed: 1.0,
            autostart: true
        )
    )

    let manager = AutostartManager(
        store: store,
        helperURL: root.appendingPathComponent("AuraWallpaperAgent")
    )

    do {
        try manager.setEnabled(false)
        Issue.record("Expected disable to fail")
    } catch let error as AutostartManagerError {
        guard case let .configurationRollbackFailed(
            operation,
            primaryError,
            rollbackError
        ) = error else {
            Issue.record("Expected a configuration rollback failure")
            return
        }
        #expect(bootoutFailed)
        #expect(operation == .disable)
        #expect(primaryError.localizedDescription.contains("bootout denied"))
        #expect(!rollbackError.localizedDescription.isEmpty)
        #expect(error.localizedDescription.contains("rollback failed"))
        #expect(error.localizedDescription.contains("bootout denied"))
    } catch {
        throw AutostartTestFailure.unexpectedError(error)
    }
}
