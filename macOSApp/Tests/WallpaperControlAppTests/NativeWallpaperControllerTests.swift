import Darwin
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
            launchAgentURL: root.appendingPathComponent("LaunchAgents/com.andrijvergeles.auraflow.plist"),
            launchctlRunner: { _ in
                LaunchctlResult(succeeded: true)
            }
        )
        try store.ensureDirectories()

        helperURL = root.appendingPathComponent("mock-agent.sh")
        let script = """
        #!/bin/bash
        trap 'exit 0' TERM INT
        while :; do
            /bin/sleep 1 &
            child=$!
            wait "$child"
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
        let pid = store.loadPID()
        try? store.disableLaunchAgent()
        // Let the persisted process identity decide whether the PID belongs
        // to this fixture. The script may have exec'd its interpreter, so
        // comparing against the script path makes cleanup report a false
        // identity mismatch and leaks the helper into later tests.
        _ = store.terminateDaemon(timeout: 0.2)
        if let pid {
            reapTestChild(pid)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestInstallerError: Error {
    case installFailed
    case uninstallFailed
}

private final class RuntimeModernInstaller: ModernLockScreenInstalling {
    let isAvailable = true
    var isInstalled: Bool

    init(isInstalled: Bool) {
        self.isInstalled = isInstalled
    }

    func install(videoURL: URL) throws {
        isInstalled = true
    }

    func installLockScreenOnly(videoURL: URL) throws {
        isInstalled = true
    }

    func uninstall() throws {
        isInstalled = false
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        LockScreenOnlyGenerationStatus(
            installed: isInstalled,
            sourceMatches: isInstalled,
            assetValid: isInstalled,
            providerAvailable: isInstalled,
            providerRunning: isInstalled,
            wallpaperStoreValid: isInstalled,
            screenSaverSelected: isInstalled
        )
    }

    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        false
    }
}

private enum NativeTestAgentError: Error {
    case readinessHandshakeFailed
}

private func terminateAndReapTestAgent(_ agent: Process) {
    if agent.isRunning {
        kill(agent.processIdentifier, SIGKILL)
    }
    agent.waitUntilExit()
}

private func reapTestChild(_ pid: Int) {
    var status: Int32 = 0
    for _ in 0..<20 {
        let result = waitpid(pid_t(pid), &status, WNOHANG)
        if result == pid_t(pid) || result == -1 {
            return
        }
        usleep(50_000)
    }
}

private func launchReadyTestAgent() throws -> Process {
    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/bin/bash")
    agent.arguments = [
        "-c",
        "exec /usr/bin/tail -f /dev/null"
    ]
    agent.standardOutput = FileHandle.nullDevice
    agent.standardError = FileHandle.nullDevice
    try agent.run()

    var executablePath = [Int8](repeating: 0, count: 4_096)
    for _ in 0..<50 {
        let pathLength = proc_pidpath(
            agent.processIdentifier,
            &executablePath,
            UInt32(executablePath.count)
        )
        if pathLength > 0,
           String(cString: executablePath) == "/usr/bin/tail" {
            return agent
        }
        usleep(20_000)
    }
    terminateAndReapTestAgent(agent)
    throw NativeTestAgentError.readinessHandshakeFailed
}

private final class RecordingLockScreenSaverInstaller: LockScreenSaverInstalling {
    var requiresNativeBridge = false

    var capabilities: PlatformCapabilities {
        // Keep the recording adapter independent from the private framework.
        // The dedicated fail-closed test opts into the production capability
        // explicitly, without requiring every controller fixture to launch a
        // real macOS 26 bridge process.
        PlatformCapabilities(
            platformName: "macOS 26 test provider",
            minimumMajorOSVersion: 26,
            supportsLockScreen: true,
            supportsLockScreenOnly: true,
            supportsSecureLockScreen: true,
            supportsAnimatedMedia: true,
            usesPrivateWallpaperFramework: requiresNativeBridge,
            availabilityMessage: "Test Lock Screen provider"
        )
    }
    private(set) var installedVideoURL: URL?
    private(set) var installedLockScreenOnlyVideoURL: URL?
    private(set) var sourceAtInstall: URL?
    var sourceProviderAtInstall: (() -> URL?)?
    private(set) var uninstallCallCount = 0
    private(set) var preservingUninstallCallCount = 0
    var installError: TestInstallerError?
    var failNextDesktopInstall = false
    var uninstallError: TestInstallerError?
    var lockScreenOnlyStatusOverride: LockScreenOnlyGenerationStatus?

    var isInstalled: Bool {
        (installedVideoURL != nil || installedLockScreenOnlyVideoURL != nil)
            && uninstallCallCount == 0
    }

    func install(videoURL: URL) throws {
        sourceAtInstall = sourceProviderAtInstall?()
        if failNextDesktopInstall {
            failNextDesktopInstall = false
            throw TestInstallerError.installFailed
        }
        if let installError {
            throw installError
        }
        installedVideoURL = videoURL
    }

    func installLockScreenOnly(videoURL: URL) throws {
        sourceAtInstall = sourceProviderAtInstall?()
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

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        if let lockScreenOnlyStatusOverride {
            return lockScreenOnlyStatusOverride
        }
        let installed = isInstalled
        let sourceMatches = installedLockScreenOnlyVideoURL
            .map { $0.standardizedFileURL == videoURL?.standardizedFileURL }
            ?? false
        return LockScreenOnlyGenerationStatus(
            installed: installed,
            sourceMatches: sourceMatches,
            assetValid: installed,
            providerAvailable: installed,
            providerRunning: installed,
            wallpaperStoreValid: installed,
            screenSaverSelected: installed
        )
    }
}

@Test func nativeStatusWithoutHelperReportsUnavailable() async throws {
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

@Test func nativeLockScreenCapabilitiesFailClosedWithoutBridge() async throws {
    let fixture = try NativeRuntimeFixture("missing-native-bridge")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    installer.requiresNativeBridge = true
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer,
        nativeBridgeURL: fixture.root.appendingPathComponent(
            "missing-native-bridge"
        )
    )

    #expect(controller.lockScreenCapabilities.supportsLockScreen == false)
    #expect(controller.lockScreenCapabilities.supportsSecureLockScreen == false)
    await expectAsyncThrowing(NativeWallpaperControllerError.self) {
        try await controller.prepareLockScreenMedia(videoURL: fixture.videoURL)
    }
}

@Test func runtimeNativeBridgeFailureUsesLegacyFallback() async throws {
    let fixture = try NativeRuntimeFixture("native-bridge-runtime-failure")
    defer { fixture.cleanup() }

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)

    let modernInstaller = RuntimeModernInstaller(isInstalled: true)
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = RecordingLockScreenSaverInstaller()
    let adapter = WallpaperPlatformAdapter(
        modern: modern,
        legacy: LegacyMacOSAdapter(installer: legacyInstaller)
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: adapter,
        nativeBridgeURL: fixture.root.appendingPathComponent("bridge")
    )

    controller.markNativeLockScreenBridgeUnavailable(
        reason: "private provider ABI changed"
    )

    #expect(controller.lockScreenCapabilities.usesPrivateWallpaperFramework == false)
    #expect(
        controller.lockScreenCapabilities.availabilityMessage?
            .contains("became unavailable") == true
    )
    try await controller.syncLockScreenSaver()

    #expect(legacyInstaller.installedVideoURL == fixture.videoURL)
    #expect(modernInstaller.isInstalled == false)
    #expect(fixture.store.loadLockScreenOnlySource() == nil)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
}

@Test func terminateDaemonDoesNotSignalProcessWithMismatchedIdentity() async throws {
    let fixture = try NativeRuntimeFixture("pid-identity")
    defer { fixture.cleanup() }

    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    defer { terminateAndReapTestAgent(agent) }

    try fixture.store.savePID(agent.processIdentifier)
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.store.daemonIdentityURL.path
        )
    )

    let mismatchedIdentity = """
    {"executablePath":"/definitely/not/auraflow","startTimeMicros":1}
    """
    try Data(mismatchedIdentity.utf8).write(
        to: fixture.store.daemonIdentityURL,
        options: .atomic
    )

    let pid = Int(agent.processIdentifier)
    #expect(
        fixture.store.terminateDaemon(timeout: 0.2)
            == .identityMismatch
    )
    #expect(fixture.store.loadPID() == nil)
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.store.daemonIdentityURL.path
        ) == false
    )
    #expect(fixture.store.processIsAlive(pid: pid))
}

@Test func runtimeOwnershipRequiresMatchingProcessIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowRuntimeOwnership-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { _ in LaunchctlResult(succeeded: true) }
    )
    try store.ensureDirectories()
    try store.savePID()
    #expect(store.ownsRuntimeProcess())

    try Data("{\"executablePath\":\"/definitely/not/auraflow\",\"startTimeMicros\":1}".utf8)
        .write(to: store.daemonIdentityURL, options: .atomic)
    #expect(store.ownsRuntimeProcess() == false)
    store.removePID()
}

@Test func terminateDaemonStopsLegacyProcessByExpectedExecutablePath() async throws {
    let fixture = try NativeRuntimeFixture("legacy-pid-identity")
    defer { fixture.cleanup() }

    let shellURL = URL(fileURLWithPath: "/usr/bin/tail")
    let agent = try launchReadyTestAgent()
    defer {
        if agent.isRunning {
            kill(agent.processIdentifier, SIGKILL)
            agent.waitUntilExit()
        }
    }

    // launchReadyTestAgent() waits for the process to exec tail before
    // returning, so the identity fallback check does not depend on timing.
    var executablePath = [Int8](repeating: 0, count: 4_096)
    var pathLength: Int32 = 0
    for _ in 0..<50 {
        pathLength = proc_pidpath(
            agent.processIdentifier,
            &executablePath,
            UInt32(executablePath.count)
        )
        if pathLength > 0,
           String(cString: executablePath) == shellURL.path {
            break
        }
        usleep(20_000)
    }
    #expect(pathLength > 0)
    #expect(String(cString: executablePath) == shellURL.path)
    try fixture.store.savePID(agent.processIdentifier)
    try FileManager.default.removeItem(at: fixture.store.daemonIdentityURL)

    let pid = Int(agent.processIdentifier)
    let termination = fixture.store.terminateDaemon(
        timeout: 0.2,
        expectedExecutableURL: shellURL
    )
    // tail can exit between the verified identity check and the first
    // post-SIGTERM poll. Both outcomes prove that the expected process was
    // safely handled; the test must not depend on that tiny scheduling race.
    #expect(termination.succeeded)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.processIsAlive(pid: pid) == false)
}

@Test func nativeStartWritesConfigAndLaunchesMockHelper() async throws {
    let fixture = try NativeRuntimeFixture("start")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let status = try await controller.start(videoURL: fixture.videoURL, speed: 1.75)
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

@Test func runtimeCommandDecodesLegacyPayloadWithoutOperationID() async throws {
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

@Test func nativeLockScreenOnlyDoesNotChangeDesktopOrLaunchAgent() async throws {
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

    let status = try await controller.installLockScreenOnly(videoURL: fixture.videoURL)
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

@Test func failedLockScreenOnlyInstallPreservesPreviousSource() async throws {
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

    await expectAsyncThrowing(TestInstallerError.self) {
        _ = try await controller.installLockScreenOnly(videoURL: fixture.videoURL)
    }
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == previousSource.standardizedFileURL
    )
    #expect(installer.installedLockScreenOnlyVideoURL == nil)
}

@Test func failedLockScreenUninstallPreservesSource() async throws {
    let fixture = try NativeRuntimeFixture("lock-screen-uninstall-failure")
    defer { fixture.cleanup() }

    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let installer = RecordingLockScreenSaverInstaller()
    try await installer.installLockScreenOnly(videoURL: fixture.videoURL)
    installer.uninstallError = .uninstallFailed
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    await expectAsyncThrowing(TestInstallerError.self) {
        _ = try await controller.setShowOnLockScreen(false)
    }
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == fixture.videoURL.standardizedFileURL
    )
    #expect(installer.isInstalled)
}

@Test func failedClearRestartsPreviousLockScreenAgent() async throws {
    let fixture = try NativeRuntimeFixture("clear-lock-screen-rollback")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try await installer.installLockScreenOnly(videoURL: fixture.videoURL)
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: "",
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    fixture.store.markLockScreenOnlyAgent(true)
    let previousAgent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(previousAgent) }
    try fixture.store.savePID(previousAgent.processIdentifier)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let previousPID = Int(previousAgent.processIdentifier)
    #expect(fixture.store.processIsAlive(pid: previousPID))
    installer.uninstallError = .uninstallFailed

    await expectAsyncThrowing(TestInstallerError.self) {
        _ = try await controller.clearWallpaper()
    }

    let restoredPID = try #require(fixture.store.loadPID())
    #expect(restoredPID != previousPID)
    #expect(fixture.store.processIsAlive(pid: restoredPID))
    #expect(fixture.store.isLockScreenOnlyAgent())
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == fixture.videoURL.standardizedFileURL
    )
    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(fixture.store.loadCommand()?.action == .reload)
}

@Test func legacyScreenSaverAppliesLockScreenOnlyWithoutAgent() async throws {
    let fixture = try NativeRuntimeFixture("legacy-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    installer.sourceProviderAtInstall = {
        fixture.store.loadLockScreenOnlySource()
    }
    let legacyPlatform = LegacyMacOSAdapter(
        installer: installer,
        isAvailable: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: legacyPlatform
    )

    #expect(legacyPlatform.capabilities.supportsLockScreenOnly)
    let status = try await controller.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(status.running == false)
    #expect(status.lock_screen_only == true)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadLockScreenOnlySource() == fixture.videoURL.standardizedFileURL)
    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(installer.installedLockScreenOnlyVideoURL == nil)
    #expect(installer.sourceAtInstall == fixture.videoURL.standardizedFileURL)
}

@Test func legacySyncMigratesLockOnlySourceIntoMainConfig() async throws {
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

    try await controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
    #expect(fixture.store.loadLockScreenOnlySource() == nil)

    try await controller.syncLockScreenSaver()
    #expect(installer.installedVideoURL == fixture.videoURL)
}

@Test func legacySyncStopsLockOnlyAgentAndClearsRuntimeState() async throws {
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

    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    #expect(FileManager.default.fileExists(atPath: fixture.store.daemonIdentityURL.path))
    #expect(fixture.store.processIsAlive(pid: Int(agent.processIdentifier)))
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

    try await controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadHealth() == nil)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}

@Test func syncFallsBackWhenLockScreenAssetProviderIsUnavailable() async throws {
    let fixture = try NativeRuntimeFixture("sync-unavailable-lock-screen-asset")
    defer { fixture.cleanup() }

    let desktopURL = fixture.root.appendingPathComponent("desktop.mp4")
    try Data([2, 4, 6]).write(to: desktopURL)
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: desktopURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)

    let installer = RecordingLockScreenSaverInstaller()
    installer.lockScreenOnlyStatusOverride = LockScreenOnlyGenerationStatus(
        installed: true,
        sourceMatches: true,
        assetValid: true,
        providerAvailable: false,
        providerRunning: false,
        wallpaperStoreValid: true,
        screenSaverSelected: true
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    try await controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
    #expect(fixture.store.loadLockScreenOnlySource() == nil)
}

@Test func syncCleansLockOnlyAgentWhenSourceIsMissing() async throws {
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

    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    #expect(FileManager.default.fileExists(atPath: fixture.store.daemonIdentityURL.path))
    #expect(fixture.store.processIsAlive(pid: Int(agent.processIdentifier)))
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

    try await controller.syncLockScreenSaver()

    #expect(fixture.store.loadLockScreenOnlySource() == nil)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadHealth() == nil)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}

@Test func syncCleansLockOnlyAgentWhenLockScreenIsDisabled() async throws {
    let fixture = try NativeRuntimeFixture("sync-disabled-lock-screen")
    defer { fixture.cleanup() }

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: false
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)

    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
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

    try await controller.syncLockScreenSaver()

    #expect(fixture.store.loadLockScreenOnlySource() == nil)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)
    #expect(fixture.store.loadPID() == nil)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadHealth() == nil)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}

@Test func enablingLockScreenOnLegacyPlatformKeepsLockOnlySource() async throws {
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

    _ = try await controller.setShowOnLockScreen(true)

    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().video_path == desktopURL.path)
    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(
        fixture.store.loadLockScreenOnlySource()
            == fixture.videoURL.standardizedFileURL
    )
}

@Test func nativeLockScreenOnlyReplacesRunningDesktopAgent() async throws {
    let fixture = try NativeRuntimeFixture("lock-screen-only-running")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    let desktopAgent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(desktopAgent) }
    try fixture.store.savePID(desktopAgent.processIdentifier)
    let desktopAgentPID = fixture.store.loadPID()
    #expect(desktopAgentPID != nil)
    #expect(fixture.store.isLockScreenOnlyAgent() == false)

    _ = try await controller.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.store.isLockScreenOnlyAgent())
    #expect(fixture.store.loadPID() != desktopAgentPID)
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()))
}

@Test func nativeSetSpeedAndScaleUpdateConfigAndCommand() async throws {
    let fixture = try NativeRuntimeFixture("settings")
    defer { fixture.cleanup() }

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    _ = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)
    _ = try controller.setSpeed(2.25)
    _ = try controller.setScaleMode(.fit)
    let config = fixture.store.loadConfig()
    let command = fixture.store.loadCommand()

    #expect(config.playback_speed == 2.25)
    #expect(config.scale_mode == WallpaperScaleMode.fit.rawValue)
    #expect(command?.action == .update)
    #expect(command?.config?.scale_mode == WallpaperScaleMode.fit.rawValue)
}

@Test func nativeStopPausesButClearTerminatesHelper() async throws {
    let fixture = try NativeRuntimeFixture("stop-clear")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let started = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)
    #expect(fixture.store.processIsAlive(pid: started.pid))

    let stopped = try controller.stop()
    #expect(stopped.paused == true)
    #expect(fixture.store.loadCommand()?.action == .pause)

    let cleared = try await controller.clearWallpaper()
    #expect(cleared.running == false)
    #expect(cleared.wallpaper_restored != nil)
    #expect(fixture.store.processIsAlive(pid: started.pid) == false)
    #expect(fixture.store.loadCommand() == nil)
    #expect(fixture.store.loadConfig().video_path.isEmpty)
    #expect(
        fixture.store.loadConfig().show_on_lock_screen == true
    )
}

@Test func nativeStopPausesLockScreenOnlyWithoutUninstalling() async throws {
    let fixture = try NativeRuntimeFixture("stop-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try await installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    defer { terminateAndReapTestAgent(agent) }
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

@Test func nativeStopIsNoOpForStaticLockScreenWallpaper() async throws {
    let fixture = try NativeRuntimeFixture("stop-static-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try await installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let agent = Process()
    agent.executableURL = fixture.helperURL
    try agent.run()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let stopped = try controller.stop()

    #expect(stopped.paused == false)
    #expect(fixture.store.loadCommand() == nil)
    #expect(installer.uninstallCallCount == 0)
    #expect(installer.isInstalled)
}

@Test func nativeLockScreenOnlyRemoveDiscardsOldDesktopBackup() async throws {
    let fixture = try NativeRuntimeFixture("remove-lock-screen-only")
    defer { fixture.cleanup() }

    let installer = RecordingLockScreenSaverInstaller()
    try await installer.installLockScreenOnly(videoURL: fixture.videoURL)
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

    let removed = try await controller.clearWallpaper()

    #expect(removed.wallpaper_restored == false)
    #expect(installer.uninstallCallCount == 1)
    #expect(installer.preservingUninstallCallCount == 1)
    #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    #expect(FileManager.default.fileExists(atPath: oldDesktopURL.path))
}

@Test func nativeStartIgnoresStaleTerminateCommandFromPreviousClear() async throws {
    let fixture = try NativeRuntimeFixture("stale-terminate")
    defer { fixture.cleanup() }

    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .terminate))

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    let status = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)

    #expect(status.running)
    #expect(status.paused == false)
    #expect(status.pid != nil)
    #expect(fixture.store.processIsAlive(pid: status.pid))
    #expect(fixture.store.loadCommand()?.action == .reload)
}

@Test func nativeAutostartPlistPointsToSwiftHelper() async throws {
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

@Test func unchangedLaunchAgentDoesNotRestartLoadedService() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentNoOp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var launchctlCalls: [[String]] = []
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            launchctlCalls.append(arguments)
            return LaunchctlResult(succeeded: true, output: "state = running")
        }
    )

    try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
    launchctlCalls.removeAll()
    try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")

    #expect(launchctlCalls == [["print", "gui/\(getuid())/com.andrijvergeles.auraflow"]])
}

@Test func waitingLaunchAgentIsRebootstrapped() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentWaiting-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var launchctlCalls: [[String]] = []
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            launchctlCalls.append(arguments)
            if arguments.first == "print" {
                return LaunchctlResult(succeeded: true, output: "state = waiting")
            }
            return LaunchctlResult(succeeded: true)
        }
    )

    try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
    launchctlCalls.removeAll()
    try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")

    #expect(
        launchctlCalls == [
            ["print", "gui/\(getuid())/com.andrijvergeles.auraflow"],
            ["bootout", "gui/\(getuid())/com.andrijvergeles.auraflow"],
            ["bootstrap", "gui/\(getuid())", store.launchAgentURL.path]
        ]
    )
}

@Test func failedLaunchAgentRemovalRestoresAndReloadsService() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentRemovalFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var launchctlCalls: [[String]] = []
    let removalError = NSError(
        domain: "AuraFlowTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "permission denied"]
    )
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            launchctlCalls.append(arguments)
            return LaunchctlResult(succeeded: true)
        },
        launchAgentFileRemover: { _ in
            throw removalError
        }
    )
    try store.ensureDirectories()
    let previousPlist = Data("previous launch agent".utf8)
    try previousPlist.write(to: store.launchAgentURL, options: .atomic)

    do {
        try store.disableLaunchAgent()
        Issue.record("Expected LaunchAgent removal to fail")
    } catch {
        #expect(error.localizedDescription.contains("permission denied"))
        #expect(error.localizedDescription.contains("previous service restored"))
    }
    #expect(try Data(contentsOf: store.launchAgentURL) == previousPlist)
    #expect(
        launchctlCalls == [
            ["bootout", "gui/\(getuid())/com.andrijvergeles.auraflow"],
            ["bootstrap", "gui/\(getuid())", store.launchAgentURL.path]
        ]
    )
}

@Test func launchAgentRemovalRollbackFailureIncludesBothErrors() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentRemovalRollbackFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let removalError = NSError(
        domain: "AuraFlowTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "permission denied"]
    )
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            if arguments.first == "bootstrap" {
                return LaunchctlResult(
                    succeeded: false,
                    output: "bootstrap denied",
                    terminationStatus: 1
                )
            }
            return LaunchctlResult(succeeded: true)
        },
        launchAgentFileRemover: { _ in
            throw removalError
        }
    )
    try store.ensureDirectories()
    try Data("previous launch agent".utf8)
        .write(to: store.launchAgentURL, options: .atomic)

    do {
        try store.disableLaunchAgent()
        Issue.record("Expected LaunchAgent removal to fail")
    } catch {
        #expect(error.localizedDescription.contains("permission denied"))
        #expect(error.localizedDescription.contains("bootstrap denied"))
        #expect(error.localizedDescription.contains("rollback failed"))
    }
}

@Test func launchAgentBootstrapFailureIsSurfaced() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            if arguments.first == "bootstrap" {
                return LaunchctlResult(
                    succeeded: false,
                    output: "Operation not permitted",
                    terminationStatus: 1
                )
            }
            return LaunchctlResult(succeeded: true)
        }
    )

    #expect(throws: WallpaperRuntimeError.self) {
        try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
    }
    #expect(FileManager.default.fileExists(atPath: store.launchAgentURL.path) == false)
}

@Test func launchAgentBootstrapFailureRestoresAndReloadsPreviousService() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentRollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var bootstrapCount = 0
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            if arguments.first == "bootstrap" {
                bootstrapCount += 1
                return LaunchctlResult(
                    succeeded: bootstrapCount > 1,
                    output: bootstrapCount > 1 ? "restored" : "new bootstrap failed",
                    terminationStatus: bootstrapCount > 1 ? 0 : 1
                )
            }
            return LaunchctlResult(succeeded: true)
        }
    )
    try store.ensureDirectories()
    let previousPlist = Data("previous launch agent".utf8)
    try previousPlist.write(to: store.launchAgentURL, options: .atomic)

    #expect(throws: WallpaperRuntimeError.self) {
        try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
    }
    #expect(bootstrapCount == 2)
    #expect(try Data(contentsOf: store.launchAgentURL) == previousPlist)
}

@Test func launchAgentWriteFailureRestoresAndReloadsPreviousService() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentWriteRollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let launchAgentURL = root.appendingPathComponent("LaunchAgents/agent.plist")
    var launchctlCalls: [[String]] = []
    let runner: LaunchctlRunner = { arguments in
        launchctlCalls.append(arguments)
        if arguments.first == "print" {
            return LaunchctlResult(succeeded: true, output: "state = running")
        }
        return LaunchctlResult(succeeded: true, output: "restored")
    }
    let writeError = NSError(
        domain: "AuraFlowTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "read-only file system"]
    )
    var writeCount = 0
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: launchAgentURL,
        launchctlRunner: runner
    )
    try store.ensureDirectories()
    let previousPlist = Data("previous launch agent".utf8)
    try previousPlist.write(to: launchAgentURL, options: .atomic)

    let manager = LaunchAgentManager(
        store: store,
        launchAgentURL: launchAgentURL,
        launchctlRunner: runner,
        launchAgentFileWriter: { data, url in
            writeCount += 1
            if writeCount == 1 {
                throw writeError
            }
            try data.write(to: url, options: .atomic)
        }
    )

    do {
        try manager.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
        Issue.record("Expected LaunchAgent plist write to fail")
    } catch {
        #expect(error.localizedDescription.contains("read-only file system"))
        #expect(!error.localizedDescription.contains("rollback failed"))
    }

    #expect(writeCount == 2)
    #expect(try Data(contentsOf: launchAgentURL) == previousPlist)
    #expect(
        launchctlCalls == [
            ["print", "gui/\(getuid())/com.andrijvergeles.auraflow"],
            ["bootout", "gui/\(getuid())/com.andrijvergeles.auraflow"],
            ["bootstrap", "gui/\(getuid())", launchAgentURL.path]
        ]
    )
}

@Test func launchAgentRollbackFailureIsIncludedInTheReportedError() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentRollbackFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { arguments in
            if arguments.first == "bootstrap" {
                return LaunchctlResult(
                    succeeded: false,
                    output: "bootstrap failed",
                    terminationStatus: 1
                )
            }
            return LaunchctlResult(succeeded: true)
        }
    )
    try store.ensureDirectories()
    try Data("previous launch agent".utf8)
        .write(to: store.launchAgentURL, options: .atomic)

    do {
        try store.enableLaunchAgent(helperPath: "/tmp/AuraWallpaperAgent")
        Issue.record("Expected LaunchAgent bootstrap to fail")
    } catch {
        #expect(error.localizedDescription.contains("Could not start the AuraFlow LaunchAgent"))
        #expect(error.localizedDescription.contains("rollback failed"))
        #expect(error.localizedDescription.contains("restore LaunchAgent"))
    }
}

@Test func statusDistinguishesLaunchAgentFileAndServiceState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowLaunchAgentStatus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { _ in
            LaunchctlResult(
                succeeded: true,
                output: "state = waiting"
            )
        }
    )
    try store.ensureDirectories()
    try Data("plist".utf8).write(to: store.launchAgentURL, options: .atomic)

    let status = store.status()
    #expect(status.autostart == false)
    #expect(status.autostart_plist_exists == true)
    #expect(status.autostart_service_loaded == true)
    #expect(status.autostart_service_running == false)
}

@Test func autostartValidationDoesNotPersistAnInvalidConfiguration() async throws {
    let fixture = try NativeRuntimeFixture("autostart-invalid")
    defer { fixture.cleanup() }
    try fixture.store.saveConfig(
        ControlConfig(video_path: "", playback_speed: 1.0, autostart: false)
    )
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )

    #expect(throws: NativeWallpaperControllerError.self) {
        try controller.setAutostart(true)
    }
    #expect(fixture.store.loadConfig().autostart == false)
    #expect(FileManager.default.fileExists(atPath: fixture.store.launchAgentURL.path) == false)
}

@Test func startValidationPreservesTheExistingLockScreenOnlyAgent() async throws {
    let fixture = try NativeRuntimeFixture("start-validation-preserves-lock-only")
    defer { fixture.cleanup() }
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller()
    )
    let missingURL = fixture.root.appendingPathComponent("missing.mp4")

    await expectAsyncThrowing(NativeWallpaperControllerError.self) {
        _ = try await controller.start(videoURL: missingURL, speed: 1.0)
    }
    #expect(fixture.store.isLockScreenOnlyAgent())
    #expect(fixture.store.loadLockScreenOnlySource() == fixture.videoURL.standardizedFileURL)
    #expect(fixture.store.loadConfig().video_path == fixture.videoURL.path)
    #expect(fixture.store.processIsAlive(pid: Int(agent.processIdentifier)))
}

@Test func failedStartRestoresThePreviousLockScreenOnlyRoute() async throws {
    let fixture = try NativeRuntimeFixture("start-rollback-lock-only")
    defer { fixture.cleanup() }
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    try fixture.store.saveCommand(WallpaperRuntimeCommand(action: .pause))
    try fixture.store.saveHealth(
        DaemonHealth(
            available: true,
            fresh: true,
            suspicious: false,
            reason: "before-start",
            paused: true
        )
    )
    fixture.store.markPaused(true)
    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let installer = RecordingLockScreenSaverInstaller()
    installer.failNextDesktopInstall = true
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    await expectAsyncThrowing(TestInstallerError.self) {
        _ = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)
    }
    #expect(fixture.store.isLockScreenOnlyAgent())
    #expect(fixture.store.loadLockScreenOnlySource() == fixture.videoURL.standardizedFileURL)
    #expect(installer.installedLockScreenOnlyVideoURL == fixture.videoURL)
    #expect(fixture.store.isPaused())
    #expect(fixture.store.loadCommand()?.action == .pause)
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()))
}

@Test func failedStartReportsAnIncompleteRollback() async throws {
    let fixture = try NativeRuntimeFixture("start-rollback-failure")
    defer { fixture.cleanup() }
    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            show_on_lock_screen: true
        )
    )
    try fixture.store.saveLockScreenOnlySource(fixture.videoURL)
    let agent = try launchReadyTestAgent()
    defer { terminateAndReapTestAgent(agent) }
    try fixture.store.savePID(agent.processIdentifier)
    fixture.store.markLockScreenOnlyAgent(true)

    let installer = RecordingLockScreenSaverInstaller()
    installer.installError = .installFailed
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    do {
        _ = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)
        Issue.record("Expected Start to fail")
    } catch {
        #expect(error.localizedDescription.contains("Start failed"))
        #expect(error.localizedDescription.contains("rollback failed"))
        #expect(fixture.store.isLockScreenOnlyAgent())
        #expect(fixture.store.loadLockScreenOnlySource() == fixture.videoURL.standardizedFileURL)
    }
}

@Test func nativeAutostartPlistIncludesNativeBridgePathWhenConfigured() async throws {
    let fixture = try NativeRuntimeFixture("autostart-native-bridge")
    defer { fixture.cleanup() }

    let nativeBridgeURL = fixture.root.appendingPathComponent("AuraWallpaperNativeBridge")
    FileManager.default.createFile(
        atPath: nativeBridgeURL.path,
        contents: Data("native bridge fixture".utf8),
        attributes: [.posixPermissions: 0o755]
    )

    try fixture.store.enableLaunchAgent(
        helperPath: fixture.helperURL.path,
        nativeBridgePath: nativeBridgeURL.path
    )
    let plist = try String(contentsOf: fixture.store.launchAgentURL, encoding: .utf8)

    #expect(plist.contains("--native-bridge-path"))
    #expect(plist.contains(nativeBridgeURL.path))
}

@Test func existingAutostartPlistIsMigratedWithNativeBridgePath() async throws {
    let fixture = try NativeRuntimeFixture("autostart-migration")
    defer { fixture.cleanup() }

    try fixture.store.saveConfig(
        ControlConfig(
            video_path: fixture.videoURL.path,
            playback_speed: 1.0,
            autostart: true
        )
    )
    let legacyPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>ProgramArguments</key>
      <array>
        <string>/old/AuraWallpaperAgent</string>
        <string>--config</string>
        <string>/old/config.json</string>
      </array>
    </dict>
    </plist>
    """
    try legacyPlist.write(
        to: fixture.store.launchAgentURL,
        atomically: true,
        encoding: .utf8
    )
    let nativeBridgeURL = fixture.root.appendingPathComponent("AuraWallpaperNativeBridge")

    _ = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: RecordingLockScreenSaverInstaller(),
        nativeBridgeURL: nativeBridgeURL
    )
    let migratedPlist = try String(
        contentsOf: fixture.store.launchAgentURL,
        encoding: .utf8
    )

    #expect(migratedPlist.contains(fixture.helperURL.path))
    #expect(migratedPlist.contains("--native-bridge-path"))
    #expect(migratedPlist.contains(nativeBridgeURL.path))
    #expect(!migratedPlist.contains("/old/AuraWallpaperAgent"))
}

