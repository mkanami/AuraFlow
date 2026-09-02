import AuraWallpaperCore
import Foundation

/// Legacy implementation boundary. The screen-saver installer is kept in the
/// application target because it also owns the bundled screen-saver component;
/// the rest of the app sees only `LockScreenPlatformOperating`.
final class LegacyMacOSAdapter: LockScreenSaverInstalling {
    private let installer: LockScreenSaverInstalling
    private let platformAvailable: Bool

    init(
        installer: LockScreenSaverInstalling = LockScreenSaverInstaller(),
        isAvailable: Bool = ProcessInfo.processInfo.operatingSystemVersion
            .majorVersion >= 13
    ) {
        self.installer = installer
        self.platformAvailable = isAvailable
    }

    var capabilities: PlatformCapabilities {
        platformAvailable ? .legacyMacOS : .unsupported
    }
    var isInstalled: Bool { installer.isInstalled }
    var installationConfirmed: Bool {
        capabilities.isAvailable && installer.installationConfirmed
    }

    func install(_ media: URL) throws {
        try requireAvailability()
        try installer.install(videoURL: media)
    }

    func install(videoURL: URL) throws {
        try requireAvailability()
        try installer.install(videoURL: videoURL)
    }

    func installLockScreenOnly(videoURL: URL) throws {
        try requireAvailability()
        try installer.installLockScreenOnly(videoURL: videoURL)
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
        try requireAvailability()
        try installer.prepareLockScreenMedia(videoURL: videoURL)
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        guard capabilities.isAvailable else {
            return LockScreenOnlyGenerationStatus()
        }
        return installer.lockScreenOnlyStatus(videoURL: videoURL)
    }

    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        try requireAvailability()
        return try installer.repairLockScreenOnlyGeneration(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    func uninstall() throws {
        try installer.uninstall()
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try installer.uninstallLockScreenOnlyPreservingCurrentDesktop()
    }

    func status() -> LockScreenStatus {
        let detailedStatus = lockScreenOnlyStatus(videoURL: nil)
        let confirmed = capabilities.isAvailable && installer.installationConfirmed
        return LockScreenStatus(
            available: capabilities.isAvailable,
            installed: installer.isInstalled,
            confirmed: confirmed,
            needsRepair: installer.isInstalled && !confirmed,
            generation: detailedStatus.generation,
            message: capabilities.availabilityMessage
        )
    }

    private func requireAvailability() throws {
        guard capabilities.isAvailable else {
            throw LockScreenPlatformError.unsupported(
                capabilities.availabilityMessage
                    ?? "Lock Screen is unavailable on this macOS version."
            )
        }
    }
}

/// Selects one platform implementation and keeps the legacy screen saver as
/// the compatibility companion for the modern Aerial route. This preserves the
/// existing all-surfaces and Lock Screen-only transactions while making the
/// platform decision explicit and testable.
final class WallpaperPlatformAdapter: LockScreenSaverInstalling {
    private let modern: ModernMacOS26Adapter
    private let legacy: LegacyMacOSAdapter
    private let unsupported: UnsupportedAdapter

    init(
        modern: ModernMacOS26Adapter = ModernMacOS26Adapter(),
        legacy: LegacyMacOSAdapter = LegacyMacOSAdapter(),
        unsupported: UnsupportedAdapter = UnsupportedAdapter()
    ) {
        self.modern = modern
        self.legacy = legacy
        self.unsupported = unsupported
    }

    var capabilities: PlatformCapabilities {
        if modern.capabilities.isAvailable {
            return modern.capabilities
        }
        if legacy.capabilities.isAvailable {
            return legacy.capabilities
        }
        return unsupported.capabilities
    }

    var isInstalled: Bool {
        modern.isInstalled || legacy.isInstalled
    }

    var installationConfirmed: Bool {
        if modern.capabilities.isAvailable || modern.isInstalled {
            return modern.installationConfirmed && legacy.installationConfirmed
        }
        if legacy.capabilities.isAvailable {
            return legacy.installationConfirmed
        }
        return false
    }

    func install(_ media: URL) throws {
        try install(videoURL: media)
    }

    func install(videoURL: URL) throws {
        if modern.capabilities.isAvailable {
            try installModernAndLegacy(videoURL: videoURL, lockScreenOnly: false)
        } else if legacy.capabilities.isAvailable {
            try legacy.install(videoURL: videoURL)
        } else {
            try unsupported.install(videoURL: videoURL)
        }
    }

    func installLockScreenOnly(videoURL: URL) throws {
        if modern.capabilities.isAvailable {
            try installModernAndLegacy(videoURL: videoURL, lockScreenOnly: true)
        } else if legacy.capabilities.isAvailable {
            try legacy.installLockScreenOnly(videoURL: videoURL)
        } else {
            try unsupported.installLockScreenOnly(videoURL: videoURL)
        }
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
        if modern.capabilities.isAvailable {
            try modern.prepareLockScreenMedia(videoURL: videoURL)
        } else {
            try legacy.prepareLockScreenMedia(videoURL: videoURL)
        }
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        if modern.isInstalled {
            return modern.lockScreenOnlyStatus(videoURL: videoURL)
        }
        if legacy.isInstalled || legacy.capabilities.isAvailable {
            return legacy.lockScreenOnlyStatus(videoURL: videoURL)
        }
        return unsupported.lockScreenOnlyStatus(videoURL: videoURL)
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
        if legacy.capabilities.isAvailable {
            return try legacy.repairLockScreenOnlyGeneration(
                videoURL: videoURL,
                shouldProceed: shouldProceed
            )
        }
        return try unsupported.repairLockScreenOnlyGeneration(
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

    func status() -> LockScreenStatus {
        let selected = capabilities
        guard selected.isAvailable else {
            return unsupported.status()
        }
        let confirmed = installationConfirmed
        let detailedStatus = lockScreenOnlyStatus(videoURL: nil)
        return LockScreenStatus(
            available: true,
            installed: isInstalled,
            confirmed: confirmed,
            needsRepair: isInstalled && !confirmed,
            generation: detailedStatus.generation,
            message: selected.availabilityMessage
        )
    }

    var requiresLockScreenSessionPromotion: Bool {
        modern.capabilities.isAvailable && modern.requiresLockScreenSessionPromotion
    }

    @discardableResult
    func activateLockScreenForCurrentSession() throws -> Bool {
        guard modern.capabilities.isAvailable else { return false }
        return try modern.activateLockScreenForCurrentSession()
    }

    @discardableResult
    func restoreDesktopAfterLockScreenSession() throws -> Bool {
        guard modern.capabilities.isAvailable else { return false }
        return try modern.restoreDesktopAfterLockScreenSession()
    }

    @discardableResult
    func applyCurrentDesktopFallback() -> Bool {
        guard modern.capabilities.isAvailable else { return false }
        return modern.applyCurrentDesktopFallback()
    }

    @discardableResult
    func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        if modern.isInstalled {
            return try modern.repair(
                videoURL: videoURL,
                shouldProceed: shouldProceed
            )
        }
        return try legacy.repair(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    @discardableResult
    func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        if modern.isInstalled {
            return try modern.rearmForNextLock(
                videoURL: videoURL,
                shouldProceed: shouldProceed
            )
        }
        return try legacy.rearmForNextLock(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    private func installModernAndLegacy(
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

/// Source compatibility for integrations that used the old name before the
/// platform boundary was introduced.
typealias LockScreenWallpaperInstaller = WallpaperPlatformAdapter
