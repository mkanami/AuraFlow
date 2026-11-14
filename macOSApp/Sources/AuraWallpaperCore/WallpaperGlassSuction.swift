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
        Self.ease((progress - 0.14) / 0.86)
    }
    var pull: Double {
        Self.ease((progress - 0.18) / 0.82)
    }
    var neck: Double { Self.ease(progress / 0.18) * (1 - Self.ease((progress - 0.72) / 0.28)) }

    func bend(toward target: SIMD2<Double>, velocity: SIMD2<Double>) -> Double {
        let span = target - origin, length = max(0.001, simd_length(span))
        let sideways = SIMD2(span.y, -span.x) / length
        return min(length * 0.28, max(-length * 0.28, -simd_dot(velocity, sideways) * duration * 0.16)) * neck
    }

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    func elongation(toward target: SIMD2<Double>) -> Double {
        // Leave space for the fluid neck between the two lobes. Extending the
        // entire gap put the source center inside the receiver immediately.
        1 + neck * min(2.1, simd_length(target - origin) / max(1, initialRadius * 1.8) * 0.3)
    }
}
