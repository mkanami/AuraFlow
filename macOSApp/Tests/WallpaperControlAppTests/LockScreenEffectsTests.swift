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
    var preparations = 0
    var requiresLockScreenSessionPromotion: Bool { isInstalled && lockInstalls > 0 && desktopInstalls == 0 && installs == 0 }
    func install(videoURL: URL) async throws { installs += 1; isInstalled = true }
    func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        desktopInstalls += 1; isInstalled = true
    }
    func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        lockInstalls += 1; isInstalled = true
    }
    func prepareLockScreenMedia(videoURL: URL) async throws { preparations += 1 }
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
    var onStop: (() throws -> Void)?
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
            stopWallpaperAgent: { self.restarts += 1; try self.onStop?() }, startWallpaperAgent: {}, sessionIsLocked: { self.locked })
    }
    func load() throws -> NSDictionary {
        try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil) as? NSDictionary)
    }
}

private func placeholderDesktops(_ value: Any) -> Any {
    guard let dictionary = value as? [String: Any] else { return value }
    return dictionary.mapValues { placeholderDesktops($0) }.reduce(into: [String: Any]()) { result, item in
        result[item.key] = ["Desktop", "Linked"].contains(item.key)
            ? ["Content": ["Choices": [["Provider": "default", "Files": [], "Configuration": Data()]]]]
            : item.value
    }
}

private func nativeDesktops(_ value: Any, path: String = "") -> [String: NSDictionary] {
    guard let root = value as? [String: Any] else { return [:] }
    var result: [String: NSDictionary] = [:]
    if let mode = (root["Desktop"] ?? root["Linked"]) as? NSDictionary { result[path] = mode }
    for (key, child) in root where key != "Desktop" && key != "Linked" && key != "Idle" {
        result.merge(nativeDesktops(child, path: path + "/" + key)) { _, new in new }
    }
    return result
}

@Test func lockEffectsShutdownPlaceholderCannotReplaceNativeDesktopDescriptors() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    f.onStop = {
        let changed = placeholderDesktops(try f.load())
        try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0).write(to: f.storeURL)
    }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    let expected = nativeDesktops(f.original!)
    #expect(nativeDesktops(try f.load()) == expected)
    for _ in 0..<2 {
        f.locked = false
        _ = try await installer.rearmForNextLock(videoURL: f.source, shouldProceed: { true })
        #expect(nativeDesktops(try f.load()) == expected)
        f.locked = true
        #expect(try installer.activateLockScreenForCurrentSession())
        f.locked = false
        _ = try await installer.restoreDesktopAfterLockScreenSessionAsync()
        #expect(nativeDesktops(try f.load()) == expected)
    }
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test func lockEffectsRepairsAnOwnedDefaultPlaceholderFromItsExactSavedDesktop() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    try PropertyListSerialization.data(fromPropertyList: placeholderDesktops(try f.load()), format: .binary, options: 0)
        .write(to: f.storeURL)
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }))
    #expect(nativeDesktops(try f.load()) == nativeDesktops(f.original!))
    f.locked = true
    #expect(try installer.activateLockScreenForCurrentSession())
    f.locked = false
    _ = try await installer.restoreDesktopAfterLockScreenSessionAsync()
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test func lockEffectsShutdownKeepsANewerExplicitNativeDesktopInsteadOfTheOldJournal() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    var current = try f.load() as! [String: Any]
    var route = current["SystemDefault"] as! [String: Any]
    var chosen = route["Desktop"] as! [String: Any]
    chosen["Appearance"] = ["mode": "light", "color": [0.9, 0.5, 0.2]]
    route["Desktop"] = chosen; current["SystemDefault"] = route
    try PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0).write(to: f.storeURL)
    f.onStop = {
        try PropertyListSerialization.data(fromPropertyList: placeholderDesktops(try f.load()), format: .binary, options: 0)
            .write(to: f.storeURL)
    }
    _ = try await installer.rearmForNextLock(videoURL: f.source, shouldProceed: { true })
    #expect((try f.load()["SystemDefault"] as? [String: Any])?["Desktop"] as? NSDictionary == chosen as NSDictionary)
    f.locked = true
    _ = try installer.activateLockScreenForCurrentSession()
    f.locked = false
    _ = try await installer.restoreDesktopAfterLockScreenSessionAsync()
    #expect((try f.load()["SystemDefault"] as? [String: Any])?["Desktop"] as? NSDictionary == chosen as NSDictionary,
        "The secure provider's final placeholder write must preserve the Desktop selected after installation")
    try await installer.uninstallAsync()
    #expect((try f.load()["SystemDefault"] as? [String: Any])?["Desktop"] as? NSDictionary == chosen as NSDictionary)
}

