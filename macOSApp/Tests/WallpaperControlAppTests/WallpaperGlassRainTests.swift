import AppKit
import AVFoundation
import CoreImage
import IOSurface
import Metal
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperGlassRainTests {
    private func settings() -> WallpaperEffectsSettings {
        var s = WallpaperEffectsSettings()
        s.enabled = true; s.parallaxEnabled = false; s.glowEnabled = false
        s.glassRainEnabled = true
        return s
    }

    @Test func independentModesMigrateNormalizeAndRoundTrip() throws {
        var s = try JSONDecoder().decode(WallpaperEffectsSettings.self, from: Data(#"{"enabled":true,"rainEnabled":true,"rainColor":"red"}"#.utf8))
        #expect(!s.glassRainEnabled && s.glassRainSlidingEnabled && s.rainBlur == 0.25 && s.rainColor == .red)
        s = settings()
        #expect(s.hasVisibleEffects && s.hasAnimatedEffects && !s.rainEnabled)
        s.rainEnabled = true; s.glassRainIntensity = 0
        #expect(s.hasAnimatedEffects)
        s.rainEnabled = false
        #expect(!s.hasAnimatedEffects)
        s.glassRainIntensity = .nan; s.glassRainWind = -2; s.glassRainRefraction = 9
        s.glassRainBlur = .infinity
        s.glassRainSlidingEnabled = false
        s = s.normalized()
        #expect(s.glassRainIntensity == 0.45 && s.glassRainWind == 0 && s.glassRainRefraction == 1 && s.glassRainBlur == 0.2)
        #expect(try JSONDecoder().decode(WallpaperEffectsSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func stationaryBeadsSlidingMergingAndTrailsStayBoundedAcrossFrameRates() {
        var a = WallpaperGlassRainSimulation(), b = WallpaperGlassRainSimulation()
        let s = settings()
        a.advance(deltaTime: 0, aspect: 16.0/9, settings: s)
        let initialBeads = a.beads, initialRunners = a.runners
        for _ in 0..<1800 { a.advance(deltaTime: 1.0/30, aspect: 16.0/9, settings: s) }
        for _ in 0..<3600 { b.advance(deltaTime: 1.0/60, aspect: 16.0/9, settings: s) }
        #expect(a.beads == b.beads && a.runners == b.runners)
        #expect(a.runners != initialRunners && a.mergeCount > 0)
        // Uncollected tiny beads remain exactly at their original positions.
        let stationary = zip(initialBeads, a.beads).filter { $0 == $1 }.count
        #expect(stationary > initialBeads.count / 3)
        #expect(!a.trails.isEmpty && a.trails.count <= 768)
        #expect(a.beads.count <= 1000 && a.runners.count <= 50 && a.instances.count <= 1818)
        #expect(a.instances.allSatisfy { $0.ellipse.x.isFinite && $0.ellipse.y.isFinite })
    }

    @Test func glassWindAndSpeedAreIndependentOfFallingRainAndCursor() {
        var a = WallpaperGlassRainSimulation(), b = WallpaperGlassRainSimulation()
        let s = settings()
        var alternate = s
        alternate.rainSpeed = 1; alternate.rainAngle = 0; alternate.rainEnabled = true
        alternate.reactsToCursor = false; alternate.rainBlur = 1
        for _ in 0..<300 {
            a.advance(deltaTime: 1.0/30, aspect: 1.6, settings: s)
            b.advance(deltaTime: 1.0/30, aspect: 1.6, settings: alternate)
        }
        #expect(a.runners == b.runners && a.beads == b.beads)
        alternate.glassRainSpeed = 1; alternate.glassRainWind = 0
        for _ in 0..<60 {
            a.advance(deltaTime: 1.0/30, aspect: 1.6, settings: s)
            b.advance(deltaTime: 1.0/30, aspect: 1.6, settings: alternate)
        }
        #expect(a.runners != b.runners)
    }

    @Test func slidingSwitchFreezesBeadsAndLargeDropsClearsTrailsAndResumesWithoutJumping() {
        var simulation = WallpaperGlassRainSimulation()
        var s = settings()
        for _ in 0..<300 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        #expect(!simulation.trails.isEmpty)
        s.glassRainSlidingEnabled = false
        simulation.advance(deltaTime: 0,aspect: 16.0/9,settings: s)
        let runners = simulation.runners, beads = simulation.beads, instances = simulation.instances
        for _ in 0..<600 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        #expect(simulation.runners == runners && simulation.beads == beads && simulation.instances == instances)
        #expect(simulation.trails.isEmpty && s.hasAnimatedEffects, "Video and Falling Rain still update through stationary glass")
        #expect(simulation.runners.allSatisfy { $0.velocityY == 0 })
        s.glassRainSlidingEnabled = true
        simulation.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
        #expect(zip(runners,simulation.runners).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y) < 2 })
        for _ in 0..<120 { simulation.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s) }
        #expect(simulation.runners != runners && !simulation.trails.isEmpty)
        #expect(simulation.runners.contains { $0.velocityY > 20 })
    }

    @Test func restingDropsHaveStableIndependentContoursAspectAndRotation() {
        var simulation = WallpaperGlassRainSimulation()
        var s = settings(); s.glassRainSlidingEnabled = false
        simulation.advance(deltaTime: 0,aspect: 16.0/9,settings: s)
        let first = simulation.instances
        let beads = first.filter { $0.optics.z == 0 }
        let aspects = beads.map { Double($0.ellipse.z / $0.ellipse.w) }
        #expect(aspects.min() ?? 1 < 0.8 && aspects.max() ?? 1 > 1.4)
        #expect(Set(beads.map { Int($0.optics.y * 100) }).count > 100)
        #expect(Set(beads.map { Int($0.shape.x * 100) }).count > 100)
        #expect(beads.allSatisfy { $0.shape.z > 0 && $0.shape.w == 0 })
        for _ in 0..<300 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        #expect(simulation.instances == first, "Random contact patches must not wobble while stationary")
    }

    @Test func flowingBodiesChangeShapeContinuouslyAndBendAlongDifferentPaths() {
        var simulation = WallpaperGlassRainSimulation()
        let s = settings()
        simulation.advance(deltaTime: 0,aspect: 16.0/9,settings: s)
        var maxStretchStep = 0.0, maxFlowStep = 0.0
        var directions: [Double: [Double]] = [:]
        var mergingFrames = 0, collectedBeadFrames = 0
        for _ in 0..<1200 {
            let previous = simulation.runners
            simulation.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
            collectedBeadFrames += simulation.beads.filter { $0.mergeRemaining > 0 }.count
            for (a,b) in zip(previous,simulation.runners) where a.seed == b.seed {
                maxStretchStep = max(maxStretchStep,abs(a.stretch-b.stretch))
                maxFlowStep = max(maxFlowStep,abs(a.flow-b.flow))
                if b.radius > 0 && b.velocityY > 15 {
                    directions[b.seed,default: []].append(atan2(b.velocityX,b.velocityY))
                }
                if b.mergeRemaining > 0 { mergingFrames += 1 }
            }
        }
        #expect(maxStretchStep > 0.001 && maxStretchStep < 0.06)
        #expect(maxFlowStep > 0.001 && maxFlowStep < 0.08)
        #expect(directions.values.filter { ($0.max() ?? 0) - ($0.min() ?? 0) > 0.12 }.count > 5)
        #expect(mergingFrames > 0, "Coalescing drops should converge over multiple frames")
        #expect(collectedBeadFrames > 0, "Collected beads should shrink into the flowing drop instead of disappearing")
    }

    @Test func suctionStretchesConnectsAndTransfersVolumeGraduallyTowardALiveReceiver() {
        let s=settings()
        var scene=contactScene(s)
        let originalVolume=pow(scene.runners[0].radius,3)+pow(scene.beads[0].radius,3)
        let initialReceiver=scene.runners[0].radius
        scene.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
        #expect(scene.beads[0].suction != nil)
        #expect(scene.runners[0].radius <= initialReceiver, "Contact must not add the entire bead volume immediately")
        var maxElongation=1.0, bridgeFrames=0
        var fractions: [Double]=[]
        for _ in 0..<70 {
            scene.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
            if let suction=scene.beads[0].suction {
                fractions.append(suction.transferredFraction)
                if scene.beads[0].mergeRemaining > 0 {
                    maxElongation=max(maxElongation,suction.elongation(toward: scene.beads[0].mergeTarget))
                    let receiver=scene.runners[0]
                    let targetDistance=hypot(scene.beads[0].mergeTarget.x-receiver.x,scene.beads[0].mergeTarget.y-receiver.y)
                    #expect(targetDistance < receiver.visibleRadius*1.4+2)
                }
                let remaining=pow(suction.initialRadius,3)*(1-suction.transferredFraction)
                let accounted=pow(scene.runners[0].radius,3)+remaining+scene.runners[0].depositedVolume
                #expect(abs(accounted-originalVolume) < 0.0001, "Water must move between the lobe, receiver and deposited film")
            }
            if scene.instances.contains(where: { $0.optics.z == 4 }) { bridgeFrames += 1 }
        }
        #expect(maxElongation > 1.5 && bridgeFrames > 5)
        #expect(fractions.contains { $0 > 0.1 && $0 < 0.9 } && fractions.last == 1)
        #expect(zip(fractions,fractions.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(scene.beads[0].mergeRemaining == 0 && scene.runners[0].courseBias > 0)
    }

    @Test func filmLossShrinksTheFlowAndOffCenterCollectionChangesItsCourse() {
        let s=settings()
        var wet=contactScene(s), dry=contactScene(s,withBead: false)
        let initial=wet.runners[0].radius
        for _ in 0..<180 {
            wet.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
            dry.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
        }
        #expect(wet.runners[0].x > dry.runners[0].x+1)
        #expect(wet.runners[0].courseBias > dry.runners[0].courseBias)
        #expect(dry.runners[0].radius < initial*0.97 && dry.runners[0].depositedVolume > 0)
        #expect(abs(pow(dry.runners[0].radius,3)+dry.runners[0].depositedVolume-pow(initial,3)) < 0.0001)
        #expect(wet.instances.count <= 1882)
    }

    @Test func suctionDoesNotJumpToARecycledReceiverAndTheSwitchFreezesItsNeck() {
        var s=settings()
        var scene=contactScene(s,nearBottom: true)
        scene.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
        #expect(scene.beads[0].suction != nil)
        let originalSeed=scene.runners[0].seed
        s.glassRainSlidingEnabled=false
        scene.advance(deltaTime: 0,aspect: 16.0/9,settings: s)
        let frozen=scene.instances
        for _ in 0..<60 { scene.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s) }
        #expect(scene.instances == frozen)
        s.glassRainSlidingEnabled=true
        var sawReplacement=false
        for _ in 0..<50 {
            scene.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
            if scene.runners[0].seed != originalSeed { sawReplacement=true }
            if scene.beads[0].mergeRemaining > 0 { #expect(scene.beads[0].y > 1050) }
        }
        #expect(sawReplacement && scene.beads[0].suction?.transferredFraction == 1)
    }

    @Test @MainActor func capillaryNeckRendersConnectedWaterBetweenTheLobes() throws {
        let renderer=try #require(WallpaperGlassRainRenderer())
        let queue=try #require(renderer.device.makeCommandQueue())
        let width=512,height=288,size=CGSize(width: 512,height: 288),rect=CGRect(x: 0,y: 0,width: 512,height: 288)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target=try #require(renderer.device.makeTexture(descriptor: descriptor))
        let lobes=[WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(800,540,50,70),optics: SIMD4(1,0,0,0)),
            WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(1000,540,100,100),optics: SIMD4(1,0,0,0))]
        let neck=WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(875,540,18,70),optics: SIMD4(0.85,-.pi/2,4,0))
        func alpha(_ instances: [WallpaperGlassRainSimulation.Instance]) throws -> UInt8 {
            let command=try #require(queue.makeCommandBuffer())
            try renderer.encode(command: command,target: target,
                source: .init(image: CIImage(color: .black).cropped(to: rect),gravity: .resize,revision: 1,label: "neck"),
                settings: settings(),size: size,contentFrame: rect,instances: instances)
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var pixel=[UInt8](repeating: 0,count: 4)
            target.getBytes(&pixel,bytesPerRow: 4,from: MTLRegionMake2D(Int(875.0/1920*512),height/2,1,1),mipmapLevel: 0)
            return pixel[3]
        }
        #expect(try alpha(lobes) == 0)
        #expect(try alpha(lobes+[neck]) > 120)
    }

    private func contactScene(_ settings: WallpaperEffectsSettings,withBead: Bool=true,nearBottom: Bool=false,delayedContact: Bool=false) -> WallpaperGlassRainSimulation {
        let beadCount=Int(180+settings.glassRainIntensity*820),runnerCount=Int(6+settings.glassRainIntensity*44)
        func drop(x: Double,y: Double,radius: Double,seed: Double) -> WallpaperGlassRainSimulation.Drop {
            var d=WallpaperGlassRainSimulation.Drop(x: x,y: y,radius: radius,seed: seed)
            d.visibleRadius=radius; d.nextPinY=10_000; d.contour=SIMD4(1.5,0.1,0.07,0)
            return d
        }
        var beads=(0..<beadCount).map { drop(x: Double($0)*3,y: -4000,radius: 2,seed: 0.7) }
        var runners=(0..<runnerCount).map { drop(x: Double($0)*40,y: -4000,radius: 6,seed: 0.8) }
        let y=nearBottom ? 1104.0 : 500.0
        runners[0]=drop(x: 960,y: y,radius: 10,seed: 0.3)
        runners[0].velocityY=nearBottom ? 120 : 30
        if withBead { beads[0]=drop(x: delayedContact ? 972 : 974,y: y+(delayedContact ? 24 : 6),radius: 4,seed: 0.4) }
        return WallpaperGlassRainSimulation(beads: beads,runners: runners,aspect: 16.0/9)
    }

    @Test @MainActor func differentContactPatchesProduceDistinctStableMetalSilhouettes() throws {
        let renderer = try #require(WallpaperGlassRainRenderer())
        let queue = try #require(renderer.device.makeCommandQueue())
        let width=512, height=288, size=CGSize(width: 512,height: 288)
        let rect=CGRect(origin: .zero,size: size)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target=try #require(renderer.device.makeTexture(descriptor: descriptor))
        func render(_ shape: SIMD4<Float>) throws -> [UInt8] {
            let command=try #require(queue.makeCommandBuffer())
            let drop=WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(960,540,300,300),optics: SIMD4(1,0,0,0),shape: shape)
            try renderer.encode(command: command,target: target,
                source: .init(image: CIImage(color: .black).cropped(to: rect),gravity: .resize,revision: 1,label: "contour"),
                settings: settings(),size: size,contentFrame: rect,instances: [drop])
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var bytes=[UInt8](repeating: 0,count: width*height*4)
            target.getBytes(&bytes,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0)
            return stride(from: 3,to: bytes.count,by: 4).map { bytes[$0] > 100 ? 1 : 0 }
        }
        let a=try render(SIMD4(0.5,-0.15,0.09,0))
        let b=try render(SIMD4(3.8,0.14,0.075,0))
        let repeated=try render(SIMD4(0.5,-0.15,0.09,0))
        let circle=try render(.zero)
        #expect(a == repeated)
        #expect(zip(a,b).filter { $0 != $1 }.count > 800)
        #expect(zip(a,circle).filter { $0 != $1 }.count > 1000)
    }

    @Test @MainActor func fallingRainSurvivesCompositorHandoffAndSourceUnavailability() throws {
        let overlay = WallpaperEffectsOverlay()
        var s = settings(); s.rainEnabled = true
        let size = CGSize(width: 1280,height: 720)
        overlay.render(settings: s,motion: WallpaperEffectsMotion(),size: size,scale: 1)
        let before = overlay.airRainInstances
        let rain = try #require(overlay.sublayers?.first { $0.name == "rain" })
        #expect(!before.isEmpty && !rain.isHidden)
        overlay.setRainComposited(true)
        #expect(rain.isHidden && overlay.airRainInstances.count == before.count)
        overlay.setRainComposited(false)
        #expect(!rain.isHidden)
        s.rainEnabled = false
        overlay.render(settings: s,motion: WallpaperEffectsMotion(),size: size,scale: 1)
        #expect(overlay.airRainInstances.isEmpty)
        s.rainEnabled = true
        let view = WallpaperEffectsView(content: NSView(frame: CGRect(origin: .zero,size: size)),store: nil)
        view.update(settings: s)
        view.applyActivity(WallpaperEffectsActivity())
        view.renderFrame(deltaTime: 1.0/30,cursor: nil)
        let visibleRain = try #require(view.layer?.sublayers?.first { $0 is WallpaperEffectsOverlay }?.sublayers?.first { $0.name == "rain" })
        #expect(view.status.glassReady == false && !visibleRain.isHidden)
        var paused = WallpaperEffectsActivity(); paused.playbackPaused = true
        view.applyActivity(paused)
        #expect(view.window == nil)
    }

    @Test @MainActor func wetGlassRefractsFallingRainAndDryAreasKeepTheSameStorm() throws {
        let renderer = try #require(WallpaperGlassRainRenderer())
        let queue = try #require(renderer.device.makeCommandQueue())
        let width = 512, height = 288
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let size = CGSize(width: width,height: height), rect = CGRect(origin: .zero,size: size)
        let background = CIImage(color: .black).cropped(to: rect)
        let water = WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(960,540,330,330),optics: SIMD4(1,0,0,0))
        let airborne = [900,350].map { x in WallpaperAirRainInstance(ellipse: SIMD4(Float(x),540,20,500),
            color: SIMD4(1,0.1,0.1,0.95),optics: SIMD4(0,0.65,0.95,0.15)) }
        var s = settings(); s.rainEnabled = true; s.glassRainBlur = 0; s.glassRainRefraction = 0
        func render(settings: WallpaperEffectsSettings,water: [WallpaperGlassRainSimulation.Instance],rain: [WallpaperAirRainInstance]) throws -> [UInt8] {
            let command = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: command,target: target,
                source: .init(image: background,gravity: .resize,revision: 1,label: "test"),settings: settings,
                size: size,contentFrame: rect,instances: water,airRain: rain)
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0,count: width*height*4)
            target.getBytes(&pixels,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0)
            return pixels
        }
        let clear = try render(settings: s,water: [water],rain: airborne)
        s.glassRainRefraction = 1
        let wet = try render(settings: s,water: [water],rain: airborne)
        var wetChanges = 0, dryChanges = 0, dryVisible = 0
        for y in 0..<height { for x in 0..<width {
            let p=(y*width+x)*4
            if abs(Int(clear[p+2])-Int(wet[p+2])) > 15 {
                if hypot(Double(x)-256,Double(y)-144) < 95 { wetChanges += 1 }
                else { dryChanges += 1 }
            }
            if x < 130 && wet[p+2] > 40 { dryVisible += 1 }
        } }
        #expect(wetChanges > 200)
        #expect(dryChanges == 0)
        #expect(dryVisible > 100)
        #expect(renderer.composedRainCount == 2)
        s.rainEnabled = false
        let noRain = try render(settings: s,water: [water],rain: airborne)
        #expect(renderer.composedRainCount == 0 && zip(wet,noRain).filter { abs(Int($0)-Int($1)) > 20 }.count > 500)
        let brightCenter = (125..<163).reduce(0) { count,y in
            count + (237..<275).filter { x in noRain[(y*width+x)*4+2] > 5 }.count
        }
        #expect(brightCenter < 10, "A specular highlight must not fill a flat triangular sector through the drop center")
        s.rainEnabled = true
        let dry = try render(settings: s,water: [],rain: airborne)
        #expect(dry[(height/2*width+Int(350.0/1920*512))*4+3] > 80)
        #expect(dry[3] == 0)
    }

    @Test @MainActor func metalReallyRefractsBlursUpdatesSourceAndLeavesDryPixelsTransparent() async throws {
        let renderer = try #require(WallpaperGlassRainRenderer(), "A Metal device and compiling glass shaders are required")
        let device = renderer.device, queue = try #require(device.makeCommandQueue())
        let width = 512, height = 288
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let size = CGSize(width: width, height: height), rect = CGRect(origin: .zero, size: size)
        let drop = WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(960,540,330,330), optics: SIMD4(1,0,0,0))
        var s = settings(); s.glassRainBlur = 0; s.glassRainRefraction = 0
        func render(_ image: CIImage, revision: UInt64, settings: WallpaperEffectsSettings) throws -> [UInt8] {
            let buffer = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: buffer, target: target,
                source: .init(image: image, gravity: .resize, revision: revision, label: "test"),
                settings: settings, size: size, contentFrame: rect, instances: [drop])
            buffer.commit(); buffer.waitUntilCompleted()
            #expect(buffer.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
            return bytes
        }
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect)
        let redTop = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0,y: height/2,width: width,height: height/2)).composited(over: blue)
        let upright = try render(redTop, revision: 1, settings: s)
        let top = (height/2 - 30) * width * 4 + width/2 * 4
        let bottom = (height/2 + 30) * width * 4 + width/2 * 4
        #expect(upright[top+2] > 180 && upright[top] < 10, "Upper red background must remain upright")
        #expect(upright[bottom] > 180 && upright[bottom+2] < 10)
        #expect(upright[3] == 0 && upright[(height * width - 1) * 4 + 3] == 0)
        let stripes = try pattern(width: width, height: height)
        let clear = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        s.glassRainRefraction = 1
        let refracted = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        #expect(zip(clear, refracted).filter { abs(Int($0)-Int($1)) > 20 }.count > 3000)
        s.glassRainBlur = 1
        let blurred = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        #expect(zip(refracted, blurred).filter { abs(Int($0)-Int($1)) > 15 }.count > 1000)
        let changed = try render(blue, revision: 3, settings: s)
        #expect(changed[top] > 180 && changed[top+2] < 10, "The next media frame must replace the cached wallpaper")
        if let path = ProcessInfo.processInfo.environment["AURAFLOW_GLASS_ARTIFACTS"] {
            try await exportScene(renderer: renderer, queue: queue, directory: path)
        }
        #expect(WallpaperGlassRainRenderer.renderSize(size: CGSize(width: 5120,height: 2880), scale: 2) == CGSize(width: 1920,height: 1080))
    }

    @Test @MainActor func liveIOSurfaceChangesAndStaticSourcesCacheWithoutCapturingAWindow() throws {
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 64,kIOSurfaceHeight: 32,
            kIOSurfaceBytesPerElement: 4,kIOSurfaceBytesPerRow: 256,kIOSurfacePixelFormat: UInt32(0x42475241)] as CFDictionary))
        let content = NSView(frame: CGRect(x: 0,y: 0,width: 640,height: 320))
        let source = WallpaperGlassFrameSource()
        let first = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 1, imageURL: nil, at: 0))
        let same = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 1, imageURL: nil, at: 0.1))
        #expect(first.revision == same.revision && first.label == "rendered-frame")
        let next = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 2, imageURL: nil, at: 0.2))
        #expect(next.revision != first.revision)
        source.stop()
        content.wantsLayer = true; content.layer?.contents = try pattern(width: 64,height: 32)
        let image = try #require(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 1))
        let cached = source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 100)
        #expect(image.revision == cached?.revision && image.label == "image")
        content.layer?.contentsGravity = .resizeAspect
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 100.1)?.gravity == .resizeAspect)
        source.stop(); content.layer?.contents = nil
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 101) == nil)
        #expect(content.window == nil && source.submittedSnapshots == 0)
    }

    @Test @MainActor func videoFrameOutputsDetachOnAllSuspensionsAndResumeWithoutWindowActions() async throws {
        let file = try await videoFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let player = AVPlayer(url: file); player.isMuted = true
        let content = NSView(frame: CGRect(x: 0,y: 0,width: 640,height: 360)); content.wantsLayer = true
        content.layer?.addSublayer(AVPlayerLayer(player: player))
        let source = WallpaperGlassFrameSource()
        player.play()
        defer { source.stop(); player.pause() }
        var frame: WallpaperGlassFrameSource.Frame?
        let deadline = Date().addingTimeInterval(5)
        while frame == nil && Date() < deadline {
            frame = source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: Date.timeIntervalSinceReferenceDate)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(frame?.label == "video" && source.hasVideoOutput)
        #expect(player.currentItem?.outputs.count == 1)
        content.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        content.layer?.addSublayer(AVPlayerLayer(player: player))
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: Date.timeIntervalSinceReferenceDate+1)?.label == "video")
        #expect(player.currentItem?.outputs.count == 1, "Rebuilding a leaf must keep the existing video output")
        source.stop()
        #expect(player.currentItem?.outputs.isEmpty == true)
        let view = WallpaperEffectsView(content: content,store: nil)
        view.update(settings: settings())
        for reason in ["hidden","saver","locked","unknownLock","sleep","playback","motion"] {
            var active = WallpaperEffectsActivity()
            view.applyActivity(active)
            view.renderFrame(deltaTime: 1.0/30,cursor: nil)
            #expect(player.currentItem?.outputs.count == 1)
            switch reason {
            case "hidden": active.windowVisible = false
            case "saver": active.screenSaverActive = true
            case "locked": active.sessionLocked = true
            case "unknownLock": active.sessionLocked = nil
            case "sleep": active.sleeping = true
            case "playback": active.playbackPaused = true
            default: active.reduceMotion = true
            }
            view.applyActivity(active)
            #expect(player.currentItem?.outputs.isEmpty == true && !view.isAnimating && view.status.glassReady == false)
        }
        #expect(view.window == nil)
    }

    private func pattern(width: Int,height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.02,green: 0.05,blue: 0.15,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
        for x in stride(from: 0,to: width,by: 8) {
            context.setFillColor(CGColor(red: 0.9,green: 0.1,blue: 0.55,alpha: 1)); context.fill(CGRect(x: x,y: 0,width: 3,height: height))
        }
        return try #require(context.makeImage())
    }

    @MainActor private func videoFile() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glass-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 32,AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: 32,kCVPixelBufferHeightKey as String: 32])
        writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil,try #require(adaptor.pixelBufferPool),&pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer,[])
            memset(CVPixelBufferGetBaseAddress(buffer),160,CVPixelBufferGetBytesPerRow(buffer)*32)
            CVPixelBufferUnlockBaseAddress(buffer,[])
            try #require(adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(i),timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @MainActor private func exportScene(renderer: WallpaperGlassRainRenderer, queue: MTLCommandQueue, directory: String) async throws {
        try FileManager.default.createDirectory(atPath: directory,withIntermediateDirectories: true)
        // An optional real wallpaper path is read only for local visual verification.
        let image: CGImage
        if let path = ProcessInfo.processInfo.environment["AURAFLOW_GLASS_WALLPAPER"], let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,nil),
           let loaded = CGImageSourceCreateImageAtIndex(source,0,nil) { image = loaded }
        else { image = try pattern(width: 1920,height: 1080) }
        let size = CGSize(width: 1920,height: 1080), rect = CGRect(origin: .zero,size: size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 1920,height: 1080,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        var simulation = WallpaperGlassRainSimulation()
        var s = settings()
        for _ in 0..<600 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        s.rainEnabled = true; s.rainAmount = 0.7; s.rainColor = .cyan
        let rain = WallpaperRainLayer()
        var motion = WallpaperEffectsMotion()
        for _ in 0..<60 {
            motion.advance(settings: s,cursor: nil,deltaTime: 1.0/30)
            rain.render(settings: s,motion: motion,size: size,scale: 1)
        }
        let command = try #require(queue.makeCommandBuffer())
        try renderer.encode(command: command,target: target,source: .init(image: CIImage(cgImage: image),gravity: .resizeAspectFill,revision: 999,label: "artifact"),
            settings: s,size: size,contentFrame: rect,instances: simulation.instances,airRain: rain.airRainInstances)
        command.commit(); await command.completed()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 1920,pixelsHigh: 1080,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 1920*4,bitsPerPixel: 32))
        var bytes = [UInt8](repeating: 0,count: 1920*1080*4)
        target.getBytes(&bytes,bytesPerRow: 1920*4,from: MTLRegionMake2D(0,0,1920,1080),mipmapLevel: 0)
        let dst = try #require(bitmap.bitmapData)
        for p in stride(from: 0,to: bytes.count,by: 4) { dst[p]=bytes[p+2]; dst[p+1]=bytes[p+1]; dst[p+2]=bytes[p]; dst[p+3]=bytes[p+3] }
        var gpuTimes: [Double] = []
        let started = Date()
        for i in 0..<60 {
            simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s)
            let measured = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: measured,target: target,
                source: .init(image: CIImage(cgImage: image),gravity: .resizeAspectFill,revision: UInt64(1000+i),label: "benchmark"),
                settings: s,size: size,contentFrame: rect,instances: simulation.instances,airRain: rain.airRainInstances)
            measured.commit(); await measured.completed()
            try #require(measured.status == .completed)
            gpuTimes.append((measured.gpuEndTime-measured.gpuStartTime)*1000)
        }
        print("Glass benchmark 1920x1080, 60 changing frames: GPU mean \(gpuTimes.reduce(0,+)/60) ms, max \(gpuTimes.max() ?? 0) ms; CPU+GPU wall mean \(Date().timeIntervalSince(started)*1000/60) ms")
        let overlay = try #require(bitmap.cgImage)
        let context = try #require(CGContext(data: nil,width: 1920,height: 1080,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in: rect); context.draw(overlay,in: rect)
        let final = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try final.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rain-on-glass.png"))
        if ProcessInfo.processInfo.environment["AURAFLOW_GLASS_ANIMATION"] == "1" {
            try await exportMotion(renderer: renderer,queue: queue,image: image,simulation: simulation,
                settings: s,directory: directory)
            try await exportMotion(renderer: renderer,queue: queue,image: image,simulation: contactScene(s,delayedContact: true),
                settings: s,directory: directory,closeup: true)
        }
    }
    @MainActor private func exportMotion(renderer: WallpaperGlassRainRenderer,queue: MTLCommandQueue,
        image: CGImage,simulation initial: WallpaperGlassRainSimulation,settings: WallpaperEffectsSettings,directory: String,closeup: Bool=false) async throws {
        let width=1280, height=720, size=CGSize(width: 1280,height: 720), rect=CGRect(x: 0,y: 0,width: 1280,height: 720)
        let url=URL(fileURLWithPath: directory).appendingPathComponent(closeup ? "glass-suction-closeup.mp4" : "glass-rain-motion.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer=try AVAssetWriter(outputURL: url,fileType: .mp4)
        let input=AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,AVVideoHeightKey: height,AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,kCVPixelBufferHeightKey as String: height])
        writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target=try #require(renderer.device.makeTexture(descriptor: descriptor))
        let rain=WallpaperRainLayer()
        var simulation=initial, motion=WallpaperEffectsMotion()
        let bitmapInfo=CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels=[UInt8](repeating: 0,count: width*height*4)
        let frameCount=closeup ? 240 : 120
        for index in 0..<frameCount {
            simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: settings)
            motion.advance(settings: settings,cursor: nil,deltaTime: 1.0/30)
            rain.render(settings: settings,motion: motion,size: size,scale: 1)
            var instances=simulation.instances
            if closeup {
                for i in instances.indices {
                    let cameraX=960+(Float(simulation.runners[0].x)-960)*0.4
                    let cameraY=500+(Float(simulation.runners[0].y)-500)*0.65
                    instances[i].ellipse.x=(instances[i].ellipse.x-cameraX)*4+960
                    instances[i].ellipse.y=(instances[i].ellipse.y-cameraY)*4+400
                    instances[i].ellipse.z*=4; instances[i].ellipse.w*=4
                }
            }
            let command=try #require(queue.makeCommandBuffer())
            try renderer.encode(command: command,target: target,
                source: .init(image: CIImage(cgImage: image),gravity: .resizeAspectFill,revision: 10_000,label: "animation"),
                settings: settings,size: size,contentFrame: rect,instances: instances,airRain: closeup ? [] : rain.airRainInstances)
            command.commit(); await command.completed(); try #require(command.status == .completed)
            target.getBytes(&pixels,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0)
            let provider=try #require(CGDataProvider(data: Data(pixels) as CFData))
            let overlay=try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),provider: provider,
                decode: nil,shouldInterpolate: true,intent: .defaultIntent))
            let deadline=Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(input.isReadyForMoreMediaData)
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil,try #require(adaptor.pixelBufferPool),&pixel) == kCVReturnSuccess)
            let buffer=try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer,[])
            let context=try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer),width: width,height: height,bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: bitmapInfo))
            context.draw(image,in: rect); context.draw(overlay,in: rect)
            if (closeup ? [0,6,12,18,30,90,180,239] : [0,39,79,119]).contains(index) {
                let snapshot=NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                try snapshot.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(closeup ? "suction" : "motion")-\(index).png"))
            }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            try #require(adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(index),timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
    }

}
