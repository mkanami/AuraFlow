import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

func expectAsyncThrowing<E: Error>(
    _ expected: E.Type,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(E.self) to be thrown")
    } catch {
        #expect(error is E)
    }
}

private final class PlatformRecordingInstaller: LockScreenSaverInstalling {
    var installedURL: URL?
    var installError: Error?
    var isInstalled: Bool { installedURL != nil }

    func install(videoURL: URL) throws {
        if let installError {
            throw installError
        }
        installedURL = videoURL
    }

    func uninstall() throws {
        installedURL = nil
    }
}

private final class RecordingModernInstaller: ModernLockScreenInstalling {
    let isAvailable: Bool
    var isInstalled: Bool
    private(set) var installCallCount = 0
    private(set) var repairCallCount = 0
    var lockScreenOnlyStatusOverride: LockScreenOnlyGenerationStatus?
    var restoreError: Error?
    private(set) var restoredLockScreenOnlyVideoURL: URL?

    init(isAvailable: Bool, isInstalled: Bool = false) {
        self.isAvailable = isAvailable
        self.isInstalled = isInstalled
    }

    func install(videoURL: URL) throws {
        installCallCount += 1
        isInstalled = true
    }

    func installLockScreenOnly(videoURL: URL) throws {
        if let restoreError {
            throw restoreError
        }
        restoredLockScreenOnlyVideoURL = videoURL
        isInstalled = true
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        if let lockScreenOnlyStatusOverride {
            return lockScreenOnlyStatusOverride
        }
        return LockScreenOnlyGenerationStatus(
            installed: isInstalled,
            sourceMatches: isInstalled,
            assetValid: isInstalled,
            providerAvailable: isAvailable && isInstalled,
            providerRunning: isAvailable && isInstalled,
            wallpaperStoreValid: isInstalled,
            screenSaverSelected: isInstalled
        )
    }

    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        repairCallCount += 1
        return false
    }

    func uninstall() throws {
        isInstalled = false
        restoredLockScreenOnlyVideoURL = nil
    }
}

private enum PlatformRecordingError: Error {
    case installFailed
    case restoreFailed
}

@Test func modernAdapterUsesInjectedInstallerOnSupportedRuntime() async throws {
    let installer = RecordingModernInstaller(isAvailable: true)
    let adapter = ModernMacOS26Adapter(
        installer: installer,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let mediaURL = URL(fileURLWithPath: "/tmp/modern-wallpaper.mov")

    #expect(adapter.capabilities.supportsLockScreenOnly)
    #expect(adapter.capabilities.supportsSecureLockScreen)
    try await adapter.install(mediaURL)
    #expect(installer.installCallCount == 1)
    #expect(adapter.status().isReady)
}

@Test func agentPlatformDisablesNativeRuntimeForLegacyMacOS() {
    let platform = LockScreenPlatformFactory.makeAgentPlatform(
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 15,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    #expect(platform.capabilities.supportsLockScreen == false)
    #expect(platform.capabilities.supportsLockScreenOnly == false)
    #expect(platform.capabilities.supportsSecureLockScreen == false)
    #expect(
        platform.capabilities.availabilityMessage?.contains(
            "legacy screen saver"
        ) == true
    )
}

@Test func nativeBridgeCapabilityCheckerFailsClosedForUnsupportedMacOS() {
    let capabilities = NativeLockScreenBridgeCapabilityChecker.check(
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 25,
            minorVersion: 0,
            patchVersion: 0
        ),
        executableURL: URL(fileURLWithPath: "/tmp/bridge")
    )

    #expect(
        capabilities.availability
            == .unsupportedOperatingSystem(currentMajorVersion: 25)
    )
    #expect(!capabilities.isAvailable)
    #expect(capabilities.message.contains("legacy screen saver"))
}

@Test func nativeBridgeCapabilityCheckerRejectsMissingPrivateFramework() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowBridgeCapabilities-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let executableURL = root.appendingPathComponent("AuraWallpaperNativeBridge")
    FileManager.default.createFile(atPath: executableURL.path, contents: Data())
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executableURL.path
    )
    let missingFramework = root.appendingPathComponent("Wallpaper.framework")

    let capabilities = NativeLockScreenBridgeCapabilityChecker.check(
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        ),
        executableURL: executableURL,
        privateFrameworkPaths: [missingFramework.path]
    )

    #expect(
        capabilities.availability
            == .privateFrameworkMissing(path: missingFramework.path)
    )
    #expect(!capabilities.isAvailable)
}

