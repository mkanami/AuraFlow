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
        let movement = min(1, simd_length(speed) / 95)
        // Spatial adhesion follows the patch of glass the drop is crossing,
        // rather than a time-based oscillation shared by all drops.
        let rear = Self.adhesion((position.y - radius) / 29 + seed * 113)
        let front = Self.adhesion((position.y + radius) / 29 + seed * 113)
        let left = Self.adhesion(position.y / 37 + position.x / 53 + seed * 193)
        let right = Self.adhesion(position.y / 37 + (position.x + radius * 2) / 53 + seed * 193)
        let accelerationY = min(1, max(-1, acceleration.y / 140))
        let accelerationX = min(1, max(-1, acceleration.x / 90))
        let target = SIMD4<Double>(
            min(0.95, max(0, movement * (0.26 + rear * 0.55) + accelerationY * 0.2)),
            min(0.42, max(-0.12, movement * (0.06 + front * 0.13) - accelerationY * 0.19 + absorption * 0.65)),
            min(0.32, max(-0.32, movement * (left - right) * 0.5 - accelerationX * 0.22)),
            movement * (front - rear) * 0.22)
        let frequency = 10 / sqrt(max(0.55, radius / 8))
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
