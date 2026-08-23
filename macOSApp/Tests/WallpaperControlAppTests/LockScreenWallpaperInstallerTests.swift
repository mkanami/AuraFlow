import Foundation
import Testing
@testable import WallpaperControlApp

private final class RecordingModernLockScreenInstaller:
    ModernLockScreenInstalling {
    let isAvailable: Bool
    var isInstalled = false
    var installCount = 0
    var activationValues: [Bool] = []
    var uninstallCount = 0

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func install(videoURL: URL) throws {
        installCount += 1
        isInstalled = true
    }

    func install(videoURL: URL, activate: Bool) throws {
        activationValues.append(activate)
        try install(videoURL: videoURL)
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

@Test func macOS26AndLaterPreferBundledScreenSaver() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(legacy.installCount == 1)
    #expect(aerial.installCount == 0)
    #expect(modern.installCount == 0)
}

@Test func standardInstallUsesAuraFlowSaverWithoutOpeningSettingsOnMacOS26AndLater() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(
        videoURL: URL(fileURLWithPath: "/tmp/lock.mov"),
        activate: false
    )

    #expect(legacy.installCount == 1)
    #expect(modern.installCount == 0)
    #expect(aerial.installCount == 0)
}

@Test func standardInstallKeepsSaverSelectedForTheRealLockScreen() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(
        videoURL: URL(fileURLWithPath: "/tmp/lock.mov"),
        activate: false
    )

    #expect(legacy.installCount == 1)
    #expect(modern.installCount == 0)
}

@Test func explicitLockScreenToggleKeepsActivationPath() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(
        videoURL: URL(fileURLWithPath: "/tmp/lock.mov"),
        activate: true
    )

    #expect(legacy.installCount == 1)
    #expect(modern.installCount == 0)
}

@Test func olderSystemsKeepAerialWhenAvailable() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 15,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(aerial.installCount == 1)
    #expect(modern.installCount == 0)
    #expect(legacy.installCount == 0)
}

@Test func macOS26AndLaterCleanUpStaleModernProvidersAfterLegacyInstall() throws {
    let modern = RecordingModernLockScreenInstaller()
    let aerial = RecordingModernLockScreenInstaller()
    let legacy = RecordingLegacyLockScreenInstaller()
    aerial.isInstalled = true
    modern.isInstalled = true
    let installer = LockScreenWallpaperInstaller(
        modern: modern,
        aerial: aerial,
        legacy: legacy,
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )
    )

    try installer.install(videoURL: URL(fileURLWithPath: "/tmp/lock.mov"))

    #expect(legacy.installCount == 1)
    #expect(aerial.uninstallCount == 1)
    #expect(modern.uninstallCount == 1)
}