@Test func nativeBridgeCapabilityCheckerAcceptsCompleteRuntime() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowBridgeCapabilities-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let executableURL = root.appendingPathComponent("AuraWallpaperNativeBridge")
    FileManager.default.createFile(atPath: executableURL.path, contents: Data())
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executableURL.path
    )
    let frameworkPaths = [
        root.appendingPathComponent("Wallpaper.framework").path,
        root.appendingPathComponent("WallpaperTypes.framework").path
    ]
    for path in frameworkPaths {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }

    let capabilities = NativeLockScreenBridgeCapabilityChecker.check(
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        ),
        executableURL: executableURL,
        privateFrameworkPaths: frameworkPaths
    )

    #expect(capabilities.availability == .available)
    #expect(capabilities.isAvailable)
}

@Test func agentPlatformDisablesNativeRuntimeWhenBridgeIsMissing() {
    let platform = LockScreenPlatformFactory.makeAgentPlatform(
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        ),
        modernInstaller: RecordingModernInstaller(isAvailable: true),
        nativeBridgeURL: nil
    )

    #expect(platform.capabilities.supportsLockScreenOnly == false)
    #expect(platform.capabilities.supportsSecureLockScreen == false)
    #expect(platform.capabilities.availabilityMessage?.contains("not bundled") == true)
}

@Test func wallpaperPlatformAdapterUsesLegacyWhenNativeBridgeIsUnavailable() async throws {
    let modernInstaller = RecordingModernInstaller(
        isAvailable: true,
        isInstalled: true
    )
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = PlatformRecordingInstaller()
    let legacy = LegacyMacOSAdapter(installer: legacyInstaller)
    let adapter = WallpaperPlatformAdapter(
        modern: modern,
        legacy: legacy,
        nativeBridgeCapabilities: NativeLockScreenBridgeCapabilities(
            availability: .privateFrameworkMissing(
                path: "/System/Library/PrivateFrameworks/Wallpaper.framework"
            )
        )
    )
    let mediaURL = URL(fileURLWithPath: "/tmp/legacy-native-bridge-wallpaper.mov")

    #expect(adapter.capabilities.supportsLockScreen)
    #expect(adapter.capabilities.supportsLockScreenOnly == false)
    #expect(adapter.capabilities.availabilityMessage?.contains("unavailable") == true)
    try await adapter.install(mediaURL)
    #expect(legacyInstaller.installedURL == mediaURL)
    #expect(modernInstaller.isInstalled == false)
    #expect(modernInstaller.installCallCount == 0)
}

@Test func unsupportedAdapterReportsActionableStatus() async throws {
    let message = "Lock Screen доступен только на macOS 26+."
    let adapter = UnsupportedAdapter(message: message)

    #expect(adapter.capabilities.supportsLockScreen == false)
    #expect(adapter.status() == .unavailable(message))
    await expectAsyncThrowing(LockScreenPlatformError.self) {
        try await adapter.install(URL(fileURLWithPath: "/tmp/wallpaper.mov"))
    }
}

