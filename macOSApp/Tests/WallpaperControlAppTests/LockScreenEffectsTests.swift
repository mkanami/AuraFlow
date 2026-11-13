import AppKit
import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import AuraWallpaperCore
@testable import AuraWallpaperAgent

private final class EffectsNativeInstaller: ModernLockScreenInstalling {
    var isAvailable = true
    var isInstalled = false
    var installs = 0
    var removes = 0
    var desktopInstalls = 0
    var lockInstalls = 0
    func install(videoURL: URL) async throws { installs += 1; isInstalled = true }
    func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        desktopInstalls += 1; isInstalled = true
    }
    func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        lockInstalls += 1; isInstalled = true
    }
    func prepareLockScreenMedia(videoURL: URL) async throws {}
    func uninstall() throws { removes += 1; isInstalled = false }
}

@Test func lockEffectsDisabledKeepsEachNativeInstallationScope() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsSettings())
    let installer = f.installer()
    try await installer.install(videoURL: f.source)
    try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1.5, scaleMode: .fit)
    try await installer.installLockScreenOnly(videoURL: f.source, playbackSpeed: 0.5, scaleMode: .fill)
    #expect(f.native.installs == 1 && f.native.desktopInstalls == 1 && f.native.lockInstalls == 1)
    #expect(f.restarts == 0)
    #expect(try f.load() == f.original)
}

private final class EffectsRouteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockEffects-\(UUID())")
    var storeURL: URL { root.appendingPathComponent("Index.plist") }
    var saverURL: URL { root.appendingPathComponent("Aura.saver") }
    var source: URL { root.appendingPathComponent("scene.mp4") }
    let native = EffectsNativeInstaller()
    var locked: Bool? = false
    var restarts = 0
    var original: NSDictionary!
    init() throws {
        try FileManager.default.createDirectory(at: saverURL.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: saverURL.appendingPathComponent("Contents/Frameworks/libAuraWallpaperEffects.dylib"))
        try Data("movie".utf8).write(to: source)
        let desktop: [String: Any] = ["Content": ["Choices": [["Provider": WallpaperPlatformConstants.imageProviderID,
            "Files": ["user-selected-photo"], "Configuration": Data([1, 2, 3]), "Options": ["appearance": "dark", "scale": "fit"]]],
            "Shuffle": "$null"], "Appearance": ["mode": "auto", "color": [0.1, 0.2, 0.3]]]
        let routes: [String: Any] = ["AllSpacesAndDisplays": ["Type": "linked", "Linked": desktop],
            "SystemDefault": ["Type": "individual", "Desktop": desktop, "Idle": desktop],
            "Displays": ["test-secondary": ["Type": "linked", "Linked": desktop]],
            "Spaces": ["test-space": ["Default": ["Type": "linked", "Linked": desktop]]]]
        original = routes as NSDictionary
        try PropertyListSerialization.data(fromPropertyList: routes, format: .binary, options: 0).write(to: storeURL)
        try WallpaperEffectsStore(appSupportURL: root).save(WallpaperEffectsPreset.cinematic.settings)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func installer() -> LiveEffectsLockScreenInstaller {
        LiveEffectsLockScreenInstaller(native: native, appSupportURL: root, saverURL: saverURL, storeURL: storeURL,
            stopWallpaperAgent: { self.restarts += 1 }, startWallpaperAgent: {}, sessionIsLocked: { self.locked })
    }
    func load() throws -> NSDictionary {
        try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil) as? NSDictionary)
    }
}

@Test(arguments: [false, true], [false, true])
func lockEffectsManualAndAutomaticSessionsPreserveCompleteNativeDescriptors(lockOnly: Bool, automatic: Bool) async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    if lockOnly { try await installer.installLockScreenOnly(videoURL: f.source) }
    else { try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1.5, scaleMode: .fit) }
    #expect(installer.lockScreenOnlyStatus(videoURL: f.source).isReady)
    #expect(f.native.installs == 0)
    let idle = try f.load()
    if automatic {
        // Idle saver before password lock is not a secure lock. No promotion.
        #expect(try installer.activateLockScreenForCurrentSession() == false)
        #expect(try f.load() == idle)
    }
    f.locked = nil // Delayed/missing notification with unavailable CGSession.
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(try f.load() == idle)
    f.locked = true
    #expect(try installer.activateLockScreenForCurrentSession())
    let secure = try f.load()
    #expect(secure != idle)
    // Sleep/wake while still locked and duplicate notifications retain source.
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }) == false)
    #expect(try f.load() == secure)
    f.locked = false // Unlock recovered by polling; no notification required.
    #expect(try await installer.restoreDesktopAfterLockScreenSessionAsync())
    #expect(try f.load() == idle)
    try await installer.uninstallLockScreenOnlyPreservingCurrentDesktopAsync()
    #expect(try f.load() == f.original)
    #expect(!installer.isInstalled && f.restarts == 2)
}

