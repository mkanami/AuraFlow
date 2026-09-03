import Foundation

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
