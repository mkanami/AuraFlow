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
        // The modern Aerial store has one shared Desktop/Lock Screen
        // descriptor on current macOS. Selecting it for a Lock-only action
        // also changes the user's desktop wallpaper. Use the legacy saver
        // for this isolated action: it is live, reads the runtime source,
        // and leaves the desktop wallpaper store untouched.
        let hadModernInstallation = modern.isInstalled
        if hadModernInstallation {
            try modern.uninstall()
        }
        try legacy.installLockScreenOnly(videoURL: videoURL)
    }

    func uninstall() throws {
        if modern.isInstalled {
            try modern.uninstall()
        }
        try legacy.uninstall()
    }
}
