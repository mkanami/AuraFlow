import Foundation

/// Describes which Lock Screen implementation was selected without exposing
/// its macOS-specific implementation to the application layer.
public struct PlatformCapabilities: Equatable, Sendable {
    public let platformName: String
    public let minimumMajorOSVersion: Int
    public let supportsLockScreen: Bool
    public let supportsLockScreenOnly: Bool
    public let supportsSecureLockScreen: Bool
    public let supportsAnimatedMedia: Bool
    public let usesPrivateWallpaperFramework: Bool
    public let availabilityMessage: String?

    public init(
        platformName: String,
        minimumMajorOSVersion: Int,
        supportsLockScreen: Bool,
        supportsLockScreenOnly: Bool,
        supportsSecureLockScreen: Bool,
        supportsAnimatedMedia: Bool,
        usesPrivateWallpaperFramework: Bool,
        availabilityMessage: String? = nil
    ) {
        self.platformName = platformName
        self.minimumMajorOSVersion = minimumMajorOSVersion
        self.supportsLockScreen = supportsLockScreen
        self.supportsLockScreenOnly = supportsLockScreenOnly
        self.supportsSecureLockScreen = supportsSecureLockScreen
        self.supportsAnimatedMedia = supportsAnimatedMedia
        self.usesPrivateWallpaperFramework = usesPrivateWallpaperFramework
        self.availabilityMessage = availabilityMessage
    }

    public var isAvailable: Bool { supportsLockScreen }

    public static let legacyMacOS = PlatformCapabilities(
        platformName: "Legacy macOS screen saver",
        minimumMajorOSVersion: 13,
        supportsLockScreen: true,
        supportsLockScreenOnly: true,
        supportsSecureLockScreen: false,
        supportsAnimatedMedia: true,
        usesPrivateWallpaperFramework: false,
        availabilityMessage:
            "The legacy screen saver provides both shared and Lock Screen-only wallpaper on macOS 13 and later."
    )

    public static func modernMacOS26(isAvailable: Bool) -> PlatformCapabilities {
        PlatformCapabilities(
            platformName: "macOS 26 Aerial",
            minimumMajorOSVersion: 26,
            supportsLockScreen: isAvailable,
            supportsLockScreenOnly: isAvailable,
            supportsSecureLockScreen: isAvailable,
            supportsAnimatedMedia: isAvailable,
            usesPrivateWallpaperFramework: true,
            availabilityMessage: isAvailable
                ? "AuraFlow uses the native macOS 26 Aerial Lock Screen."
                : "Lock Screen is unavailable because the macOS 26 Aerial provider is not present."
        )
    }

    public static let unsupported = PlatformCapabilities(
        platformName: "Unsupported macOS",
        minimumMajorOSVersion: 13,
        supportsLockScreen: false,
        supportsLockScreenOnly: false,
        supportsSecureLockScreen: false,
        supportsAnimatedMedia: false,
        usesPrivateWallpaperFramework: false,
        availabilityMessage: "Lock Screen is unavailable on this macOS version."
    )
}

/// Stable status returned by a platform adapter. The detailed generation
/// status remains available to the runtime, while UI code can rely on this
/// small, implementation-independent value.
public struct LockScreenStatus: Equatable, Sendable {
    public let available: Bool
    public let installed: Bool
    public let confirmed: Bool
    public let needsRepair: Bool
    public let generation: UInt64?
    public let message: String?

    public init(
        available: Bool,
        installed: Bool,
        confirmed: Bool,
        needsRepair: Bool = false,
        generation: UInt64? = nil,
        message: String? = nil
    ) {
        self.available = available
        self.installed = installed
        self.confirmed = confirmed
        self.needsRepair = needsRepair
        self.generation = generation
        self.message = message
    }

    public var isReady: Bool {
        available && installed && confirmed && !needsRepair
    }

    public static func unavailable(_ message: String) -> LockScreenStatus {
        LockScreenStatus(
            available: false,
            installed: false,
            confirmed: false,
            message: message
        )
    }
}

public enum LockScreenPlatformError: LocalizedError, Equatable {
    case unsupported(String)
    case fallbackRollbackFailed(
        installError: String,
        rollbackError: String
    )

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case let .fallbackRollbackFailed(installError, rollbackError):
            return "Legacy Lock Screen fallback failed (\(installError)); "
                + "restoring the modern Lock Screen route also failed "
                + "(\(rollbackError))."
        }
    }
}

/// The application-facing boundary for all macOS Lock Screen behavior.
/// Implementations may use a screen saver, the macOS 26 Aerial provider, or a
/// safe unsupported implementation, but callers do not depend on those
/// details.
public protocol LockScreenPlatform: AnyObject {
    var capabilities: PlatformCapabilities { get }

    func install(_ media: URL) async throws
    func uninstall() throws
    func status() -> LockScreenStatus
}

/// Runtime operations needed by the wallpaper agent and controller. The
/// smaller `LockScreenPlatform` protocol is intentionally kept as the public
/// conceptual API; this refinement carries lifecycle and recovery hooks that
/// are still required by the existing runtime.
public protocol LockScreenPlatformOperating: LockScreenPlatform {
    var isInstalled: Bool { get }
    var installationConfirmed: Bool { get }