@Test func lockEffectsCanMigrateExistingNativePlaybackAndStayLiveWhenSettingsToggle() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    f.native.isInstalled = true
    let installer = f.installer()
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { false }) == false)
    #expect(f.native.removes == 0)
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }))
    #expect(f.native.removes == 1 && installer.lockScreenOnlyStatus(videoURL: f.source).isReady)
    let before = try f.load()
    try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsSettings())
    #expect(try await installer.rearmForNextLock(videoURL: f.source, shouldProceed: { true }))
    #expect(try f.load() == before && f.restarts == 1)
    try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsPreset.dreamy.settings)
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }) == false)
    #expect(try f.load() == before && f.restarts == 1)
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test @MainActor func lockEffectsUseTheDesktopRendererWithTheSameStrengthColorsAndCursorResponse() throws {
    let desktop = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600)), store: nil)
    let secure = WallpaperEffectsView(content: NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600)), store: nil, isScreenSaver: true)
    var settings = WallpaperEffectsPreset.cinematic.settings
    settings.rainEnabled = true; settings.rainAmount = 0.8; settings.rainColor = .red
    settings.reflectionEnabled = true; settings.sparkleEnabled = true
    desktop.update(settings: settings); secure.update(settings: settings)
    var active = WallpaperEffectsActivity()
    desktop.applyActivity(active)
    active.screenSaverPresentation = true; active.sessionLocked = true
    active.sessionActive = false; active.screenSaverActive = true
    secure.applyActivity(active)
    for frame in 0..<90 {
        let cursor = CGPoint(x: frame < 45 ? -0.8 : 0.8, y: 0.5)
        desktop.renderFrame(deltaTime: 1.0/60, cursor: cursor, at: Double(frame)/60)
        secure.renderFrame(deltaTime: 1.0/60, cursor: cursor, at: Double(frame)/60)
    }
    let a = desktop.status, b = secure.status
    #expect(b.surface == "lockScreen" && b.active && b.pauseReason == nil && b.renderedFrames == 90)
    #expect(a.parallaxX == b.parallaxX && a.parallaxY == b.parallaxY)
    #expect(a.glowOpacity == b.glowOpacity && a.glowX == b.glowX && a.flareOpacity == b.flareOpacity)
    #expect(a.flareX == b.flareX && a.flareY == b.flareY && b.cursorX > 0.7)
    let desktopOverlay = try #require(desktop.layer?.sublayers?.compactMap { $0 as? WallpaperEffectsOverlay }.first)
    let secureOverlay = try #require(secure.layer?.sublayers?.compactMap { $0 as? WallpaperEffectsOverlay }.first)
    let air = desktopOverlay.airRainInstances, secureAir = secureOverlay.airRainInstances
    #expect(!air.isEmpty && air.count == secureAir.count)
    #expect(zip(air, secureAir).allSatisfy { $0.ellipse == $1.ellipse && $0.color == $1.color && $0.optics == $1.optics })
    #expect(desktop.subviews.first?.layer?.filters?.count == secure.subviews.first?.layer?.filters?.count)
    #expect(secure.hitTest(.zero) == nil && secure.window == nil)
    active.sleeping = true; secure.applyActivity(active)
    #expect(!secure.isAnimating && secure.status.pauseReason == "sleeping")
    active.sleeping = false; secure.applyActivity(active)
    #expect(secure.isAnimating)
    active.windowVisible = false; secure.applyActivity(active)
    #expect(!secure.isAnimating)
}