@Test func nativeLockScreenSettingInstallsSaverAndSendsPreviewCommands() async throws {
    let fixture = try NativeRuntimeFixture("lock-screen")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try await controller.start(videoURL: fixture.videoURL, speed: 1.0)
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
    _ = try await controller.setShowOnLockScreen(true)

    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(installer.installedVideoURL == fixture.videoURL)
    #expect(fixture.store.loadConfig().scale_mode == WallpaperScaleMode.fit.rawValue)
    #expect(fixture.store.loadCommand()?.action == .update)
    #expect(
        DaemonProcessManager(
            store: fixture.store,
            expectedExecutableURL: fixture.helperURL
        ).processStatus == .owned
    )

    _ = try controller.beginLockScreenPreview()
    #expect(fixture.store.loadCommand()?.action == .previewLock)

    _ = try controller.endLockScreenPreview()
    #expect(fixture.store.loadCommand()?.action == .previewUnlock)

    _ = try await controller.clearWallpaper()
    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(fixture.store.loadConfig().video_path.isEmpty)
    #expect(installer.uninstallCallCount == 1)
}

@Test func nativeLockScreenPreferenceCanWaitForASelectedWallpaper() async throws {
    let fixture = try NativeRuntimeFixture("lock-screen-pending")
    defer { fixture.cleanup() }
    let installer = RecordingLockScreenSaverInstaller()
    let controller = try NativeWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        lockScreenSaverInstaller: installer
    )

    _ = try await controller.setShowOnLockScreen(true)

    #expect(fixture.store.loadConfig().show_on_lock_screen == true)
    #expect(installer.installedVideoURL == nil)
}

@Test func nativeLockScreenSyncIgnoresAnEmptyOrMissingSource() async throws {
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
    try await controller.syncLockScreenSaver()

    #expect(installer.installedVideoURL == nil)
}

@Test func runtimeNormalizationDefaultsLockScreenSettingToDisabled() async throws {
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
}

@Test func legacyRemoveStateKeepsLockScreenDisabledUntilOptIn() async throws {
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

    #expect(fixture.store.loadConfig().show_on_lock_screen == false)
}

@Test func currentLockScreenOnlyConfigMigratesToDesktopSource() async throws {
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

@Test func nativeStatusJSONKeepsLegacyContractShape() async throws {
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

@Test func wallpaperBackupSkipsManagedLastFrameAndWritesCurrentEntries() async throws {
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
