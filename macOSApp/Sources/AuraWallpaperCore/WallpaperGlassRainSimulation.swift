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
        var velocityX = 0.0, velocityY = 0.0
        var pinRemaining = 0.0, nextPinY = 0.0
        var trailX = 0.0, trailY = 0.0
        var aspect = 1.0, restingAngle = 0.0
        var contour = SIMD4<Double>(repeating: 0) // phase, shear, lobes, flow
        var visibleRadius = 0.0
        var stretch = 1.0, stretchVelocity = 0.0
        var tilt = 0.0, tiltVelocity = 0.0, flow = 0.0
        var visualOffset = SIMD2<Double>(repeating: 0)
        var mergeRemaining = 0.0
        var mergeTarget = SIMD2<Double>(repeating: 0)
        var mergeVelocity = SIMD2<Double>(repeating: 0)
    }
    struct Trail {
        var x: Double, y: Double, width: Double, length: Double, angle: Double, life: Double
    }
    /// Two float4s match the Metal instance layout. Radii are in logical pane units.
    struct Instance: Equatable {
        var ellipse: SIMD4<Float>
        var optics: SIMD4<Float> // strength, rotation, kind, seed
        var shape = SIMD4<Float>(repeating: 0) // phase, shear, lobes, continuous flow
    }
    private(set) var beads: [Drop] = []
    private(set) var runners: [Drop] = []
    private(set) var trails: [Trail] = []
    private(set) var mergeCount = 0
    private(set) var time = 0.0
    private var remainder = 0.0
    private var serial: UInt64 = 1
    private var aspect = 0.0
    private(set) var slidingEnabled = true
    static let maximumTrails = 768
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
        guard settings.glassRainSlidingEnabled else {
            if slidingEnabled {
                trails.removeAll(keepingCapacity: true)
                for i in runners.indices {
                    runners[i].velocityX = 0; runners[i].velocityY = 0
                    runners[i].trailX = runners[i].x; runners[i].trailY = runners[i].y
                }
            }
            slidingEnabled = false; remainder = 0
            return
        }
        slidingEnabled = true
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
        var drop = Drop(x: random(1) * paneWidth, y: anywhere ? random(2) * 1080 : -25,
            radius: moving ? 5.8 + random(3) * 8 : 1.3 + pow(random(3), 2) * 3.5, seed: random(4))
        drop.pinRemaining = drop.radius < 9 ? 0.5 + random(5) * 3.5 : random(5) * 0.6
        drop.nextPinY = drop.y + 80 + random(6) * 180
        drop.trailX = drop.x; drop.trailY = drop.y
        drop.aspect = moving ? 0.82 + random(7) * 0.38 : 0.62 + random(7) * 1.05
        drop.restingAngle = moving ? (random(8) - 0.5) * 0.3 : random(8) * .pi * 2
        drop.contour = SIMD4(random(9) * .pi * 2, (random(10) - 0.5) * 0.3, 0.035 + random(11) * 0.055, 0)
        drop.visibleRadius = drop.radius
        serial &+= 1
        return drop
    }

    private mutating func step(dt: Double, settings: WallpaperEffectsSettings) {
        time += dt
        for i in trails.indices { trails[i].life -= dt / 5 }
        trails.removeAll { $0.life <= 0 }
        // A spatial grid bounds bead/runner collision work at high density.
        var grid: [Int: [Int]] = [:]
        let columns = Int(ceil(paneWidth / 48)) + 2
        func cell(_ x: Double, _ y: Double) -> Int { Int(floor(y / 48)) * columns + Int(floor(x / 48)) }
        for i in beads.indices {
            if beads[i].cooldown > 0 {
                if beads[i].mergeRemaining > 0 {
                    var bead = beads[i]
                    animateMerge(&bead, dt: dt)
                    beads[i] = bead
                }
                beads[i].cooldown -= dt
                if beads[i].cooldown <= 0 { beads[i] = makeDrop(moving: false, anywhere: true) }
            } else { grid[cell(beads[i].x, beads[i].y), default: []].append(i) }
        }
        let wind = (settings.glassRainWind - 0.5) * 0.55 + sin(time * 0.17) * 0.035
        for i in runners.indices {
            if runners[i].mergeRemaining > 0 {
                var drop = runners[i]
                animateMerge(&drop, dt: dt)
                runners[i] = drop
                continue
            }
            guard runners[i].radius > 0 else { continue }
            let old = runners[i]
            // Contact-line adhesion pins small drops. Once released, inertia and
            // gravity produce an accelerating run, rather than a shared sine-wave speed.
            if runners[i].pinRemaining > 0 {
                runners[i].pinRemaining = max(0, old.pinRemaining - dt * (old.radius > 11 ? 3 : 1))
            }
            if old.y >= old.nextPinY {
                runners[i].nextPinY = old.y + 100 + old.seed * 220
                if old.radius < 9.5 { runners[i].pinRemaining = 0.4 + old.seed * 1.7 }
            }
            let pinned = runners[i].pinRemaining > 0
            let gravitySpeed = min(210, pow(max(1, old.radius - 3.8), 1.55) * 3.2)
                * (0.25 + settings.glassRainSpeed * 1.75)
            let targetY = pinned ? 0 : gravitySpeed
            let response = 1 - exp(-dt * (pinned ? 7 + old.seed * 4 : 1.6 + old.seed * 1.8))
            runners[i].velocityY += (targetY - old.velocityY) * response
            // Surface variations bend each rivulet differently, filtered through inertia.
            let surfaceDrift = sin(old.y * 0.016 + old.seed * 31) * (0.08 + old.seed * 0.12)
                + sin(old.y * 0.047 + old.seed * 57) * 0.025
            let targetX = runners[i].velocityY * (wind * 0.4 + surfaceDrift)
            runners[i].velocityX += (targetX - old.velocityX) * (1 - exp(-dt * (2 + old.seed)))
            runners[i].y += runners[i].velocityY * dt
            runners[i].x += runners[i].velocityX * dt
            let dx = runners[i].x - old.trailX, dy = runners[i].y - old.trailY
            let distance = hypot(dx, dy)
            if distance >= max(4, old.radius * 0.65) {
                // Overlapping capsule segments join into a continuous rivulet.
                trails.append(Trail(x: (old.trailX + runners[i].x) / 2,
                    y: (old.trailY + runners[i].y) / 2,
                    width: max(0.7, old.radius * 0.095), length: distance / 2 + 1.1,
                    angle: -atan2(dx, max(0.001, dy)), life: 1))
                runners[i].trailX = runners[i].x; runners[i].trailY = runners[i].y
            }
            let key = cell(runners[i].x, runners[i].y)
            for row in -1...1 { for col in -1...1 {
                for j in grid[key + row * columns + col] ?? [] where beads[j].cooldown <= 0 {
                    if overlaps(runners[i], beads[j]) {
                        runners[i].radius = mergedRadius(runners[i].radius, beads[j].radius)
                        if runners[i].radius > 10 { runners[i].pinRemaining = 0 }
                        beads[j].cooldown = 5 + beads[j].seed * 12
                        beads[j].mergeRemaining = 0.22
                        beads[j].mergeTarget = SIMD2(runners[i].x, runners[i].y) + runners[i].visualOffset
                        beads[j].mergeVelocity = SIMD2(runners[i].velocityX, runners[i].velocityY)
                        mergeCount += 1
                    }
                }
            } }
            for j in runners.indices where j < i && runners[j].radius > 0 {
                if overlaps(runners[i], runners[j]) {
                    let a = pow(runners[i].radius, 3), b = pow(runners[j].radius, 3)
                    let previous = SIMD2(runners[i].x, runners[i].y)
                    runners[i].x = (runners[i].x * a + runners[j].x * b) / (a + b)
                    runners[i].y = (runners[i].y * a + runners[j].y * b) / (a + b)
                    runners[i].visualOffset += previous - SIMD2(runners[i].x, runners[i].y)
                    runners[i].radius = mergedRadius(runners[i].radius, runners[j].radius)
                    runners[i].velocityY = (runners[i].velocityY * a + runners[j].velocityY * b) / (a + b)
                    runners[i].velocityX = (runners[i].velocityX * a + runners[j].velocityX * b) / (a + b)
                    runners[i].pinRemaining = 0 // Added weight releases the contact line.
                    runners[i].trailX = runners[i].x; runners[i].trailY = runners[i].y
                    runners[j].radius = 0
                    runners[j].mergeRemaining = 0.22
                    runners[j].mergeTarget = SIMD2(runners[i].x, runners[i].y) + runners[i].visualOffset
                    runners[j].mergeVelocity = SIMD2(runners[i].velocityX, runners[i].velocityY)
                    mergeCount += 1
                }
            }
            animateBody(index: i, dt: dt)
            if runners[i].y > 1110 || runners[i].x < -30 || runners[i].x > paneWidth + 30 {
                runners[i] = makeDrop(moving: true, anywhere: false)
            }
        }
        for i in runners.indices where runners[i].radius == 0 && runners[i].mergeRemaining <= 0 {
            runners[i] = makeDrop(moving: true, anywhere: false)
        }
        if trails.count > Self.maximumTrails { trails.removeFirst(trails.count - Self.maximumTrails) }
    }

    private func animateMerge(_ drop: inout Drop, dt: Double) {
        drop.mergeRemaining = max(0, drop.mergeRemaining - dt)
        drop.mergeTarget += drop.mergeVelocity * dt
        let follow = 1 - exp(-dt * 18)
        drop.x += (drop.mergeTarget.x - drop.x) * follow
        drop.y += (drop.mergeTarget.y - drop.y) * follow
    }

    private mutating func animateBody(index: Int, dt: Double) {
        var drop = runners[index]
        // Damped capillary response: the body stretches after release, leans into
        // turns and settles after pinning instead of switching rigid silhouettes.
        let targetStretch = 1 + min(0.8, drop.velocityY / 155)
        let targetTilt = atan2(drop.velocityX, max(8, drop.velocityY))
        spring(value: &drop.stretch, velocity: &drop.stretchVelocity, target: targetStretch,
            frequency: 9 + drop.seed * 3, damping: 0.78, dt: dt)
        spring(value: &drop.tilt, velocity: &drop.tiltVelocity, target: targetTilt,
            frequency: 8, damping: 0.9, dt: dt)
        drop.stretch = min(1.9, max(0.9, drop.stretch))
        drop.flow += (min(1, drop.velocityY / 65) - drop.flow) * (1 - exp(-dt * 6))
        drop.visibleRadius += (drop.radius - drop.visibleRadius) * (1 - exp(-dt * 9))
        drop.visualOffset *= exp(-dt * 10)
        runners[index] = drop
    }

    private func spring(value: inout Double, velocity: inout Double, target: Double,
                        frequency: Double, damping: Double, dt: Double) {
        velocity += ((target - value) * frequency * frequency - 2 * damping * frequency * velocity) * dt
        value += velocity * dt
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
                optics: SIMD4(Float(trail.life * 0.32), Float(trail.angle), 1, 0)))
        }
        for bead in beads where bead.cooldown <= 0 || bead.mergeRemaining > 0 {
            let fade = bead.mergeRemaining > 0 ? min(1, bead.mergeRemaining / 0.22) : 1
            let visibleRadius = bead.radius * 1.8 * sqrt(fade)
            let aspect = sqrt(bead.aspect)
            result.append(Instance(ellipse: SIMD4(Float(bead.x), Float(bead.y),
                    Float(visibleRadius * aspect * 1.28), Float(visibleRadius / aspect * 1.28)),
                optics: SIMD4(Float((0.85 + bead.seed * 0.15) * min(1, fade * 3)), Float(bead.restingAngle), 0, Float(bead.seed)),
                shape: SIMD4(Float(bead.contour.x), Float(bead.contour.y), Float(bead.contour.z), 0)))
        }
        for drop in runners {
            let merging = drop.mergeRemaining > 0
            let fade = merging ? min(1, drop.mergeRemaining / 0.22) : 1
            let radius = drop.visibleRadius * 1.35 * (merging ? sqrt(fade) : 1)
            let aspect = sqrt(drop.aspect)
            let angle = drop.restingAngle * (1 - drop.flow) - drop.tilt
            let shear = drop.contour.y + (atan2(drop.velocityX, max(8, drop.velocityY)) - drop.tilt) * drop.flow * 0.45
            result.append(Instance(ellipse: SIMD4(Float(drop.x + drop.visualOffset.x), Float(drop.y + drop.visualOffset.y),
                    Float(radius * aspect / sqrt(drop.stretch) * 1.28), Float(radius / aspect * drop.stretch * 1.28)),
                optics: SIMD4(Float(min(1, fade * 3)), Float(angle), 2, Float(drop.seed)),
                shape: SIMD4(Float(drop.contour.x), Float(shear), Float(drop.contour.z), Float(drop.flow))))
        }
        return result
    }
}
