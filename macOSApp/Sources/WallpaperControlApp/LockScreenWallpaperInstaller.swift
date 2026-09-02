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
        if modern.isInstalled {
            return modern.installationConfirmed
                && legacy.installationConfirmed
        }
        return legacy.installationConfirmed
    }

    func install(videoURL: URL) throws {
        if modern.isAvailable {
            try installModernAndScreenSaver(
                videoURL: videoURL,
                lockScreenOnly: false
            )
        } else {
            try legacy.install(videoURL: videoURL)
        }
    }

    func installLockScreenOnly(videoURL: URL) throws {
        if modern.isAvailable {
            try installModernAndScreenSaver(
                videoURL: videoURL,
                lockScreenOnly: true
            )
        } else {
            try legacy.installLockScreenOnly(videoURL: videoURL)
        }
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
        guard modern.isAvailable else { return }
        try modern.prepareLockScreenMedia(videoURL: videoURL)
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        if modern.isInstalled {
            return modern.lockScreenOnlyStatus(videoURL: videoURL)
        }
        return legacy.lockScreenOnlyStatus(videoURL: videoURL)
    }

    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        if modern.isInstalled {
            return try modern.repairLockScreenOnlyGeneration(
                videoURL: videoURL,
                shouldProceed: shouldProceed
            )
        }
        return try legacy.repairLockScreenOnlyGeneration(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    func uninstall() throws {
        if modern.isInstalled {
            try modern.uninstall()
        }
        try legacy.uninstall()
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        if modern.isInstalled {
            try modern.uninstallLockScreenOnlyPreservingCurrentDesktop()
        }
        try legacy.uninstall()
    }

    private func installModernAndScreenSaver(
        videoURL: URL,
        lockScreenOnly: Bool
    ) throws {
        if lockScreenOnly {
            try legacy.installLockScreenOnly(videoURL: videoURL)
        } else {
            try legacy.install(videoURL: videoURL)
        }
        do {
            if lockScreenOnly {
                try modern.installLockScreenOnly(videoURL: videoURL)
            } else {
                try modern.install(videoURL: videoURL)
            }
        } catch {
            try? legacy.uninstall()
            throw error
        }
    }
}
