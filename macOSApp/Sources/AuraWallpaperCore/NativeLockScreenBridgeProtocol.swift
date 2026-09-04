import Foundation

/// The result of the cheap preflight that runs before AuraFlow offers the
/// native Lock Screen route. The checker intentionally lives in the portable
/// core and only inspects files and OS metadata; it never imports Apple's
/// private framework.
public enum NativeLockScreenBridgeAvailability: Equatable, Sendable {
    case available
    case unsupportedOperatingSystem(currentMajorVersion: Int)
    case executableMissing
    case executableNotRunnable
    case privateFrameworkMissing(path: String)
    case runtimeFailure(reason: String)

    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var message: String {
        switch self {
        case .available:
            return "Native macOS 26 Lock Screen bridge is available."
        case .unsupportedOperatingSystem(let version):
            return "Native Lock Screen requires macOS 26 or later (detected macOS \(version)); the legacy screen saver remains available."
        case .executableMissing:
            return "Native Lock Screen bridge is not bundled in this build; the legacy screen saver remains available."
        case .executableNotRunnable:
            return "Native Lock Screen bridge is not executable; the legacy screen saver remains available."
        case .privateFrameworkMissing(let path):
            return "Native Lock Screen is disabled because the required private framework is unavailable (\(path)); the legacy screen saver remains available."
        case .runtimeFailure(let reason):
            return "Native Lock Screen bridge became unavailable (\(reason)); the legacy screen saver is being used."
        }
    }
}

/// Capability preflight for the optional native bridge. A missing framework,
/// missing helper, or unsupported OS is a normal compatibility state, not a
/// process-launch error. Callers can therefore fail closed and select the
/// legacy screen saver before mutating Lock Screen state.
public struct NativeLockScreenBridgeCapabilities: Equatable, Sendable {
    public static let minimumMajorOSVersion = 26
    public static let requiredPrivateFrameworkPaths = [
        "/System/Library/PrivateFrameworks/Wallpaper.framework",
        "/System/Library/PrivateFrameworks/WallpaperTypes.framework",
    ]

    public let availability: NativeLockScreenBridgeAvailability

    public init(availability: NativeLockScreenBridgeAvailability) {
        self.availability = availability
    }

    public var isAvailable: Bool { availability.isAvailable }
    public var message: String { availability.message }
}

public enum NativeLockScreenBridgeCapabilityChecker {
    public static func check(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion,
        executableURL: URL?,
        fileManager: FileManager = .default,
        privateFrameworkPaths: [String] = NativeLockScreenBridgeCapabilities
            .requiredPrivateFrameworkPaths
    ) -> NativeLockScreenBridgeCapabilities {
        guard operatingSystemVersion.majorVersion >=
                NativeLockScreenBridgeCapabilities.minimumMajorOSVersion
        else {
            return NativeLockScreenBridgeCapabilities(
                availability: .unsupportedOperatingSystem(
                    currentMajorVersion: operatingSystemVersion.majorVersion
                )
            )
        }

        guard let executableURL else {
            return NativeLockScreenBridgeCapabilities(
                availability: .executableMissing
            )
        }
        guard fileManager.fileExists(atPath: executableURL.path) else {
            return NativeLockScreenBridgeCapabilities(
                availability: .executableMissing
            )
        }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return NativeLockScreenBridgeCapabilities(
                availability: .executableNotRunnable
            )
        }

        for path in privateFrameworkPaths {
            guard fileManager.fileExists(atPath: path) else {
                return NativeLockScreenBridgeCapabilities(
                    availability: .privateFrameworkMissing(path: path)
                )
            }
        }

        return NativeLockScreenBridgeCapabilities(availability: .available)
    }
}

/// Commands exchanged between the portable wallpaper agent and the optional
/// macOS 26 native Lock Screen bridge process. Keeping this wire contract in
/// the platform-neutral core prevents the agent from importing private APIs.
public enum NativeLockScreenBridgeAction: String, Codable, Sendable {
    case prepare
    case show
    case hide
    case pause
    case resume
    case shutdown
}

public struct NativeLockScreenBridgeRequest: Codable, Sendable {
    public let id: String
    public let action: NativeLockScreenBridgeAction

    public init(
        id: String = UUID().uuidString,
        action: NativeLockScreenBridgeAction
    ) {
        self.id = id
        self.action = action
    }
}

public struct NativeLockScreenBridgeResponse: Codable, Sendable {
    public let id: String
    public let action: NativeLockScreenBridgeAction
    public let succeeded: Bool
    public let errorDescription: String?

    public init(
        id: String,
        action: NativeLockScreenBridgeAction,
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.action = action
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}
