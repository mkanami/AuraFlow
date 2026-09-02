import Foundation

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

public protocol LockScreenSaverInstalling {
    var isInstalled: Bool { get }
    var installationConfirmed: Bool { get }

    func install(videoURL: URL) throws
    func installLockScreenOnly(videoURL: URL) throws
    /// Prepares native Lock Screen media without changing the active
    /// wallpaper store, provider, or installation.
    func prepareLockScreenMedia(videoURL: URL) throws
    func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus
    @discardableResult
    func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool
    func uninstall() throws
    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws
}

public extension LockScreenSaverInstalling {
    var installationConfirmed: Bool {
        isInstalled
    }

    func installLockScreenOnly(videoURL: URL) throws {
        try install(videoURL: videoURL)
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
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
    ) throws -> Bool {
        guard shouldProceed() else { return false }
        return false
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try uninstall()
    }
}
