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
/// On macOS 26 and later, prefer Apple's signed Aerial provider when it is
/// available. It changes only the Idle/Lock Screen slots and does not require
/// System Settings automation or access to the extension's protected
/// container. The WallpaperExtensionKit and legacy screen-saver paths remain
/// available as compatibility fallbacks.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let normalStart: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling
    private let useExtensionPath: Bool

    init(
        modern: ModernLockScreenInstalling = WallpaperExtensionLockScreenInstaller(),
        normalStart: ModernLockScreenInstalling = AerialLockScreenInstaller(),
        legacy: LockScreenSaverInstalling = LockScreenSaverInstaller(),
        operatingSystemVersion: OperatingSystemVersion =
            ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.modern = modern
        self.normalStart = normalStart
        self.legacy = legacy
        self.useExtensionPath = operatingSystemVersion.majorVersion >= 26
    }

    var isInstalled: Bool {
        modern.isInstalled || normalStart.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: true)
    }

    func install(videoURL: URL, activate: Bool = true) throws {
        if useExtensionPath {
            if normalStart.isAvailable {
                try normalStart.install(videoURL: videoURL, activate: false)
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

    /// Installs the wallpaper used by the ordinary Start/Resume actions.
    ///
    /// On macOS 26+ the extension's optional System Settings activation uses
    /// System Events and therefore needs a TCC Accessibility grant that is
    /// unavailable on some systems. Aerial is already a signed Apple Lock
    /// Screen provider and can be selected by updating the wallpaper store
    /// directly, so normal playback never opens System Settings.
    func installForNormalStart(videoURL: URL) throws {
        if useExtensionPath {
            if normalStart.isAvailable {
                try normalStart.install(videoURL: videoURL, activate: false)
                if legacy.isInstalled {
                    try? legacy.uninstall()
                }
                return
            }
            guard modern.isAvailable else {
                throw WallpaperExtensionLockScreenInstallerError.extensionNotBundled
            }
            // Normal Start must never open System Settings. If Aerial is not
            // available, commit the extension's persisted choice without the
            // optional System Events activation step.
            try modern.install(videoURL: videoURL, activate: false)
            if legacy.isInstalled {
                try? legacy.uninstall()
            }
            return
        }

        try install(videoURL: videoURL, activate: true)
    }

    func uninstall() throws {
        if modern.isInstalled {
            try modern.uninstall()
        }
        if normalStart.isInstalled {
            try normalStart.uninstall()
        }
        try legacy.uninstall()
    }
}
