import Foundation
import simd

/// Logical coordinates use a 1080-point pane, with y increasing down the glass.
/// The simulation owns no windows, playback or GPU resources.
struct WallpaperGlassRainSimulation {
    struct Drop: Equatable {
        var x: Double
        var y: Double
        var radius: Double
        var seed: Double
        var cooldown = 0.0
    }
    struct Trail {
        var x: Double, y: Double, width: Double, length: Double, angle: Double, life: Double
    }
    /// Two float4s match the Metal instance layout. Radii are in logical pane units.
    struct Instance {
        var ellipse: SIMD4<Float>
        var optics: SIMD4<Float> // strength, rotation, trail flag, reserved
    }
    private(set) var beads: [Drop] = []
    private(set) var runners: [Drop] = []
    private(set) var trails: [Trail] = []
    private(set) var mergeCount = 0
    private(set) var time = 0.0
    private var remainder = 0.0
    private var serial: UInt64 = 1
    private var aspect = 0.0
    private var trailClock = 0.0
    var paneWidth: Double { max(1, aspect * 1080) }

    mutating func advance(deltaTime: Double, aspect: Double, settings: WallpaperEffectsSettings) {
        guard aspect.isFinite, aspect > 0 else { return }
        if abs(self.aspect - aspect) > 0.01 {
            self = Self(); self.aspect = aspect
        }
        let intensity = settings.glassRainIntensity
        let beadCount = intensity > 0 ? Int(180 + intensity * 820) : 0
        let runnerCount = intensity > 0 ? Int(6 + intensity * 44) : 0
        if beads.count > beadCount { beads.removeLast(beads.count - beadCount) }
        if runners.count > runnerCount { runners.removeLast(runners.count - runnerCount) }
        while beads.count < beadCount { beads.append(makeDrop(moving: false, anywhere: true)) }
        while runners.count < runnerCount { runners.append(makeDrop(moving: true, anywhere: true)) }
        let dt = deltaTime.isFinite ? min(0.1, max(0, deltaTime)) : 0
        remainder += dt
        while remainder + 1e-9 >= 1.0 / 60 {
            step(dt: 1.0 / 60, settings: settings)
            remainder -= 1.0 / 60
        }
    }

    private mutating func makeDrop(moving: Bool, anywhere: Bool) -> Drop {
        func random(_ offset: UInt64) -> Double {
            var n = serial &+ offset &* 0x9e3779b97f4a7c15
            n = (n ^ (n >> 30)) &* 0xbf58476d1ce4e5b9
            n = (n ^ (n >> 27)) &* 0x94d049bb133111eb
            return Double((n ^ (n >> 31)) >> 11) / 9_007_199_254_740_992
        }
        let drop = Drop(x: random(1) * paneWidth, y: anywhere ? random(2) * 1080 : -25,
            radius: moving ? 7 + random(3) * 8 : 1.3 + pow(random(3), 2) * 3.5, seed: random(4))
        serial &+= 1
        return drop
    }

    private mutating func step(dt: Double, settings: WallpaperEffectsSettings) {
        time += dt
        trailClock += dt
        let leaveTrail = trailClock >= 0.075
        if leaveTrail { trailClock = 0 }
        for i in trails.indices { trails[i].life -= dt / 5 }
        trails.removeAll { $0.life <= 0 }
        // A spatial grid bounds bead/runner collision work at high density.
        var grid: [Int: [Int]] = [:]
        let columns = Int(ceil(paneWidth / 48)) + 2
        func cell(_ x: Double, _ y: Double) -> Int { Int(floor(y / 48)) * columns + Int(floor(x / 48)) }
        for i in beads.indices {
            if beads[i].cooldown > 0 {
                beads[i].cooldown -= dt
                if beads[i].cooldown <= 0 { beads[i] = makeDrop(moving: false, anywhere: true) }
            } else { grid[cell(beads[i].x, beads[i].y), default: []].append(i) }
        }
        let wind = (settings.glassRainWind - 0.5) * 0.55 + sin(time * 0.17) * 0.035
        for i in runners.indices {
            guard runners[i].radius > 0 else { continue }
            let old = runners[i]
            let adhesion = 0.22 + 0.78 * pow(0.5 + 0.5 * sin(time * 0.8 + old.seed * 31), 2)
            let velocity = (9 + old.radius * 2.8) * (0.25 + settings.glassRainSpeed * 1.75) * adhesion
            runners[i].y += velocity * dt
            runners[i].x += velocity * dt * (wind + sin(time * 0.6 + old.seed * 18) * 0.045)
            if leaveTrail {
                let dx = runners[i].x - old.x, dy = runners[i].y - old.y
                trails.append(Trail(x: old.x, y: old.y - old.radius * 0.5,
                    width: max(0.65, old.radius * 0.105), length: max(2, velocity * 0.09),
                    angle: -atan2(dx, max(0.001, dy)), life: 1))
            }
            let key = cell(runners[i].x, runners[i].y)
            for row in -1...1 { for col in -1...1 {
                for j in grid[key + row * columns + col] ?? [] where beads[j].cooldown <= 0 {
                    if overlaps(runners[i], beads[j]) {
                        runners[i].radius = mergedRadius(runners[i].radius, beads[j].radius)
                        beads[j].cooldown = 5 + beads[j].seed * 12
                        mergeCount += 1
                    }
                }
            } }
            for j in runners.indices where j < i && runners[j].radius > 0 {
                if overlaps(runners[i], runners[j]) {
                    let a = pow(runners[i].radius, 3), b = pow(runners[j].radius, 3)
                    runners[i].x = (runners[i].x * a + runners[j].x * b) / (a + b)
                    runners[i].y = max(runners[i].y, runners[j].y)
                    runners[i].radius = mergedRadius(runners[i].radius, runners[j].radius)
                    runners[j].radius = 0
                    mergeCount += 1
                }
            }
            if runners[i].y > 1110 || runners[i].x < -30 || runners[i].x > paneWidth + 30 {
                runners[i] = makeDrop(moving: true, anywhere: false)
            }
        }
        for i in runners.indices where runners[i].radius == 0 { runners[i] = makeDrop(moving: true, anywhere: false) }
        if trails.count > 384 { trails.removeFirst(trails.count - 384) }
    }

    private func overlaps(_ a: Drop, _ b: Drop) -> Bool {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy < pow((a.radius + b.radius) * 0.85, 2)
    }
    private func mergedRadius(_ a: Double, _ b: Double) -> Double { min(22, cbrt(a * a * a + b * b * b)) }

    var instances: [Instance] {
        var result: [Instance] = []
        result.reserveCapacity(beads.count + runners.count + trails.count)
        for trail in trails {
            result.append(Instance(ellipse: SIMD4(Float(trail.x), Float(trail.y), Float(trail.width), Float(trail.length)),
                optics: SIMD4(Float(trail.life * 0.23), Float(trail.angle), 1, 0)))
        }
        for bead in beads where bead.cooldown <= 0 {
            result.append(Instance(ellipse: SIMD4(Float(bead.x), Float(bead.y), Float(bead.radius), Float(bead.radius * (0.85 + bead.seed * 0.3))),
                optics: SIMD4(Float(0.65 + bead.seed * 0.35), 0, 0, 0)))
        }
        for drop in runners {
            result.append(Instance(ellipse: SIMD4(Float(drop.x), Float(drop.y), Float(drop.radius), Float(drop.radius * 1.35)),
                optics: SIMD4(1, Float(sin(time + drop.seed * 20) * 0.04), 2, 0)))
        }
        return result
    }
}
