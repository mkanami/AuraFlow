import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

private final class PlatformRecordingInstaller: LockScreenSaverInstalling {
    var installedURL: URL?
    var isInstalled: Bool { installedURL != nil }

    func install(videoURL: URL) throws {
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

    init(isAvailable: Bool, isInstalled: Bool = false) {
        self.isAvailable = isAvailable
        self.isInstalled = isInstalled
    }

    func install(videoURL: URL) throws {
        installCallCount += 1
        isInstalled = true
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
    }
}

@Test func modernAdapterUsesInjectedInstallerOnSupportedRuntime() throws {
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
    try adapter.install(mediaURL)
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

@Test func unsupportedAdapterReportsActionableStatus() throws {
    let message = "Lock Screen доступен только на macOS 26+."
    let adapter = UnsupportedAdapter(message: message)

    #expect(adapter.capabilities.supportsLockScreen == false)
    #expect(adapter.status() == .unavailable(message))
    #expect(throws: LockScreenPlatformError.self) {
        try adapter.install(URL(fileURLWithPath: "/tmp/wallpaper.mov"))
    }
}

@Test func wallpaperPlatformAdapterUsesLegacyWhenModernProviderIsUnavailable() throws {
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
    try adapter.install(mediaURL)
    #expect(recordingInstaller.installedURL == mediaURL)
}

@Test func staleModernMarkerFallsBackToLegacyRuntime() throws {
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
    try adapter.install(mediaURL)
    #expect(legacyInstaller.installedURL == mediaURL)
    #expect(modernInstaller.installCallCount == 0)

    _ = try adapter.repair(
        videoURL: mediaURL,
        shouldProceed: { true }
    )
    #expect(modernInstaller.repairCallCount == 0)
}
