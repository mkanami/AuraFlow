import Foundation
import simd

/// A damped contact-line model, separate from the drop's path and water volume.
/// The rear meniscus lags behind, the leading body rounds out when braking,
/// and uneven glass adhesion bends the neck. Stationary water does not wobble.
struct WallpaperGlassDropBody: Equatable {
    private(set) var shape = SIMD4<Double>(repeating: 0) // rear neck, front bulge, bend, shoulder
    private var velocity = SIMD4<Double>(repeating: 0)

    mutating func advance(position: SIMD2<Double>, speed: SIMD2<Double>, acceleration: SIMD2<Double>,
                          radius: Double, seed: Double, absorption: Double, deltaTime: Double) {
        let dt = min(1.0 / 30, max(0, deltaTime))
        guard dt > 0 else { return }
        // A slow runner is still flowing water. The old linear /95 ramp
        // attenuated all contour changes to subpixel motion at normal speeds.
        let movement = min(1, simd_length(speed) / 32)
        // Spatial adhesion follows the patch of glass the drop is crossing,
        // rather than a time-based oscillation shared by all drops.
        let rear = Self.adhesion((position.y - radius) / 18 + seed * 113)
        let front = Self.adhesion((position.y + radius) / 18 + seed * 113)
        let left = Self.adhesion(position.y / 24 + position.x / 35 + seed * 193)
        let right = Self.adhesion(position.y / 24 + (position.x + radius * 2) / 35 + seed * 193)
        let accelerationY = min(1, max(-1, acceleration.y / 140))
        let accelerationX = min(1, max(-1, acceleration.x / 90))
        let target = SIMD4<Double>(
            min(1, max(0, movement * (rear - 0.1) * 1.3 + accelerationY * 0.24)),
            min(0.65, max(-0.28, movement * (0.13 + (front - 0.5) * 0.75) - accelerationY * 0.3 + absorption * 0.8)),
            min(0.45, max(-0.45, movement * (left - right) * 0.85 - accelerationX * 0.3)),
            movement * (front - rear) * 0.45)
        let frequency = 9 / sqrt(max(0.55, radius / 8))
        let rates = SIMD4<Double>(frequency * 0.8, frequency, frequency * 0.85, frequency * 0.7)
        for axis in 0..<4 {
            let rate = rates[axis]
            velocity[axis] += ((target[axis] - shape[axis]) * rate * rate - velocity[axis] * rate * 1.65) * dt
            shape[axis] += velocity[axis] * dt
        }
    }

    private static func adhesion(_ x: Double) -> Double {
        let cell = floor(x), t = x - cell
        func hash(_ n: Double) -> Double {
            let v = sin(n * 127.1 + 311.7) * 43758.5453
            return v - floor(v)
        }
        let blend = t * t * t * (t * (t * 6 - 15) + 10)
        return hash(cell) + (hash(cell + 1) - hash(cell)) * blend
    }
}
