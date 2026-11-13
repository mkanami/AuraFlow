import Foundation
import QuartzCore

enum WallpaperRainPlane: Int, CaseIterable {
    case far, middle, near
    var name: String { ["rain-far", "rain-middle", "rain-near"][rawValue] }
    var strokeWidth: Double { [1.6, 3.8, 5.6][rawValue] }
    var referenceLength: Double { [5, 22, 52][rawValue] }
    var depth: Double { [0.12, 0.45, 1][rawValue] }
    func velocity(speed: Double) -> Double { [85 + speed * 130, 240 + speed * 360, 650 + speed * 850][rawValue] }
    var exposure: Double { [0.025, 0.045, 0.05][rawValue] }
    var opacity: Double { [0.30, 0.96, 0.85][rawValue] }
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
        var opticalWidth = 0.0
        var opticalLength = 0.0
        var halo = 0.0
        var color = SIMD4<Float>(repeating: 0)
        var rotation = 0.0
        var styleRevision: UInt64 = 0
        var active = false
        var position = CGPoint.zero
        var size = CGSize.zero
        var opacity: Float = 0
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
    private var textureBlur = -1.0
    private var textureScale: CGFloat = 0
    private var lastTime: Double?
    private var styleRevision: UInt64 = 0
    var lighting = WallpaperRainLighting.neutral
    private var palette: [WallpaperRainLighting.RGB] = []
    private var unit: CGFloat = 1
    private var scale: CGFloat = 1
    private var blur = 0.0
    private(set) var hasVisibleDrops = false

