import Foundation
import CryptoKit
import Testing
@testable import AuraWallpaperCore

private final class RenderedNativeRecorder: ModernLockScreenInstalling {
    var isAvailable = true
    var isInstalled = false
    var calls: [(String, URL, Double, WallpaperScaleMode)] = []
    var installed: URL?
    var lockOnly = false
    var shouldPromote = false
    var requiresLockScreenSessionPromotion: Bool { shouldPromote }
    func install(videoURL: URL) async throws { record("shared", videoURL, 1, .fill) }
    func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        record("desktop", videoURL, playbackSpeed, scaleMode)
    }
    func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        record("lockOnly", videoURL, playbackSpeed, scaleMode)
    }
    func record(_ name: String, _ url: URL, _ rate: Double, _ mode: WallpaperScaleMode) {
        calls.append((name, url, rate, mode)); installed = url; isInstalled = true
        lockOnly = name == "lockOnly"
    }
    func prepareLockScreenMedia(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        calls.append(("prepare", videoURL, playbackSpeed, scaleMode))
    }
    func pauseLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool { calls.append(("pause", videoURL, 1, .fill)); return true }
    func resumeLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool { calls.append(("resume", videoURL, 1, .fill)); return true }
    func repair(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool { calls.append(("repair", videoURL, 1, .fill)); return false }
    func rearmForNextLock(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool { calls.append(("rearm", videoURL, 1, .fill)); return shouldProceed() }
    func activateLockScreenForCurrentSession() throws -> Bool { calls.append(("activate", installed!, 1, .fill)); return true }
    func restoreDesktopAfterLockScreenSession() throws -> Bool { calls.append(("restore", installed!, 1, .fill)); return true }
    func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus {
        guard lockOnly else { return .init() }
        return .init(installed: isInstalled, sourceMatches: videoURL == nil || videoURL == installed,
            assetValid: isInstalled, providerAvailable: true, providerRunning: true,
            wallpaperStoreValid: isInstalled, screenSaverSelected: isInstalled, assetID: "native-fixture")
    }
    func uninstall() throws { calls.append(("uninstall", installed!, 1, .fill)); installed = nil; isInstalled = false }
}

private final class PreparedEffectsRecorder: NativeEffectsMediaPreparing {
    let output: URL
    var fail = false
    var beforeReturn: (() throws -> Void)?
    init(_ output: URL) { self.output = output }
    func prepare(source: URL, settings: WallpaperEffectsSettings, speed: Double,
        scaleMode: WallpaperScaleMode, shouldProceed: @escaping @Sendable () -> Bool) async throws -> URL {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try beforeReturn?()
        guard shouldProceed() else { throw CancellationError() }
        return settings.enabled && settings.hasVisibleEffects ? output : source
    }
}

private final class NativeEffectsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNativeInstaller-\(UUID())")
    var original: URL { root.appendingPathComponent("original.mp4") }
    var rendered: URL { root.appendingPathComponent("rendered.mov") }
    let native = RenderedNativeRecorder()
    let media: PreparedEffectsRecorder
    let store: WallpaperRuntimeStore
    init() throws {
        media = PreparedEffectsRecorder(root.appendingPathComponent("rendered.mov"))
        store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original); try Data("rendered".utf8).write(to: rendered)
        try WallpaperEffectsStore(appSupportURL: root).save(WallpaperEffectsPreset.cinematic.settings)
        try store.saveConfig(.init(video_path: original.path, playback_speed: 1.5, show_on_lock_screen: true, scale_mode: "fit"))
    }
    func installer() -> AerialEffectsLockScreenInstaller { .init(native: native, appSupportURL: root, media: media) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func nativeEffectsRebuildsThePreviousRigidDropRendererWithoutChangingItsScope() async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installLockScreenOnly(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    let record = f.root.appendingPathComponent("native-effects-source.json")
    var mapping = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var legacy = try encoder.encode(WallpaperEffectsPreset.cinematic.settings.normalized())
    legacy.append(Data("1.5:fit".utf8))
    mapping["effectsSignature"] = SHA256.hash(data: legacy).map { String(format: "%02x", $0) }.joined()
    try JSONSerialization.data(withJSONObject: mapping).write(to: record, options: .atomic)
    #expect(!installer.lockScreenOnlyStatus(videoURL: f.original).sourceMatches)
    let config = f.store.loadConfig(), original = try Data(contentsOf: f.original)
    #expect(try await installer.repair(videoURL: f.original, shouldProceed: { true }))
    #expect(f.native.calls.last?.0 == "lockOnly" && f.native.calls.last?.1 == f.rendered)
    #expect(installer.lockScreenOnlyStatus(videoURL: f.original).sourceMatches)
    #expect(f.store.loadConfig() == config)
    #expect(try Data(contentsOf: f.original) == original)
}

@Test(arguments: ["shared", "desktop", "lockOnly"], [false, true])
func nativeEffectsInstallPreservesScopeAndOriginalDesktopPreferences(scope: String, enabled: Bool) async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    if !enabled { try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsSettings()) }
    if scope == "shared" {
        var config = f.store.loadConfig(); config.playback_speed = 1; config.scale_mode = "fill"
        try f.store.saveConfig(config)
    }
    let config = f.store.loadConfig(), installer = f.installer()
    switch scope {
    case "shared": try await installer.install(videoURL: f.original)
    case "desktop": try await installer.installForDesktopAgent(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    default: try await installer.installLockScreenOnly(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    }
    let call = try #require(f.native.calls.last)
    #expect(call.0 == scope && call.1 == (enabled ? f.rendered : f.original))
    #expect(call.2 == (enabled || scope == "shared" ? 1 : 1.5))
    #expect(call.3 == (enabled || scope == "shared" ? .fill : .fit))
    #expect(f.store.loadConfig() == config)
    #expect(try Data(contentsOf: f.original) == Data("original".utf8))
    _ = try await installer.pauseLockScreenOnlyPlayback(videoURL: f.original)
    _ = try await installer.resumeLockScreenOnlyPlayback(videoURL: f.original)
    #expect(f.native.calls.suffix(2).allSatisfy { $0.1 == call.1 })
    #expect(installer.installationConfirmed)
    #expect(installer.lockScreenOnlyStatus(videoURL: f.original).isReady == (scope == "lockOnly"))
}

@Test func nativeEffectsPreviewPreparationCannotReplaceTheInstalledSource() async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.prepareLockScreenMedia(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    #expect(!installer.isInstalled && f.native.calls.map(\.0) == ["prepare"])
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-effects-source.json").path))
    #expect(f.native.calls.last?.1 == f.rendered && f.native.calls.last?.2 == 1)
}

@Test func nativeEffectsFailedOrStaleRenderKeepsTheExistingNativeGeneration() async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installForDesktopAgent(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    let mapping = try Data(contentsOf: f.root.appendingPathComponent("native-effects-source.json"))
    f.media.fail = true
    do { try await installer.installLockScreenOnly(videoURL: f.original); Issue.record("Expected rendering failure") }
    catch { #expect((error as NSError).code == CocoaError.fileWriteOutOfSpace.rawValue) }
    f.media.fail = false
    f.media.beforeReturn = { try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsPreset.dreamy.settings) }
    do { try await installer.installLockScreenOnly(videoURL: f.original); Issue.record("Expected stale render cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(f.native.calls.count == 1 && f.native.installed == f.rendered)
    #expect(try Data(contentsOf: f.root.appendingPathComponent("native-effects-source.json")) == mapping)
    #expect(!installer.lockScreenOnlyStatus(videoURL: f.original).sourceMatches)
    #expect(!installer.installationConfirmed)
}

@Test(arguments: [false, true]) func nativeEffectsManualAndAutomaticTransitionsUseOnePreparedSource(automatic: Bool) async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installForDesktopAgent(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    // The native shared route is selected before either kind of transition.
    #expect(!installer.requiresLockScreenSessionPromotion)
    if automatic { _ = try await installer.rearmForNextLock(videoURL: f.original, shouldProceed: { true }) }
    #expect(try installer.activateLockScreenForCurrentSession())
    #expect(try installer.restoreDesktopAfterLockScreenSession())
    #expect(f.native.calls.allSatisfy { $0.1 == f.rendered })
    #expect(f.native.calls.filter { ["shared", "desktop", "lockOnly"].contains($0.0) }.count == 1)
    #expect(installer.installationConfirmed)
}

@Test(arguments: [false, true])
func nativeEffectsLostSessionApprovalCannotApplyACompletedMovie(automatic: Bool) async throws {
    let f = try NativeEffectsFixture(); defer { f.cleanup() }
    let installer = f.installer()
    try await installer.installForDesktopAgent(videoURL: f.original, playbackSpeed: 1.5, scaleMode: .fit)
    let record = f.root.appendingPathComponent("native-effects-source.json")
    let before = try Data(contentsOf: record)
    try WallpaperEffectsStore(appSupportURL: f.root).save(WallpaperEffectsPreset.dreamy.settings)
    var approved = true
    f.media.beforeReturn = { approved = false }
    do {
        if automatic { _ = try await installer.rearmForNextLock(videoURL: f.original, shouldProceed: { approved }) }
        else { _ = try await installer.repair(videoURL: f.original, shouldProceed: { approved }) }
        Issue.record("A completed movie must not be applied after session approval is lost")
    } catch { #expect(error is CancellationError) }
    #expect(f.native.calls.count == 1 && f.native.installed == f.rendered)
    #expect(try Data(contentsOf: record) == before)
}
