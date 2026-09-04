import AVFoundation
import AppKit
import CryptoKit
import Foundation

struct AdaptiveContrastAnalysis {
    let appearance: AdaptiveGlassAppearance
    let sourceSignature: String
    let sampleCount: Int
    let cacheHit: Bool
    let selectedToneScore: CGFloat
    let alternateToneScore: CGFloat
}

/// Computes one stable text polarity for the whole application while keeping
/// the amount of protection local to each glass surface.
enum AdaptiveContrastAnalyzer {
    static let version = "adaptive-contrast-v3"

    private static let cache = NSCache<NSString, AppearanceCacheEntry>()
    private static let fullHashLimit: UInt64 = 64 * 1024 * 1024
    private static let sampledHashChunkSize = 1024 * 1024
    private static let pixelWidth = 144
    private static let pixelHeight = 90

    private final class AppearanceCacheEntry: NSObject {
        let appearance: AdaptiveGlassAppearance
        let selectedToneScore: CGFloat
        let alternateToneScore: CGFloat

        init(
            appearance: AdaptiveGlassAppearance,
            selectedToneScore: CGFloat,
            alternateToneScore: CGFloat
        ) {
            self.appearance = appearance
            self.selectedToneScore = selectedToneScore
            self.alternateToneScore = alternateToneScore
        }
    }

    private enum AnalysisRegion: CaseIterable {
        case full
        case top
        case center
        case bottom

