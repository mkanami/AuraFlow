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