@Test(arguments: [false, true])
func lockEffectsRepeatedSessionsReloadTheStoreAfterTheSystemFlushesItsCachedDesktop(automatic: Bool) async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    let idle = try f.load()
    // Model the real server cache: changing the file alone does not change
    // the source it will render, and shutdown writes its cached route back.
    var serverCache = idle
    f.onStop = {
        try PropertyListSerialization.data(fromPropertyList: serverCache, format: .binary, options: 0).write(to: f.storeURL)
    }
    for cycle in 1...3 {
        f.locked = false
        if automatic {
            #expect(try installer.activateLockScreenForCurrentSession() == false,
                "An idle saver before the password lock cannot promote Desktop")
        }
        #expect(try installer.activateLockScreenForCurrentSession() == false)
        f.locked = nil
        #expect(try installer.activateLockScreenForCurrentSession() == false)
        #expect(f.restarts == cycle)
        f.locked = true
        #expect(try installer.activateLockScreenForCurrentSession())
        #expect(f.restarts == cycle + 1, "Each secure session must make the server read the promoted route")
        serverCache = try f.load()
        let live = try f.load()["AllSpacesAndDisplays"] as! [String: Any]
        #expect(live["Desktop"] as? NSDictionary == live["Idle"] as? NSDictionary,
            "The restarted server must resolve AuraFlow for both secure modes")
        #expect(installer.lockScreenOnlyStatus(videoURL: f.source).isReady)
        #expect(try installer.activateLockScreenForCurrentSession() == false)
        #expect(try f.load()["AllSpacesAndDisplays"] as? NSDictionary == live as NSDictionary)
        // A sleep/wake or duplicate lock callback in the same secure session
        // retains its provider rather than restarting it again.
        #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }) == false)
        #expect(f.restarts == cycle + 1)
        f.locked = false
        #expect(try await installer.restoreDesktopAfterLockScreenSessionAsync())
        #expect(try f.load() == idle)
        // On unlock the OS may already hold the native Desktop in memory.
        // The next lock must work whether or not it observed our restoration.
        if cycle % 2 == 0 { serverCache = idle }
    }
    f.onStop = nil
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
    #expect(f.restarts == 5)
}

