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
/// macOS 26 can expose a WallpaperExtensionKit provider in Index.plist while
/// the active secure Lock Screen still remains on Apple's Aerial surface. Use
/// the Aerial-backed path when available so Start changes the real Lock Screen
/// as well as the Desktop agent. Keep the AuraFlow extension as a fallback for
/// systems where Aerial is unavailable.
final class LockScreenWallpaperInstaller: LockScreenSaverInstalling {
    private let modern: ModernLockScreenInstalling
    private let aerial: ModernLockScreenInstalling
    private let legacy: LockScreenSaverInstalling
    private let useExtensionPath: Bool

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
        self.useExtensionPath = operatingSystemVersion.majorVersion >= 26
    }

    var isInstalled: Bool {
        aerial.isInstalled || modern.isInstalled || legacy.isInstalled
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: false)
    }

    func install(videoURL: URL, activate: Bool) throws {
        if useExtensionPath {
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
            return
        }

        if aerial.isAvailable {
            try uninstallExtensionIfNeeded()
            if legacy.isInstalled {
                try legacy.uninstall()
            }
            try aerial.install(videoURL: videoURL, activate: activate)
        } else if modern.isAvailable {
            if legacy.isInstalled {
                try legacy.uninstall()
            }
            try modern.install(videoURL: videoURL, activate: activate)
        } else {
            try legacy.install(videoURL: videoURL)
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
