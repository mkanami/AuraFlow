import AuraWallpaperCore
import Foundation
import OSLog

private let lockScreenFallbackLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenFallback"
)

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

    func install(_ media: URL) async throws {
        try await install(videoURL: media)
    }

    func install(videoURL: URL) async throws {
        try requireAvailability()
        try await installer.install(videoURL: videoURL)
    }

    func installLockScreenOnly(videoURL: URL) async throws {
        guard capabilities.supportsLockScreenOnly else {
            throw LockScreenPlatformError.unsupported(
                capabilities.availabilityMessage
                    ?? "Lock Screen-only wallpaper is unavailable."
            )
        }
        try requireAvailability()
        try await installer.installLockScreenOnly(videoURL: videoURL)
    }

    func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        try await install(videoURL: videoURL)
    }

    func prepareLockScreenMedia(videoURL: URL) async throws {
        try requireAvailability()
        try await installer.prepareLockScreenMedia(videoURL: videoURL)
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
    ) async throws -> Bool {
        try requireAvailability()
        return try await installer.repairLockScreenOnlyGeneration(
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
        selectedPlatform.capabilities
    }

    var isInstalled: Bool {
        modern.isInstalled || legacy.isInstalled
    }

    var installationConfirmed: Bool {
        if modern.capabilities.isAvailable {
            return modern.installationConfirmed && legacy.installationConfirmed
        }
        return selectedPlatform.installationConfirmed
    }

    func install(_ media: URL) async throws {
        try await install(videoURL: media)
    }

    func install(videoURL: URL) async throws {
        if modern.capabilities.isAvailable {
            try await installModernAndLegacy(videoURL: videoURL, lockScreenOnly: false)
        } else if legacy.capabilities.isAvailable {
            try await legacy.install(videoURL: videoURL)
        } else {
            try await unsupported.install(videoURL: videoURL)
        }
    }

    func installLockScreenOnly(videoURL: URL) async throws {
        if modern.capabilities.isAvailable {
            try await installModernAndLegacy(videoURL: videoURL, lockScreenOnly: true)
        } else if legacy.capabilities.isAvailable {
            try await legacy.installLockScreenOnly(videoURL: videoURL)
        } else {
            try await unsupported.installLockScreenOnly(videoURL: videoURL)
        }
    }

    func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        let removedModernRoute = modern.isInstalled
        do {
            // This is an explicit downgrade transaction. Remove only the
            // modern lock-only route so the user's Desktop routes survive;
            // leave the existing legacy saver in place until its own atomic
            // install has succeeded.
            if removedModernRoute {
                try modern.uninstallLockScreenOnlyPreservingCurrentDesktop()
            }
            try await legacy.install(videoURL: videoURL)
        } catch let installError {
            // Recover the previous native route when this operation removed
            // one. If recovery also fails, surface both failures so the UI
            // and diagnostics do not mistake a partial downgrade for a
            // complete rollback.
            if removedModernRoute, let restoringLockScreenOnlyVideoURL {
                do {
                    try await modern.installLockScreenOnly(
                        videoURL: restoringLockScreenOnlyVideoURL
                    )
                } catch let rollbackError {
                    lockScreenFallbackLogger.error(
                        "Legacy fallback failed and modern Lock Screen rollback failed. install=\(installError.localizedDescription, privacy: .public) rollback=\(rollbackError.localizedDescription, privacy: .public)"
                    )
                    throw LockScreenPlatformError.fallbackRollbackFailed(
                        installError: installError.localizedDescription,
                        rollbackError: rollbackError.localizedDescription
                    )
                }
            }
            throw installError
        }
    }

    func prepareLockScreenMedia(videoURL: URL) async throws {
        try await selectedPlatform.prepareLockScreenMedia(videoURL: videoURL)
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        selectedPlatform.lockScreenOnlyStatus(videoURL: videoURL)
    }

    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try await selectedPlatform.repairLockScreenOnlyGeneration(
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
        guard modern.capabilities.isAvailable else { return false }
        return modern.requiresLockScreenSessionPromotion
    }

    @discardableResult
    func activateLockScreenForCurrentSession() throws -> Bool {
        guard selectedPlatform === modern else { return false }
        return try selectedPlatform.activateLockScreenForCurrentSession()
    }

    @discardableResult
    func restoreDesktopAfterLockScreenSession() throws -> Bool {
        guard selectedPlatform === modern else { return false }
        return try selectedPlatform.restoreDesktopAfterLockScreenSession()
    }

    @discardableResult
    func applyCurrentDesktopFallback() -> Bool {
        guard selectedPlatform === modern else { return false }
        return selectedPlatform.applyCurrentDesktopFallback()
    }

    @discardableResult
    func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try await selectedPlatform.repair(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    @discardableResult
    func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try await selectedPlatform.rearmForNextLock(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    private var selectedPlatform: LockScreenPlatformOperating {
        if modern.capabilities.isAvailable {
            return modern
        }
        if legacy.capabilities.isAvailable {
            return legacy
        }
        return unsupported
    }

    private func installModernAndLegacy(
        videoURL: URL,
        lockScreenOnly: Bool
    ) async throws {
        // The legacy saver is only the compatibility companion here. Its
        // standalone Lock Screen-only mode is intentionally unavailable.
        try await legacy.install(videoURL: videoURL)

        do {
            if lockScreenOnly {
                try await modern.installLockScreenOnly(videoURL: videoURL)
            } else {
                try await modern.install(videoURL: videoURL)
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
