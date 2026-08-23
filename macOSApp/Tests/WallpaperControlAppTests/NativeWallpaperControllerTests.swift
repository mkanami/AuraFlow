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

        videoURL = root.appendingPathComponent("wallpaper.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: Data([0, 0, 0, 0]), attributes: nil)
    }

    func cleanup() {
        store.disableLaunchAgent()
        _ = store.terminateDaemon(timeout: 0.2)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingLockScreenSaverInstaller: LockScreenSaverInstalling {
    private(set) var installedVideoURL: URL?
    private(set) var uninstallCallCount = 0

    var isInstalled: Bool {
        installedVideoURL != nil && uninstallCallCount == 0
    }

    func install(videoURL: URL) throws {
        installedVideoURL = videoURL
    }

    func uninstall() throws {
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

@Test func nativeStartWritesConfigAndLaunchesMockHelperWithoutLockScreen() throws {
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
    #expect(status.pid != nil)
    #expect(fixture.store.processIsAlive(pid: status.pid))
    #expect(command?.action == .reload)
    #expect(command?.config?.video_path == fixture.videoURL.path)
    #expect(config.show_on_lock_screen == false)
    #expect(installer.installedVideoURL == nil)
}

@Test func nativeStartInstallsEnabledLockScreenWithoutChangingPreference() throws {
    let fixture = try NativeRuntimeFixture("start-with-lock-screen")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: true,
            lock_screen_preference_configured: true
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.start(videoURL: fixture.videoURL, speed: 1.0)

    let config = fixture.store.loadConfig()
    #expect(config.show_on_lock_screen == true)
    #expect(installer.installedVideoURL == fixture.videoURL)
}

@Test func lockScreenFallbackFrameReplacesDesktopAndPreservesIdle() throws {
    let originalDesktop: [String: Any] = [
        "LastSet": Date(timeIntervalSince1970: 1),
        "Content": [
            "Choices": [[
                "Provider": "com.apple.wallpaper.choice.sequoia",
                "Files": [],
            ]],
        ],
    ]
    let originalIdle: [String: Any] = [
        "LastSet": Date(timeIntervalSince1970: 1),
        "Content": [
            "Choices": [[
                "Provider": "com.apple.wallpaper.choice.aerials",
                "Files": [],
            ]],
        ],
    ]
    let store: [String: Any] = [
        "AllSpacesAndDisplays": [
            "Type": "individual",
            "Desktop": originalDesktop,
            "Idle": originalIdle,
        ],
        "SystemDefault": [
            "Type": "individual",
            "Desktop": originalDesktop,
            "Idle": originalIdle,
        ],
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: store,
        format: .binary,
        options: 0
    )
    let framePath = "/Users/test/Library/Application Support/AuraFlow/last_frame.png"
    let transformedData = try #require(
        WallpaperDesktopSupport.wallpaperStoreDataWithLockScreenFallbackFrame(
            data: data,
            imagePath: framePath,
            date: Date(timeIntervalSince1970: 2)
        )
    )
    let transformed = try #require(
        PropertyListSerialization.propertyList(
            from: transformedData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    let allSpaces = try #require(
        transformed["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktop = try #require(allSpaces["Desktop"] as? [String: Any])
    let idle = try #require(allSpaces["Idle"] as? [String: Any])
    let desktopContent = try #require(desktop["Content"] as? [String: Any])
    let desktopChoices = try #require(
        desktopContent["Choices"] as? [[String: Any]]
    )
    let desktopProvider = desktopChoices.first?["Provider"] as? String
    #expect(desktopProvider == "com.apple.wallpaper.choice.image")
    #expect(
        String(describing: desktop).contains("last_frame.png")
    )
    let idleContent = try #require(idle["Content"] as? [String: Any])
    let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
    let idleProvider = idleChoices.first?["Provider"] as? String
    #expect(idleProvider == "com.apple.wallpaper.choice.aerials")
}

@Test func removeRestoresExternalImageToDesktopAndIdleTogether() throws {
    let managedDesktop: [String: Any] = [
        "Content": [
            "Choices": [[
                "Provider": "com.apple.wallpaper.choice.image",
                "Files": [[
                    "relative": "file:///Users/test/AuraFlow/last_frame.png",
                ]],
            ]],
        ],
    ]
    let staleIdle: [String: Any] = [
        "Content": [
            "Choices": [[
                "Provider": "com.apple.wallpaper.choice.screen-saver",
                "Files": [],
            ]],
        ],
    ]
    let store: [String: Any] = [
        "AllSpacesAndDisplays": [
            "Desktop": managedDesktop,
            "Idle": staleIdle,
        ],
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: store,
        format: .binary,
        options: 0
    )
    let restoredData = try #require(
        WallpaperDesktopSupport.wallpaperStoreDataWithRestoredImage(
            data: data,
            imagePath: "/Users/test/Pictures/user-wallpaper.jpg",
            date: Date(timeIntervalSince1970: 3)
        )
    )
    let restored = try #require(
        PropertyListSerialization.propertyList(
            from: restoredData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    let allSpaces = try #require(
        restored["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktop = try #require(allSpaces["Desktop"] as? [String: Any])
    let idle = try #require(allSpaces["Idle"] as? [String: Any])
    #expect(String(describing: desktop).contains("user-wallpaper.jpg"))
    #expect(String(describing: idle).contains("user-wallpaper.jpg"))
    #expect(String(describing: restored).contains("last_frame") == false)
}

@Test func nativeSetSpeedAndScaleUpdateConfigAndCommand() throws {
    let fixture = try NativeRuntimeFixture("settings")
    defer { fixture.cleanup() }

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller:
            RecordingLockScreenSaverInstaller()
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
        fixture.store.loadConfig().show_on_lock_screen == false
    )
}

@Test func damagedWallpaperBackupReturnsFalse() throws {
    let fixture = try NativeRuntimeFixture("damaged-backup")
    defer { fixture.cleanup() }

    let backupURL = fixture.store.appSupportURL
        .appendingPathComponent("wallpaper_backup.json")
    try Data("not-json".utf8).write(to: backupURL, options: .atomic)

    #expect(fixture.store.restoreWallpaperBackup() == false)
}

@Test func missingWallpaperBackupReturnsFalse() throws {
    let fixture = try NativeRuntimeFixture("missing-backup")
    defer { fixture.cleanup() }

    #expect(fixture.store.restoreWallpaperBackup() == false)
}

@Test func enablingLockScreenWithoutWallpaperPersistsPreferenceForNextStart() throws {
    let fixture = try NativeRuntimeFixture("lock-preference-before-start")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    let status = try controller.setShowOnLockScreen(true)
    let config = fixture.store.loadConfig()

    #expect(status.config.show_on_lock_screen == true)
    #expect(config.show_on_lock_screen == true)
    #expect(config.lock_screen_preference_configured == true)
    #expect(installer.installedVideoURL == nil)
}

@Test func interruptedRemovalBackupIsRecoveredOnNextControllerLaunch() throws {
    let fixture = try NativeRuntimeFixture("interrupted-removal")
    defer { fixture.cleanup() }

    let baselineURL = fixture.root.appendingPathComponent("baseline.jpg")
    FileManager.default.createFile(
        atPath: baselineURL.path,
        contents: Data([13, 14, 15]),
        attributes: nil
    )
    #expect(WallpaperDesktopSupport.saveWallpaperBackup(
        appSupportPath: fixture.store.appSupportURL.path,
        wallpapers: ["screen-a": baselineURL.path]
    ))
    try fixture.store.saveConfig(ControlConfig(
        video_path: "",
        playback_speed: 1,
        show_on_lock_screen: false,
        lock_screen_preference_configured: true
    ))

    _ = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )

    #expect(!FileManager.default.fileExists(
        atPath: fixture.store.appSupportURL
            .appendingPathComponent("wallpaper_backup.json").path
    ))
}