@Test func lockEffectsUnlockDuringProviderRefreshRestoresTheExactDesktop() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    let idle = try f.load()
    f.locked = true
    f.onStop = { f.locked = false }
    _ = try installer.activateLockScreenForCurrentSession()
    #expect(try f.load() == idle)
    #expect(f.restarts == 2)
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(f.restarts == 2, "A delayed completion cannot rearm an unlocked Mac")
    f.onStop = nil
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test func lockEffectsFailedProviderRefreshRemainsRetryableForTheSameLockSession() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.source)
    f.locked = true
    f.onStop = { throw CocoaError(.fileReadUnknown) }
    #expect(throws: CocoaError.self) { try installer.activateLockScreenForCurrentSession() }
    f.onStop = nil
    #expect(try installer.activateLockScreenForCurrentSession())
    #expect(f.restarts == 3)
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(f.restarts == 3)
    f.locked = false
    _ = try await installer.restoreDesktopAfterLockScreenSessionAsync()
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test(arguments: [false, true], [false, true])
func lockEffectsProviderReloadRetainsTheWarmSaverOnlyForSessionRebinds(stopOnly: Bool, resetScreenSaver: Bool) throws {
    var inspected: [String] = [], commands: [[String]] = [], waited: [Set<pid_t>] = []
    var freshWaits = 0
    let actions = LiveScreenSaverStoreCoordinator.RestartActions(
        processes: { name in inspected.append(name); return name == "legacyScreenSaver" ? [82] : [41] },
        run: { commands.append([$0] + $1) },
        waitForExit: { ids, _ in waited.append(ids); return true },
        waitForFreshAgent: { ids in #expect(ids == [41]); freshWaits += 1; return true })
    try LiveScreenSaverStoreCoordinator.restartWallpaperAgent(stopOnly: stopOnly,
        resetScreenSaver: resetScreenSaver, actions: actions)
    #expect(commands.contains(["/usr/bin/killall", "WallpaperAgent"]))
    #expect(inspected.contains("legacyScreenSaver") == resetScreenSaver)
    #expect(commands.contains(["/usr/bin/pkill", "-x", "legacyScreenSaver"]) == resetScreenSaver)
    #expect(waited == (resetScreenSaver ? [[41], [82]] : [[41]]))
    #expect(freshWaits == (stopOnly ? 0 : 1))
}

@Test(arguments: [false, true], [false, true])
func lockEffectsManualAndAutomaticSessionsPreserveCompleteNativeDescriptors(lockOnly: Bool, automatic: Bool) async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    if lockOnly { try await installer.installLockScreenOnly(videoURL: f.source) }
    else { try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1.5, scaleMode: .fit) }
    #expect(installer.lockScreenOnlyStatus(videoURL: f.source).isReady)
    #expect(f.native.installs == 0 && f.native.lockInstalls == 0,
        "Lock with live effects must never enter native effects movie preparation")
    #expect(installer.requiresLockScreenSessionPromotion == lockOnly)
    let idle = try f.load()
    if lockOnly {
        let actual = idle["AllSpacesAndDisplays"] as! [String: Any]
        let original = f.original["AllSpacesAndDisplays"] as! [String: Any]
        #expect(actual["Desktop"] as? NSDictionary == original["Linked"] as? NSDictionary)
        #expect(actual["Linked"] == nil)
    }
    if automatic {
        // Idle saver before password lock is not a secure lock. No promotion.
        #expect(try installer.activateLockScreenForCurrentSession() == false)
        #expect(try f.load() == idle)
    }
    f.locked = nil // Delayed/missing notification with unavailable CGSession.
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(try f.load() == idle)
    f.locked = true
    #expect(try installer.activateLockScreenForCurrentSession() == lockOnly)
    let secure = try f.load()
    #expect((secure == idle) == !lockOnly,
        "Lock-only promotes the live source only after a confirmed secure lock")
    if !lockOnly {
        let coordinator = LiveScreenSaverStoreCoordinator(storeURL: f.storeURL,
            journalURL: f.root.appendingPathComponent("live-lock-screen-route.json"), saverURL: f.saverURL,
            stopWallpaperAgent: {}, startWallpaperAgent: {})
        #expect(coordinator.isSharedSelected)
        #expect(!installer.requiresLockScreenSessionPromotion)
    }
    // Sleep/wake while still locked and duplicate notifications retain source.
    #expect(try installer.activateLockScreenForCurrentSession() == false)
    #expect(try await installer.repair(videoURL: f.source, shouldProceed: { true }) == false)
    #expect(try f.load() == secure)
    f.locked = false // Unlock recovered by polling; no notification required.
    #expect(try await installer.restoreDesktopAfterLockScreenSessionAsync() == lockOnly)
    #expect(try f.load() == idle)
    try await installer.uninstallLockScreenOnlyPreservingCurrentDesktopAsync()
    #expect(try f.load() == f.original)
    #expect(!installer.isInstalled && f.restarts == (lockOnly ? 3 : 2))
}

@Test(arguments: ["scene.mp4", "still.png"])
func lockEffectsLockOnlyUsesTheOriginalMediaWithoutBakingOrNativePreparation(name: String) async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let source = f.root.appendingPathComponent(name)
    if source != f.source { try Data("still fixture".utf8).write(to: source) }
    let installer = f.installer()
    try WallpaperRuntimeStore(appSupportURL: f.root).saveLockScreenOnlySource(source)
    try await installer.prepareLockScreenMedia(videoURL: source, playbackSpeed: 1.5, scaleMode: .fit)
    try await installer.installLockScreenOnly(videoURL: source, playbackSpeed: 1.5, scaleMode: .fit)
    #expect(f.native.preparations == 0 && f.native.lockInstalls == 0)
    #expect(LiveEffectsLockScreenInstaller.usesLiveRenderer(appSupportURL: f.root))
    #expect(installer.installationConfirmed && installer.requiresLockScreenSessionPromotion)
    let marker = try JSONSerialization.jsonObject(with: Data(contentsOf:
        f.root.appendingPathComponent("live-lock-screen-effects.json"))) as! [String: Any]
    #expect(marker["path"] as? String == source.standardizedFileURL.path)
    #expect(marker["desktopIncluded"] as? Bool == false)
    var settings = WallpaperEffectsPreset.dreamy.settings
    settings.rainEnabled = true
    settings.glassRainEnabled = true
    try WallpaperEffectsStore(appSupportURL: f.root).save(settings)
    #expect(try await installer.repair(videoURL: source, shouldProceed: { true }) == false)
    #expect(f.native.lockInstalls == 0 && f.native.preparations == 0)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("NativeEffectsCache").path))
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
}

