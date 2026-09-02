import Foundation
import Testing
@testable import WallpaperControlApp

private struct NativeRuntimeFixture {
    let root: URL
    let store: WallpaperRuntimeStore
    let helperURL: URL
    let videoURL: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowNativeRuntimeTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WallpaperRuntimeStore(
            appSupportURL: root.appendingPathComponent("Support", isDirectory: true),
            launchAgentURL: root.appendingPathComponent("LaunchAgents/com.andrijvergeles.auraflow.plist")
        )
        try store.ensureDirectories()

        helperURL = root.appendingPathComponent("mock-agent.sh")
        let script = """
        #!/bin/sh
        while true; do
          sleep 1
        done
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        videoURL = root.appendingPathComponent("wallpaper.png")
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
                + "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        FileManager.default.createFile(
            atPath: videoURL.path,
            contents: png,
            attributes: nil
        )
    }

    func cleanup() {
        store.disableLaunchAgent()
        _ = store.terminateDaemon(timeout: 0.2)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestInstallerError: Error {
    case installFailed
    case uninstallFailed
}

private final class RecordingLockScreenSaverInstaller: LockScreenSaverInstalling {
    var capabilities: PlatformCapabilities {
        // These controller tests exercise the dedicated native route. The
        // production legacy adapter advertises this capability as unavailable.
        .modernMacOS26(isAvailable: true)
    }
    private(set) var installedVideoURL: URL?
    private(set) var installedLockScreenOnlyVideoURL: URL?
    private(set) var uninstallCallCount = 0
    private(set) var preservingUninstallCallCount = 0
    var installError: TestInstallerError?
    var uninstallError: TestInstallerError?

    var isInstalled: Bool {
        (installedVideoURL != nil || installedLockScreenOnlyVideoURL != nil)
            && uninstallCallCount == 0
    }

    func install(videoURL: URL) throws {
        if let installError {
            throw installError
        }
        installedVideoURL = videoURL
    }

    func installLockScreenOnly(videoURL: URL) throws {
        if let installError {
            throw installError
        }
        installedLockScreenOnlyVideoURL = videoURL
    }

    func uninstall() throws {
        if let uninstallError {
            throw uninstallError
        }
        uninstallCallCount += 1
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        if let uninstallError {
            throw uninstallError
        }
        preservingUninstallCallCount += 1
        uninstallCallCount += 1
    }
}

@Test func nativeStatusWithoutHelperReportsUnavailable() throws {
    let fixture = try NativeRuntimeFixture("status")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let status = try controller.status()

    #expect(status.running == false)
    #expect(status.pid == nil)
    #expect(status.health?.available == false)
}

@Test func nativeStartWritesConfigAndLaunchesMockHelper() throws {
    let fixture = try NativeRuntimeFixture("start")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let status = try controller.start(videoURL: fixture.videoURL, speed: 1.75)
    let config = fixture.store.loadConfig()
    let command = fixture.store.loadCommand()

    #expect(config.video_path == fixture.videoURL.path)
    #expect(config.playback_speed == 1.75)
    #expect(config.show_on_lock_screen == true)
    #expect(status.pid != nil)
    #expect(fixture.store.processIsAlive(pid: status.pid))
    #expect(command?.action == .reload)
    #expect(command?.operationID == 1)
    #expect(command?.config?.video_path == fixture.videoURL.path)
    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(installer.installedLockScreenOnlyVideoURL == nil)
}

@Test func runtimeCommandDecodesLegacyPayloadWithoutOperationID() throws {
    let data = Data(
        """
        {"id":"legacy","action":"pause","created_at":1}
        """.utf8
    )
    let command = try JSONDecoder().decode(
        WallpaperRuntimeCommand.self,
        from: data
    )
    #expect(command.operationID == nil)
    #expect(command.action == .pause)
}

@Test func nativeLockScreenOnlyDoesNotChangeDesktopOrLaunchAgent() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-only")
    defer { fixture.cleanup() }

    let desktopURL = fixture.root.appendingPathComponent("desktop.mp4")
    FileManager.default.createFile(
        atPath: desktopURL.path,
        contents: Data([1, 2, 3, 4]),
        attributes: nil
    )
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: desktopURL.path,
            playback_speed: 1.0
        )
    )

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    let status = try controller.installLockScreenOnly(videoURL: fixture.videoURL)
    let config = fixture.store.loadConfig()

    #expect(status.running == false)
    #expect(status.pid == nil)
    #expect(config.video_path == desktopURL.path)
    #expect(config.show_on_lock_screen == true)
    #expect(installer.installedVideoURL == nil)
    #expect(installer.installedLockScreenOnlyVideoURL == fixture.videoURL)
    #expect(fixture.store.loadLockScreenOnlySource() == fixture.videoURL.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: fixture.store.lastFrameURL.path))
}

@Test func failedLockScreenOnlyInstallPreservesPreviousSource() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-only-install-failure")
    defer { fixture.cleanup() }

    let previousSource = fixture.root.appendingPathComponent("previous.mp4")
    try fixture.store.saveLockScreenOnlySource(previousSource)

    let installer = RecordingLockScreenSaverInstaller()
    installer.installError = .installFailed
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    #expect(throws: TestInstallerError.self) {
        try controller.installLockScreenOnly(videoURL: fixture.videoURL)
    }
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == previousSource.standardizedFileURL
    )
    #expect(installer.installedLockScreenOnlyVideoURL == nil)
}

@Test func failedLockScreenUninstallPreservesSource() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-uninstall-failure")
    defer { fixture.cleanup() }

    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let installer = RecordingLockScreenSaverInstaller()
    try installer.installLockScreenOnly(videoURL: fixture.videoURL)
    installer.uninstallError = .uninstallFailed
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    #expect(throws: TestInstallerError.self) {
        try controller.setShowOnLockScreen(false)
    }
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == fixture.videoURL.standardizedFileURL
    )
    #expect(installer.isInstalled)
}

@Test func legacyScreenSaverDoesNotLaunchLockScreenOnlyAgent() throws {
    let fixture = try NativeRuntimeFixture("legacy-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let legacyPlatform = LegacyMacOSAdapter(
        installer: installer,
        isAvailable: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: legacyPlatform
    )

    #expect(legacyPlatform.capabilities.supportsLockScreenOnly == false)
    #expect(throws: NativeWallpaperControllerError.self) {
        try controller.installLockScreenOnly(videoURL: fixture.videoURL)
    }
    #expect(fixture.store.loadPID() == nil)
    #expect(installer.installedLockScreenOnlyVideoURL == nil)
}

@Test func legacySyncMigratesLockOnlySourceIntoMainConfig() throws {
    let fixture = try NativeRuntimeFixture("legacy-sync-lock-only-migration")
    defer { fixture.cleanup() }

    let desktopURL = fixture.root.appendingPathComponent("desktop.mp4")
    try Data([1, 2, 3]).write(to: desktopURL)
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: desktopURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)

    let installer = RecordingLockScreenSaverInstaller()
    let legacyPlatform = LegacyMacOSAdapter(
        installer: installer,
        isAvailable: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: legacyPlatform
    )

    try controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
    #expect(fixture.store.loadLockScreenOnlySource() == nil)

    try controller.syncLockScreenSaver()
    #expect(installer.installedVideoURL == fixture.videoURL)
}

@Test func legacySyncStopsLockOnlyAgentAndClearsRuntimeState() throws {
    let fixture = try NativeRuntimeFixture("legacy-sync-lock-only-agent")
    defer { fixture.cleanup() }

    let desktopURL = fixture.root.appendingPathComponent("desktop.mp4")
    try Data([7, 8, 9]).write(to: desktopURL)
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: desktopURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)

    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)
    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .reload))
    try fixture.store.saveHealth(
        DaemonHealth(available: true, fresh: true, suspicious: false)
    )

    let installer = RecordingLockScreenSaverInstaller()
    let legacyPlatform = LegacyMacOSAdapter(
        installer: installer,
        isAvailable: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: legacyPlatform
    )

    try controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadHealth() == nil)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}

@Test func syncCleansLockOnlyAgentWhenSourceIsMissing() throws {
    let fixture = try NativeRuntimeFixture("sync-missing-lock-only-source")
    defer { fixture.cleanup() }

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(
        fixture.root.appendingPathComponent("missing.mp4")
    )

    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)
    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .reload))
    try fixture.store.saveHealth(
        DaemonHealth(available: true, fresh: true, suspicious: false)
    )

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )

    try controller.syncLockScreenSaver()

    #expect(fixture.store.loadLockScreenOnlySource() == nil)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadHealth() == nil)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}

@Test func enablingLockScreenOnLegacyPlatformMigratesLockOnlySource() throws {
    let fixture = try NativeRuntimeFixture("legacy-enable-lock-only-migration")
    defer { fixture.cleanup() }

    let desktopURL = fixture.root.appendingPathComponent("desktop.mp4")
    try Data([4, 5, 6]).write(to: desktopURL)
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: desktopURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: false
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    try Data("{}".utf8).write(to: fixture.store.appSupportURL
        .appendingPathComponent("wallpaper_backup.json"))

    let installer = RecordingLockScreenSaverInstaller()
    let legacyPlatform = LegacyMacOSAdapter(
        installer: installer,
        isAvailable: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: legacyPlatform
    )

    _ = try controller.setShowOnLockScreen(true)

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
    #expect(fixture.store.loadLockScreenOnlySource() == nil)
}

@Test func nativeLockScreenOnlyReplacesRunningDesktopAgent() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-only-running")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    let desktopAgent = Process()
    desktopAgent.executableURL = fixture.helperURL
    try desktopAgent.run()
    try fixture.store.savePID(desktopAgent.processIdentifier)
    let desktopAgentPID = fixture.store.loadPID()
    #expect(desktopAgentPID != nil)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)

    _ = try controller.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.store.isLockScreenOnlyAgent())
    #expect(fixture.store.loadPID() != desktopAgentPID)
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()))
}

@Test func nativeSetSpeedAndScaleUpdateConfigAndCommand() throws {
    let fixture = try NativeRuntimeFixture("settings")
    defer { fixture.cleanup() }

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    _ = try controller.start(videoURL: fixture.videoURL, speed: 1.0)
    _ = try controller.setSpeed(2.25)
    _ = try controller.setScaleMode(.fit)
    let config = fixture.store.loadConfig()
    let command = fixture.store.loadCommand()

    #expect(config.playback_speed == 2.25)
    #expect(config.scale_mode == WallpaperScaleMode.fit.rawValue)
    #expect(command?.action == .update)
    #expect(command?.config?.scale_mode == WallpaperScaleMode.fit.rawValue)
}

@Test func nativeStopPausesButClearTerminatesHelper() throws {
    let fixture = try NativeRuntimeFixture("stop-clear")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let started = try controller.start(videoURL: fixture.videoURL, speed: 1.0)
    #expect(fixture.store.processIsAlive(pid: started.pid))

    let stopped = try controller.stop()
    #expect(stopped.paused == true)
    #expect(fixture.store.loadCommand()?.action == .pause)

    let cleared = try controller.clearWallpaper()
    #expect(cleared.running == false)
    #expect(cleared.wallpaper_restored != nil)
    #expect(fixture.store.processIsAlive(pid: started.pid) == false)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadConfig().video_path.isEmpty)
    #expect(
        fixture.store.loadConfig().show_on_lock_screen == true
    )
}

@Test func nativeStopPausesLockScreenOnlyWithoutUninstalling() throws {
    let fixture = try NativeRuntimeFixture("stop-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let stopped = try controller.stop()

    #expect(stopped.running == false)
    #expect(stopped.paused == true)
    #expect(fixture.store.loadCommand()?.action == .pause)
    #expect(installer.uninstallCallCount == 0)
    #expect(installer.isInstalled)
    #expect(
        fixture.store.processIsAlive(pid: Int(agent.processIdentifier))
    )
}

@Test func nativeStopIsNoOpForStaticLockScreenWallpaper() throws {
    let fixture = try NativeRuntimeFixture("stop-static-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let stopped = try controller.stop()

    #expect(stopped.paused == false)
    #expect(fixture.store.loadCommand() == nil)
    #expect(installer.uninstallCallCount == 0)
    #expect(installer.isInstalled)
}

@Test func nativeLockScreenOnlyRemoveDiscardsOldDesktopBackup() throws {
    let fixture = try NativeRuntimeFixture("remove-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try installer.installLockScreenOnly(videoURL: fixture.videoURL)
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let oldDesktopURL = fixture.root.appendingPathComponent("old.jpg")
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: oldDesktopURL)
    let backupURL = fixture.store.appSupportURL
        .appendingPathComponent("wallpaper_backup.json")
    let backupData = try JSONSerialization.data(
        withJSONObject: ["display": oldDesktopURL.path]
    )
    try backupData.write(to: backupURL)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    let removed = try controller.clearWallpaper()

    #expect(removed.wallpaper_restored == false)
    #expect(installer.uninstallCallCount == 1)
    #expect(installer.preservingUninstallCallCount == 1)
    #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    #expect(FileManager.default.fileExists(atPath: oldDesktopURL.path))
}

@Test func nativeStartIgnoresStaleTerminateCommandFromPreviousClear() throws {
    let fixture = try NativeRuntimeFixture("stale-terminate")
    defer { fixture.cleanup() }

    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .terminate))

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    let status = try controller.start(videoURL: fixture.videoURL, speed: 1.0)

    #expect(status.running)
    #expect(status.paused == false)
    #expect(status.pid != nil)
    #expect(fixture.store.processIsAlive(pid: status.pid))
    #expect(fixture.store.loadCommand()?.action == .reload)
}

@Test func nativeAutostartPlistPointsToSwiftHelper() throws {
    let fixture = try NativeRuntimeFixture("autostart")
    defer { fixture.cleanup() }

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            volume: 0,
            autostart: false
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    _ = try controller.setAutostart(true)
    let plist = try String(contentsOf: fixture.store.launchAgentURL, encoding: .utf8)

    #expect(plist.contains(fixture.helperURL.path))
    #expect(plist.contains("--config"))
    #expect(plist.contains(fixture.store.configURL.path))
}

@Test func nativeLockScreenSettingInstallsSaverAndSendsPreviewCommands() throws {
    let fixture = try NativeRuntimeFixture("lock-screen")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.start(videoURL: fixture.videoURL, speed: 1.0)
    _ = try controller.setScaleMode(.fit)
    let videoAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.videoURL.path
    )
    let videoSize = try #require(
        videoAttributes[.size] as? NSNumber
    )
    let videoModifiedAt = try #require(
        videoAttributes[.modificationDate] as? Date
    )
    FileManager.default.createFile(
        atPath: fixture.store.lastFrameURL.path,
        contents: Data([0x89, 0x50, 0x4E, 0x47]),
        attributes: nil
    )
    let lastFrameSource = try JSONSerialization.data(
        withJSONObject: [
            "path": fixture.videoURL.standardizedFileURL.path,
            "size": videoSize.uint64Value,
            "modifiedAt": videoModifiedAt.timeIntervalSince1970,
        ],
        options: []
    )
    try lastFrameSource.write(
        to: fixture.store.lastFrameSourceURL,
        options: .atomic
    )
    _ = try controller.setShowOnLockScreen(true)

    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().scale_mode == WallpaperScaleMode.fit.rawValue)
    #expect(fixture.store.loadCommand()?.action == .update)

    _ = try controller.beginLockScreenPreview()
    #expect(fixture.store.loadCommand()?.action == .previewLock)

    _ = try controller.endLockScreenPreview()
    #expect(fixture.store.loadCommand()?.action == .previewUnlock)

    _ = try controller.clearWallpaper()
    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(fixture.store.loadConfig().video_path.isEmpty)
    #expect(installer.uninstallCallCount == 1)
}

@Test func nativeLockScreenPreferenceCanWaitForASelectedWallpaper() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-pending")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.setShowOnLockScreen(true)

    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(installer.installedVideoURL == nil)
}

@Test func nativeLockScreenSyncIgnoresAnEmptyOrMissingSource() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-empty-sync")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == nil)
}

@Test func runtimeNormalizationDefaultsLegacyLockScreenSettingToEnabled() throws {
    let fixture = try NativeRuntimeFixture("legacy-lock-default")
    defer { fixture.cleanup() }

    let legacyJSON = """
    {
      "video_path": "\(fixture.videoURL.path)",
      "playback_speed": 1.0,
      "pause_on_fullscreen": true,
      "scale_mode": "fill"
    }
    """
    try Data(legacyJSON.utf8).write(
        to: fixture.store.configURL,
        options: .atomic
    )

    let config = fixture.store.loadConfig()
    #expect(config.show_on_lock_screen == true)
}

@Test func legacyRemoveStateKeepsLockScreenEnabledForNextWallpaper() throws {
    let fixture = try NativeRuntimeFixture("legacy-remove-lock-default")
    defer { fixture.cleanup() }

    let legacyJSON = """
    {
      "video_path": "",
      "playback_speed": 1.0,
      "pause_on_fullscreen": true,
      "show_on_lock_screen": false,
      "scale_mode": "fill"
    }
    """
    try Data(legacyJSON.utf8).write(
        to: fixture.store.configURL,
        options: .atomic
    )

    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
}

@Test func currentLockScreenOnlyConfigMigratesToDesktopSource() throws {
    let fixture = try NativeRuntimeFixture("config-migration")
    defer { fixture.cleanup() }

    let legacyConfig: [String: Any] = [
        "video_path": "",
        "lock_screen_path": fixture.videoURL.path,
        "lock_screen_runtime_path": fixture.videoURL.path,
        "playback_speed": 1.0,
        "volume": 0.0,
        "autostart": false,
        "blend_interpolation": false,
        "pause_on_fullscreen": true,
        "show_on_lock_screen": true,
        "lock_screen_preference_configured": true,
        "scale_mode": "fill"
    ]
    let data = try JSONSerialization.data(withJSONObject: legacyConfig)
    try data.write(to: fixture.store.configURL, options: .atomic)

    let config = fixture.store.loadConfig()
    #expect(config.video_path == fixture.videoURL.path)

    let encoded = try JSONEncoder().encode(config)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["lock_screen_path"] == nil)
    #expect(object["lock_screen_runtime_path"] == nil)
    #expect(object["lock_screen_preference_configured"] == nil)
}

@Test func nativeStatusJSONKeepsLegacyContractShape() throws {
    let payload = ControlStatus(
        running: true,
        config: ControlConfig(
            video_path: "/tmp/wallpaper.mp4",
            playback_speed: 1.2,
            volume: 0,
            autostart: true,
            blend_interpolation: false,
            pause_on_fullscreen: true,
            scale_mode: "fill"
        ),
        pid: 42,
        autostart: true,
        paused: false,
        health: DaemonHealth(available: true, fresh: true, suspicious: false, reason: "ok")
    )

    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require(object["config"] as? [String: Any])
    let decoded = try JSONDecoder().decode(ControlStatus.self, from: data)

    #expect(object["contract_version"] as? Int == 3)
    #expect(config["video_path"] as? String == "/tmp/wallpaper.mp4")
    #expect(config["playback_speed"] as? Double == 1.2)
    #expect(decoded.health?.reason == "ok")
}

@Test func wallpaperBackupSkipsManagedLastFrameAndWritesCurrentEntries() throws {
    let fixture = try NativeRuntimeFixture("backup-files")
    defer { fixture.cleanup() }

    let appSupportPath = fixture.store.appSupportURL.path
    let managedPath = fixture.store.lastFrameURL.path
    let latestWallpaperURL = fixture.root.appendingPathComponent("latest-desktop.jpg")
    FileManager.default.createFile(atPath: latestWallpaperURL.path, contents: Data([1, 2, 3]), attributes: nil)

    let saved = WallpaperDesktopSupport.saveWallpaperBackup(
        appSupportPath: appSupportPath,
        wallpapers: [
            "screen-a": managedPath,
            "screen-b": latestWallpaperURL.path
        ]
    )

    #expect(saved)
    let laterWallpaperURL = fixture.root
        .appendingPathComponent("later-desktop.jpg")
    FileManager.default.createFile(
        atPath: laterWallpaperURL.path,
        contents: Data([4, 5, 6]),
        attributes: nil
    )
    #expect(
        WallpaperDesktopSupport.saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: ["screen-b": laterWallpaperURL.path]
        )
    )

    let backupURL = fixture.store.appSupportURL.appendingPathComponent("wallpaper_backup.json")
    let legacyBackupURL = fixture.store.appSupportURL.appendingPathComponent("wallpaper_backup_original.json")
    let backupData = try Data(contentsOf: backupURL)
    let legacyData = try Data(contentsOf: legacyBackupURL)
    let backup = try #require(JSONSerialization.jsonObject(with: backupData) as? [String: String])
    let legacyBackup = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: String])

    #expect(backup["screen-a"] == nil)
    #expect(backup["screen-b"] == latestWallpaperURL.standardizedFileURL.path)
    #expect(legacyBackup == backup)
}
