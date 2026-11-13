import CoreGraphics
import Foundation

/// Optical streak profile shared with Metal's airRainFragment. Soft cross-section,
/// tapered exposure trail and restrained defocus replace the flat rectangular stripe.
struct WallpaperRainTexture {
    let image: CGImage
    let size: CGSize

    static func opticalColor(_ color: WallpaperRainLighting.RGB, plane: WallpaperRainPlane) -> WallpaperRainLighting.RGB {
        // Clear water keeps the selected hue, with a less saturated lit core.
        color.mixed(with: .init(r: 0.85, g: 0.92, b: 1), amount: [0.08, 0.16, 0.24][plane.rawValue])
    }
    static func softness(plane: WallpaperRainPlane, amount: Double) -> Double {
        switch plane {
        case .far: return 0.12 + amount * 0.15
        case .middle: return 0.1 + amount * 0.3
        case .near: return 0.28 + amount * 0.75
        }
    }
    static func make(color: WallpaperRainLighting.RGB, plane: WallpaperRainPlane,
                     highlighted: Bool, unit: CGFloat, scale: CGFloat, softness: Double = 0.25) -> Self? {
        let color = opticalColor(color, plane: plane)
        let width = plane.strokeWidth * unit
        let length = plane.referenceLength * unit
        let halo = Self.softness(plane: plane, amount: softness)
        let size = spriteSize(plane: plane, unit: unit, softness: softness)
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        for y in 0..<pixelHeight {
            let localY = ((Double(y) + 0.5) / scale - size.height / 2) / (length / 2)
            let t = min(1, max(0, (localY + 1) / 2))
            guard abs(localY) < 1 else { continue }
            let longitudinal = pow(sin(.pi * t), 0.7)
            let taper = 0.72 + 0.28 * sin(.pi * t)
            for x in 0..<pixelWidth {
                let q = ((Double(x) + 0.5) / scale - size.width / 2) / (width / 2) / taper
                let core = exp(-q * q * 2.6)
                let soft = exp(-q * q / (1 + halo * 3)) * halo * 0.16
                let alpha = min(0.96, (core * 0.9 + soft) * longitudinal * (highlighted ? 1.04 : 1))
                let offset = (y * pixelWidth + x) * 4
                pixels[offset] = UInt8(min(255, (color.r * alpha * 255).rounded()))
                pixels[offset+1] = UInt8(min(255, (color.g * alpha * 255).rounded()))
                pixels[offset+2] = UInt8(min(255, (color.b * alpha * 255).rounded()))
                pixels[offset+3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Self(image: image, size: size)
    }

    /// Metal uses this geometry directly; it does not need a CPU sprite image.
    static func spriteSize(plane: WallpaperRainPlane, unit: CGFloat, softness: Double) -> CGSize {
        let halo = Self.softness(plane: plane, amount: softness)
        let padding = ceil(3 * unit + halo * 2 * unit)
        return CGSize(width: ceil(plane.strokeWidth * unit + padding * 2),
            height: ceil(plane.referenceLength * unit + padding * 2))
    }
}
