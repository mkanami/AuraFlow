import Foundation
import Testing
@testable import AuraWallpaperCore

private enum AutostartTestFailure: Error {
    case unexpectedError(Error)
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
