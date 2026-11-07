import Foundation

/// Read-only diagnostics from the installed renderer, independent of the app's preview.
/// Cursor values are normalized to this surface; no global pointer coordinates are recorded.
public struct WallpaperEffectsStatus: Codable, Equatable, Sendable {
    public var surface: String
    public var enabled: Bool
    public var active: Bool
    public var pauseReason: String?
    public var framesPerSecond: Double
    public var renderedFrames: UInt64
    public var cursorX: Double
    public var cursorY: Double
    public var parallaxX: Double
    public var parallaxY: Double
    public var glowX: Double
    public var glowY: Double
    public var glowOpacity: Double
    public var flareX: Double
    public var flareY: Double
    public var flareOpacity: Double
}
