import AuraWallpaperCore
import Foundation

protocol ModernLockScreenInstalling: LockScreenSaverInstalling {
    var isAvailable: Bool { get }

    func install(videoURL: URL, activate: Bool) throws
}

extension AerialLockScreenInstaller: ModernLockScreenInstalling {}

extension ModernLockScreenInstalling {
    func install(videoURL: URL, activate _: Bool) throws {
        try install(videoURL: videoURL)
    }
}

/// Routes Lock Screen media to the surface that macOS actually launches.
///
/// On macOS 26 and later the visible secure Lock Screen is driven by the
/// selected screen-saver module (`com.apple.screensaver`), even though the
/// wallpaper store may contain an Aerial or WallpaperExtensionKit entry for
/// its Idle slot. Prefer AuraFlow's signed saver there so the wallpaper shown
/// after a real lock is the same media that Start installed. Keep the modern
/// providers as fallbacks for hosts where the bundled saver is unavailable.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let aerial: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling
    private let preferLegacy: Bool

    init(
        modern: ModernLockScreenInstalling = WallpaperExtensionLockScreenInstaller(),
        aerial: ModernLockScreenInstalling? = nil,
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller(),
        operatingSystemVersion: OperatingSystemVersion =
            ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.modern = modern
        self.aerial = aerial ?? AerialLockScreenInstaller()
        self.legacy = legacy
        self.preferLegacy = operatingSystemVersion.majorVersion >= 26
    }

    var isInstalled: Bool {
        aerial.isInstalled || modern.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: false)
    }

    func install(videoURL: URL, activate: Bool) throws {
        if preferLegacy {
            do {
                // Clear stale modern deployments first. Aerial/extension
                // uninstall restores their own Store snapshot, so doing this
                // after the saver install could erase AuraFlow's new Idle
                // screen-saver descriptor again.
                if aerial.isInstalled {
                    try? aerial.uninstall()
                }
                if modern.isInstalled {
                    try? modern.uninstall()
                }
                // The legacy installer updates the real macOS screen-saver
                // selection directly and never opens System Settings. The
                // `activate` value is intentionally ignored here: Start and
                // Resume both need the selected saver to remain available,
                // while the preference itself is controlled by the UI toggle.
                try legacy.install(videoURL: videoURL)
                return
            } catch LockScreenSaverInstallerError.componentNotBundled {
                // Development or partial builds may omit the saver bundle.
                // Fall through to the modern provider paths in that case.
            }
        }

        if aerial.isAvailable {
            try uninstallExtensionIfNeeded()
            try aerial.install(videoURL: videoURL, activate: activate)
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            return
        }
        guard modern.isAvailable else {
            throw WallpaperExtensionLockScreenInstallerError.extensionNotBundled
        }
        try modern.install(videoURL: videoURL, activate: activate)
        if legacy.isInstalled {
            try? legacy.uninstall()
        }
    }

    func uninstall() throws {
        if aerial.isInstalled {
            try aerial.uninstall()
        }
        if modern.isInstalled {
            try modern.uninstall()
        }
        try legacy.uninstall()
    }

    func refreshAfterWallpaperRestore() {
        (aerial as? AerialLockScreenInstaller)?.refreshAfterWallpaperRestore()
    }

    private func uninstallExtensionIfNeeded() throws {
        guard modern.isInstalled else { return }
        try modern.uninstall()
    }
}
