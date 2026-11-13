import AppKit
import AVFoundation
import QuartzCore
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperEffectsPerformanceTests {
    @Test func glassCadenceDoesNotAccumulateNativeTimerJitterOrCatchUpAfterSleep() {
        for fps in [30.0, 60.0] {
            var cadence = WallpaperGlassRainCadence()
            var submitted = 0
            for frame in 0..<Int(fps * 10) {
                let time = Double(frame)/fps + sin(Double(frame) * 1.3) * 0.002
                if cadence.wantsFrame(at: time) { cadence.submitted(at: time); submitted += 1 }
            }
            #expect(abs(submitted - 300) <= 1)
            #expect(cadence.wantsFrame(at: 100))
            cadence.submitted(at: 100)
            #expect(!cadence.wantsFrame(at: 100.01), "A delayed callback must not cause a burst of catch-up frames")
            cadence.sourceUnavailable(at: 100)
            #expect(!cadence.wantsFrame(at: 100.05) && cadence.wantsFrame(at: 100.1))
        }
    }

    @Test @MainActor func nativeSaverClockAdvancesExactlyOncePerHostFrameAndStopsForPauseSleepAndUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSaverClock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try WallpaperEffectsStore(appSupportURL: root).save(WallpaperEffectsPreset.cinematic.settings)
        let bridge = ScreenSaverEffectsBridge(content: NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600)), appSupportURL: root, isPreview: true)
        let view = try #require(bridge.view as? WallpaperEffectsView)
        var reads = 0
        view.screenSaverPresentationIsVisible = { reads += 1; return true }
        bridge.setPresenting(true, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        var active = WallpaperEffectsActivity(); active.screenSaverPresentation = true
        view.applyActivity(active)
        let initial = view.status.renderedFrames, visibilityReads = reads
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.status.renderedFrames == initial, "There must be no independent timer competing with ScreenSaver.framework")
        for _ in 0..<120 { _ = bridge.presentationVisible; _ = bridge.frameInterval }
        #expect(reads == visibilityReads, "Playback checks must use the sampled visibility instead of polling system IPC each frame")
        let start = CACurrentMediaTime()
        for frame in 0..<120 {
            view.advanceScreenSaverFrame(at: start + Double(frame)/60, cursor: CGPoint(x: frame < 60 ? -0.8 : 0.8, y: 0.3))
        }
        #expect(view.status.renderedFrames == initial + 120 && view.status.cursorX > 0.7)
        #expect(abs(bridge.frameInterval - 1.0/60) < 0.00001)
        active.lowPower = true; view.applyActivity(active)
        #expect(abs(bridge.frameInterval - 1.0/30) < 0.00001)
        active.sleeping = true; view.applyActivity(active)
        let asleep = view.status.renderedFrames
        view.advanceScreenSaverFrame(at: start + 5)
        #expect(view.status.renderedFrames == asleep && !view.isAnimating)
        active.sleeping = false; active.lowPower = false; view.applyActivity(active)
        view.advanceScreenSaverFrame(at: start + 10)
        #expect(view.status.renderedFrames == asleep + 1)
        bridge.setPresenting(true, paused: true, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        let paused = view.status.renderedFrames
        bridge.advanceFrame()
        #expect(view.status.renderedFrames == paused && !view.isAnimating)
        bridge.setPresenting(false, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        bridge.advanceFrame()
        #expect(!bridge.presentationVisible && view.status.framesPerSecond == 0 && view.status.renderedFrames == paused)
    }

    @Test @MainActor func metalRainKeepsSpriteOpticsAndTrajectoriesWithoutUpdatingAHiddenSpriteTree() throws {
        let sprites = WallpaperRainLayer(), metal = WallpaperRainLayer()
        var settings = WallpaperEffectsPreset.cinematic.settings
        settings.rainEnabled = true; settings.rainAmount = 1; settings.rainSpeed = 0.7
        let size = CGSize(width: 1710, height: 1112)
        var motion = WallpaperEffectsMotion()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for frame in 0..<120 {
            if frame == 40 { settings.rainColor = .red; settings.rainBlur = 0.8 }
            if frame == 80 { settings.rainSpeed = 0.3; settings.rainAmount = 0.6 }
            motion.advance(settings: settings, cursor: CGPoint(x: frame < 60 ? -0.8 : 0.8, y: 0.4), deltaTime: 1.0/60)
            sprites.render(settings: settings, motion: motion, size: size, scale: 2)
            metal.render(settings: settings, motion: motion, size: size, scale: 2, renderSprites: false)
            let a = sprites.airRainInstances, b = metal.airRainInstances
            #expect(!a.isEmpty && a.count == b.count)
            #expect(zip(a,b).allSatisfy { $0.ellipse == $1.ellipse && $0.color == $1.color && $0.optics == $1.optics })
        }
        #expect(metal.sublayers?.allSatisfy { $0.sublayers?.isEmpty != false } == true,
            "Composited rain must not attach or update unused particle layers")
        let before = metal.airRainInstances
        metal.presentSprites()
        let after = metal.airRainInstances
        #expect(!metal.isHidden && zip(before,after).allSatisfy { $0.ellipse == $1.ellipse && $0.color == $1.color && $0.optics == $1.optics },
            "Source/Metal fallback must appear immediately at the same positions without advancing simulation twice")
        #expect(metal.sublayers?.contains { $0.sublayers?.contains { !$0.isHidden && $0.contents != nil } == true } == true)
    }
}
