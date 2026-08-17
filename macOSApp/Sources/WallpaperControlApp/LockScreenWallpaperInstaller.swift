import AuraWallpaperCore
import Foundation

protocol ModernLockScreenInstalling: LockScreenSaverInstalling {
    var isAvailable: Bool { get }

    /// `activate` is false during status refreshes. Refreshing the app must not
    /// reopen System Settings; only an explicit user change commits selection.
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
/// macOS 26 and later require a registered WallpaperExtensionKit provider.
/// Older systems retain the existing Aerial/screen-saver compatibility paths.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling
    private let useExtensionPath: Bool

    init(
        modern: ModernLockScreenInstalling = WallpaperExtensionLockScreenInstaller(),
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller(),
        operatingSystemVersion: OperatingSystemVersion =
            ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.modern = modern
        self.legacy = legacy
        self.useExtensionPath = operatingSystemVersion.majorVersion >= 26
    }

    var isInstalled: Bool {
        modern.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: true)
    }

    func install(videoURL: URL, activate: Bool = true) throws {
        if useExtensionPath {
            guard modern.isAvailable else {
                throw WallpaperExtensionLockScreenInstallerError.extensionNotBundled
            }
            try modern.install(videoURL: videoURL, activate: activate)
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            return
        }

        if modern.isAvailable {
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            try modern.install(videoURL: videoURL, activate: activate)
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