    func install(videoURL: URL) async throws
    func installLockScreenOnly(videoURL: URL) async throws
    /// Installs the compatibility screen saver without routing through a
    /// modern provider. Platform adapters may use the optional previous
    /// source to restore native Lock Screen state if the fallback fails.
    func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws
    func prepareLockScreenMedia(videoURL: URL) async throws
    func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus
    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool
    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws
    /// Async mutation variants used by application and agent orchestration.
    /// Implementations must serialize these with async installs and the
    /// synchronous compatibility methods on the same mutation coordinator.
    func uninstallAsync() async throws
    func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws

    var requiresLockScreenSessionPromotion: Bool { get }
    @discardableResult
    func activateLockScreenForCurrentSession() throws -> Bool
    @discardableResult
    func restoreDesktopAfterLockScreenSession() throws -> Bool
    @discardableResult
    func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool
    @discardableResult
    func applyCurrentDesktopFallback() -> Bool
    @discardableResult
    func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool
    @discardableResult
    func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool
}

/// A read-only snapshot of the lock-only installation.  The runtime uses this
/// instead of treating the presence of a marker file as proof that macOS is
/// still presenting AuraFlow.
public struct LockScreenOnlyGenerationStatus: Equatable, Sendable {
    public var installed: Bool
    public var sourceMatches: Bool
    public var assetValid: Bool
    public var providerAvailable: Bool
    public var providerRunning: Bool
    public var wallpaperStoreValid: Bool
    public var screenSaverSelected: Bool
    public var sourceSignature: String?
    public var generation: UInt64?
    public var assetID: String?
    public var storeHash: String?

    public init(
        installed: Bool = false,
        sourceMatches: Bool = false,
        assetValid: Bool = false,
        providerAvailable: Bool = false,
        providerRunning: Bool = false,
        wallpaperStoreValid: Bool = false,
        screenSaverSelected: Bool = false,
        sourceSignature: String? = nil,
        generation: UInt64? = nil,
        assetID: String? = nil,
        storeHash: String? = nil
    ) {
        self.installed = installed
        self.sourceMatches = sourceMatches
        self.assetValid = assetValid
        self.providerAvailable = providerAvailable
        self.providerRunning = providerRunning
        self.wallpaperStoreValid = wallpaperStoreValid
        self.screenSaverSelected = screenSaverSelected
        self.sourceSignature = sourceSignature
        self.generation = generation
        self.assetID = assetID
        self.storeHash = storeHash
    }

    public var isReady: Bool {
        installed
            && sourceMatches
            && assetValid
            && providerAvailable
            && wallpaperStoreValid
            && screenSaverSelected
    }
}

public protocol LockScreenSaverInstalling: LockScreenPlatformOperating {
    func install(videoURL: URL) async throws
    func installLockScreenOnly(videoURL: URL) async throws
    /// Prepares native Lock Screen media without changing the active
    /// wallpaper store, provider, or installation.
    func prepareLockScreenMedia(videoURL: URL) async throws
    func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus
    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool
    func uninstall() throws
    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws
}

/// Injectable implementation boundary for the native macOS 26 provider.
/// Keeping the concrete Aerial installer out of the adapter makes platform
/// selection and provider-removal behavior testable without touching the real
/// wallpaper store.
public protocol ModernLockScreenInstalling: LockScreenSaverInstalling {
    var isAvailable: Bool { get }
}

public extension LockScreenSaverInstalling {
    var capabilities: PlatformCapabilities {
        .legacyMacOS
    }

    var installationConfirmed: Bool {
        isInstalled
    }

    func install(_ media: URL) async throws {
        try await install(videoURL: media)
    }

    func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        try await install(videoURL: videoURL)
    }

    func status() -> LockScreenStatus {
        let detailedStatus = lockScreenOnlyStatus(videoURL: nil)
        let confirmed = installationConfirmed
        return LockScreenStatus(
            available: capabilities.isAvailable,
            installed: isInstalled,
            confirmed: confirmed,
            needsRepair: isInstalled && !confirmed,
            generation: detailedStatus.generation,
            message: capabilities.availabilityMessage
        )
    }

    func installLockScreenOnly(videoURL: URL) async throws {
        try await install(videoURL: videoURL)
    }

    func prepareLockScreenMedia(videoURL: URL) async throws {
        // Legacy screen-saver implementations have no separate media cache.
    }

    func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        let confirmed = installationConfirmed
        return LockScreenOnlyGenerationStatus(
            installed: isInstalled,
            sourceMatches: confirmed,
            assetValid: confirmed,
            providerAvailable: confirmed,
            providerRunning: confirmed,
            wallpaperStoreValid: confirmed,
            screenSaverSelected: confirmed
        )
    }

    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool = { true }
    ) async throws -> Bool {
        guard shouldProceed() else { return false }
        return false
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try uninstall()
    }

    func uninstallAsync() async throws {
        try uninstall()
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws {
        try uninstallLockScreenOnlyPreservingCurrentDesktop()
    }

    var requiresLockScreenSessionPromotion: Bool { false }

    func activateLockScreenForCurrentSession() throws -> Bool { false }

    func restoreDesktopAfterLockScreenSession() throws -> Bool { false }

    func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool {
        try restoreDesktopAfterLockScreenSession()
    }

    func applyCurrentDesktopFallback() -> Bool { false }

    @discardableResult
    func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try await repairLockScreenOnlyGeneration(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    @discardableResult
    func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try await repairLockScreenOnlyGeneration(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }
}
