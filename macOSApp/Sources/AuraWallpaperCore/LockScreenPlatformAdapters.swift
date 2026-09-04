import Foundation

/// Adapter for the native Aerial route introduced for the modern macOS
/// Lock Screen. All knowledge of the private installer stays behind this
/// type; callers use only `LockScreenPlatformOperating`.
public final class ModernMacOS26Adapter: LockScreenSaverInstalling {
    private let installer: ModernLockScreenInstalling
    private let operatingSystemVersion: OperatingSystemVersion

    public init(
        installer: ModernLockScreenInstalling = AerialLockScreenInstaller(),
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion
    ) {
        self.installer = installer
        self.operatingSystemVersion = operatingSystemVersion
    }

    public var capabilities: PlatformCapabilities {
        .modernMacOS26(isAvailable: isModernOS && installer.isAvailable)
    }

    public var isInstalled: Bool {
        installer.isInstalled
    }

    public var installationConfirmed: Bool {
        guard capabilities.isAvailable else { return false }
        return installer.installationConfirmed
    }

    public func install(_ media: URL) async throws {
        try requireAvailability()
        try await installer.install(videoURL: media)
    }

    public func install(videoURL: URL) async throws {
        try await install(videoURL)
    }

    public func installLockScreenOnly(videoURL: URL) async throws {
        try requireAvailability()
        try await installer.installLockScreenOnly(videoURL: videoURL)
    }

    public func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        throw LockScreenPlatformError.unsupported(
            "The legacy Lock Screen fallback is not owned by the modern adapter."
        )
    }

    public func prepareLockScreenMedia(videoURL: URL) async throws {
        try requireAvailability()
        try await installer.prepareLockScreenMedia(videoURL: videoURL)
    }

    public func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        guard capabilities.isAvailable else {
            return LockScreenOnlyGenerationStatus()
        }
        return installer.lockScreenOnlyStatus(videoURL: videoURL)
    }

    @discardableResult
    public func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try requireAvailability()
        return try await installer.repairLockScreenOnlyGeneration(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    public func uninstall() throws {
        // Cleanup remains allowed if a macOS update removed the provider after
        // installation. This prevents stale AuraFlow markers from becoming
        // permanent just because the provider is no longer available.
        try installer.uninstall()
    }

    public func uninstallAsync() async throws {
        try await installer.uninstallAsync()
    }

    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try installer.uninstallLockScreenOnlyPreservingCurrentDesktop()
    }

    public func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws {
        try await installer
            .uninstallLockScreenOnlyPreservingCurrentDesktopAsync()
    }

    public func status() -> LockScreenStatus {
        guard capabilities.isAvailable else {
            return .unavailable(
                capabilities.availabilityMessage
                    ?? "Lock Screen is unavailable on this macOS version."
            )
        }

        let confirmed = installer.installationConfirmed
        let detailedStatus = installer.lockScreenOnlyStatus(videoURL: nil)
        return LockScreenStatus(
            available: true,
            installed: installer.isInstalled,
            confirmed: confirmed,
            needsRepair: installer.isInstalled && !confirmed,
            generation: detailedStatus.generation,
            message: capabilities.availabilityMessage
        )
    }

    public var requiresLockScreenSessionPromotion: Bool {
        guard capabilities.isAvailable else { return false }
        return installer.requiresLockScreenSessionPromotion
    }

    @discardableResult
    public func activateLockScreenForCurrentSession() throws -> Bool {
        try requireAvailability()
        return try installer.activateLockScreenForCurrentSession()
    }

    @discardableResult
    public func restoreDesktopAfterLockScreenSession() throws -> Bool {
        try requireAvailability()
        return try installer.restoreDesktopAfterLockScreenSession()
    }

    @discardableResult
    public func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool {
        try requireAvailability()
        return try await installer.restoreDesktopAfterLockScreenSessionAsync()
    }

    @discardableResult
    public func applyCurrentDesktopFallback() -> Bool {
        guard capabilities.isAvailable else { return false }
        return installer.applyCurrentDesktopFallback()
    }

    @discardableResult
    public func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try requireAvailability()
        return try await installer.repair(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    @discardableResult
    public func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        try requireAvailability()
        return try await installer.rearmForNextLock(
            videoURL: videoURL,
            shouldProceed: shouldProceed
        )
    }

    private var isModernOS: Bool {
        operatingSystemVersion.majorVersion >= 26
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

/// Builds the platform implementation used by the standalone wallpaper agent.
/// The legacy screen saver is owned by the main application target, so the
/// agent must not enter the native Aerial lifecycle on older macOS releases or
/// when the modern provider has disappeared after an update.
public enum LockScreenPlatformFactory {
    public static func makeAgentPlatform(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion,
        modernInstaller: ModernLockScreenInstalling? = nil,
        nativeBridgeURL: URL? = nil
    ) -> LockScreenPlatformOperating {
        guard operatingSystemVersion.majorVersion >= 26 else {
            return UnsupportedAdapter(
                message:
                "The legacy screen saver owns Lock Screen runtime on this macOS version."
            )
        }

        let nativeBridgeCapabilities = NativeLockScreenBridgeCapabilityChecker.checkRuntime(
            operatingSystemVersion: operatingSystemVersion,
            executableURL: nativeBridgeURL,
            requireValidCodeSignature: true
        )
        guard nativeBridgeCapabilities.isAvailable else {
            return UnsupportedAdapter(message: nativeBridgeCapabilities.message)
        }

        let adapter = ModernMacOS26Adapter(
            installer: modernInstaller ?? AerialLockScreenInstaller(),
            operatingSystemVersion: operatingSystemVersion
        )
        guard adapter.capabilities.supportsSecureLockScreen else {
            return UnsupportedAdapter(
                message:
                    "The macOS 26 Aerial provider is unavailable; native Lock Screen runtime is disabled."
            )
        }
        return adapter
    }
}

/// Safe terminal adapter used when neither the modern provider nor the legacy
/// screen saver can service the requested operation.
public final class UnsupportedAdapter: LockScreenSaverInstalling {
    public let capabilities: PlatformCapabilities

    public init(
        message: String = "Lock Screen is unavailable on this macOS version."
    ) {
        capabilities = PlatformCapabilities(
            platformName: "Unsupported macOS",
            minimumMajorOSVersion: 13,
            supportsLockScreen: false,
            supportsLockScreenOnly: false,
            supportsSecureLockScreen: false,
            supportsAnimatedMedia: false,
            usesPrivateWallpaperFramework: false,
            availabilityMessage: message
        )
    }

    public var isInstalled: Bool { false }
    public var installationConfirmed: Bool { false }

    public func install(_ media: URL) async throws {
        try fail()
    }

    public func install(videoURL: URL) async throws {
        try fail()
    }

    public func installLockScreenOnly(videoURL: URL) async throws {
        try fail()
    }

    public func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        try fail()
    }

    public func prepareLockScreenMedia(videoURL: URL) async throws {
        try fail()
    }

    public func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        LockScreenOnlyGenerationStatus()
    }

    @discardableResult
    public func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        throw LockScreenPlatformError.unsupported(
            capabilities.availabilityMessage
                ?? "Lock Screen is unavailable on this macOS version."
        )
    }

    public func uninstall() throws {}

    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {}

    public func status() -> LockScreenStatus {
        .unavailable(
            capabilities.availabilityMessage
                ?? "Lock Screen is unavailable on this macOS version."
        )
    }

    private func fail() throws {
        throw LockScreenPlatformError.unsupported(
            capabilities.availabilityMessage
                ?? "Lock Screen is unavailable on this macOS version."
        )
    }
}
