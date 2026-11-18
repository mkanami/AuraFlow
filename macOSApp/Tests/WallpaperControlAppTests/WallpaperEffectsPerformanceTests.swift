import AppKit
import AVFoundation
import QuartzCore
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperEffectsPerformanceTests {
    @Test @MainActor func previewWindowDragFreezesTheComposedFrameWithoutResettingEffects() throws {
        let view = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500)), store: nil, isPreview: true)
        view.update(settings: WallpaperEffectsPreset.cinematic.settings)
        let active = WallpaperEffectsActivity()
        view.applyActivity(active)
        view.renderFrame(deltaTime: 1.0/60, cursor: CGPoint(x: 1, y: 1))
        let transform = try #require(view.subviews.first?.layer?.affineTransform())
        let before = view.status.renderedFrames
        view.setPreviewInteractionActive(true)
        for _ in 0..<100 {
            view.applyActivity(active)
            view.renderFrame(deltaTime: 1.0/60, cursor: CGPoint(x: -1, y: -1))
        }
        #expect(!view.isAnimating && view.status.pauseReason == "interaction")
        #expect(view.status.renderedFrames == before)
        #expect(view.subviews.first?.layer?.affineTransform() == transform,
            "Window dragging must hold the current image rather than remove the effect layers")
        view.setPreviewInteractionActive(false)
        view.applyActivity(active)
        view.renderFrame(deltaTime: 1.0/60, cursor: .zero)
        #expect(view.isAnimating && view.status.renderedFrames > before)
    }

    @Test @MainActor func previewWindowDragGateCannotPauseDesktopOrScreenSaverEffects() {
        for saver in [false, true] {
            let view = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500)), store: nil, isScreenSaver: saver)
            view.update(settings: WallpaperEffectsPreset.cinematic.settings)
            let active = WallpaperEffectsActivity()
            view.applyActivity(active)
            let before = view.status.renderedFrames
            view.setPreviewInteractionActive(true)
            view.renderFrame(deltaTime: 1.0/60, cursor: .zero)
            #expect(view.isAnimating && view.status.renderedFrames > before)
        }
    }
    @Test @MainActor func exhaustedDrawablePoolNeverBlocksTheMainThreadOrQueuesMoreWaiters() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let source = WallpaperGlassDrawableSource { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            finished.signal()
            return nil
        }
        defer { release.signal(); source.stop() }
        let layer = CAMetalLayer()
        let start = CACurrentMediaTime()
        #expect(source.take(from: layer) == nil)
        try #require(CACurrentMediaTime() - start < 0.15, "A busy Metal drawable pool must never wait on the main thread")
        let didStart = await Task.detached { started.wait(timeout: .now() + 1) == .success }.value
        try #require(didStart)
        for _ in 0..<1_000 { source.stop(); #expect(source.take(from: layer) == nil) }
        #expect(started.wait(timeout: .now()) == .timedOut, "Hide/show must retain only one in-flight drawable request")
        release.signal()
        let didFinish = await Task.detached { finished.wait(timeout: .now() + 1) == .success }.value
        #expect(didFinish)
        source.stop()
    }

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

    @Test @MainActor func saverClockRunsWithoutNativeHostFramesAndStopsForPauseSleepAndUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSaverClock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try WallpaperEffectsStore(appSupportURL: root).save(WallpaperEffectsPreset.cinematic.settings)
        let bridge = ScreenSaverEffectsBridge(content: NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600)), appSupportURL: root, isPreview: true)
        let view = try #require(bridge.view as? WallpaperEffectsView)
        // The window stays hidden. No ordering or system saver/lock action.
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.stopMonitoring() // This test supplies sleep/lock activity explicitly.
        defer { window.contentView = nil }
        var reads = 0
        view.screenSaverPresentationIsVisible = { reads += 1; return true }
        bridge.setPresenting(true, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        var active = WallpaperEffectsActivity(); active.screenSaverPresentation = true
        view.applyActivity(active)
        #expect(abs(bridge.frameInterval - 1.0/60) < 0.00001)
        let initial = view.status.renderedFrames, visibilityReads = reads
        for _ in 0..<120 { _ = bridge.presentationVisible; _ = bridge.frameInterval }
        #expect(reads == visibilityReads, "Playback checks must use cached visibility instead of system IPC each frame")
        // Do not deliver any ScreenSaver.framework frame. Its protected host
        // can tick at 2–5 Hz and must never gate the interactive renderer.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if view.status.renderedFrames > initial { break }
        }
        #expect(view.status.renderedFrames > initial)
        active.lowPower = true; view.applyActivity(active)
        #expect(abs(bridge.frameInterval - 1.0/30) < 0.00001)
        active.sleeping = true; view.applyActivity(active)
        let asleep = view.status.renderedFrames
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.status.renderedFrames == asleep && !view.isAnimating)
        active.sleeping = false; active.lowPower = false; view.applyActivity(active)
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.status.renderedFrames > asleep)
        bridge.setPresenting(true, paused: true, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        let paused = view.status.renderedFrames
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.status.renderedFrames == paused && !view.isAnimating)
        bridge.setPresenting(false, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
        try await Task.sleep(for: .milliseconds(70))
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