@Test func lockEffectsSwitchingSharedPlaybackToLockOnlyRecoversTheOriginalDesktop() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1, scaleMode: .fill)
    try WallpaperRuntimeStore(appSupportURL: f.root).saveLockScreenOnlySource(f.source)
    try await installer.installLockScreenOnly(videoURL: f.source)
    let current = try f.load()["AllSpacesAndDisplays"] as! [String: Any]
    let original = f.original["AllSpacesAndDisplays"] as! [String: Any]
    #expect(current["Desktop"] as? NSDictionary == original["Linked"] as? NSDictionary)
    #expect(installer.installationConfirmed && installer.requiresLockScreenSessionPromotion)
    #expect(f.native.lockInstalls == 0)
    try await installer.uninstallAsync()
    #expect(try f.load() == f.original)
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

private struct MigratingEffectsMedia: NativeEffectsMediaPreparing {
    let output: URL
    func prepare(source: URL, settings: WallpaperEffectsSettings, speed: Double,
        scaleMode: WallpaperScaleMode, shouldProceed: @escaping () -> Bool) async throws -> URL {
        guard shouldProceed() else { throw CancellationError() }
        return output
    }
}

@Test func nativeEffectsMigrationRestoresEveryOriginalDescriptorBeforeSelectingAerial() async throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let old = f.installer()
    try await old.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1, scaleMode: .fill)
    #expect(try f.load() != f.original)
    let output = f.root.appendingPathComponent("native-effects.mov")
    try Data("rendered".utf8).write(to: output)
    let installer = AerialEffectsLockScreenInstaller(native: f.native, appSupportURL: f.root,
        media: MigratingEffectsMedia(output: output), legacyInstaller: old)
    try await installer.installForDesktopAgent(videoURL: f.source, playbackSpeed: 1, scaleMode: .fill)
    #expect(try f.load() == f.original)
    #expect(!LiveEffectsLockScreenInstaller.usesLiveRenderer(appSupportURL: f.root))
    #expect(f.native.desktopInstalls == 1 && f.restarts == 2)
    #expect(FileManager.default.isReadableFile(atPath: f.root.appendingPathComponent("native-effects-source.json").path))
}

@Test func lockEffectsSharedChoiceRestoresDistinctNativeDescriptorsAndMissingDesktopFields() throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    var original = f.original as! [String: Any]
    let night: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.sequoia",
        "Files": [], "Configuration": Data([9, 8, 7]), "Options": ["appearance": "night"]]]],
        "Appearance": ["mode": "dark", "color": [0.7, 0.2, 0.1]]]
    var system = original["SystemDefault"] as! [String: Any]; system["Idle"] = night
    original["SystemDefault"] = system
    var displays = original["Displays"] as! [String: Any]
    displays["inheriting-display"] = ["Idle": night]
    original["Displays"] = displays
    try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0).write(to: f.storeURL)
    let routes = LiveScreenSaverStoreCoordinator(storeURL: f.storeURL,
        journalURL: f.root.appendingPathComponent("shared.json"), saverURL: f.saverURL,
        stopWallpaperAgent: {}, startWallpaperAgent: {})
    try routes.activate(includeDesktop: true)
    #expect(routes.isSharedSelected)
    try routes.activate(includeDesktop: true)
    try routes.restoreCurrentDesktopIfOwned()
    #expect(try f.load() == original as NSDictionary)
}