@Test func nativeStartIgnoresStaleTerminateCommandFromPreviousClear() throws {
    let fixture = try NativeRuntimeFixture("stale-terminate")
    defer { fixture.cleanup() }

    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .terminate))

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller:
            RecordingLockScreenSaverInstaller()
    )
    let status = try controller.start(videoURL: fixture.videoURL, speed: 1.0)

    #expect(status.running)
    #expect(status.paused == false)
    #expect(status.pid != nil)
    #expect(fixture.store.processIsAlive(pid: status.pid))
    #expect(fixture.store.loadCommand()?.action == .reload)
}

@Test func nativeResumeDoesNotReinstallOrEnableLockScreen() throws {
    let fixture = try NativeRuntimeFixture("resume-lock-screen")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: false,
            lock_screen_preference_configured: true
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.resume()

    let config = fixture.store.loadConfig()
    #expect(config.show_on_lock_screen == false)
    #expect(installer.installedVideoURL == nil)
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
    let controller = try NativeWallpaperController(store: fixture.store, helperURL: fixture.helperURL)
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
    #expect(fixture.store.loadConfig().lock_screen_path == nil)
    #expect(installer.uninstallCallCount == 1)
}

@Test func lockScreenCanBeConfiguredWithoutTouchingDesktopSource() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-only")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.setLockScreenMedia(fixture.videoURL)

    let config = fixture.store.loadConfig()
    #expect(config.video_path.isEmpty)
    #expect(config.lock_screen_path == fixture.videoURL.standardizedFileURL.path)
    #expect(config.effectiveLockScreenPath == fixture.videoURL.standardizedFileURL.path)
    #expect(config.show_on_lock_screen == true)
    #expect(installer.installedVideoURL == fixture.videoURL)

    _ = try controller.clearWallpaper()
    let clearedConfig = fixture.store.loadConfig()
    #expect(clearedConfig.video_path.isEmpty)
    #expect(clearedConfig.lock_screen_path == nil)
    #expect(clearedConfig.show_on_lock_screen == true)
    #expect(installer.uninstallCallCount == 1)
}

