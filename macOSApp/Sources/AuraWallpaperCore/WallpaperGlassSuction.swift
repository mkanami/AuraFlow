import Foundation
import simd

/// A short capillary attachment followed by a volume transfer. The contact point
/// follows the receiving drop; it is never extrapolated toward a recycled slot.
struct WallpaperGlassSuction: Equatable {
    var receiver: Int
    var receiverSeed: Double
    let origin: SIMD2<Double>
    let initialRadius: Double
    let duration: Double
    var elapsed = 0.0
    var transferredFraction = 0.0

    var progress: Double { min(1, max(0, elapsed / duration)) }
    var volumeFraction: Double {
        let t = min(1, max(0, (progress - 0.12) / 0.88))
        return t * t * (3 - 2 * t)
    }
    var pull: Double {
        let t = min(1, max(0, (progress - 0.06) / 0.94))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
    var neck: Double { sin(.pi * progress) }

    func elongation(toward target: SIMD2<Double>) -> Double {
        1 + neck * min(2.1, simd_length(target - origin) / max(1, initialRadius * 1.8))
    }
}