@Test func wallpaperPlatformAdapterUsesLegacyWhenModernProviderIsUnavailable() async throws {
    let recordingInstaller = PlatformRecordingInstaller()
    let legacy = LegacyMacOSAdapter(installer: recordingInstaller)
    let modern = ModernMacOS26Adapter(
        installer: AerialLockScreenInstaller(
            wallpaperStoreURL: URL(fileURLWithPath: "/tmp/aura-missing-store-(UUID().uuidString)"),
            aerialProviderURL: URL(fileURLWithPath: "/tmp/aura-missing-provider-(UUID().uuidString)"),
            stateDirectoryURL: URL(fileURLWithPath: "/tmp/aura-platform-tests-(UUID().uuidString)")
        ),
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let adapter = WallpaperPlatformAdapter(modern: modern, legacy: legacy)
    let mediaURL = URL(fileURLWithPath: "/tmp/legacy-wallpaper.mov")

    #expect(adapter.capabilities == .legacyMacOS)
    try await adapter.install(mediaURL)
    #expect(recordingInstaller.installedURL == mediaURL)
}

@Test func staleModernMarkerFallsBackToLegacyRuntime() async throws {
    let modernInstaller = RecordingModernInstaller(
        isAvailable: false,
        isInstalled: true
    )
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = PlatformRecordingInstaller()
    let legacy = LegacyMacOSAdapter(installer: legacyInstaller)
    let adapter = WallpaperPlatformAdapter(modern: modern, legacy: legacy)
    let mediaURL = URL(fileURLWithPath: "/tmp/stale-modern-wallpaper.mov")

    #expect(adapter.capabilities == .legacyMacOS)
    try await adapter.install(mediaURL)
    #expect(legacyInstaller.installedURL == mediaURL)
    #expect(modernInstaller.installCallCount == 0)

    _ = try await adapter.repair(
        videoURL: mediaURL,
        shouldProceed: { true }
    )
    #expect(modernInstaller.repairCallCount == 0)
}

@Test func wallpaperPlatformAdapterUsesExplicitLegacyFallbackWhenModernAssetIsUnavailable() async throws {
    let modernInstaller = RecordingModernInstaller(
        isAvailable: true,
        isInstalled: true
    )
    modernInstaller.lockScreenOnlyStatusOverride = LockScreenOnlyGenerationStatus(
        installed: true,
        sourceMatches: true,
        assetValid: true,
        providerAvailable: false,
        providerRunning: false,
        wallpaperStoreValid: true,
        screenSaverSelected: true
    )
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = PlatformRecordingInstaller()
    let legacy = LegacyMacOSAdapter(installer: legacyInstaller)
    let adapter = WallpaperPlatformAdapter(modern: modern, legacy: legacy)
    let previousURL = URL(fileURLWithPath: "/tmp/old-lock-screen.mov")
    let fallbackURL = URL(fileURLWithPath: "/tmp/legacy-fallback.mov")

    try await adapter.installLegacyLockScreenFallback(
        videoURL: fallbackURL,
        restoringLockScreenOnlyVideoURL: previousURL
    )

    #expect(legacyInstaller.installedURL == fallbackURL)
    #expect(modernInstaller.isInstalled == false)
    #expect(modernInstaller.installCallCount == 0)
    #expect(modernInstaller.restoredLockScreenOnlyVideoURL == nil)
}

@Test func explicitLegacyFallbackRestoresModernInstallationWhenLegacyFails() async throws {
    let modernInstaller = RecordingModernInstaller(
        isAvailable: true,
        isInstalled: true
    )
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = PlatformRecordingInstaller()
    legacyInstaller.installError = PlatformRecordingError.installFailed
    let previousLegacyURL = URL(fileURLWithPath: "/tmp/previous-legacy.mov")
    legacyInstaller.installedURL = previousLegacyURL
    let legacy = LegacyMacOSAdapter(installer: legacyInstaller)
    let adapter = WallpaperPlatformAdapter(modern: modern, legacy: legacy)
    let previousURL = URL(fileURLWithPath: "/tmp/old-lock-screen.mov")

    await expectAsyncThrowing(PlatformRecordingError.self) {
        try await adapter.installLegacyLockScreenFallback(
            videoURL: URL(fileURLWithPath: "/tmp/legacy-fallback.mov"),
            restoringLockScreenOnlyVideoURL: previousURL
        )
    }
    #expect(modernInstaller.isInstalled)
    #expect(modernInstaller.restoredLockScreenOnlyVideoURL == previousURL)
    #expect(legacyInstaller.installedURL == previousLegacyURL)
}

@Test func explicitLegacyFallbackReportsRollbackFailure() async throws {
    let modernInstaller = RecordingModernInstaller(
        isAvailable: true,
        isInstalled: true
    )
    modernInstaller.restoreError = PlatformRecordingError.restoreFailed
    let modern = ModernMacOS26Adapter(
        installer: modernInstaller,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )
    let legacyInstaller = PlatformRecordingInstaller()
    legacyInstaller.installError = PlatformRecordingError.installFailed
    let legacy = LegacyMacOSAdapter(installer: legacyInstaller)
    let adapter = WallpaperPlatformAdapter(modern: modern, legacy: legacy)

    do {
        try await adapter.installLegacyLockScreenFallback(
            videoURL: URL(fileURLWithPath: "/tmp/legacy-fallback.mov"),
            restoringLockScreenOnlyVideoURL: URL(
                fileURLWithPath: "/tmp/old-lock-screen.mov"
            )
        )
        #expect(Bool(false), "Expected fallback rollback failure")
    } catch let error as LockScreenPlatformError {
        guard case let .fallbackRollbackFailed(installError, rollbackError) = error else {
            #expect(Bool(false), "Expected a fallback rollback error")
            return
        }
        #expect(!installError.isEmpty)
        #expect(!rollbackError.isEmpty)
    }
    #expect(modernInstaller.isInstalled == false)
}
