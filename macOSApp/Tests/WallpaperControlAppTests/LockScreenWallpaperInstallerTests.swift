import Foundation
import Testing
@testable import WallpaperControlApp

private final class RecordingModernLockScreenInstaller:
    ModernLockScreenInstalling {
    let isAvailable: Bool
    var isInstalled = false
    var installCount = 0
    var uninstallCount = 0

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func install(videoURL: URL) throws {
        installCount += 1
        isInstalled = true
    }

    func uninstall() throws {
        uninstallCount += 1
        isInstalled = false
    }
}

private final class RecordingLegacyLockScreenInstaller:
    LockScreenSaverInstalling {
    var isInstalled = false
    var installCount = 0
    var uninstallCount = 0

    func install(videoURL: URL) throws {
        installCount += 1
        isInstalled = true
    }

    func uninstall() throws {
        uninstallCount += 1
        isInstalled = false
    }
}

@Test func macOS26AndLaterPreferWallpaperExtension() throws {
    let modern = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(legacy.installCount == 0)
    #expect(modern.installCount == 1)
}

@Test func olderSystemsKeepAerialWhenAvailable() throws {
    let modern = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 15,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(modern.installCount == 1)
    #expect(legacy.installCount == 0)
}

@Test func macOS26AndLaterCleanUpStaleScreenSaverAfterExtensionInstall() throws {
    let modern = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    legacy.isInstalled = true
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(legacy.installCount == 0)
    #expect(legacy.uninstallCount == 1)
    #expect(modern.installCount == 1)
}
