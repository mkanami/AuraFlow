import AppKit
import CryptoKit
import Foundation

/// Aerial cannot composite client effects. Effects-enabled installations use
/// the signed Aura ScreenSaver provider instead, retaining the same native
/// secure presentation assertions and the existing session lifecycle.
public final class LiveEffectsLockScreenInstaller: ModernLockScreenInstalling {
    private struct Installation: Codable {
        var path: String
        var signature: String
        var generation: UInt64
        var desktopIncluded: Bool?
    }
    private let native: ModernLockScreenInstalling
    private let root: URL
    private let saverURL: URL
    private let routes: LiveScreenSaverStoreCoordinator
    private let recovery: ScreenSaverRouteRecovery
    private let sessionIsLocked: () -> Bool?
    private let mutations = AerialMutationCoordinator()
    // The OS keeps a separate cached provider for loginwindow. A restored
    // Desktop starts a new session even when the Idle descriptor is unchanged.
    private var lockOnlyProviderPreparedForSession = false
    private var markerURL: URL { root.appendingPathComponent("live-lock-screen-effects.json") }
    private var installation: Installation? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(Installation.self, from: data)
    }
    private var rendererAvailable: Bool {
        FileManager.default.fileExists(atPath: saverURL.appendingPathComponent("Contents/Frameworks/libAuraWallpaperEffects.dylib").path)
    }
    private var usesLiveEffects: Bool { installation != nil }
    public static func usesLiveRenderer(appSupportURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: appSupportURL.appendingPathComponent("live-lock-screen-effects.json")) else { return false }
        return (try? JSONDecoder().decode(Installation.self, from: data)) != nil
    }
    private var wantsLiveEffects: Bool {
        let settings = WallpaperEffectsStore(appSupportURL: root).load()
        return rendererAvailable && settings.enabled && settings.hasVisibleEffects
    }

    public init(native: ModernLockScreenInstalling = AerialEffectsLockScreenInstaller(),
                appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL(),
                saverURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/AuraFlowLockScreen.saver"),
                storeURL: URL = WallpaperPlatformConstants.wallpaperStoreURL(homeURL: FileManager.default.homeDirectoryForCurrentUser),
                stopWallpaperAgent: (() throws -> Void)? = nil, startWallpaperAgent: (() throws -> Void)? = nil,
                sessionIsLocked: @escaping () -> Bool? = { LockScreenSession.currentIsLocked() }) {
        self.native = native; root = appSupportURL; self.saverURL = saverURL
        self.sessionIsLocked = sessionIsLocked
        let journal = appSupportURL.appendingPathComponent("live-lock-screen-route.json")
        recovery = ScreenSaverRouteRecovery(storeURL: storeURL, journalURL: journal, saverURL: saverURL)
        if let stopWallpaperAgent, let startWallpaperAgent {
            routes = LiveScreenSaverStoreCoordinator(storeURL: storeURL, journalURL: journal, saverURL: saverURL,
                stopWallpaperAgent: stopWallpaperAgent, startWallpaperAgent: startWallpaperAgent)
        } else {
            routes = LiveScreenSaverStoreCoordinator(storeURL: storeURL, journalURL: journal, saverURL: saverURL)
        }
    }

    public var isAvailable: Bool { native.isAvailable || rendererAvailable }
    public var isInstalled: Bool { usesLiveEffects || native.isInstalled }
    public var installationConfirmed: Bool { usesLiveEffects ? lockScreenOnlyStatus(videoURL: nil).isReady : native.installationConfirmed }
    public var requiresLockScreenSessionPromotion: Bool {
        usesLiveEffects ? installation?.desktopIncluded != true : native.requiresLockScreenSessionPromotion
    }

    public func install(videoURL: URL) async throws {
        try await mutations.withExclusiveAsync {
            if self.wantsLiveEffects || self.usesLiveEffects { try await self.installLive(videoURL: videoURL) }
            else { try await self.native.install(videoURL: videoURL) }
        }
    }
    public func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        try await mutations.withExclusiveAsync {
            if self.wantsLiveEffects || self.usesLiveEffects { try await self.installLive(videoURL: videoURL) }
            else { try await self.native.installForDesktopAgent(videoURL: videoURL, playbackSpeed: playbackSpeed, scaleMode: scaleMode) }
        }
    }
    public func installLockScreenOnly(videoURL: URL) async throws {
        try await installLockScreenOnly(videoURL: videoURL, playbackSpeed: 1, scaleMode: .fill)
    }
    public func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        try await mutations.withExclusiveAsync {
            if self.wantsLiveEffects || self.usesLiveEffects {
                // The saver consumes the original source and renders effects
                // live. Baking a movie here delays Lock for every new source
                // or effects adjustment, even though this renderer is ready.
                try await self.installLive(videoURL: videoURL, includeDesktop: false)
            } else {
                try await self.native.installLockScreenOnly(videoURL: videoURL, playbackSpeed: playbackSpeed, scaleMode: scaleMode)
            }
        }
    }
    private func installLive(videoURL: URL, includeDesktop: Bool = true) async throws {
        guard rendererAvailable, FileManager.default.isReadableFile(atPath: videoURL.path) else { throw CocoaError(.fileReadNoSuchFile) }
        // Remove the Aerial assertion/route first, using its descriptor-preserving
        // transaction. The custom route journals the restored user choices.
        if native.isInstalled { try await native.uninstallLockScreenOnlyPreservingCurrentDesktopAsync() }
        if !includeDesktop, installation?.desktopIncluded == true {
            // Switching an existing shared route to Lock-only must first
            // recover the exact Desktop descriptor saved by that route.
            try routes.restoreIfOwned()
        }
        // Reject an unsafe replacement before overwriting the working marker.
        // The coordinator revalidates again after the system's final flush.
        try routes.validateActivation(includeDesktop: includeDesktop)
        let generation = (installation?.generation ?? 0) &+ 1
        let next = Installation(path: videoURL.standardizedFileURL.path, signature: signature(videoURL), generation: generation,
            desktopIncluded: includeDesktop)
        lockOnlyProviderPreparedForSession = false
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: markerURL, options: .atomic)
        // Shared playback binds both routes up front. Lock-only selects Idle;
        // its existing secure-session handoff temporarily promotes Desktop
        // only after a confirmed lock and restores it after unlock.
        do { try routes.activate(includeDesktop: includeDesktop) }
        catch {
            try? routes.restoreIfOwned()
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
    }
    public func prepareLockScreenMedia(videoURL: URL) async throws {
        try await prepareLockScreenMedia(videoURL: videoURL, playbackSpeed: 1, scaleMode: .fill)
    }
    public func prepareLockScreenMedia(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) async throws {
        if !wantsLiveEffects && !usesLiveEffects {
            try await native.prepareLockScreenMedia(videoURL: videoURL, playbackSpeed: playbackSpeed, scaleMode: scaleMode)
        }
    }
    public func lockScreenOnlyStatus(videoURL: URL?) -> LockScreenOnlyGenerationStatus {
        guard let installation else { return native.lockScreenOnlyStatus(videoURL: videoURL) }
        let url = URL(fileURLWithPath: installation.path)
        let matches = videoURL.map { $0.standardizedFileURL == url } ?? true
        let selected = installation.desktopIncluded == true ? routes.isSharedSelected : routes.isSelected
        return LockScreenOnlyGenerationStatus(installed: true, sourceMatches: matches,
            assetValid: FileManager.default.isReadableFile(atPath: url.path) && signature(url) == installation.signature,
            providerAvailable: rendererAvailable,
            providerRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.wallpaper.agent").isEmpty,
            wallpaperStoreValid: selected, screenSaverSelected: selected,
            sourceSignature: installation.signature, generation: installation.generation, assetID: "AuraFlowLiveEffects")
    }
    public func repairLockScreenOnlyGeneration(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        try await repair(videoURL: videoURL, shouldProceed: shouldProceed)
    }
    public func repair(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        try await mutations.withExclusiveAsync {
            guard shouldProceed() else { return false }
            if !self.usesLiveEffects && self.wantsLiveEffects && self.native.isInstalled,
               !self.native.requiresLockScreenSessionPromotion {
                try await self.installLive(videoURL: videoURL)
                return true
            }
            if self.usesLiveEffects {
                // Only old markers lacked a scope. An explicit Lock-only
                // installation must never become shared during repair, even
                // if runtime source metadata is delayed or unavailable.
                if self.installation?.desktopIncluded == nil,
                   WallpaperRuntimeStore(appSupportURL: self.root).loadLockScreenOnlySource() == nil {
                    try await self.installLive(videoURL: videoURL)
                    return true
                }
                var changed = false
                if var installed = self.installation, installed.path == videoURL.standardizedFileURL.path,
                   installed.signature != self.signature(videoURL), shouldProceed() {
                    installed.signature = self.signature(videoURL)
                    installed.generation &+= 1
                    try JSONEncoder().encode(installed).write(to: self.markerURL, options: .atomic)
                    changed = true
                }
                return try self.recovery.recoverIfNeeded(shouldProceed: shouldProceed) || changed
            }
            return try await self.native.repair(videoURL: videoURL, shouldProceed: shouldProceed)
        }
    }
    public func rearmForNextLock(videoURL: URL, shouldProceed: @escaping () -> Bool) async throws -> Bool {
        if usesLiveEffects || (wantsLiveEffects && !native.requiresLockScreenSessionPromotion) {
            _ = try await repair(videoURL: videoURL, shouldProceed: shouldProceed)
            // Ready is not the same as changed. The agent must bind a fresh
            // presentation and acknowledge the current command even when the
            // selected live route already needs no filesystem repair.
            return shouldProceed() && lockScreenOnlyStatus(videoURL: videoURL).isReady
        }
        return try await native.rearmForNextLock(videoURL: videoURL, shouldProceed: shouldProceed)
    }
    public func activateLockScreenForCurrentSession() throws -> Bool {
        if usesLiveEffects {
            guard installation?.desktopIncluded != true else { return false }
            return try mutations.withExclusive {
                guard self.sessionIsLocked() == true, self.usesLiveEffects else { return false }
                let changed = try recovery.activateDesktopForLockSession {
                    self.sessionIsLocked() == true && self.usesLiveEffects
                }
                guard changed || !self.lockOnlyProviderPreparedForSession else { return false }
                try self.routes.refreshProviderForLockSession {
                    self.sessionIsLocked() == true && self.usesLiveEffects
                }
                self.lockOnlyProviderPreparedForSession = self.sessionIsLocked() == true && self.usesLiveEffects
                return true
            }
        }
        return try native.activateLockScreenForCurrentSession()
    }
    public func restoreDesktopAfterLockScreenSession() throws -> Bool {
        if usesLiveEffects {
            guard installation?.desktopIncluded != true else { return false }
            return try mutations.withExclusive {
                let restored = try recovery.restoreDesktopAfterLockSession()
                if restored { lockOnlyProviderPreparedForSession = false }
                return restored
            }
        }
        return try native.restoreDesktopAfterLockScreenSession()
    }
    public func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool {
        if usesLiveEffects {
            guard installation?.desktopIncluded != true else { return false }
            return try await mutations.withExclusiveAsync {
                let restored = try self.recovery.restoreDesktopAfterLockSession()
                if restored { self.lockOnlyProviderPreparedForSession = false }
                return restored
            }
        }
        return try await native.restoreDesktopAfterLockScreenSessionAsync()
    }
    public func pauseLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool {
        usesLiveEffects ? false : try await native.pauseLockScreenOnlyPlayback(videoURL: videoURL)
    }
    public func resumeLockScreenOnlyPlayback(videoURL: URL) async throws -> Bool {
        usesLiveEffects ? false : try await native.resumeLockScreenOnlyPlayback(videoURL: videoURL)
    }
    public func updatePlaybackSpeed(videoURL: URL, speed: Double) async throws -> Bool {
        usesLiveEffects ? true : try await native.updatePlaybackSpeed(videoURL: videoURL, speed: speed)
    }
    public func updateScaleMode(videoURL: URL, mode: WallpaperScaleMode) async throws -> Bool {
        usesLiveEffects ? true : try await native.updateScaleMode(videoURL: videoURL, mode: mode)
    }
    public func uninstall() throws {
        try mutations.withExclusive {
            if usesLiveEffects {
                try routes.restoreIfOwned()
                try FileManager.default.removeItem(at: markerURL)
            }
            if native.isInstalled { try native.uninstall() }
        }
    }
    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws { try uninstall() }
    public func uninstallAsync() async throws {
        try await mutations.withExclusiveAsync {
            if self.usesLiveEffects {
                try self.routes.restoreIfOwned()
                try FileManager.default.removeItem(at: self.markerURL)
            }
            if self.native.isInstalled { try await self.native.uninstallAsync() }
        }
    }
    public func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws { try await uninstallAsync() }
    private func signature(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let text = "\(url.standardizedFileURL.path):\(attributes?[.size] ?? "missing"):\(modified)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