        var rectFromTop: CGRect {
            switch self {
            case .full:
                return CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.96)
            case .top:
                return CGRect(x: 0.20, y: 0.02, width: 0.60, height: 0.18)
            case .center:
                return CGRect(x: 0.08, y: 0.18, width: 0.84, height: 0.58)
            case .bottom:
                return CGRect(x: 0.05, y: 0.76, width: 0.90, height: 0.22)
            }
        }
    }

    private struct FrameProfile {
        let full: TextLuminanceStats
        let top: TextLuminanceStats
        let center: TextLuminanceStats
        let bottom: TextLuminanceStats

        func stats(for region: AnalysisRegion) -> TextLuminanceStats {
            switch region {
            case .full: return full
            case .top: return top
            case .center: return center
            case .bottom: return bottom
            }
        }
    }

    private struct TextLuminanceStats {
        let mean: CGFloat
        let standardDeviation: CGFloat
        let lowerQuartile: CGFloat
        let median: CGFloat
        let upperQuartile: CGFloat
        let darkCoverage: CGFloat
        let lightCoverage: CGFloat

        static let empty = TextLuminanceStats(
            mean: 0.0,
            standardDeviation: 0.0,
            lowerQuartile: 0.0,
            median: 0.0,
            upperQuartile: 0.0,
            darkCoverage: 1.0,
            lightCoverage: 0.0
        )
    }

    static func analyze(
        url: URL,
        scaleMode: WallpaperScaleMode
    ) async -> AdaptiveContrastAnalysis? {
        guard let sourceSignature = sourceSignature(for: url) else {
            return nil
        }

        let cacheKey = "\(sourceSignature)|\(scaleMode.rawValue)|\(version)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return AdaptiveContrastAnalysis(
                appearance: cached.appearance,
                sourceSignature: sourceSignature,
                sampleCount: 0,
                cacheHit: true,
                selectedToneScore: cached.selectedToneScore,
                alternateToneScore: cached.alternateToneScore
            )
        }

        let frames = await sampleFrames(for: url)
        guard !frames.isEmpty else {
            return nil
        }

        let result = makeAppearance(for: frames)
        cache.setObject(
            AppearanceCacheEntry(
                appearance: result.appearance,
                selectedToneScore: result.selectedToneScore,
                alternateToneScore: result.alternateToneScore
            ),
            forKey: cacheKey
        )

        return AdaptiveContrastAnalysis(
            appearance: result.appearance,
            sourceSignature: sourceSignature,
            sampleCount: frames.count,
            cacheHit: false,
            selectedToneScore: result.selectedToneScore,
            alternateToneScore: result.alternateToneScore
        )
    }

    /// Synchronous compatibility entry point for callers that cannot suspend
    /// (for example, AppKit palette helpers). The live preview path uses the
    /// async method above so AVFoundation metadata loading never blocks it.
    static func analyzeSynchronously(
        url: URL,
        scaleMode: WallpaperScaleMode
    ) -> AdaptiveContrastAnalysis? {
        guard let sourceSignature = sourceSignature(for: url) else {
            return nil
        }

        let cacheKey = "\(sourceSignature)|\(scaleMode.rawValue)|\(version)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return AdaptiveContrastAnalysis(
                appearance: cached.appearance,
                sourceSignature: sourceSignature,
                sampleCount: 0,
                cacheHit: true,
                selectedToneScore: cached.selectedToneScore,
                alternateToneScore: cached.alternateToneScore
            )
        }

        let frames = sampleFramesSynchronously(for: url)
        guard !frames.isEmpty else {
            return nil
        }

        let result = makeAppearance(for: frames)
        cache.setObject(
            AppearanceCacheEntry(
                appearance: result.appearance,
                selectedToneScore: result.selectedToneScore,
                alternateToneScore: result.alternateToneScore
            ),
            forKey: cacheKey
        )

        return AdaptiveContrastAnalysis(
            appearance: result.appearance,
            sourceSignature: sourceSignature,
            sampleCount: frames.count,
            cacheHit: false,
            selectedToneScore: result.selectedToneScore,
            alternateToneScore: result.alternateToneScore
        )
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    static func appearance(for cgImage: CGImage) -> AdaptiveGlassAppearance {
        makeAppearance(for: [cgImage]).appearance
    }

    static func appearance(for frames: [CGImage]) -> AdaptiveGlassAppearance {
        makeAppearance(for: frames).appearance
    }

    static func sourceSignature(for url: URL) -> String? {
        var hasher = SHA256()
        hasher.update(data: Data(version.utf8))

        guard url.isFileURL else {
            hasher.update(data: Data(url.absoluteString.utf8))
            return hexString(hasher.finalize())
        }

        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ]), values.isRegularFile == true else {
            return nil
        }

        let size = UInt64(max(values.fileSize ?? 0, 0))
        let modificationDate = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let resourceID = values.fileResourceIdentifier.map(String.init(describing:)) ?? "none"
        hasher.update(data: Data("|size=\(size)|mtime=\(modificationDate)|id=\(resourceID)".utf8))

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        if size <= fullHashLimit {
            while true {
                guard let chunk = try? handle.read(upToCount: sampledHashChunkSize),
                      !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
        } else {
            if let firstChunk = try? handle.read(upToCount: sampledHashChunkSize),
               !firstChunk.isEmpty {
                hasher.update(data: firstChunk)
            }

            let lastOffset = size > UInt64(sampledHashChunkSize)
                ? size - UInt64(sampledHashChunkSize)
                : 0
            try? handle.seek(toOffset: lastOffset)
            if let lastChunk = try? handle.read(upToCount: sampledHashChunkSize),
               !lastChunk.isEmpty {
                hasher.update(data: lastChunk)
            }
        }

        return hexString(hasher.finalize())
    }

    private static func sampleFrames(for url: URL) async -> [CGImage] {
        if let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ) {
            return [cgImage]
        }

        let asset = AVURLAsset(url: url)
        let duration: Double
        if let loadedDuration = try? await asset.load(.duration) {
            duration = loadedDuration.seconds
        } else {
            duration = 0
        }
        return sampleVideoFrames(for: asset, duration: duration)
    }

    private static func sampleFramesSynchronously(for url: URL) -> [CGImage] {
        if let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ) {
            return [cgImage]
        }

        return sampleVideoFrames(
            for: AVURLAsset(url: url),
            duration: 0
        )
    }

    private static func sampleVideoFrames(
        for asset: AVAsset,
        duration: Double
    ) -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let fractions: [Double] = [0.0, 0.08, 0.25, 0.50, 0.75, 0.96]
        let seconds: [Double]
        if duration.isFinite, duration > 0.001 {
            seconds = fractions.map { fraction in
                min(max(duration * fraction, 0), max(duration - 0.001, 0))
            }
        } else {
            seconds = [0.0, 0.05, 0.20, 0.50]
        }

        var frames: [CGImage] = []
        var seenTimes = Set<Int64>()
        for second in seconds {
            let time = CMTime(seconds: second, preferredTimescale: 600)
            guard seenTimes.insert(time.value).inserted else { continue }
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                frames.append(image)
            }
        }

        // Some containers reject an exact zero timestamp even though they can
        // decode a nearby keyframe. Keep the first valid frame in that case.
        if frames.isEmpty {
            let fallbackTime = CMTime(seconds: 0.05, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: fallbackTime, actualTime: nil) {
                frames.append(image)
            }
        }

        return frames
    }

    private static func makeAppearance(
        for images: [CGImage]
    ) -> (appearance: AdaptiveGlassAppearance, selectedToneScore: CGFloat, alternateToneScore: CGFloat) {
        let profiles = images.compactMap(frameProfile(for:))
        guard !profiles.isEmpty else {
            return (
                AdaptiveGlassAppearance.safeFallback,
                0.0,
                0.0
            )
        }

        let darkScore = toneScore(.dark, profiles: profiles)
        let lightScore = toneScore(.light, profiles: profiles)
        let selectedTone = preferredTone(
            darkScore: darkScore,
            lightScore: lightScore,
            profiles: profiles
        )

        let topProtection = maxProtection(
            for: .top,
            tone: selectedTone,
            profiles: profiles
        )
        let centerProtection = maxProtection(
            for: .center,
            tone: selectedTone,
            profiles: profiles
        )
        let bottomProtection = maxProtection(
            for: .bottom,
            tone: selectedTone,
            profiles: profiles
        )

        let appearance = AdaptiveGlassAppearance(
            topGlassAlpha: max(0.84, 1.0 - (0.14 * topProtection)),
            bottomGlassAlpha: max(0.80, 1.0 - (0.18 * bottomProtection)),
            centerGlassAlpha: max(0.82, 1.0 - (0.18 * centerProtection)),
            topProtectionOverlayOpacity: topProtection,
            bottomProtectionOverlayOpacity: bottomProtection,
            centerProtectionOverlayOpacity: centerProtection,
            bottomButtonProtectionOpacity: min(0.68, bottomProtection * 0.96),
            bottomButtonHighlightOpacity: max(0.012, 0.055 - (0.050 * bottomProtection)),
            textTone: selectedTone
        )

        let selectedScore = selectedTone == .dark ? darkScore : lightScore
        let alternateScore = selectedTone == .dark ? lightScore : darkScore
        return (appearance, selectedScore, alternateScore)
    }

    private static func frameProfile(for image: CGImage) -> FrameProfile? {
        guard let pixels = rgbaPixels(
            from: image,
            width: pixelWidth,
            height: pixelHeight
        ) else {
            return nil
        }

        func stats(_ region: AnalysisRegion) -> TextLuminanceStats {
            luminanceStats(
                pixels: pixels,
                width: pixelWidth,
                height: pixelHeight,
                region: region.rectFromTop
            )
        }

        return FrameProfile(
            full: stats(.full),
            top: stats(.top),
            center: stats(.center),
            bottom: stats(.bottom)
        )
    }

    private static func preferredTone(
        darkScore: CGFloat,
        lightScore: CGFloat,
        profiles: [FrameProfile]
    ) -> AdaptiveTextTone {
        if abs(darkScore - lightScore) >= 0.12 {
            return darkScore > lightScore ? .dark : .light
        }

        let brightCoverage = profiles
            .map { $0.full.lightCoverage }
            .reduce(0.0, +) / CGFloat(profiles.count)
        let darkCoverage = profiles
            .map { $0.full.darkCoverage }
            .reduce(0.0, +) / CGFloat(profiles.count)

        // Tie-breaking toward black on bright/pastel artwork is intentional:
        // it prevents pale anime/sky frames from retaining white text.
        return brightCoverage >= darkCoverage ? .dark : .light
    }

    private static func toneScore(
        _ tone: AdaptiveTextTone,
        profiles: [FrameProfile]
    ) -> CGFloat {
        let contrasts = profiles.flatMap { profile in
            AnalysisRegion.allCases.map { region in
                textContrast(for: tone, stats: profile.stats(for: region))
            }
        }
        guard !contrasts.isEmpty else { return 0.0 }
        let sorted = contrasts.sorted()
        let worst = sorted[0]
        let lowerQuartile = percentile(sorted, at: 0.25)
        return (worst * 0.72) + (lowerQuartile * 0.28)
    }

    private static func maxProtection(
        for region: AnalysisRegion,
        tone: AdaptiveTextTone,
        profiles: [FrameProfile]
    ) -> CGFloat {
        profiles
            .map { protectionLevel(for: $0.stats(for: region), tone: tone) }
            .max() ?? 0.0
    }

    private static func textContrast(
        for tone: AdaptiveTextTone,
        stats: TextLuminanceStats
    ) -> CGFloat {
        let background: CGFloat
        switch tone {
        case .dark:
            background = (stats.lowerQuartile * 0.70) + (stats.median * 0.30)
            return (background + 0.05) / 0.05
        case .light:
            background = (stats.upperQuartile * 0.70) + (stats.median * 0.30)
            return 1.05 / (background + 0.05)
        }
    }

    private static func protectionLevel(
        for stats: TextLuminanceStats,
        tone: AdaptiveTextTone
    ) -> CGFloat {
        let background = tone == .dark
            ? (stats.lowerQuartile * 0.70) + (stats.median * 0.30)
            : (stats.upperQuartile * 0.70) + (stats.median * 0.30)

        let requiredBacking: CGFloat
        switch tone {
        case .dark:
            let targetBackground = ((4.5 * 0.05) - 0.05) / 1.0
            requiredBacking = background < targetBackground
                ? (targetBackground - background) / max(1.0 - background, 0.001)
                : 0.0
        case .light:
            let maximumBackground = (1.05 / 4.5) - 0.05
            requiredBacking = background > maximumBackground
                ? (background - maximumBackground) / max(background, 0.001)
                : 0.0
        }

        let brightPressure = normalized(stats.mean, lower: 0.55, upper: 0.90)
        let flatPressure = 1.0 - normalized(
            stats.standardDeviation,
            lower: 0.05,
            upper: 0.25
        )
        let mixedBackground = min(stats.darkCoverage, stats.lightCoverage) * 2.0
        let complexity = max(
            normalized(stats.upperQuartile - stats.lowerQuartile, lower: 0.14, upper: 0.72),
            min(mixedBackground, 1.0)
        )

        let visualBacking = brightPressure * flatPressure * 0.34
            + (complexity * 0.12)
        return min(max(requiredBacking + visualBacking, 0.0), 0.68)
    }

    private static func normalized(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        guard upper > lower else { return 0.0 }
        return min(max((value - lower) / (upper - lower), 0.0), 1.0)
    }

    private static func rgbaPixels(
        from cgImage: CGImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func luminanceStats(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: CGRect
    ) -> TextLuminanceStats {
        let minX = max(Int(CGFloat(width) * region.minX), 0)
        let maxX = min(Int(CGFloat(width) * region.maxX), width)
        let minY = max(Int(CGFloat(height) * (1.0 - region.maxY)), 0)
        let maxY = min(Int(CGFloat(height) * (1.0 - region.minY)), height)

        guard minX < maxX, minY < maxY else {
            return .empty
        }

        var values: [CGFloat] = []
        values.reserveCapacity((maxX - minX) * (maxY - minY))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = ((y * width) + x) * 4
                let red = linearizeSRGB(CGFloat(pixels[offset]) / 255.0)
                let green = linearizeSRGB(CGFloat(pixels[offset + 1]) / 255.0)
                let blue = linearizeSRGB(CGFloat(pixels[offset + 2]) / 255.0)
                values.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }

        guard !values.isEmpty else { return .empty }
        values.sort()
        let mean = values.reduce(0.0, +) / CGFloat(values.count)
        let variance = values.reduce(0.0) { partialResult, value in
            let delta = value - mean
            return partialResult + (delta * delta)
        } / CGFloat(values.count)
        let darkCount = values.reduce(into: 0) { count, value in
            if value < 0.18 { count += 1 }
        }
        let lightCount = values.reduce(into: 0) { count, value in
            if value > 0.65 { count += 1 }
        }

        return TextLuminanceStats(
            mean: mean,
            standardDeviation: sqrt(variance),
            lowerQuartile: percentile(values, at: 0.25),
            median: percentile(values, at: 0.50),
            upperQuartile: percentile(values, at: 0.75),
            darkCoverage: CGFloat(darkCount) / CGFloat(values.count),
            lightCoverage: CGFloat(lightCount) / CGFloat(values.count)
        )
    }

    private static func linearizeSRGB(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private static func percentile(_ values: [CGFloat], at fraction: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0.0 }
        let index = Int((CGFloat(values.count - 1) * min(max(fraction, 0.0), 1.0)).rounded())
        return values[min(max(index, 0), values.count - 1)]
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
