import AppKit
import QuartzCore

/// Procedural layers stay independent of the wallpaper's AVPlayer, Metal or WebKit content.
final class WallpaperEffectsOverlay: CALayer {
    private let glow = CAGradientLayer()
    private let core = CAGradientLayer()
    private let reflection = CAGradientLayer()
    private let ghosts = (0..<3).map { _ in CAGradientLayer() }
    private let sparkles = (0..<48).map { _ in CAShapeLayer() }
    private let rain = WallpaperRainLayer()

    var glowPosition: CGPoint { glow.position }
    var flarePosition: CGPoint { core.position }
    var glowOpacity: Float { isHidden ? 0 : glow.opacity }
    var flareOpacity: Float { isHidden ? 0 : core.opacity }

    override init() {
        super.init()
        masksToBounds = true
        zPosition = 1
        glow.name = "glow"
        core.name = "flare"
        reflection.name = "reflection"
        reflection.startPoint = CGPoint(x: 0, y: 0.15)
        reflection.endPoint = CGPoint(x: 1, y: 0.85)
        addSublayer(reflection)
        for gradient in [glow, core] + ghosts {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            addSublayer(gradient)
        }
        for sparkle in sparkles { sparkle.name = "sparkle"; addSublayer(sparkle) }
        addSublayer(rain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var configuredSettings: WallpaperEffectsSettings?
    private var configuredSize = CGSize.zero
    private var configuredScale: CGFloat = 0
    private var sparkleCount = 0
    private(set) var styleGeneration: UInt64 = 0

    /// Pointer-only frames update transforms and opacity; gradient textures and paths stay cached.
    func render(settings: WallpaperEffectsSettings, motion: WallpaperEffectsMotion, size: CGSize, scale: CGFloat) {
        configure(settings: settings, size: size, scale: scale)
        let focus = CGPoint(x: size.width * (0.5 + motion.pointer.x * 0.44),
                            y: size.height * (0.5 + motion.pointer.y * 0.44))
        glow.position = CGPoint(x: size.width * (0.5 + motion.pointer.x * 0.24),
                                y: size.height * (0.5 + motion.pointer.y * 0.24))
        glow.opacity = settings.glowEnabled ? Float(settings.glowIntensity * motion.presence) : 0
        reflection.position = CGPoint(x: size.width * (0.5 + motion.pointer.x * 0.44 + motion.pointer.y * 0.16),
                                      y: size.height / 2)
        reflection.opacity = settings.reflectionEnabled ? Float(settings.reflectionIntensity * motion.presence) : 0
        let flareAlpha = settings.flareEnabled ? Float(settings.flareIntensity * motion.presence) : 0
        core.position = focus
        core.opacity = flareAlpha
        for (index, ghost) in ghosts.enumerated() {
            let distance = [0.3, 0.75, 1.3][index]
            ghost.position = CGPoint(x: size.width / 2 - motion.pointer.x * size.width * distance * 0.35,
                                     y: size.height / 2 - motion.pointer.y * size.height * distance * 0.35)
            ghost.opacity = flareAlpha
        }
        for (index, sparkle) in sparkles.prefix(sparkleCount).enumerated() {
            let seed = Double(index + 1)
            let x = fraction(seed * 0.61803398875)
            let y = fraction(seed * 0.41421356237 + motion.time * (0.012 + fraction(seed * 0.7) * 0.018))
            let dx = focus.x / max(1, size.width) - x
            let dy = focus.y / max(1, size.height) - y
            let attraction = settings.reactsToCursor ? exp(-(dx * dx + dy * dy) * 12) * motion.presence : 0
            let depth = settings.parallaxEnabled ? settings.parallaxAmount * (0.01 + fraction(seed * 0.31) * 0.04) : 0
            sparkle.position = CGPoint(x: (x + sin(motion.time + seed) * 0.01 + dx * attraction * 0.14 - motion.pointer.x * depth) * size.width,
                                       y: (y + dy * attraction * 0.14 - motion.pointer.y * depth) * size.height)
            sparkle.opacity = Float((0.12 + (sin(motion.time * 1.7 + seed * 2.4) + 1) * 0.22
                + attraction * 0.35) * settings.sparkleAmount)
        }
        rain.render(settings: settings, motion: motion, size: size, scale: scale)
    }

    private func configure(settings: WallpaperEffectsSettings, size: CGSize, scale: CGFloat) {
        guard configuredSettings != settings || configuredSize != size || configuredScale != scale else { return }
        configuredSettings = settings
        configuredSize = size
        configuredScale = scale
        styleGeneration &+= 1
        frame = CGRect(origin: .zero, size: size)
        let colors = palette(settings.tint)
        let unit = min(size.width, size.height)
        let glowDiameter = unit * (0.3 + settings.glowSize * 1.1)
        glow.bounds = CGRect(x: 0, y: 0, width: glowDiameter, height: glowDiameter)
        glow.colors = [colors.0.withAlphaComponent(0.6).cgColor,
                       colors.1.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 0.35, 1]
        core.bounds = CGRect(x: 0, y: 0, width: unit * 0.18, height: unit * 0.18)
        core.colors = [colors.0.withAlphaComponent(0.45).cgColor,
                       colors.0.withAlphaComponent(0.14).cgColor, NSColor.clear.cgColor]
        core.locations = [0, 0.28, 1]
        reflection.bounds = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
        reflection.colors = [NSColor.clear.cgColor, colors.0.withAlphaComponent(0.01).cgColor,
                              colors.0.withAlphaComponent(0.22).cgColor,
                              colors.1.withAlphaComponent(0.07).cgColor, NSColor.clear.cgColor]
        reflection.locations = [0, 0.38, 0.5, 0.62, 1]
        for (index, ghost) in ghosts.enumerated() {
            let diameter = unit * [0.045, 0.09, 0.16][index]
            ghost.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ghost.colors = [colors.1.withAlphaComponent(0.10).cgColor,
                            colors.1.withAlphaComponent(0.045).cgColor, NSColor.clear.cgColor]
            ghost.locations = [0, 0.35, 1]
        }
        // These lights are deliberately soft. Cache them at one pixel per point;
        // moving a cached layer must not redraw a display-sized radial gradient.
        for gradient in [glow, core, reflection] + ghosts {
            gradient.shouldRasterize = true
            gradient.rasterizationScale = 1
        }
        sparkleCount = settings.sparkleEnabled && settings.sparkleAmount > 0 ? Int(8 + settings.sparkleAmount * 40) : 0
        for (index, sparkle) in sparkles.enumerated() {
            sparkle.isHidden = index >= sparkleCount
            guard index < sparkleCount else { continue }
            let seed = Double(index + 1)
            let radius = 1.3 + fraction(seed * 0.7548) * 2.5
            sparkle.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            let path = CGMutablePath()
            for point in 0..<8 {
                let angle = Double(point) * .pi / 4
                let length = point.isMultiple(of: 2) ? radius : radius * 0.2
                let vertex = CGPoint(x: radius + cos(angle) * length, y: radius + sin(angle) * length)
                if point == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
            }
            path.closeSubpath()
            sparkle.path = path
            sparkle.fillColor = (index.isMultiple(of: 3) ? colors.1 : colors.0).cgColor
            sparkle.contentsScale = scale
        }
    }

    private func fraction(_ value: Double) -> Double { value - floor(value) }

    private func palette(_ tint: WallpaperEffectsTint) -> (NSColor, NSColor) {
        switch tint {
        case .pearl: return (NSColor(red: 0.78, green: 0.9, blue: 1, alpha: 1), .white)
        case .warm: return (NSColor(red: 1, green: 0.79, blue: 0.44, alpha: 1),
                            NSColor(red: 1, green: 0.45, blue: 0.25, alpha: 1))
        case .aurora: return (NSColor(red: 0.42, green: 1, blue: 0.88, alpha: 1),
                              NSColor(red: 0.74, green: 0.48, blue: 1, alpha: 1))
        }
    }
}
