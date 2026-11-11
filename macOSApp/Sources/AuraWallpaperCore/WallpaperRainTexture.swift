import CoreGraphics
import Foundation

/// Shared streak sprites: softness is baked once, never a live per-drop blur filter.
struct WallpaperRainTexture {
    let image: CGImage
    let size: CGSize

    static func make(color: WallpaperRainLighting.RGB, plane: WallpaperRainPlane,
                     highlighted: Bool, unit: CGFloat, scale: CGFloat, softness: Double = 0.25) -> Self? {
        let width = plane.strokeWidth * unit
        let length = plane.referenceLength * unit
        let blur = plane == .near ? (softness * 5.6) * unit : 0
        let padding = ceil(3 * unit + blur * 2)
        let size = CGSize(width: ceil(width + padding * 2), height: ceil(length + padding * 2))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
            height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        func tone(_ alpha: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [color.r, color.g, color.b, alpha])!
        }
        let body = CGRect(x: (size.width - width) / 2, y: padding, width: width, height: length)
        if blur > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1.8 * unit), blur: blur, color: tone(0.25))
            context.setFillColor(tone(0.12))
            context.fill(body)
            context.restoreGState()
        }
        context.saveGState()
        context.clip(to: body)
        let gradient = CGGradient(colorsSpace: space,
            colors: [tone(0), tone(0.5), tone(0.95), tone(0.5), tone(0)] as CFArray,
            locations: [0, 0.16, 0.52, 0.84, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.minY),
            end: CGPoint(x: body.midX, y: body.maxY), options: [])
        context.restoreGState()
        if highlighted {
            // Only one in ten drops receives this small, subdued head/glint.
            context.setFillColor(tone(0.30))
            context.fillEllipse(in: CGRect(x: body.midX - width * 0.6, y: padding + length * 0.22,
                width: width * 1.2, height: width * 1.8))
        }
        guard let image = context.makeImage() else { return nil }
        return Self(image: image, size: size)
    }
}