@Test func desktopSourceIsAppliedImmediatelyWhenChosenForLockScreen() throws {
    let fixture = try NativeRuntimeFixture("lock-screen-desktop-source")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.start(videoURL: fixture.videoURL, speed: 1.0)
    _ = try controller.setLockScreenMedia(nil)

    let config = fixture.store.loadConfig()
    #expect(config.video_path == fixture.videoURL.path)
    #expect(config.lock_screen_path == nil)
    #expect(config.show_on_lock_screen == true)
    #expect(installer.installedVideoURL == fixture.videoURL)
}

@Test func realtimeDesktopChangeReplacesStaleDedicatedLockScreenSource() throws {
    let fixture = try NativeRuntimeFixture("realtime-lock-screen-sync")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let oldLockScreenURL = fixture.root.appendingPathComponent("old-lock-screen.mp4")
    let newDesktopURL = fixture.root.appendingPathComponent("new-desktop.mp4")
    FileManager.default.createFile(
        atPath: oldLockScreenURL.path,
        contents: Data([1, 2, 3]),
        attributes: nil
    )
    FileManager.default.createFile(
        atPath: newDesktopURL.path,
        contents: Data([4, 5, 6]),
        attributes: nil
    )

    _ = try controller.start(videoURL: fixture.videoURL, speed: 1.0)
    _ = try controller.setLockScreenMedia(oldLockScreenURL)
    _ = try controller.setVideo(newDesktopURL)

    let config = fixture.store.loadConfig()
    #expect(config.video_path == newDesktopURL.path)
    #expect(config.lock_screen_path == nil)
    #expect(config.lock_screen_runtime_path == nil)
    #expect(installer.installedVideoURL == newDesktopURL)
}

@Test func runtimeNormalizationKeepsLegacyLockScreenSettingDisabledUntilExplicitlyEnabled() throws {
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
    #expect(config.show_on_lock_screen == false)
    #expect(config.lock_screen_preference_configured == false)
}

@Test func legacyLockScreenDefaultRemainsDisabledOnNormalWallpaperStart() throws {
    let fixture = try NativeRuntimeFixture("legacy-lock-migration")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: false,
            lock_screen_preference_configured: nil
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.start(
        videoURL: fixture.videoURL,
        speed: 1.0
    )

    let config = fixture.store.loadConfig()
    #expect(config.show_on_lock_screen == false)
    #expect(installer.installedVideoURL == nil)
}

@Test func normalWallpaperStartPreservesSettingsOptOut() throws {
    let fixture = try NativeRuntimeFixture("lock-opt-out")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: false,
            lock_screen_preference_configured: true
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try controller.start(
        videoURL: fixture.videoURL,
        speed: 1.0
    )

    let config = fixture.store.loadConfig()
    #expect(config.show_on_lock_screen == false)
    #expect(installer.installedVideoURL == nil)
}

