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

/// Routes Lock Screen media to the provider used by macOS's secure Lock Screen.
///
/// The v1.3.1 path uses Apple's signed Aerial provider and replaces only its
/// selected Lock Screen asset with AuraFlow media. On macOS 26+ this is still
/// the reliable system-owned Lock Screen surface; the WallpaperExtensionKit
/// and legacy saver paths remain compatibility fallbacks only.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let aerial: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling

    init(
        modern: ModernLockScreenInstalling = WallpaperExtensionLockScreenInstaller(),
        aerial: ModernLockScreenInstalling? = nil,
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller()
    ) {
        self.modern = modern
        self.aerial = aerial ?? AerialLockScreenInstaller()
        self.legacy = legacy
    }

    var isInstalled: Bool {
        aerial.isInstalled || modern.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: false)
    }

    func install(videoURL: URL, activate: Bool) throws {
        if aerial.isAvailable {
            // Remove only a stale extension deployment before installing
            // Aerial. Its uninstall can restore an old Store snapshot, so it
            // must happen before Aerial writes the new Lock Screen choice.
            try uninstallExtensionIfNeeded()
            try aerial.install(videoURL: videoURL, activate: activate)
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            return
        }

        if modern.isAvailable {
            try modern.install(videoURL: videoURL, activate: activate)
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            return
        }

        do {
            try legacy.install(videoURL: videoURL)
        } catch LockScreenSaverInstallerError.componentNotBundled {
            throw WallpaperExtensionLockScreenInstallerError.extensionNotBundled
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
