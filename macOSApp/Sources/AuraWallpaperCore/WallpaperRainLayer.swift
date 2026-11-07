import Foundation
import QuartzCore

/// Depth-sorted textured drops. Only positions and wind transforms change per frame.
final class WallpaperRainLayer: CALayer {
    private static let maximumDrops = 512
    private static let variants = 8
    private final class Drop {
        let layer = CALayer()
        let variant: Int
        var x: Double
        var fall: Double

        init(index: Int) {
            let seed = UInt64(index + 1) * 3
            variant = min(WallpaperRainLayer.variants - 1, Int(randomUnit(seed) * Double(WallpaperRainLayer.variants)))
            x = randomUnit(seed + 1)
            fall = randomUnit(seed + 2)
            layer.name = "rain-drop"
            layer.zPosition = CGFloat(variant) / CGFloat(WallpaperRainLayer.variants)
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
        }
    }

    private var drops: [Drop] = []
    private var textures: [WallpaperRainTexture] = []
    private var textureColor: WallpaperRainColor?
    private var textureUnit: CGFloat = 0
    private var textureScale: CGFloat = 0
    private var activeCount = 0
    private var lastTime: Double?

    override init() {
        super.init()
        name = "rain"
        masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(settings: WallpaperEffectsSettings, motion: WallpaperEffectsMotion, size: CGSize, scale: CGFloat) {
        frame = CGRect(origin: .zero, size: size)
        guard settings.enabled, settings.rainEnabled, settings.rainAmount > 0, size.width > 0, size.height > 0 else {
            isHidden = true
            lastTime = nil
            return
        }
        let unit = min(1.5, max(0.7, min(size.width, size.height) / 1000))
        let scale = max(1, scale)
        let densityScale = min(1, max(0.35, size.width * size.height / (1600 * 1000)))
        let count = min(Self.maximumDrops, Int((56 + settings.rainAmount * 456) * densityScale))
        let rebuild = textureColor != settings.rainColor || textureUnit != unit || textureScale != scale
        if rebuild {
            let next = (0..<Self.variants).compactMap { index in
                WallpaperRainTexture.make(color: settings.rainColor, depth: depth(at: index), unit: unit, scale: scale)
            }
            guard next.count == Self.variants else { isHidden = true; lastTime = nil; return }
            textures = next
            textureColor = settings.rainColor
            textureUnit = unit
            textureScale = scale
        }
        let previousPoolSize = drops.count
        while drops.count < count {
            let drop = Drop(index: drops.count)
            drops.append(drop)
            addSublayer(drop.layer)
        }
        if rebuild || count != activeCount {
            for (index, drop) in drops.enumerated() {
                drop.layer.isHidden = index >= count
                if rebuild || index >= previousPoolSize {
                    let texture = textures[drop.variant]
                    drop.layer.contents = texture.image
                    drop.layer.bounds = CGRect(origin: .zero, size: texture.size)
                    drop.layer.contentsScale = scale
                    drop.layer.opacity = Float(0.28 + depth(at: drop.variant) * 0.60)
                }
            }
            activeCount = count
        }
        isHidden = false
        // Integrate wind over frame deltas. Multiplying cursor wind by the total
        // elapsed time would make drops teleport after the wallpaper runs for a while.
        let dt = lastTime.map { min(0.1, max(0, motion.time - $0)) } ?? 0
        lastTime = motion.time
        let margin: CGFloat = 64 * unit
        let width = size.width + margin * 2
        let height = size.height + margin * 2
        let wind = (settings.rainAngle - 0.5) * 0.9
            + (settings.reactsToCursor ? motion.pointer.x * 0.12 : 0)
            + sin(motion.time * 0.55) * 0.025
        let transforms = (0..<Self.variants).map { index in
            CGAffineTransform(rotationAngle: CGFloat(atan(wind * (0.8 + depth(at: index) * 0.2))))
        }
        for drop in drops.prefix(count) {
            let depth = depth(at: drop.variant)
            let velocity = (0.45 + settings.rainSpeed * 1.7) * (0.35 + depth * 0.8)
            drop.fall = fraction(drop.fall + dt * velocity)
            drop.x = fraction(drop.x + dt * velocity * wind * (0.8 + depth * 0.2) * height / width)
            let parallax = settings.parallaxEnabled ? settings.parallaxAmount * depth : 0
            drop.layer.position = CGPoint(
                x: drop.x * width - margin - motion.pointer.x * 22 * unit * parallax,
                y: (1 - drop.fall) * height - margin - motion.pointer.y * 12 * unit * parallax)
            drop.layer.setAffineTransform(transforms[drop.variant])
        }
    }
}

private func fraction(_ value: Double) -> Double { value - floor(value) }
private func depth(at index: Int) -> Double { 0.25 + Double(index) / 7 * 0.75 }

/// Stable independent seeds avoid visible diagonal bands without random work per frame.
private func randomUnit(_ seed: UInt64) -> Double {
    var value = seed &+ 0x9e3779b97f4a7c15
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    value ^= value >> 31
    return Double(value >> 11) / 9_007_199_254_740_992
}
