import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Suite(.serialized)
struct WallpaperEffectsTests {
    @Test func preferencesMigrateAndRejectInvalidNumbers() throws {
        let old = try JSONDecoder().decode(WallpaperEffectsSettings.self, from: Data("{}".utf8))
        #expect(old == WallpaperEffectsSettings())
        #expect(!old.enabled && !old.hasVisibleEffects)
        let future = try JSONDecoder().decode(WallpaperEffectsSettings.self,
            from: Data(#"{"enabled":true,"tint":"future-color","parallaxAmount":42,"rainSpeed":-9}"#.utf8))
        #expect(future.tint == .pearl && future.parallaxAmount == 1 && future.rainSpeed == 0)
        var invalid = old
        invalid.glowIntensity = .nan
        invalid.blurAmount = .infinity
        #expect(invalid.normalized().glowIntensity == old.glowIntensity)
        #expect(invalid.normalized().blurAmount == old.blurAmount)
    }

    @Test(arguments: WallpaperEffectsPreset.allCases)
    func settingsRoundTripAndCorruptFilesDisableEffects(preset: WallpaperEffectsPreset) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperEffectsStore(appSupportURL: root)
        #expect(!store.load().enabled)
        try store.save(preset.settings)
        #expect(WallpaperEffectsStore(appSupportURL: root).load() == preset.settings)
        try Data("interrupted".utf8).write(to: store.url)
        #expect(store.load() == WallpaperEffectsSettings())
    }

    @Test func cursorUsesActualDisplayOriginsAndReturnsToRestOnOtherDisplays() {
        let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        #expect(WallpaperEffectsMotion.normalizedCursor(CGPoint(x: -960, y: 240), in: secondary) == .zero)
        #expect(WallpaperEffectsMotion.normalizedCursor(CGPoint(x: -1920, y: -300), in: secondary) == CGPoint(x: -1, y: -1))
        #expect(WallpaperEffectsMotion.normalizedCursor(CGPoint(x: 50, y: 50), in: secondary) == nil)
        #expect(WallpaperEffectsMotion.normalizedCursor(.zero, in: .zero) == nil)
        let settings = WallpaperEffectsPreset.subtle.settings
        var motion = WallpaperEffectsMotion()
        for _ in 0..<120 { motion.advance(settings: settings, cursor: CGPoint(x: 1, y: -1), deltaTime: 1.0 / 30) }
        #expect(motion.pointer.x > 0.99 && motion.presence > 0.99)
        for _ in 0..<120 { motion.advance(settings: settings, cursor: nil, deltaTime: 1.0 / 30) }
        #expect(abs(motion.pointer.x) < 0.001 && motion.presence < 0.001)
    }

    @Test(arguments: [CGSize(width: 3840, height: 2160), CGSize(width: 900, height: 1600), CGSize(width: 400, height: 300)])
    func parallaxCoversEveryEdgeAndNeverStretches(size: CGSize) {
        var settings = WallpaperEffectsPreset.cinematic.settings
        settings.parallaxAmount = 1
        for x in [-1.0, 0, 1] {
            for y in [-1.0, 0, 1] {
                var motion = WallpaperEffectsMotion()
                for _ in 0..<150 { motion.advance(settings: settings, cursor: CGPoint(x: x, y: y), deltaTime: 1.0 / 30) }
                let frame = motion.contentFrame(in: size, settings: settings)
                #expect(frame.minX <= 0 && frame.minY <= 0)
                #expect(frame.maxX >= size.width && frame.maxY >= size.height)
                #expect(abs(frame.width / size.width - frame.height / size.height) < 0.0001)
                settings.enabled = false
                #expect(motion.contentFrame(in: size, settings: settings) == CGRect(origin: .zero, size: size))
                settings.enabled = true
            }
        }
    }

    @Test func smoothingIsIndependentOfFrameRateAndAmbientModeDoesNotNeedACursor() {
        let settings = WallpaperEffectsPreset.subtle.settings
        var slow = WallpaperEffectsMotion(), fast = WallpaperEffectsMotion()
        for _ in 0..<30 { slow.advance(settings: settings, cursor: CGPoint(x: 1, y: 0.5), deltaTime: 1.0 / 30) }
        for _ in 0..<60 { fast.advance(settings: settings, cursor: CGPoint(x: 1, y: 0.5), deltaTime: 1.0 / 60) }
        #expect(abs(slow.pointer.x - fast.pointer.x) < 0.0001)
        var ambient = settings
        ambient.reactsToCursor = false
        var motion = WallpaperEffectsMotion()
        for _ in 0..<120 { motion.advance(settings: ambient, cursor: nil, deltaTime: 1.0 / 30) }
        #expect(motion.presence > 0.99 && motion.pointer != .zero)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func manualAndAutomaticLocksSleepWakeAndMissingNotificationsOnlySuspendEffects(automatic: Bool, lowPower: Bool) {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let view = WallpaperEffectsView(content: content, store: nil)
        view.update(settings: WallpaperEffectsPreset.cinematic.settings)
        var activity = WallpaperEffectsActivity()
        activity.lowPower = lowPower
        view.applyActivity(activity)
        #expect(view.isAnimating)
        // Automatic idle saver precedes password lock; the session is still unlocked.
        if automatic {
            activity.screenSaverActive = true
            view.applyActivity(activity)
            #expect(!view.isAnimating && activity.sessionLocked == false)
        }
        // The authoritative sample is locked even when the lock notification is late or absent.
        activity.sessionLocked = true
        activity.screenSaverActive = false
        view.applyActivity(activity)
        #expect(!view.isAnimating)
        activity.sleeping = true
        view.applyActivity(activity)
        activity.sleeping = false // Wake does not establish an unlock.
        view.applyActivity(activity)
        #expect(!view.isAnimating)
        activity.sessionLocked = nil
        view.applyActivity(activity)
        #expect(!view.isAnimating)
        activity.sessionLocked = false // Poll recovers with no unlock notification.
        view.applyActivity(activity)
        #expect(view.isAnimating)
        view.renderFrame(deltaTime: 1.0 / 30, cursor: .zero)
        #expect(content.frame.size == CGSize(width: 640, height: 400))
        activity.windowVisible = false
        view.applyActivity(activity)
        #expect(!view.isAnimating)
        #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
        // No test window is ordered and no system action or wallpaper adapter is invoked.
        #expect(view.window == nil)
    }

    @Test func suspensionHintsExpireWhenResumeOrSaverStopNotificationsAreMissing() {
        var hints = WallpaperEffectsSuspensionHints()
        hints.systemWillSuspend(at: 10)
        hints.saverDidStart(at: 10)
        #expect(hints.systemSuspended(at: 11) && hints.saverSuspended(at: 11))
        #expect(!hints.systemSuspended(at: 12) && !hints.saverSuspended(at: 12))
        hints.saverDidStart(at: 20) // Delayed idle notification after unlock is bounded too.
        #expect(!hints.saverSuspended(at: 22))
        hints.systemWillSuspend(at: 30)
        hints.systemDidResume()
        hints.saverDidStart(at: 30)
        hints.saverDidStop()
        #expect(!hints.systemSuspended(at: 30) && !hints.saverSuspended(at: 30))
    }

    @Test(arguments: [0, 1, 2, 3, 4]) @MainActor
    func hiddenPausedInactiveAndAccessibilityStatesStopRendering(reason: Int) {
        let view = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500)), store: nil)
        view.update(settings: WallpaperEffectsPreset.dreamy.settings)
        var activity = WallpaperEffectsActivity()
        view.applyActivity(activity)
        for _ in 0..<30 { view.renderFrame(deltaTime: 1.0 / 30, cursor: CGPoint(x: 1, y: 1)) }
        #expect(view.isAnimating)
        switch reason {
        case 0: activity.windowVisible = false
        case 1: activity.playbackPaused = true
        case 2: activity.sessionActive = false
        case 3: activity.reduceMotion = true
        default: activity.sleeping = true
        }
        view.applyActivity(activity)
        #expect(!view.isAnimating)
        #expect(view.subviews.first?.layer?.affineTransform() == .identity)
        #expect(view.subviews.first?.layer?.filters == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func desktopLayersReactToTheCursorIncludingInLowPowerMode(lowPower: Bool) throws {
        let view = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800)), store: nil)
        view.update(settings: WallpaperEffectsPreset.cinematic.settings)
        var activity = WallpaperEffectsActivity()
        activity.lowPower = lowPower
        view.applyActivity(activity)
        let fps = lowPower ? 30.0 : 60
        #expect(view.isAnimating && view.status.framesPerSecond == fps)
        for _ in 0..<60 { view.renderFrame(deltaTime: 1 / fps, cursor: CGPoint(x: -0.8, y: -0.6)) }
        let left = view.status
        for _ in 0..<60 { view.renderFrame(deltaTime: 1 / fps, cursor: CGPoint(x: 0.8, y: 0.6)) }
        let right = view.status
        #expect(right.surface == "desktop" && right.active && right.pauseReason == nil)
        #expect(left.cursorX < -0.79 && right.cursorX > 0.79)
        #expect(abs(left.parallaxX - right.parallaxX) > 20)
        #expect(abs(left.glowX - right.glowX) > 300 && abs(left.flareX - right.flareX) > 600)
        #expect(right.flareOpacity > 0.5 && right.renderedFrames == 120)
        let health = DaemonHealth(effects: [right])
        #expect(try JSONDecoder().decode(DaemonHealth.self, from: JSONEncoder().encode(health)) == health)
        #expect(try JSONDecoder().decode(DaemonHealth.self, from: Data("{}".utf8)).effects == nil)

        // Power-mode changes only reschedule the clock, retaining the current depth and light position.
        activity.lowPower.toggle()
        view.applyActivity(activity)
        #expect(view.status.framesPerSecond == (lowPower ? 60 : 30))
        #expect(view.status.cursorX == right.cursorX && view.status.parallaxX == right.parallaxX)
        activity.reduceMotion = true
        view.applyActivity(activity)
        #expect(!view.status.active && view.status.pauseReason == "reduceMotion")
    }

    @Test func defaultCursorSmoothingRespondsWithinOneTenthOfASecond() {
        var motion = WallpaperEffectsMotion()
        let settings = WallpaperEffectsPreset.subtle.settings
        for _ in 0..<6 { motion.advance(settings: settings, cursor: CGPoint(x: 1, y: 0), deltaTime: 1.0 / 60) }
        #expect(motion.pointer.x > 0.7)
    }

    @Test @MainActor func pointerFramesReuseGradientStylesAndParticlePaths() throws {
        var settings = WallpaperEffectsPreset.dreamy.settings
        settings.rainEnabled = true
        let overlay = WallpaperEffectsOverlay()
        var motion = WallpaperEffectsMotion()
        let size = CGSize(width: 1200, height: 800)
        overlay.render(settings: settings, motion: motion, size: size, scale: 2)
        let generation = overlay.styleGeneration
        let sparkle = try #require(overlay.sublayers?.first { $0.name == "sparkle" }) as? CAShapeLayer
        let path = try #require(sparkle?.path)
        for _ in 0..<120 {
            motion.advance(settings: settings, cursor: CGPoint(x: 0.8, y: 0.6), deltaTime: 1.0 / 60)
            overlay.render(settings: settings, motion: motion, size: size, scale: 2)
        }
        #expect(overlay.styleGeneration == generation)
        #expect(sparkle?.path === path)
        settings.tint = .warm
        overlay.render(settings: settings, motion: motion, size: size, scale: 2)
        #expect(overlay.styleGeneration == generation + 1)
    }

    @Test @MainActor func animationClockDoesNotRetainTheRemovedWallpaperView() async throws {
        weak var retained: WallpaperEffectsView?
        autoreleasepool {
            let view = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400)), store: nil)
            retained = view
            view.update(settings: WallpaperEffectsPreset.cinematic.settings)
            view.applyActivity(WallpaperEffectsActivity())
            #expect(view.isAnimating)
        }
        // AppKit/Core Animation retain pending layout work until the transaction drains.
        for _ in 0..<10 where retained != nil {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(retained == nil)
    }

    @Test @MainActor func parallaxKeepsPlayerIdentityAndSourceGeometryAndDisableIsReversible() throws {
        let player = AVQueuePlayer()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        content.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = content.bounds
        content.layer?.addSublayer(playerLayer)
        let view = WallpaperEffectsView(content: content, store: nil)
        view.update(settings: WallpaperEffectsPreset.cinematic.settings)
        view.applyActivity(WallpaperEffectsActivity())
        for _ in 0..<30 { view.renderFrame(deltaTime: 1.0 / 30, cursor: CGPoint(x: 1, y: -1)) }
        let transform = try #require(view.subviews.first?.layer?.affineTransform())
        #expect(transform.a > 1 && transform.a == transform.d)
        #expect(content.bounds.size == CGSize(width: 800, height: 500))
        #expect(playerLayer.frame.size == content.bounds.size && playerLayer.player === player)
        view.update(settings: WallpaperEffectsSettings())
        #expect(!view.isAnimating && view.subviews.first?.layer?.affineTransform() == .identity)
        #expect(playerLayer.player === player && player.rate == 0)
    }

    @Test func blurAndBloomAreIndependentAndDoNotMutateAttachedFilters() throws {
        var settings = WallpaperEffectsSettings()
        settings.enabled = true
        #expect(WallpaperEffectsFilters.make(settings: settings).isEmpty)
        settings.blurEnabled = true
        settings.blurAmount = 0.5
        let previous = try #require(WallpaperEffectsFilters.make(settings: settings).first)
        #expect(previous.name == "wallpaperBlur")
        #expect(previous.value(forKey: kCIInputRadiusKey) as? Double == 9)
        settings.bloomEnabled = true
        let filters = WallpaperEffectsFilters.make(settings: settings)
        #expect(filters.count == 2 && filters.last?.name == "wallpaperBloom")
        #expect(filters.first !== previous)
        settings.blurEnabled = false
        #expect(WallpaperEffectsFilters.make(settings: settings).count == 1)
        settings.enabled = false
        #expect(WallpaperEffectsFilters.make(settings: settings).isEmpty)
    }

    @Test @MainActor func staticFiltersDoNotStartAFrameTimerOrChangeSourceDimensions() {
        var settings = WallpaperEffectsSettings()
        settings.enabled = true
        settings.parallaxEnabled = false
        settings.glowEnabled = false
        settings.blurEnabled = true
        settings.bloomEnabled = true
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let view = WallpaperEffectsView(content: content, store: nil)
        view.update(settings: settings)
        view.applyActivity(WallpaperEffectsActivity())
        #expect(settings.hasVisibleEffects && !settings.hasAnimatedEffects)
        #expect(!view.isAnimating && view.subviews.first?.layer?.filters?.count == 2)
        #expect((view.subviews.first?.layer?.affineTransform().a ?? 1) > 1) // Blur's transparent border is cropped away.
        #expect(content.bounds.size == CGSize(width: 800, height: 500))
        var paused = WallpaperEffectsActivity()
        paused.playbackPaused = true
        view.applyActivity(paused)
        #expect(view.subviews.first?.layer?.filters == nil)
    }

    @Test @MainActor func lightAndForegroundPlanesMoveDifferentlyAndWeatherCanBeRemoved() throws {
        var settings = WallpaperEffectsPreset.dreamy.settings
        settings.rainEnabled = true
        settings.reflectionEnabled = true
        var motion = WallpaperEffectsMotion()
        for _ in 0..<60 { motion.advance(settings: settings, cursor: CGPoint(x: 1, y: 0.5), deltaTime: 1.0 / 30) }
        let overlay = WallpaperEffectsOverlay()
        overlay.render(settings: settings, motion: motion, size: CGSize(width: 1200, height: 800), scale: 2)
        let layers = try #require(overlay.sublayers)
        let glow = try #require(layers.first { $0.name == "glow" })
        let flare = try #require(layers.first { $0.name == "flare" })
        #expect(glow.position.x < flare.position.x && glow.position.y < flare.position.y)
        let drops = layers.filter { $0.name == "rain" && !$0.isHidden }
        #expect(drops.count > 20 && drops.allSatisfy { $0.bounds.height < 60 && $0.bounds.width < 30 })
        let firstPosition = try #require(drops.first?.frame.origin)
        motion.advance(settings: settings, cursor: CGPoint(x: -1, y: 0), deltaTime: 1.0 / 30)
        overlay.render(settings: settings, motion: motion, size: CGSize(width: 1200, height: 800), scale: 2)
        #expect(drops.first?.frame.origin != firstPosition)
        settings.rainEnabled = false
        settings.sparkleEnabled = false
        settings.reflectionEnabled = false
        overlay.render(settings: settings, motion: motion, size: CGSize(width: 1200, height: 800), scale: 2)
        #expect(layers.filter { $0.name == "rain" || $0.name == "sparkle" }.allSatisfy { $0.isHidden })
        #expect(layers.first { $0.name == "reflection" }?.opacity == 0)
    }

    @Test @MainActor func runningPresentationReloadsSavedPreferencesWithoutPlaybackCommands() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperEffectsStore(appSupportURL: root)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let view = WallpaperEffectsView(content: content, store: store)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view // Hidden throughout: only persistence and timers are exercised.
        defer { window.contentView = nil; window.close() }
        #expect(!view.settings.enabled && !view.isAnimating)
        try store.save(WallpaperEffectsPreset.cinematic.settings)
        let deadline = Date().addingTimeInterval(2)
        while view.settings != WallpaperEffectsPreset.cinematic.settings && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.settings == WallpaperEffectsPreset.cinematic.settings)
        #expect(!view.isAnimating && !window.isVisible)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("command.json").path))
    }

    @Test @MainActor func saveFailureKeepsTheLastAppliedPreferencesAndReportsTheError() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(controller: MockNativeWallpaperController(), appSupportDirectoryURL: root)
        let file = WallpaperEffectsStore(appSupportURL: root).url
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        model.applyWallpaperEffectsPreset(.dreamy)
        #expect(model.wallpaperEffects == WallpaperEffectsSettings())
        #expect(model.alertMessage?.contains("Could not save wallpaper effects") == true)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func effectsPersistWithoutChangingLoginLockPlaybackOrNativeDescriptors(login: Bool, lock: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = ControlConfig(video_path: "/unopened/source.mp4", playback_speed: 0.75, volume: 0.2,
                                   autostart: login, show_on_lock_screen: lock, scale_mode: "fit")
        let configURL = root.appendingPathComponent("config.json")
        let bytes = try JSONEncoder().encode(config)
        try bytes.write(to: configURL)
        let descriptorsURL = root.appendingPathComponent("wallpaper-store-backup.plist")
        let descriptors = Data("complete opaque native descriptors and appearance".utf8)
        try descriptors.write(to: descriptorsURL)
        let controller = MockNativeWallpaperController()
        controller.statusConfigAutostart = login
        controller.statusShowOnLockScreen = lock
        let model = AppViewModel(controller: controller, appSupportDirectoryURL: root)
        model.applyWallpaperEffectsPreset(.cinematic)
        model.setWallpaperEffect(\.rainEnabled, true)
        model.setWallpaperEffect(\.rainSpeed, 0.8)
        #expect(model.wallpaperEffects.rainEnabled && model.wallpaperEffects.rainSpeed == 0.8)
        #expect(WallpaperEffectsStore(appSupportURL: root).load() == model.wallpaperEffects)
        let reopened = AppViewModel(controller: controller, appSupportDirectoryURL: root)
        #expect(reopened.wallpaperEffects == model.wallpaperEffects)
        model.setWallpaperEffect(\.enabled, false)
        #expect(!model.wallpaperEffects.enabled && model.wallpaperEffects.rainEnabled)
        #expect(try Data(contentsOf: configURL) == bytes)
        #expect(try Data(contentsOf: descriptorsURL) == descriptors)
        #expect(controller.startCallCount == 0 && controller.stopCallCount == 0 && controller.resumeCallCount == 0)
        #expect(controller.clearCallCount == 0 && controller.lockCallCount == 0 && controller.syncLockScreenCallCount == 0)
        model.resetWallpaperEffects()
        #expect(WallpaperEffectsStore(appSupportURL: root).load() == WallpaperEffectsSettings())
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AuraEffects-\(UUID())")
    }
}
