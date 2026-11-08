import Foundation
import QuartzCore

enum WallpaperRainPlane: Int, CaseIterable {
    case far, middle, near
    var name: String { ["rain-far", "rain-middle", "rain-near"][rawValue] }
    var strokeWidth: Double { [0.5, 0.95, 1.5][rawValue] }
    var referenceLength: Double { [5, 22, 52][rawValue] }
    var depth: Double { [0.12, 0.45, 1][rawValue] }
    func velocity(speed: Double) -> Double { [85 + speed * 130, 240 + speed * 360, 650 + speed * 850][rawValue] }
    var exposure: Double { [0.025, 0.045, 0.05][rawValue] }
    var opacity: Double { [0.22, 0.82, 0.66][rawValue] }
}

/// Three independent particle pools: 70% distant, 25% middle, 5% foreground.
final class WallpaperRainLayer: CALayer {
    private static let maximumDrops = 512
    private final class Drop {
        let layer = CALayer()
        let highlighted: Bool
        let speed: Double
        let length: Double
        let thickness: Double
        let brightness: Double
        let catchesLight: Bool
        let accent: Int
        var styleRevision: UInt64 = 0
        var x: Double
        var fall: Double
        init(index: Int, plane: WallpaperRainPlane) {
            let seed = UInt64(index + 1) * 11 + UInt64(plane.rawValue) * 100_003
            highlighted = index % 10 == 7
            speed = 0.8 + randomUnit(seed) * 0.4
            length = 0.7 + randomUnit(seed + 1) * 0.65
            thickness = 0.65 + randomUnit(seed + 2) * 0.7
            brightness = 0.3 + pow(randomUnit(seed + 3), 1.5) * 0.7
            catchesLight = randomUnit(seed + 4) > 0.8
            accent = Int(randomUnit(seed + 5) * 2)
            x = randomUnit(seed + 6)
            fall = randomUnit(seed + 7)
            layer.name = highlighted ? "rain-drop-highlight" : "rain-drop"
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
        }
    }
    private let planes = WallpaperRainPlane.allCases.map { plane -> CALayer in
        let layer = CALayer(); layer.name = plane.name; layer.zPosition = Double(plane.rawValue); return layer
    }
    private var pools = [[Drop]](repeating: [], count: 3)
    private var textures: [[[WallpaperRainTexture]]] = []
    private var texturePalette: [WallpaperRainLighting.RGB] = []
    private var textureUnit: CGFloat = 0
    private var textureScale: CGFloat = 0
    private var lastTime: Double?
    private var styledSpeed = -1.0
    private var styleRevision: UInt64 = 0
    var lighting = WallpaperRainLighting.neutral

    override init() {
        super.init()
        name = "rain"; masksToBounds = true; isHidden = true
        planes.forEach(addSublayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(settings: WallpaperEffectsSettings, motion: WallpaperEffectsMotion, size: CGSize, scale: CGFloat) {
        frame = CGRect(origin: .zero, size: size)
        guard settings.enabled, settings.rainEnabled, settings.rainAmount > 0, size.width > 0, size.height > 0 else {
            isHidden = true; lastTime = nil; return
        }
        let unit = min(1.5, max(0.7, min(size.width, size.height) / 1000))
        let scale = max(1, scale)
        let density = min(1, max(0.35, size.width * size.height / 1_600_000))
        let count = min(Self.maximumDrops, Int((56 + settings.rainAmount * 456) * density))
        let counts = [count - count / 4 - count / 20, count / 4, count / 20]
        let palette = lighting.palette(base: settings.rainColor)
        let rebuild = palette != texturePalette || unit != textureUnit || scale != textureScale
        let restyle = rebuild || styledSpeed != settings.rainSpeed
        if rebuild {
            var next: [[[WallpaperRainTexture]]] = []
            for plane in WallpaperRainPlane.allCases {
                var colors: [[WallpaperRainTexture]] = []
                for color in palette {
                    let pair = [false, true].compactMap {
                        WallpaperRainTexture.make(color: color, plane: plane, highlighted: $0, unit: unit, scale: scale)
                    }
                    guard pair.count == 2 else { isHidden = true; lastTime = nil; return }
                    colors.append(pair)
                }
                next.append(colors)
            }
            textures = next; texturePalette = palette; textureUnit = unit; textureScale = scale
        }
        if restyle { styleRevision &+= 1 }
        let dt = lastTime.map { min(0.1, max(0, motion.elapsedTime - $0)) } ?? 0
        lastTime = motion.elapsedTime
        let margin = 100 * unit
        let width = size.width + margin * 2
        let height = size.height + margin * 2
        for plane in WallpaperRainPlane.allCases {
            let p = plane.rawValue
            planes[p].frame = CGRect(origin: .zero, size: size)
            while pools[p].count < counts[p] {
                let drop = Drop(index: pools[p].count, plane: plane)
                pools[p].append(drop); planes[p].addSublayer(drop.layer)
            }
            for (index, drop) in pools[p].enumerated() {
                if drop.layer.isHidden != (index >= counts[p]) { drop.layer.isHidden = index >= counts[p] }
                guard index < counts[p] else { continue }
                let accent = drop.catchesLight && palette.count > 1 ? 1 + drop.accent % (palette.count - 1) : 0
                let texture = textures[p][accent][drop.highlighted ? 1 : 0]
                // Trail length follows velocity; changing speed never redraws a sprite.
                let velocity = plane.velocity(speed: settings.rainSpeed) * drop.speed * unit
                let trail = max(2 * unit, velocity * plane.exposure * drop.length)
                // Hidden pooled drops can miss a color, speed or scale change.
                // Rebind their current style when they become visible again.
                if drop.styleRevision != styleRevision {
                    drop.layer.contents = texture.image
                    drop.layer.bounds = CGRect(x: 0, y: 0, width: texture.size.width * drop.thickness,
                        height: texture.size.height * trail / (plane.referenceLength * unit))
                    drop.layer.contentsScale = scale
                    drop.styleRevision = styleRevision
                }
                // A slow coherent field: two long gusts plus a gentle spatial variation.
                // Cursor coordinates never enter the trajectory or rotation.
                let t = motion.elapsedTime
                let wind = (settings.rainAngle - 0.5) * 0.9
                    + sin(t * 0.21) * 0.065 + sin(t * 0.087 + 1.4) * 0.035
                    + sin(drop.x * 4 + (1 - drop.fall) * 2 + t * 0.13) * 0.025
                drop.fall = fraction(drop.fall + dt * velocity / height)
                drop.x = fraction(drop.x + dt * velocity * wind / width)
                let parallax = settings.parallaxEnabled ? settings.parallaxAmount * plane.depth : 0
                drop.layer.position = CGPoint(x: drop.x * width - margin - motion.pointer.x * 10 * unit * parallax,
                    y: (1 - drop.fall) * height - margin - motion.pointer.y * 5 * unit * parallax)
                drop.layer.setAffineTransform(CGAffineTransform(rotationAngle: atan(wind)))
                let illumination = lighting.illumination(x: drop.x, y: 1 - drop.fall)
                drop.layer.opacity = Float(plane.opacity * drop.brightness * (0.5 + illumination * 0.5))
            }
        }
        styledSpeed = settings.rainSpeed
        isHidden = false
    }
}

private func fraction(_ value: Double) -> Double { value - floor(value) }
private func randomUnit(_ seed: UInt64) -> Double {
    var value = seed &+ 0x9e3779b97f4a7c15
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    value ^= value >> 31
    return Double(value >> 11) / 9_007_199_254_740_992
}
