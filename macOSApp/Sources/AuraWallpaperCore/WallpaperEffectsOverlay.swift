import AppKit
import QuartzCore

/// Procedural layers stay independent of the wallpaper's AVPlayer, Metal or WebKit content.
final class WallpaperEffectsOverlay: CALayer {
    private let glow = CAGradientLayer()
    private let core = CAGradientLayer()
    private let streak = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let reflection = CAGradientLayer()
    private let ghosts = (0..<3).map { _ in CAGradientLayer() }
    private let sparkles = (0..<48).map { _ in CAShapeLayer() }
    private let rain = (0..<120).map { _ in CAShapeLayer() }

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
        streak.startPoint = CGPoint(x: 0, y: 0.5)
        streak.endPoint = CGPoint(x: 1, y: 0.5)
        addSublayer(streak)
        ring.fillColor = nil
        ring.lineWidth = 1
        addSublayer(ring)
        for sparkle in sparkles { sparkle.name = "sparkle"; addSublayer(sparkle) }
        for drop in rain { drop.name = "rain"; addSublayer(drop) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(settings: WallpaperEffectsSettings, motion: WallpaperEffectsMotion, size: CGSize, scale: CGFloat) {
        frame = CGRect(origin: .zero, size: size)
        let colors = palette(settings.tint)
        let focus = CGPoint(x: size.width * (0.5 + motion.pointer.x * 0.44),
                            y: size.height * (0.5 + motion.pointer.y * 0.44))
        let farFocus = CGPoint(x: size.width * (0.5 + motion.pointer.x * 0.24),
                               y: size.height * (0.5 + motion.pointer.y * 0.24))
        let unit = min(size.width, size.height)
        let glowDiameter = unit * (0.3 + settings.glowSize * 1.1)
        glow.frame = centered(farFocus, diameter: glowDiameter)
        glow.colors = [colors.0.withAlphaComponent(0.6).cgColor,
                       colors.1.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 0.35, 1]
        glow.opacity = settings.glowEnabled ? Float(settings.glowIntensity * motion.presence) : 0

        reflection.frame = bounds.insetBy(dx: -size.width * 0.5, dy: 0)
        let sweep = 0.5 + motion.pointer.x * 0.22 + motion.pointer.y * 0.08
        reflection.colors = [NSColor.clear.cgColor, colors.0.withAlphaComponent(0.01).cgColor,
                              colors.0.withAlphaComponent(0.22).cgColor,
                              colors.1.withAlphaComponent(0.07).cgColor, NSColor.clear.cgColor]
        reflection.locations = [0, NSNumber(value: sweep - 0.12), NSNumber(value: sweep),
                                NSNumber(value: sweep + 0.12), 1]
        reflection.opacity = settings.reflectionEnabled ? Float(settings.reflectionIntensity * motion.presence) : 0

        let flareAlpha = settings.flareEnabled ? Float(settings.flareIntensity * motion.presence) : 0
        core.frame = centered(focus, diameter: unit * 0.12)
        core.colors = [NSColor.white.withAlphaComponent(0.9).cgColor,
                       colors.0.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
        core.locations = [0, 0.16, 1]
        core.opacity = flareAlpha
        let streakWidth = unit * (0.45 + settings.flareIntensity * 0.6)
        streak.frame = CGRect(x: focus.x - streakWidth / 2, y: focus.y - 1, width: streakWidth, height: 2)
        streak.colors = [NSColor.clear.cgColor, colors.0.withAlphaComponent(0.15).cgColor,
                         NSColor.white.withAlphaComponent(0.85).cgColor,
                         colors.0.withAlphaComponent(0.15).cgColor, NSColor.clear.cgColor]
        streak.locations = [0, 0.35, 0.5, 0.65, 1]
        streak.opacity = flareAlpha
        for (index, ghost) in ghosts.enumerated() {
            let distance = [0.3, 0.75, 1.3][index]
            let position = CGPoint(x: size.width / 2 - motion.pointer.x * size.width * distance * 0.35,
                                   y: size.height / 2 - motion.pointer.y * size.height * distance * 0.35)
            ghost.frame = centered(position, diameter: unit * [0.045, 0.09, 0.16][index])
            ghost.colors = [colors.1.withAlphaComponent(0.02).cgColor,
                            colors.1.withAlphaComponent(0.22).cgColor, NSColor.clear.cgColor]
            ghost.locations = [0, 0.7, 1]
            ghost.opacity = flareAlpha
        }
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: centered(focus, diameter: unit * 0.2), transform: nil)
        ring.strokeColor = colors.1.withAlphaComponent(0.22).cgColor
        ring.opacity = flareAlpha

        let count = settings.sparkleEnabled && settings.sparkleAmount > 0 ? Int(8 + settings.sparkleAmount * 40) : 0
        for (index, sparkle) in sparkles.enumerated() {
            sparkle.isHidden = index >= count
            guard index < count else { continue }
            let seed = Double(index + 1)
            let x = fraction(seed * 0.61803398875)
            let y = fraction(seed * 0.41421356237 + motion.time * (0.012 + fraction(seed * 0.7) * 0.018))
            let dx = focus.x / max(1, size.width) - x
            let dy = focus.y / max(1, size.height) - y
            let attraction = settings.reactsToCursor ? exp(-(dx * dx + dy * dy) * 12) * motion.presence : 0
            let depth = settings.parallaxEnabled ? settings.parallaxAmount * (0.01 + fraction(seed * 0.31) * 0.04) : 0
            let position = CGPoint(x: (x + sin(motion.time + seed) * 0.01 + dx * attraction * 0.14 - motion.pointer.x * depth) * size.width,
                                   y: (y + dy * attraction * 0.14 - motion.pointer.y * depth) * size.height)
            let radius = 1.3 + fraction(seed * 0.7548) * 2.5
            sparkle.frame = CGRect(x: position.x - radius, y: position.y - radius,
                                   width: radius * 2, height: radius * 2)
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
            sparkle.opacity = Float((0.12 + (sin(motion.time * 1.7 + seed * 2.4) + 1) * 0.22
                + attraction * 0.35) * settings.sparkleAmount)
        }

        let dropCount = settings.rainEnabled && settings.rainAmount > 0 ? Int(20 + settings.rainAmount * 100) : 0
        for (index, drop) in rain.enumerated() {
            drop.isHidden = index >= dropCount
            guard index < dropCount else { continue }
            let seed = Double(index + 1)
            let depth = 0.4 + fraction(seed * 0.75487766) * 0.6
            let fall = motion.time * (0.4 + settings.rainSpeed * 1.6) * depth
            let wind = (settings.rainAngle - 0.5) * 0.6 + (settings.reactsToCursor ? motion.pointer.x * 0.08 : 0)
            let parallax = settings.parallaxEnabled ? motion.pointer.x * settings.parallaxAmount * 0.04 * depth : 0
            let x = fraction(seed * 0.61803398875 + fall * wind - parallax) * (size.width + 60) - 30
            let y = (1 - fraction(seed * 0.41421356237 + fall)) * (size.height + 60) - 30
            let length = (8 + depth * 22) * max(0.65, unit / 900)
            let dropFrame = CGRect(x: min(x, x - wind * length) - 2, y: y - 2,
                                   width: abs(wind * length) + 4, height: length + 4)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - dropFrame.minX, y: y - dropFrame.minY))
            path.addLine(to: CGPoint(x: x - wind * length - dropFrame.minX, y: y + length - dropFrame.minY))
            drop.frame = dropFrame
            drop.path = path
            drop.strokeColor = colors.0.withAlphaComponent(0.18 + depth * 0.3).cgColor
            drop.lineWidth = 0.5 + depth
            drop.lineCap = .round
            drop.contentsScale = scale
        }
    }

    private func centered(_ point: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
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
