import AuraWallpaperCore
import Foundation

/// Chooses the modern secure-lock path on systems that provide Apple's Aerial
/// wallpaper engine. Older systems retain the legacy screen saver fallback.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: AerialLockScreenInstaller
    private let legacy: LockScreenSaverInstalling

    init(
        modern: AerialLockScreenInstaller = AerialLockScreenInstaller(),
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller()
    ) {
        self.modern = modern
        self.legacy = legacy
    }

    var isInstalled: Bool {
        modern.isInstalled || legacy.isInstalled
    }

    var installationConfirmed: Bool {
        if modern.isAvailable {
            return modern.installationConfirmed
        }
        return legacy.installationConfirmed
    }

    func install(videoURL: URL) throws {
        if modern.isAvailable {
            if legacy.isInstalled {
                try legacy.uninstall()
            }
            try modern.install(videoURL: videoURL)
        } else {
            try legacy.install(videoURL: videoURL)
        }
    }

    func installLockScreenOnly(videoURL: URL) throws {
        if modern.isAvailable {
            // On macOS 26+ loginwindow renders the real Lock Screen through
            // Apple's Aerial wallpaper provider. The provider requires the
            // shared Desktop + Idle descriptor to be selected, even for the
            // Lock-only action; the legacy saver is not consulted by that
            // loginwindow path.
            if legacy.isInstalled {
                try legacy.uninstall()
            }
            try modern.install(videoURL: videoURL)
        } else {
            try legacy.installLockScreenOnly(videoURL: videoURL)
        }
    }

    func uninstall() throws {
        if modern.isInstalled {
            try modern.uninstall()
        }
        try legacy.uninstall()
    }
}
