import AuraWallpaperCore
import Foundation

protocol ModernLockScreenInstalling: LockScreenSaverInstalling {
    var isAvailable: Bool { get }
}

extension AerialLockScreenInstaller: ModernLockScreenInstalling {}

/// Routes Lock Screen media to the surface that macOS actually launches.
///
/// macOS 26 and later no longer make the old Aerial store injection the active
/// lock/screen-saver surface. AuraFlow already bundles a signed screen saver
/// component, so prefer that component on those systems. Older systems retain
/// the Aerial path when it is available.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling
    private let preferLegacy: Bool

    init(
        modern: ModernLockScreenInstalling = AerialLockScreenInstaller(),
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller(),
        operatingSystemVersion: OperatingSystemVersion =
            ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.modern = modern
        self.legacy = legacy
        self.preferLegacy = operatingSystemVersion.majorVersion >= 26
    }

    var isInstalled: Bool {
        modern.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        if preferLegacy {
            try legacy.install(videoURL: videoURL)
            // Remove a stale Aerial installation after the working screen
            // saver is active. A failed cleanup must not undo the working
            // Lock Screen selection.
            if modern.isInstalled {
                try? modern.uninstall()
            }
            return
        }

        if modern.isAvailable {
            if legacy.isInstalled {
                try legacy.uninstall()
            }
            try modern.install(videoURL: videoURL)
        } else {
            try legacy.install(videoURL: videoURL)
        }
    }

    func uninstall() throws {
        if modern.isInstalled {
            try modern.uninstall()
        }
        try legacy.uninstall()
    }
}
