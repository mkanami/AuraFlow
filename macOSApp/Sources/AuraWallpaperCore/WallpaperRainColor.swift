import Foundation

/// Rain has its own palette, independent of the wallpaper's lighting effects.
public enum WallpaperRainColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, red, cyan, purple, green, gold, pink, white

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blue: return (0.12, 0.46, 1)
        case .red: return (1, 0.16, 0.23)
        case .cyan: return (0.08, 0.86, 1)
        case .purple: return (0.64, 0.30, 1)
        case .green: return (0.14, 0.85, 0.42)
        case .gold: return (1, 0.70, 0.12)
        case .pink: return (1, 0.30, 0.63)
        case .white: return (0.84, 0.93, 1)
        }
    }
}