@Test func lockEffectsSharedSuspendAndResumePreserveRealNativeChoicesAfterARuntimeExit() throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let journal = f.root.appendingPathComponent("shared.json")
    let routes = LiveScreenSaverStoreCoordinator(storeURL: f.storeURL, journalURL: journal,
        saverURL: f.saverURL, stopWallpaperAgent: {}, startWallpaperAgent: {})
    let recovery = ScreenSaverRouteRecovery(storeURL: f.storeURL, journalURL: journal, saverURL: f.saverURL)
    try routes.activate(includeDesktop: true)
    let selected = try f.load()
    #expect(try recovery.suspendIfNeeded(shouldProceed: { false }) == false)
    #expect(try f.load() == selected)
    #expect(try recovery.suspendIfNeeded(shouldProceed: { true }))
    #expect(!routes.isSelected && !routes.isSharedSelected)
    let root = try f.load() as! [String: Any]
    let all = root["AllSpacesAndDisplays"] as! [String: Any]
    let expected = (f.original["AllSpacesAndDisplays"] as! [String: Any])["Linked"] as! NSDictionary
    #expect(all["Desktop"] as? NSDictionary == expected && all["Idle"] as? NSDictionary == expected)
    #expect(try recovery.recoverIfNeeded())
    #expect(routes.isSharedSelected)
    try routes.restoreIfOwned()
    #expect(try f.load() == f.original)
}

@Test func lockEffectsSharedRemovePreservesAnExplicitNewIdleOrDesktopChoice() throws {
    for changed in ["Desktop", "Idle"] {
        let f = try EffectsRouteFixture(); defer { f.cleanup() }
        let routes = LiveScreenSaverStoreCoordinator(storeURL: f.storeURL,
            journalURL: f.root.appendingPathComponent("shared.json"), saverURL: f.saverURL,
            stopWallpaperAgent: {}, startWallpaperAgent: {})
        try routes.activate(includeDesktop: true)
        var root = try f.load() as! [String: Any]
        var all = root["SystemDefault"] as! [String: Any]
        let explicit: [String: Any] = ["Content": ["Choices": [["Provider": WallpaperPlatformConstants.imageProviderID,
            "Files": ["new-user-photo"], "Configuration": Data([99])]]], "Appearance": ["mode": "light"]]
        all[changed] = explicit; root["SystemDefault"] = all
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: f.storeURL)
        try routes.restoreIfOwned()
        let restored = (try f.load()["SystemDefault"]) as! [String: Any]
        #expect(restored[changed] as? NSDictionary == explicit as NSDictionary)
        let other = changed == "Desktop" ? "Idle" : "Desktop"
        #expect(restored[other] as? NSDictionary == (f.original["SystemDefault"] as! [String: Any])[other] as? NSDictionary)
    }
}

@Test @MainActor func lockEffectsHealthRecordsTheSaverCursorAndParallaxAndStopsItsClock() throws {
    let f = try EffectsRouteFixture(); defer { f.cleanup() }
    let bridge = ScreenSaverEffectsBridge(content: NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600)), appSupportURL: f.root)
    let effects = try #require(bridge.view as? WallpaperEffectsView)
    effects.screenSaverPresentationIsVisible = { true }
    bridge.setPresenting(true, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    for index in 0..<120 {
        effects.renderFrame(deltaTime: 1.0/60, cursor: CGPoint(x: index < 60 ? -0.9 : 0.9, y: 0.2))
        bridge.setPresenting(true, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    }
    bridge.setPresenting(false, paused: false, surfaceID: nil, sequence: nil, imageURL: nil, gravity: AVLayerVideoGravity.resizeAspectFill.rawValue)
    let files = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("ScreenSaverEffects"), includingPropertiesForKeys: nil)
    let file = try #require(files.first)
    let record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(try #require(record["cursorMinX"] as? Double) < -0.7)
    #expect(try #require(record["cursorMaxX"] as? Double) > 0.7)
    let low = try #require(record["parallaxMinX"] as? Double)
    let high = try #require(record["parallaxMaxX"] as? Double)
    #expect(high - low > 10, "Cursor motion must move the rendered content, including its crop offset")
    let status = try #require(record["status"] as? [String: Any])
    #expect(status["surface"] as? String == "lockScreen")
    #expect(status["active"] as? Bool == false && status["framesPerSecond"] as? Double == 0)
}
