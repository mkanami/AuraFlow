import Foundation

public enum WallpaperEffectsTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case pearl, warm, aurora
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pearl: return "Pearl"
        case .warm: return "Warm"
        case .aurora: return "Aurora"
        }
    }
}

/// Desktop presentation preferences, deliberately separate from playback and login registration.
public struct WallpaperEffectsSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var reactsToCursor = true
    public var smoothing = 0.55
    public var parallaxEnabled = true
    public var parallaxAmount = 0.35
    public var glowEnabled = true
    public var glowIntensity = 0.35
    public var glowSize = 0.5
    public var flareEnabled = false
    public var flareIntensity = 0.35
    public var reflectionEnabled = false
    public var reflectionIntensity = 0.3
    public var bloomEnabled = false
    public var bloomIntensity = 0.35
    public var bloomRadius = 0.4
    public var blurEnabled = false
    public var blurAmount = 0.15
    public var sparkleEnabled = false
    public var sparkleAmount = 0.35
    public var rainEnabled = false
    public var rainAmount = 0.45
    public var rainSpeed = 0.5
    public var rainAngle = 0.5
    public var rainColor: WallpaperRainColor = .blue
    public var ambientSpeed = 0.3
    public var tint: WallpaperEffectsTint = .pearl

    public init() {}

    public var hasVisibleEffects: Bool {
        hasAnimatedEffects || (enabled && ((bloomEnabled && bloomIntensity > 0) || (blurEnabled && blurAmount > 0)))
    }

    public var hasAnimatedEffects: Bool {
        enabled && ((parallaxEnabled && parallaxAmount > 0)
            || (glowEnabled && glowIntensity > 0)
            || (flareEnabled && flareIntensity > 0)
            || (reflectionEnabled && reflectionIntensity > 0)
            || (sparkleEnabled && sparkleAmount > 0)
            || (rainEnabled && rainAmount > 0))
    }

    public func normalized() -> Self {
        var result = self
        let defaults = Self()
        for key in Self.numericKeys {
            let value = self[keyPath: key]
            result[keyPath: key] = value.isFinite ? min(1, max(0, value)) : defaults[keyPath: key]
        }
        return result
    }

    private static let numericKeys: [WritableKeyPath<Self, Double>] = [
        \.smoothing, \.parallaxAmount, \.glowIntensity, \.glowSize,
        \.flareIntensity, \.reflectionIntensity, \.bloomIntensity, \.bloomRadius, \.blurAmount,
        \.sparkleAmount, \.rainAmount, \.rainSpeed, \.rainAngle, \.ambientSpeed
    ]

    private enum CodingKeys: String, CodingKey {
        case enabled, reactsToCursor, smoothing, parallaxEnabled, parallaxAmount
        case glowEnabled, glowIntensity, glowSize, flareEnabled, flareIntensity
        case reflectionEnabled, reflectionIntensity, bloomEnabled, bloomIntensity, bloomRadius, blurEnabled, blurAmount
        case sparkleEnabled, sparkleAmount, ambientSpeed, tint
        case rainEnabled, rainAmount, rainSpeed, rainAngle, rainColor
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        reactsToCursor = try values.decodeIfPresent(Bool.self, forKey: .reactsToCursor) ?? reactsToCursor
        smoothing = try values.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        parallaxEnabled = try values.decodeIfPresent(Bool.self, forKey: .parallaxEnabled) ?? parallaxEnabled
        parallaxAmount = try values.decodeIfPresent(Double.self, forKey: .parallaxAmount) ?? parallaxAmount
        glowEnabled = try values.decodeIfPresent(Bool.self, forKey: .glowEnabled) ?? glowEnabled
        glowIntensity = try values.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? glowIntensity
        glowSize = try values.decodeIfPresent(Double.self, forKey: .glowSize) ?? glowSize
        flareEnabled = try values.decodeIfPresent(Bool.self, forKey: .flareEnabled) ?? flareEnabled
        flareIntensity = try values.decodeIfPresent(Double.self, forKey: .flareIntensity) ?? flareIntensity
        reflectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .reflectionEnabled) ?? reflectionEnabled
        reflectionIntensity = try values.decodeIfPresent(Double.self, forKey: .reflectionIntensity) ?? reflectionIntensity
        bloomEnabled = try values.decodeIfPresent(Bool.self, forKey: .bloomEnabled) ?? bloomEnabled
        bloomIntensity = try values.decodeIfPresent(Double.self, forKey: .bloomIntensity) ?? bloomIntensity
        bloomRadius = try values.decodeIfPresent(Double.self, forKey: .bloomRadius) ?? bloomRadius
        blurEnabled = try values.decodeIfPresent(Bool.self, forKey: .blurEnabled) ?? blurEnabled
        blurAmount = try values.decodeIfPresent(Double.self, forKey: .blurAmount) ?? blurAmount
        sparkleEnabled = try values.decodeIfPresent(Bool.self, forKey: .sparkleEnabled) ?? sparkleEnabled
        sparkleAmount = try values.decodeIfPresent(Double.self, forKey: .sparkleAmount) ?? sparkleAmount
        rainEnabled = try values.decodeIfPresent(Bool.self, forKey: .rainEnabled) ?? rainEnabled
        rainAmount = try values.decodeIfPresent(Double.self, forKey: .rainAmount) ?? rainAmount
        rainSpeed = try values.decodeIfPresent(Double.self, forKey: .rainSpeed) ?? rainSpeed
        rainAngle = try values.decodeIfPresent(Double.self, forKey: .rainAngle) ?? rainAngle
        if let rawRainColor = try values.decodeIfPresent(String.self, forKey: .rainColor) {
            rainColor = WallpaperRainColor(rawValue: rawRainColor) ?? .blue
        }
        ambientSpeed = try values.decodeIfPresent(Double.self, forKey: .ambientSpeed) ?? ambientSpeed
        if let rawTint = try values.decodeIfPresent(String.self, forKey: .tint) {
            tint = WallpaperEffectsTint(rawValue: rawTint) ?? .pearl
        }
        self = normalized()
    }
}

public enum WallpaperEffectsPreset: String, CaseIterable, Identifiable {
    case subtle, cinematic, dreamy
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var settings: WallpaperEffectsSettings {
        var result = WallpaperEffectsSettings()
        result.enabled = true
        switch self {
        case .subtle: break
        case .cinematic:
            result.parallaxAmount = 0.6
            result.glowIntensity = 0.3
            result.glowSize = 0.35
            result.flareEnabled = true
            result.flareIntensity = 0.55
            result.reflectionEnabled = true
            result.reflectionIntensity = 0.2
            result.tint = .warm
        case .dreamy:
            result.parallaxAmount = 0.45
            result.smoothing = 0.8
            result.glowIntensity = 0.55
            result.glowSize = 0.7
            result.flareEnabled = true
            result.flareIntensity = 0.25
            result.sparkleEnabled = true
            result.sparkleAmount = 0.55
            result.bloomEnabled = true
            result.bloomIntensity = 0.25
            result.tint = .aurora
        }
        return result
    }
}
