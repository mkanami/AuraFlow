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
        var suction: WallpaperGlassSuction?
        var mergeReceiver = -1
        var mergeReceiverSeed = 0.0
        var courseBias = 0.0, absorptionPulse = 0.0
        var body = WallpaperGlassDropBody()
        var depositedVolume = 0.0
    }
    struct Trail {
        var x: Double, y: Double, width: Double, length: Double, angle: Double, life: Double
    }
    /// Four float4s match the Metal instance layout. Radii are in logical pane units.
    struct Instance: Equatable {
        var ellipse: SIMD4<Float>
        var optics: SIMD4<Float> // strength, rotation, kind, seed
        var shape = SIMD4<Float>(repeating: 0) // phase, shear, lobes, continuous flow
        var body = SIMD4<Float>(repeating: 0) // rear neck, leading bulge, bend, shoulder
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
    static let maximumBridges = 64

    init() {}

    /// Explicit initial conditions also support focused offscreen scene exports.
    init(beads: [Drop], runners: [Drop], aspect: Double) {
        self.beads = beads; self.runners = runners; self.aspect = aspect
    }
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
                    if bead.suction != nil { animateSuction(&bead, dt: dt) }
                    else { animateMerge(&bead, dt: dt) }
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
            runners[i].courseBias *= exp(-dt * 0.35)
            runners[i].absorptionPulse *= exp(-dt * 5)
            // Contact-line adhesion pins small drops. Once released, inertia and
            // gravity produce an accelerating run, rather than a shared sine-wave speed.
            if runners[i].pinRemaining > 0 {
                runners[i].pinRemaining = max(0, old.pinRemaining - dt * (old.radius > 11 ? 3 : 1))
            }
            if old.y >= old.nextPinY {
                runners[i].nextPinY = old.y + 100 + old.seed * 220
                if old.radius < 9.5 {
                    runners[i].pinRemaining = 0.4 + old.seed * 1.7
                    runners[i].courseBias = min(0.32, max(-0.32, runners[i].courseBias
                        + sin(old.y * 0.031 + old.seed * 91) * 0.13))
                }
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
            let targetX = runners[i].velocityY * (wind * 0.4 + surfaceDrift + runners[i].courseBias)
            runners[i].velocityX += (targetX - old.velocityX) * (1 - exp(-dt * (2 + old.seed)))
            runners[i].y += runners[i].velocityY * dt
            runners[i].x += runners[i].velocityX * dt
            // The wet film contains water from this drop: depositing a trail
            // gradually reduces its volume and can pin or redirect a lighter body.
            let travelled = hypot(runners[i].x - old.x, runners[i].y - old.y)
            let filmWidth = max(0.7, old.radius * 0.095)
            let volume = pow(runners[i].radius, 3)
            let deposited = min(max(0, volume - pow(4.3, 3)),
                travelled * filmWidth * filmWidth * (0.85 + old.seed * 0.55))
            runners[i].radius = cbrt(max(0, volume - deposited))
            runners[i].depositedVolume += deposited
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
            let reach = max(1, Int(ceil((runners[i].visibleRadius * 1.35 * runners[i].stretch + 9) / 48)))
            for row in -reach...reach { for col in -reach...reach {
                for j in grid[key + row * columns + col] ?? [] where beads[j].cooldown <= 0 {
                    if touchesBead(runners[i], beads[j]) {
                        let duration = 0.46 + beads[j].seed * 0.18
                        beads[j].cooldown = 5 + beads[j].seed * 12 + duration
                        beads[j].mergeRemaining = duration
                        beads[j].mergeTarget = SIMD2(runners[i].x, runners[i].y) + runners[i].visualOffset
                        beads[j].mergeVelocity = SIMD2(runners[i].velocityX, runners[i].velocityY)
                        beads[j].suction = WallpaperGlassSuction(receiver: i, receiverSeed: runners[i].seed,
                            origin: SIMD2(beads[j].x, beads[j].y), initialRadius: beads[j].radius, duration: duration)
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
                    runners[j].mergeReceiver = i
                    runners[j].mergeReceiverSeed = runners[i].seed
                    runners[j].mergeTarget = SIMD2(runners[i].x, runners[i].y) + runners[i].visualOffset
                    runners[j].mergeVelocity = SIMD2(runners[i].velocityX, runners[i].velocityY)
                    mergeCount += 1
                }
            }
            animateBody(index: i, previous: old, dt: dt)
            if runners[i].y > 1110 || runners[i].x < -30 || runners[i].x > paneWidth + 30 {
                runners[i] = makeDrop(moving: true, anywhere: false)
            }
        }
        for i in runners.indices where runners[i].radius == 0 && runners[i].mergeRemaining <= 0 {
            runners[i] = makeDrop(moving: true, anywhere: false)
        }
        if trails.count > Self.maximumTrails { trails.removeFirst(trails.count - Self.maximumTrails) }
    }

    private func receiverIndex(for suction: WallpaperGlassSuction) -> Int? {
        guard runners.indices.contains(suction.receiver), runners[suction.receiver].seed == suction.receiverSeed else { return nil }
        // A recipient may itself coalesce while it is drawing in a bead.
        var index = suction.receiver
        for _ in runners.indices {
            if runners[index].radius > 0 { return index }
            let ghost = runners[index]
            let next = ghost.mergeReceiver
            guard runners.indices.contains(next), runners[next].seed == ghost.mergeReceiverSeed else { return nil }
            index = next
        }
        return nil
    }

    private mutating func animateSuction(_ drop: inout Drop, dt: Double) {
        guard var suction = drop.suction else { return }
        suction.elapsed = min(suction.duration, suction.elapsed + dt)
        let fraction = suction.volumeFraction
        let deltaVolume = max(0, fraction - suction.transferredFraction) * pow(suction.initialRadius, 3)
        if let index = receiverIndex(for: suction) {
            suction.receiver = index; suction.receiverSeed = runners[index].seed
            var receiver = runners[index]
            let center = SIMD2(receiver.x, receiver.y) + receiver.visualOffset
            let toward = center - suction.origin
            let distance = max(0.001, simd_length(toward))
            let direction = toward / distance
            // Land inside the receiving meniscus, while the source stays attached
            // to its original patch during the initial capillary stretch.
            drop.mergeTarget = center - direction * min(distance * 0.65, receiver.visibleRadius * 1.35 * 0.55)
            drop.mergeVelocity = SIMD2(receiver.velocityX, receiver.velocityY)
            if deltaVolume > 0 {
                let volume = pow(receiver.radius, 3)
                let nextVolume = min(pow(22, 3), volume + deltaVolume)
                let ratio = deltaVolume / max(1, volume + deltaVolume)
                receiver.radius = cbrt(nextVolume)
                receiver.depositedVolume += max(0, volume + deltaVolume - nextVolume)
                receiver.velocityY *= volume / max(1, volume + deltaVolume)
                receiver.velocityX = receiver.velocityX * (1 - ratio) - direction.x * ratio * 70
                receiver.courseBias = min(0.32, max(-0.32, receiver.courseBias - direction.x * ratio * 1.6))
                receiver.absorptionPulse = min(0.3, receiver.absorptionPulse + ratio)
                if receiver.radius > 10 { receiver.pinRemaining = 0 }
                runners[index] = receiver
            }
        } else {
            // The old receiver left the pane: finish along its last course,
            // never toward the newly spawned drop occupying that slot.
            drop.mergeTarget += drop.mergeVelocity * dt
        }
        suction.transferredFraction = fraction
        let point = suction.origin + (drop.mergeTarget - suction.origin) * suction.pull
        drop.x = point.x; drop.y = point.y
        drop.visibleRadius = suction.initialRadius * cbrt(max(0, 1 - fraction))
        drop.mergeRemaining = max(0, suction.duration - suction.elapsed)
        drop.suction = suction
    }

    private func suctionCenter(_ bead: Drop, phase: WallpaperGlassSuction) -> SIMD2<Double> {
        let point = SIMD2(bead.x, bead.y)
        let toward = bead.mergeTarget - point
        let distance = max(0.001, simd_length(toward))
        let extensionLength = bead.visibleRadius * 1.8 / sqrt(bead.aspect)
            * (phase.elongation(toward: bead.mergeTarget) - 1)
        // Extend the front into the receiver; keep the rear contact patch anchored
        // instead of inflating an ellipse in both directions.
        return point + toward / distance * extensionLength
    }

    private func touchesBead(_ receiver: Drop, _ bead: Drop) -> Bool {
        let delta = SIMD2(bead.x - receiver.x, bead.y - receiver.y) - receiver.visualOffset
        let angle = receiver.restingAngle * (1 - receiver.flow) - receiver.tilt
        let c = cos(angle), s = sin(angle)
        let local = SIMD2(c * delta.x + s * delta.y, -s * delta.x + c * delta.y)
        let aspect = sqrt(receiver.aspect)
        let x = max(0.1, receiver.visibleRadius * 1.35 * aspect / sqrt(receiver.stretch)) + bead.radius * 1.8
        let y = max(0.1, receiver.visibleRadius * 1.35 / aspect * receiver.stretch) + bead.radius * 1.8
        return local.x * local.x / (x * x) + local.y * local.y / (y * y) < 0.92 * 0.92
    }

    private func animateMerge(_ drop: inout Drop, dt: Double) {
        drop.mergeRemaining = max(0, drop.mergeRemaining - dt)
        drop.mergeTarget += drop.mergeVelocity * dt
        let follow = 1 - exp(-dt * 18)
        drop.x += (drop.mergeTarget.x - drop.x) * follow
        drop.y += (drop.mergeTarget.y - drop.y) * follow
    }

    private mutating func animateBody(index: Int, previous: Drop, dt: Double) {
        var drop = runners[index]
        drop.body.advance(position: SIMD2(drop.x, drop.y), speed: SIMD2(drop.velocityX, drop.velocityY),
            acceleration: SIMD2(drop.velocityX - previous.velocityX, drop.velocityY - previous.velocityY) / dt,
            radius: drop.radius, seed: drop.seed, absorption: drop.absorptionPulse, deltaTime: dt)
        // Damped capillary response: the body stretches after release, leans into
        // turns and settles after pinning instead of switching rigid silhouettes.
        let targetStretch = 1 + min(0.8, drop.velocityY / 155) + drop.body.shape.x * 0.16
            - min(0.12, drop.absorptionPulse * 0.6)
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
        result.reserveCapacity(beads.count + runners.count + trails.count + Self.maximumBridges)
        for trail in trails {
            result.append(Instance(ellipse: SIMD4(Float(trail.x), Float(trail.y), Float(trail.width), Float(trail.length)),
                optics: SIMD4(Float(trail.life * 0.32), Float(trail.angle), 1, 0)))
        }
        var bridgeCount = 0
        for bead in beads where bead.mergeRemaining > 0 && bead.suction != nil {
            guard bridgeCount < Self.maximumBridges, let suction = bead.suction,
                  suction.progress > 0.03, suction.progress < 0.9 else { continue }
            let from = suctionCenter(bead, phase: suction)
            let delta = bead.mergeTarget - from
            guard simd_dot(delta, bead.mergeTarget - SIMD2(bead.x, bead.y)) > 0 else { continue }
            let distance = simd_length(delta)
            let sourceRadius = bead.visibleRadius * 1.8
            guard distance > max(0.7, sourceRadius * 0.35) else { continue }
            let start = from + delta / distance * min(distance * 0.65, sourceRadius * suction.elongation(toward: bead.mergeTarget) * 0.6)
            let span = bead.mergeTarget - start
            let length = simd_length(span)
            let width = max(0.5, min(2.8, sourceRadius * 0.4 * suction.neck))
            let center = (start + bead.mergeTarget) / 2
            result.append(Instance(ellipse: SIMD4(Float(center.x), Float(center.y), Float(width), Float(length / 2 + width)),
                optics: SIMD4(Float(0.4 + suction.neck * 0.4), Float(-atan2(span.x, span.y)), 4, 0)))
            bridgeCount += 1
        }
        for bead in beads where bead.cooldown <= 0 || bead.mergeRemaining > 0 {
            let suction = bead.mergeRemaining > 0 ? bead.suction : nil
            let visibleRadius = (suction == nil ? bead.radius : bead.visibleRadius) * 1.8
            let aspect = sqrt(bead.aspect)
            let elongation = suction?.elongation(toward: bead.mergeTarget) ?? 1
            let delta = bead.mergeTarget - SIMD2(bead.x, bead.y)
            let targetAngle = -atan2(delta.x, delta.y)
            let turn = atan2(sin(targetAngle - bead.restingAngle), cos(targetAngle - bead.restingAngle))
            let alignment = suction.map { min(1, $0.progress / 0.28) } ?? 0
            let angle = bead.restingAngle + turn * alignment * alignment * (3 - 2 * alignment)
            let center = suction.map { suctionCenter(bead, phase: $0) } ?? SIMD2(bead.x, bead.y)
            result.append(Instance(ellipse: SIMD4(Float(center.x), Float(center.y),
                    Float(visibleRadius * aspect / elongation * 1.28), Float(visibleRadius / aspect * elongation * 1.28)),
                optics: SIMD4(Float(0.85 + bead.seed * 0.15), Float(angle), suction == nil ? 0 : 3, Float(bead.seed)),
                shape: SIMD4(Float(bead.contour.x), Float(bead.contour.y), Float(bead.contour.z), Float(suction?.neck ?? 0))))
        }
        for drop in runners {
            let merging = drop.mergeRemaining > 0
            let fade = merging ? min(1, drop.mergeRemaining / 0.22) : 1
            let radius = drop.visibleRadius * 1.35 * (merging ? sqrt(fade) : 1)
            let aspect = sqrt(drop.aspect)
            let angle = drop.restingAngle * (1 - drop.flow) - drop.tilt
            let shear = drop.contour.y + (atan2(drop.velocityX, max(8, drop.velocityY)) - drop.tilt) * drop.flow * 0.45
            result.append(Instance(ellipse: SIMD4(Float(drop.x + drop.visualOffset.x), Float(drop.y + drop.visualOffset.y),
                    Float(radius * aspect / sqrt(drop.stretch) * 1.6), Float(radius / aspect * drop.stretch * 1.6)),
                optics: SIMD4(Float(min(1, fade * 3)), Float(angle), 2, Float(drop.seed)),
                shape: SIMD4(Float(drop.contour.x), Float(shear), Float(drop.contour.z), Float(drop.flow)),
                body: SIMD4<Float>(drop.body.shape)))
        }
        return result
    }
}
