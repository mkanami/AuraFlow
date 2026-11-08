import CoreGraphics
import Foundation

/// A tiny wallpaper-only light field. No screen capture or saved image data.
struct WallpaperRainLighting: Equatable {
    struct RGB: Equatable, Hashable {
        var r: Double
        var g: Double
        var b: Double
        var luminance: Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }
        var saturation: Double { max(r, g, b) - min(r, g, b) }
        func mixed(with other: RGB, amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }
        var quantized: RGB { RGB(r: (r * 12).rounded() / 12, g: (g * 12).rounded() / 12, b: (b * 12).rounded() / 12) }
    }
    static let width = 8
    static let height = 4
    static let neutral = WallpaperRainLighting(cells: [], accents: [])
    var cells: [RGB]
    var accents: [RGB]

    static func analyze(_ image: CGImage) -> WallpaperRainLighting? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let cells = stride(from: 0, to: bytes.count, by: 4).map {
            RGB(r: Double(bytes[$0]) / 255, g: Double(bytes[$0 + 1]) / 255, b: Double(bytes[$0 + 2]) / 255)
        }
        let vivid = cells.filter { $0.saturation > 0.25 && $0.luminance > 0.10 }
            .sorted { $0.saturation * $0.luminance > $1.saturation * $1.luminance }
        var accents: [RGB] = []
        for color in vivid {
            guard accents.allSatisfy({ abs($0.r - color.r) + abs($0.g - color.g) + abs($0.b - color.b) > 0.6 }) else { continue }
            accents.append(color.quantized)
            if accents.count == 2 { break }
        }
        return WallpaperRainLighting(cells: cells, accents: accents)
    }

    func illumination(x: Double, y: Double) -> Double {
        guard cells.count == Self.width * Self.height else { return 0.75 }
        // CGContext rows are top-down; the rain simulation uses bottom-up coordinates.
        let column = min(1, max(0, x)) * Double(Self.width - 1)
        let row = min(1, max(0, 1 - y)) * Double(Self.height - 1)
        let x0 = Int(column), x1 = min(Self.width - 1, x0 + 1)
        let y0 = Int(row), y1 = min(Self.height - 1, y0 + 1)
        let fx = column - Double(x0), fy = row - Double(y0)
        let top = cells[y0 * Self.width + x0].luminance * (1 - fx) + cells[y0 * Self.width + x1].luminance * fx
        let bottom = cells[y1 * Self.width + x0].luminance * (1 - fx) + cells[y1 * Self.width + x1].luminance * fx
        return top * (1 - fy) + bottom * fy
    }

    func palette(base: WallpaperRainColor) -> [RGB] {
        let rgb = base.rgb
        let original = RGB(r: rgb.red, g: rgb.green, b: rgb.blue)
        guard !cells.isEmpty else { return [original] }
        let mean = cells.reduce(0) { $0 + $1.luminance } / Double(cells.count)
        // Dark artwork receives a restrained cool cast. The user's chosen hue remains primary.
        let subdued = original.mixed(with: RGB(r: 0.32, g: 0.46, b: 0.65), amount: mean < 0.18 ? 0.18 : 0.04)
        return [subdued.quantized] + accents.map { subdued.mixed(with: $0, amount: 0.55).quantized }
    }
}