    override init() {
        super.init()
        name = "rain"; masksToBounds = true; isHidden = true
        planes.forEach(addSublayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(settings: WallpaperEffectsSettings, motion: WallpaperEffectsMotion, size: CGSize, scale: CGFloat,
                renderSprites: Bool = true) {
        let bounds = CGRect(origin: .zero, size: size)
        if frame != bounds { frame = bounds }
        guard settings.enabled, settings.rainEnabled, settings.rainAmount > 0, size.width > 0, size.height > 0 else {
            hasVisibleDrops = false
            if !isHidden { isHidden = true }
            lastTime = nil
            return
        }
        hasVisibleDrops = true
        unit = min(1.5, max(0.7, min(size.width, size.height) / 1000))
        self.scale = max(1, scale)
        blur = settings.rainBlur
        palette = lighting.palette(base: settings.rainColor)
        let density = min(1, max(0.35, size.width * size.height / 1_600_000))
        let count = min(Self.maximumDrops, Int((56 + settings.rainAmount * 456) * density))
        let counts = [count - count / 4 - count / 20, count / 4, count / 20]
        let dt = lastTime.map { min(0.1, max(0, motion.elapsedTime - $0)) } ?? 0
        lastTime = motion.elapsedTime
        let margin = 100 * unit
        let width = size.width + margin * 2, height = size.height + margin * 2
        let t = motion.elapsedTime
        let windField = (settings.rainAngle - 0.5) * 0.9
            + sin(t * 0.21) * 0.065 + sin(t * 0.087 + 1.4) * 0.035
        for plane in WallpaperRainPlane.allCases {
            let p = plane.rawValue
            let sprite = WallpaperRainTexture.spriteSize(plane: plane, unit: unit, softness: blur)
            let halo = WallpaperRainTexture.softness(plane: plane, amount: blur)
            let colors = palette.map { WallpaperRainTexture.opticalColor($0, plane: plane) }
            while pools[p].count < counts[p] { pools[p].append(Drop(index: pools[p].count, plane: plane)) }
            for (index, drop) in pools[p].enumerated() {
                drop.active = index < counts[p]
                guard drop.active else { continue }
                let accent = drop.catchesLight && palette.count > 1 ? 1 + drop.accent % (palette.count - 1) : 0
                let velocity = plane.velocity(speed: settings.rainSpeed) * drop.speed * unit
                let trail = max(2 * unit, velocity * plane.exposure * drop.length)
                drop.opticalWidth = plane.strokeWidth * unit * drop.thickness
                drop.opticalLength = trail; drop.halo = halo
                let rgb = colors[accent]
                drop.color = SIMD4(Float(rgb.r), Float(rgb.g), Float(rgb.b), 0)
                drop.size = CGSize(width: sprite.width * drop.thickness,
                    height: sprite.height * trail / (plane.referenceLength * unit))
                let wind = windField + sin(drop.x * 4 + (1 - drop.fall) * 2 + t * 0.13) * 0.025
                drop.fall = fraction(drop.fall + dt * velocity / height)
                drop.x = fraction(drop.x + dt * velocity * wind / width)
                let parallax = settings.parallaxEnabled ? settings.parallaxAmount * plane.depth : 0
                drop.position = CGPoint(x: drop.x * width - margin - motion.pointer.x * 10 * unit * parallax,
                    y: (1 - drop.fall) * height - margin - motion.pointer.y * 5 * unit * parallax)
                drop.rotation = -atan(wind)
                let illumination = lighting.illumination(x: drop.x, y: 1 - drop.fall)
                drop.opacity = Float(plane.opacity * drop.brightness * (0.5 + illumination * 0.5))
            }
        }
        if renderSprites { presentSprites() }
        else if !isHidden { isHidden = true }
    }

    /// Only the fallback draws sprites. Metal consumes the particle state
    /// directly, without generating textures or mutating hundreds of hidden layers.
    func presentSprites() {
        guard hasVisibleDrops else { if !isHidden { isHidden = true }; return }
        if palette != texturePalette || unit != textureUnit || scale != textureScale || blur != textureBlur {
            var next: [[[WallpaperRainTexture]]] = []
            for plane in WallpaperRainPlane.allCases {
                var colors: [[WallpaperRainTexture]] = []
                for color in palette {
                    let pair = [false, true].compactMap {
                        WallpaperRainTexture.make(color: color, plane: plane, highlighted: $0, unit: unit, scale: scale, softness: blur)
                    }
                    guard pair.count == 2 else { isHidden = true; return }
                    colors.append(pair)
                }
                next.append(colors)
            }
            textures = next; texturePalette = palette; textureUnit = unit; textureScale = scale; textureBlur = blur
            styleRevision &+= 1
        }
        for plane in WallpaperRainPlane.allCases {
            let p = plane.rawValue
            if planes[p].frame != frame { planes[p].frame = frame }
            for drop in pools[p] {
                if drop.layer.isHidden != !drop.active { drop.layer.isHidden = !drop.active }
                guard drop.active else { continue }
                if drop.layer.superlayer == nil { planes[p].addSublayer(drop.layer) }
                let accent = drop.catchesLight && palette.count > 1 ? 1 + drop.accent % (palette.count - 1) : 0
                if drop.styleRevision != styleRevision {
                    drop.layer.contents = textures[p][accent][drop.highlighted ? 1 : 0].image
                    drop.layer.contentsScale = scale
                    drop.styleRevision = styleRevision
                }
                let bounds = CGRect(origin: .zero, size: drop.size)
                if drop.layer.bounds != bounds { drop.layer.bounds = bounds }
                drop.layer.position = drop.position
                drop.layer.setAffineTransform(CGAffineTransform(rotationAngle: -drop.rotation))
                drop.layer.opacity = drop.opacity
            }
        }
        if isHidden { isHidden = false }
    }

    /// Both backends consume the same trajectories, widths, brightness and colors.
    var airRainInstances: [WallpaperAirRainInstance] {
        guard hasVisibleDrops, frame.height > 0 else { return [] }
        let factor = 1080 / frame.height
        var instances: [WallpaperAirRainInstance] = []
        instances.reserveCapacity(Self.maximumDrops)
        for pool in pools { for drop in pool where drop.active {
            let width = drop.size.width, length = drop.size.height
            var color = drop.color
            color.w = drop.opacity * (drop.highlighted ? 1.04 : 1)
            instances.append(WallpaperAirRainInstance(
                ellipse: SIMD4(Float(drop.position.x * factor), Float((frame.height - drop.position.y) * factor),
                    Float(width * factor / 2), Float(length * factor / 2)),
                color: color, optics: SIMD4(Float(drop.rotation), Float(drop.opticalWidth / width),
                    Float(drop.opticalLength / length), Float(drop.halo))))
        } }
        return instances
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