@Test func enabledLockPreferenceWithoutVideoDoesNotAttemptSync() throws {
    let fixture = try NativeRuntimeFixture("empty-lock-sync")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: true,
            lock_screen_preference_configured: true
        )
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    try controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == nil)
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

@Test func wallpaperBackupRefreshesToLatestExternalEntriesAndSkipsManagedLastFrame() throws {
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
    #expect(WallpaperDesktopSupport.saveWallpaperBackup(
        appSupportPath: appSupportPath,
        wallpapers: ["screen-b": laterWallpaperURL.path]
    ))

    let backupURL = fixture.store.appSupportURL.appendingPathComponent("wallpaper_backup.json")
    let legacyBackupURL = fixture.store.appSupportURL.appendingPathComponent("wallpaper_backup_original.json")
    let backupData = try Data(contentsOf: backupURL)
    let legacyData = try Data(contentsOf: legacyBackupURL)
    let backup = try #require(JSONSerialization.jsonObject(with: backupData) as? [String: String])
    let legacyBackup = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: String])

    #expect(backup["screen-a"] == nil)
    #expect(backup["screen-b"] == laterWallpaperURL.standardizedFileURL.path)
    #expect(legacyBackup == backup)

    for _ in 0..<1_000 {
        #expect(WallpaperDesktopSupport.saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: ["screen-b": latestWallpaperURL.path]
        ))
    }
    let repeatedData = try Data(contentsOf: backupURL)
    let repeatedBackup = try #require(
        JSONSerialization.jsonObject(with: repeatedData) as? [String: String]
    )
    #expect(repeatedBackup["screen-b"] == latestWallpaperURL.standardizedFileURL.path)
}

@Test func activeWallpaperSessionDoesNotReplaceItsBaselineFromCachedSystemState() throws {
    let fixture = try NativeRuntimeFixture("backup-session-baseline")
    defer { fixture.cleanup() }

    let baselineURL = fixture.root.appendingPathComponent("baseline.jpg")
    FileManager.default.createFile(
        atPath: baselineURL.path,
        contents: Data([7, 8, 9]),
        attributes: nil
    )
    let appSupportPath = fixture.store.appSupportURL.path
    #expect(WallpaperDesktopSupport.saveWallpaperBackup(
        appSupportPath: appSupportPath,
        wallpapers: ["screen-a": baselineURL.path]
    ))
    #expect(WallpaperDesktopSupport.beginWallpaperBackupSession(
        appSupportPath: appSupportPath
    ))

    #expect(WallpaperDesktopSupport.captureCurrentDesktopWallpaperBackup(
        appSupportPath: appSupportPath
    ))

    let backupURL = fixture.store.appSupportURL
        .appendingPathComponent("wallpaper_backup.json")
    let data = try Data(contentsOf: backupURL)
    let backup = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: String]
    )
    #expect(backup == ["screen-a": baselineURL.standardizedFileURL.path])
}

@Test func disablingLockScreenKeepsBackupForLaterRemove() throws {
    let fixture = try NativeRuntimeFixture("lock-toggle-keeps-backup")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let baselineURL = fixture.root.appendingPathComponent("baseline.jpg")
    FileManager.default.createFile(
        atPath: baselineURL.path,
        contents: Data([10, 11, 12]),
        attributes: nil
    )
    #expect(WallpaperDesktopSupport.saveWallpaperBackup(
        appSupportPath: fixture.store.appSupportURL.path,
        wallpapers: ["screen-a": baselineURL.path]
    ))
    try fixture.store.saveConfig(ControlConfig(
        video_path: fixture.videoURL.path,
        playback_speed: 1,
        show_on_lock_screen: true,
        lock_screen_preference_configured: true
    ))
    try installer.install(videoURL: fixture.videoURL)

    _ = try controller.setShowOnLockScreen(false)

    #expect(installer.uninstallCallCount == 1)
    #expect(FileManager.default.fileExists(
        atPath: fixture.store.appSupportURL
            .appendingPathComponent("wallpaper_backup.json").path
    ))
}
