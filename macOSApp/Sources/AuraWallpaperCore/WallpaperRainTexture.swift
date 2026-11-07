import CoreGraphics
import Foundation

/// A few shared, display-resolution sprites replace per-drop drawing and live blur filters.
struct WallpaperRainTexture {
    let image: CGImage
    let size: CGSize

    static func make(color: WallpaperRainColor, depth: Double, unit: CGFloat, scale: CGFloat) -> Self? {
        let radius = (0.55 + depth * 1.9) * unit
        let length = (10 + depth * depth * 26) * unit
        let padding = ceil(4 * unit)
        let size = CGSize(width: ceil(radius * 2 + padding * 2), height: ceil(length + padding * 2))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
            height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)

        let rgb = color.rgb
        func tone(_ alpha: CGFloat, highlight: Double = 0) -> CGColor {
            CGColor(colorSpace: space, components: [
                rgb.red + (1 - rgb.red) * highlight,
                rgb.green + (1 - rgb.green) * highlight,
                rgb.blue + (1 - rgb.blue) * highlight, alpha
            ])!
        }
        let x = size.width / 2
        let head = padding + radius
        let top = size.height - padding
        let body = CGMutablePath()
        body.move(to: CGPoint(x: x, y: top))
        body.addCurve(to: CGPoint(x: x + radius, y: head),
            control1: CGPoint(x: x + radius * 0.2, y: top - length * 0.4),
            control2: CGPoint(x: x + radius, y: head + radius * 2))
        body.addArc(center: CGPoint(x: x, y: head), radius: radius,
                    startAngle: 0, endAngle: -.pi, clockwise: true)
        body.addCurve(to: CGPoint(x: x, y: top),
            control1: CGPoint(x: x - radius, y: head + radius * 2),
            control2: CGPoint(x: x - radius * 0.2, y: top - length * 0.4))
        body.closeSubpath()

        // A faint halo is baked once into the texture; no per-frame shadows or filters.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 1.2 * unit, color: tone(0.18))
        context.addPath(body)
        context.setFillColor(tone(0.12))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(body)
        context.clip()
        let gradient = CGGradient(colorsSpace: space,
            colors: [tone(0), tone(0.20), tone(0.70), tone(0.95)] as CFArray,
            locations: [0, 0.35, 0.8, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: x, y: top),
            end: CGPoint(x: x, y: padding), options: [])
        // A short curved glint and a shaded edge give the rounded head volume.
        context.setStrokeColor(tone(0.68, highlight: 0.45))
        context.setLineWidth(0.35 + depth * 0.35)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: x - radius * 0.28, y: head - radius * 0.35))
        context.addQuadCurve(to: CGPoint(x: x - radius * 0.38, y: head + radius * 2.8),
            control: CGPoint(x: x - radius * 0.72, y: head + radius * 0.7))
        context.strokePath()
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return Self(image: image, size: size)
    }
}