@Test @MainActor func lockEffectsBridgeStopsItsClockWhenTheSaverStopsAndReloadsSettings() throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let bridge = ScreenSaverEffectsBridge(content: NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400)), appSupportURL: f.root, isPreview: true)
    bridge.setPresenting(true, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    #expect(bridge.diagnostics["active"] as? Bool == true)
    bridge.setPresenting(true, paused: true, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    #expect(bridge.diagnostics["active"] as? Bool == false)
    bridge.setPresenting(false, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    #expect(bridge.diagnostics["framesPerSecond"] as? Double == 0)
}

@Test func lockEffectsDoNotAnimateThePrewarmedHostOnAnActiveDesktop() {
    #expect(!WallpaperScreenSaverActivity.isVisible(locked: false, saverRunning: false))
    #expect(!WallpaperScreenSaverActivity.isVisible(locked: nil, saverRunning: nil))
    #expect(WallpaperScreenSaverActivity.isVisible(locked: true, saverRunning: false))
    // Rendering the automatic saver during password grace does not imply lock.
    #expect(WallpaperScreenSaverActivity.isVisible(locked: false, saverRunning: true))
}

@Test @MainActor func lockEffectsRefractionMatchesTheScaleOfImageAndTerminalWebFallbacks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraEffectsImage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
    let file = root.appendingPathComponent("frame.png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    let source = WallpaperGlassFrameSource()
    defer { source.stop() }
    let content = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    for gravity in [AVLayerVideoGravity.resizeAspect, .resize, .resizeAspectFill] {
        var frame: WallpaperGlassFrameSource.Frame?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            frame = source.current(content: content, surfaceID: nil, sequence: nil, imageURL: file,
                surfaceGravity: gravity, at: CACurrentMediaTime())
            if frame == nil { try await Task.sleep(for: .milliseconds(10)) }
        } while frame == nil && Date() < deadline
        #expect(frame?.gravity == gravity)
    }
}

private final class EffectsMigratingPlatform: LockScreenSaverInstalling {
    var capabilities: PlatformCapabilities { .modernMacOS26(isAvailable: true) }
    var isInstalled = true
    var migrated = false
    func install(videoURL: URL) async throws {}
    func uninstall() throws {}
    func repair(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        guard shouldProceed(), !migrated else { return false }
        migrated = true
        return true
    }
    func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus {
        .init(installed: true, sourceMatches: true, assetValid: true, providerAvailable: true,
            wallpaperStoreValid: true, screenSaverSelected: true, assetID: migrated ? "AuraFlowLiveEffects" : "native")
    }
}
private final class EffectsBridgeTrace: NativeLockScreenBridging {
    var isReady = true
    var onFailure: (@Sendable (String) -> Void)?
    var invalidations = 0
    var preparations = 0
    func prepare(completion: @escaping @Sendable (Bool) -> Void) { preparations += 1; completion(true) }
    func showForLockTransition(completion: (@Sendable (Bool) -> Void)?) { completion?(true) }
    func hideAfterUnlock() {}
    func pause() {}
    func resumeAfterPause() {}
    func invalidatePreparation() { invalidations += 1 }
    func shutdown() {}
}

@Test @MainActor func lockEffectsMigrationRebindsTheWarmNativeBridgeWithoutRestartingDesktop() async throws {
    _ = NSApplication.shared
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let store = WallpaperRuntimeStore(appSupportURL: f.root, launchAgentURL: f.root.appendingPathComponent("login.plist"))
    let source = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    try store.saveConfig(.init(video_path: source.path, playback_speed: 1, pause_on_fullscreen: false, show_on_lock_screen: true))
    let platform = EffectsMigratingPlatform(), bridge = EffectsBridgeTrace()
    let agent = WallpaperAgentDelegate(store: store, lockScreenPlatform: platform, nativeLockScreenBridge: bridge,
        presentWindow: { _, _ in }, observesSystemEvents: false, sessionIsLocked: { false })
    defer { agent.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    agent.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let player = agent.player
    agent.samplePlaybackHealth()
    let deadline = Date().addingTimeInterval(2)
    while bridge.invalidations == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(platform.migrated && bridge.invalidations == 1 && bridge.preparations >= 2)
    #expect(agent.player === player && agent.windows.allSatisfy { !$0.isVisible })
}

@Test @MainActor func lockEffectsExistingRouteAcknowledgesTheNewStartOperationWithoutRestartingVideo() async throws {
    _ = NSApplication.shared
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let movie = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    try Data(contentsOf: movie).write(to: f.source)
    let installer = f.installer()
    try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1, scaleMode: .fill)
    let store = WallpaperRuntimeStore(appSupportURL: f.root, launchAgentURL: f.root.appendingPathComponent("login.plist"))
    let config = ControlConfig(video_path: f.source.path, playback_speed: 1, pause_on_fullscreen: false, show_on_lock_screen: true)
    try store.saveConfig(config)
    let platform = ModernMacOS26Adapter(installer: installer,
        operatingSystemVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    let bridge = EffectsBridgeTrace()
    let agent = WallpaperAgentDelegate(store: store, lockScreenPlatform: platform, nativeLockScreenBridge: bridge,
        presentWindow: { _, _ in }, observesSystemEvents: false, sessionIsLocked: { false })
    defer { agent.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    agent.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let player = agent.player
    try store.saveCommand(.init(operationID: 42, action: .rearmLockScreen, config: config))
    agent.pollCommand()
    let deadline = Date().addingTimeInterval(3)
    while !store.isLockScreenAgentReady(operationID: 42), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.isLockScreenAgentReady(operationID: 42))
    #expect(agent.player === player && f.restarts == 1)
    #expect(agent.windows.allSatisfy { !$0.isVisible })
}
