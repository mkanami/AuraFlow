import CryptoKit
import Foundation

/// Apple owns the protected surface. Supply a native movie containing the
/// shared FX instead of relying on a third-party saver at a manual lock edge.
public final class AerialEffectsLockScreenInstaller: ModernLockScreenInstalling {
    private enum Scope: String, Codable { case shared, desktop, lockOnly }
    private struct Source: Codable {
        var originalPath: String
        var originalSignature: String
        var renderedPath: String
        var effectsSignature: String
        var speed: Double
        var mode: WallpaperScaleMode
        var scope: Scope
    }
    private let native: ModernLockScreenInstalling
    private let legacy: ModernLockScreenInstalling
    private let root: URL
    private let media: NativeEffectsMediaPreparing
    private let mutations = AerialMutationCoordinator()
    private var sourceURL: URL { root.appendingPathComponent("native-effects-source.json") }
    private var source: Source? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        return try? JSONDecoder().decode(Source.self, from: data)
    }
    private var liveInstalled: Bool { LiveEffectsLockScreenInstaller.usesLiveRenderer(appSupportURL: root) }
    private var settings: WallpaperEffectsSettings { WallpaperEffectsStore(appSupportURL: root).load() }
    private var config: ControlConfig { WallpaperRuntimeStore(appSupportURL: root).loadConfig() }

    public convenience init(native: ModernLockScreenInstalling = AerialLockScreenInstaller(),
        appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL(),
        media: NativeEffectsMediaPreparing? = nil) {
        self.init(native: native, appSupportURL: appSupportURL, media: media,
            legacyInstaller: LiveEffectsLockScreenInstaller(native: native, appSupportURL: appSupportURL))
    }
    init(native: ModernLockScreenInstalling, appSupportURL: URL,
        media: NativeEffectsMediaPreparing?, legacyInstaller: ModernLockScreenInstalling) {
        self.native = native; root = appSupportURL
        legacy = legacyInstaller
        self.media = media ?? NativeEffectsMediaPreparer(directory: appSupportURL.appendingPathComponent("NativeEffectsCache"))
    }
    public var isAvailable: Bool { native.isAvailable }
    public var isInstalled: Bool { native.isInstalled || liveInstalled }
    public var installationConfirmed: Bool {
        // The native detailed status is intentionally dedicated-lock-only.
        // Shared Desktop+Idle installs have their own confirmation contract.
        !liveInstalled && native.installationConfirmed && sourceIsCurrent
    }
    public var requiresLockScreenSessionPromotion: Bool { native.requiresLockScreenSessionPromotion }

    public func install(videoURL: URL) async throws {
        try await apply(videoURL, speed: 1, mode: .fill, scope: .shared)
    }
    public func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        try await apply(videoURL, speed: playbackSpeed, mode: scaleMode, scope: .desktop)
    }
    public func installLockScreenOnly(videoURL: URL) async throws {
        try await installLockScreenOnly(videoURL: videoURL, playbackSpeed: 1, scaleMode: .fill)
    }
    public func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        try await apply(videoURL, speed: playbackSpeed, mode: scaleMode, scope: .lockOnly)
    }
    private func apply(_ url: URL, speed: Double, mode: WallpaperScaleMode, scope: Scope) async throws {
        try await mutations.withExclusiveAsync {
            try await self.applyLocked(url, speed: speed, mode: mode, scope: scope, shouldProceed: { true })
        }
    }
    private func applyLocked(_ url: URL, speed: Double, mode: WallpaperScaleMode, scope: Scope,
        shouldProceed: @escaping () -> Bool) async throws {
        let selected = settings
        let effects = selected.enabled && selected.hasVisibleEffects
        let signature = effectsSignature(selected, speed: speed, mode: mode)
        let rendered = try await media.prepare(source: url, settings: selected, speed: speed, scaleMode: mode,
            shouldProceed: { shouldProceed() && self.settings == selected })
        guard shouldProceed(), settings == selected else { throw CancellationError() }
        if liveInstalled {
            // This companion saved the exact user descriptors; drain it before
            // restoring the native Aerial route. No saver/lock is started here.
            try await legacy.uninstallLockScreenOnlyPreservingCurrentDesktopAsync()
        }
        guard shouldProceed() else { throw CancellationError() }
        // FX frames already include the selected rate and scaling. Retiming
        // that movie again would also speed up the rain and water simulation.
        let nativeSpeed = effects ? 1 : speed
        let nativeMode: WallpaperScaleMode = effects ? .fill : mode
        switch scope {
        case .shared: try await native.install(videoURL: rendered)
        case .desktop: try await native.installForDesktopAgent(videoURL: rendered, playbackSpeed: nativeSpeed, scaleMode: nativeMode)
        case .lockOnly: try await native.installLockScreenOnly(videoURL: rendered, playbackSpeed: nativeSpeed, scaleMode: nativeMode)
        }
        let next = Source(originalPath: url.standardizedFileURL.path, originalSignature: fileSignature(url),
            renderedPath: rendered.path, effectsSignature: signature, speed: speed, mode: mode, scope: scope)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: sourceURL, options: .atomic)
    }
    public func prepareLockScreenMedia(videoURL: URL) async throws {
        try await prepareLockScreenMedia(videoURL: videoURL, playbackSpeed: 1, scaleMode: .fill)
    }
    public func prepareLockScreenMedia(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        let selected = settings
        let movie = try await media.prepare(source: videoURL, settings: selected, speed: playbackSpeed,
            scaleMode: scaleMode, shouldProceed: { self.settings == selected })
        let effected = selected.enabled && selected.hasVisibleEffects
        try await native.prepareLockScreenMedia(videoURL: movie, playbackSpeed: effected ? 1 : playbackSpeed,
            scaleMode: effected ? .fill : scaleMode)
    }
    private func mapped(_ url: URL?) -> URL? {
        guard let source else { return url }
        if url == nil || url?.standardizedFileURL.path == source.originalPath { return URL(fileURLWithPath: source.renderedPath) }
        return url
    }
    private var sourceIsCurrent: Bool {
        guard let source else { return !settings.enabled || !settings.hasVisibleEffects }
        let config = config
        let mode = WallpaperScaleMode(rawValue: config.scale_mode ?? "") ?? .fill
        return fileSignature(URL(fileURLWithPath: source.originalPath)) == source.originalSignature
            && source.effectsSignature == effectsSignature(settings, speed: config.playback_speed, mode: mode)
            && FileManager.default.isReadableFile(atPath: source.renderedPath)
    }
    public func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus {
        if liveInstalled { return .init(installed: true, providerAvailable: native.isAvailable) }
        var status = native.lockScreenOnlyStatus(videoURL: mapped(videoURL))
        if !sourceIsCurrent { status.sourceMatches = false }
        return status
    }
    private func needsUpdate(_ url: URL) -> Bool {
        guard let source else { return true }
        let config = config, mode = WallpaperScaleMode(rawValue: config.scale_mode ?? "") ?? .fill
        return liveInstalled || source.originalPath != url.standardizedFileURL.path
            || source.originalSignature != fileSignature(url)
            || source.effectsSignature != effectsSignature(settings, speed: config.playback_speed, mode: mode)
            || !FileManager.default.isReadableFile(atPath: source.renderedPath)
    }
    public func repair(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        try await mutations.withExclusiveAsync {
            guard shouldProceed(), self.isInstalled else { return false }
            if self.needsUpdate(videoURL) {
                let config = self.config
                let mode = WallpaperScaleMode(rawValue: config.scale_mode ?? "") ?? .fill
                let scope = self.source?.scope ?? (WallpaperRuntimeStore(appSupportURL: self.root).loadLockScreenOnlySource() == nil ? .desktop : .lockOnly)
                try await self.applyLocked(videoURL, speed: config.playback_speed, mode: mode, scope: scope, shouldProceed: shouldProceed)
                return true
            }
            return try await self.native.repair(videoURL: self.mapped(videoURL) ?? videoURL, shouldProceed: shouldProceed)
        }
    }
    public func repairLockScreenOnlyGeneration(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        try await repair(videoURL: videoURL, shouldProceed: shouldProceed)
    }
    public func rearmForNextLock(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        _ = try await repair(videoURL: videoURL, shouldProceed: shouldProceed)
        guard shouldProceed() else { return false }
        return try await native.rearmForNextLock(videoURL: mapped(videoURL) ?? videoURL, shouldProceed: shouldProceed)
    }
    public func activateLockScreenForCurrentSession() throws -> Bool { try native.activateLockScreenForCurrentSession() }
    public func restoreDesktopAfterLockScreenSession() throws -> Bool { try native.restoreDesktopAfterLockScreenSession() }
    public func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool { try await native.restoreDesktopAfterLockScreenSessionAsync() }
    public func applyCurrentDesktopFallback() -> Bool { native.applyCurrentDesktopFallback() }
    public func pauseLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool {
        try await native.pauseLockScreenOnlyPlayback(videoURL: mapped(videoURL) ?? videoURL)
    }
    public func resumeLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool {
        try await native.resumeLockScreenOnlyPlayback(videoURL: mapped(videoURL) ?? videoURL)
    }
    public func updatePlaybackSpeed(videoURL: URL, speed: Double) async throws -> Bool {
        let mode = source?.mode ?? .fill
        try await apply(videoURL, speed: speed, mode: mode, scope: source?.scope ?? .desktop)
        return true
    }
    public func updateScaleMode(videoURL: URL, mode: WallpaperScaleMode) async throws -> Bool {
        try await apply(videoURL, speed: source?.speed ?? config.playback_speed, mode: mode, scope: source?.scope ?? .desktop)
        return true
    }
    public func uninstall() throws {
        try mutations.withExclusive {
            if liveInstalled { try legacy.uninstall() }
            else { try native.uninstall() }
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }
    public func uninstallAsync() async throws {
        try await mutations.withExclusiveAsync {
            if self.liveInstalled { try await self.legacy.uninstallAsync() }
            else { try await self.native.uninstallAsync() }
            try? FileManager.default.removeItem(at: self.sourceURL)
        }
    }
    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try mutations.withExclusive {
            if liveInstalled { try legacy.uninstallLockScreenOnlyPreservingCurrentDesktop() }
            else { try native.uninstallLockScreenOnlyPreservingCurrentDesktop() }
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }
    public func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws {
        try await mutations.withExclusiveAsync {
            if self.liveInstalled { try await self.legacy.uninstallLockScreenOnlyPreservingCurrentDesktopAsync() }
            else { try await self.native.uninstallLockScreenOnlyPreservingCurrentDesktopAsync() }
            try? FileManager.default.removeItem(at: self.sourceURL)
        }
    }
    private func effectsSignature(_ settings: WallpaperEffectsSettings, speed: Double, mode: WallpaperScaleMode) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(settings.normalized())) ?? Data()
        data.append(Data("\(speed):\(mode.rawValue):renderer-v\(WallpaperEffectsRenderRevision.current)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func fileSignature(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.standardizedFileURL.path):\(attributes?[.size] ?? 0):\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
}
