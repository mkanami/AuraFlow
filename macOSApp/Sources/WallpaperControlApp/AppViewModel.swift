import AppKit
@_exported import AuraWallpaperCore
import AVKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum AdaptiveTextTone: Equatable {
    case dark
    case light
}

struct AdaptiveGlassAppearance: Equatable {
    var topGlassAlpha: CGFloat
    var bottomGlassAlpha: CGFloat
    var topProtectionOverlayOpacity: CGFloat
    var bottomProtectionOverlayOpacity: CGFloat
    var bottomButtonProtectionOpacity: CGFloat
    var bottomButtonHighlightOpacity: CGFloat
    var topTextTone: AdaptiveTextTone
    var bottomTextTone: AdaptiveTextTone
    var centerTextTone: AdaptiveTextTone

    static let `default` = AdaptiveGlassAppearance(
        topGlassAlpha: 1.0,
        bottomGlassAlpha: 1.0,
        topProtectionOverlayOpacity: 0.0,
        bottomProtectionOverlayOpacity: 0.0,
        bottomButtonProtectionOpacity: 0.0,
        bottomButtonHighlightOpacity: 0.055,
        topTextTone: .light,
        bottomTextTone: .light,
        centerTextTone: .light
    )
}

struct CatalogVideoSource: Hashable, Codable {
    let url: URL
    let width: Int
    let height: Int
}

struct CatalogWallpaper: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let category: String
    let attribution: String
    let previewImageURL: URL?
    let sourcePageURL: URL?
    let sources: [CatalogVideoSource]

    static let defaultCatalog: [CatalogWallpaper] = []
}

enum CatalogWallpaperGroup: String, CaseIterable, Identifiable {
    case anime
    case animeNature
    case scenic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime:
            return "Anime"
        case .animeNature:
            return "Anime Nature"
        case .scenic:
            return "Scenic"
        }
    }

    var systemImage: String {
        switch self {
        case .anime:
            return "sparkles"
        case .animeNature:
            return "mountain.2"
        case .scenic:
            return "leaf"
        }
    }
}

extension CatalogWallpaper {
    var catalogGroup: CatalogWallpaperGroup {
        if category.localizedCaseInsensitiveCompare("Anime Nature") == .orderedSame ||
            attribution.localizedCaseInsensitiveCompare("MotionBGS") == .orderedSame ||
            sourcePageURL?.host?.localizedCaseInsensitiveContains("motionbgs.com") == true {
            return .animeNature
        }
        if category.localizedCaseInsensitiveCompare("Anime") == .orderedSame ||
            attribution.localizedCaseInsensitiveCompare("MoeWalls") == .orderedSame ||
            sourcePageURL?.host?.localizedCaseInsensitiveContains("moewalls.com") == true {
            return .anime
        }
        return .scenic
    }
}

struct DownloadedCatalogWallpaper: Identifiable, Hashable, Codable {
    let id: String
    let wallpaperID: String
    let title: String
    let category: String
    let attribution: String
    let previewImageURL: URL?
    let localPreviewPath: String?
    let sourcePageURL: URL?
    let localPath: String
    let downloadedAt: Date

    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    var localPreviewURL: URL? {
        guard let localPreviewPath, !localPreviewPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPreviewPath)
    }

    var effectivePreviewURL: URL? {
        localPreviewURL ?? previewImageURL
    }
}

enum CatalogDownloadError: LocalizedError {
    case badStatus(url: URL, statusCode: Int)
    case htmlResponse(url: URL)
    case unsupportedResponse(url: URL)

    var errorDescription: String? {
        switch self {
        case .badStatus(let url, let statusCode):
            let host = url.host ?? "server"
            switch statusCode {
            case 401, 403:
                return "\(host) blocked the download request (\(statusCode))."
            case 404:
                return "The wallpaper file is no longer available on \(host)."
            case 429:
                return "\(host) is rate-limiting download requests (\(statusCode))."
            case 500...599:
                return "\(host) returned a server error (\(statusCode))."
            default:
                return "\(host) returned HTTP \(statusCode)."
            }
        case .htmlResponse(let url):
            let host = url.host ?? "server"
            return "\(host) returned an HTML page instead of a wallpaper file."
        case .unsupportedResponse(let url):
            let host = url.host ?? "server"
            return "\(host) returned an unsupported response instead of a wallpaper file."
        }
    }
}

func catalogOriginHeaderValue(for url: URL) -> String? {
    guard let scheme = url.scheme,
          let host = url.host else {
        return nil
    }

    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.string
}

protocol WallpaperControlling {
    func status() throws -> ControlStatus
    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus
    func resume() throws -> ControlStatus
    func stop() throws -> ControlStatus
    func clearWallpaper() throws -> ControlStatus
    func setVideo(_ url: URL) throws -> ControlStatus
    func installLockScreenOnly(videoURL: URL) throws -> ControlStatus
    func setSpeed(_ speed: Double) throws -> ControlStatus
    func setInterpolation(_ enabled: Bool) throws -> ControlStatus
    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus
    func setShowOnLockScreen(_ enabled: Bool) throws -> ControlStatus
    func syncLockScreenSaver() throws
    func beginLockScreenPreview() throws -> ControlStatus
    func endLockScreenPreview() throws -> ControlStatus
    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus
    func setAutostart(_ enabled: Bool) throws -> ControlStatus
    func metrics() throws -> DaemonMetrics
}

extension WallpaperControlling {
    func installLockScreenOnly(videoURL: URL) throws -> ControlStatus {
        throw NativeWallpaperControllerError.unavailable(
            "Lock Screen-only wallpaper is unavailable."
        )
    }
}

enum NativeWallpaperControllerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

final class NativeWallpaperController: WallpaperControlling {
    private struct RuntimeHelperResolution {
        let url: URL
        let didUpdateInstalledCopy: Bool
    }

    private let store: WallpaperRuntimeStore
    private let helperURL: URL
    private let lockScreenSaverInstaller: LockScreenSaverInstalling

    init(
        store: WallpaperRuntimeStore = WallpaperRuntimeStore(),
        helperURL: URL? = nil,
        lockScreenSaverInstaller: LockScreenSaverInstalling? = nil
    ) throws {
        self.store = store
        let helperResolution: RuntimeHelperResolution
        if let helperURL {
            helperResolution = RuntimeHelperResolution(
                url: helperURL,
                didUpdateInstalledCopy: false
            )
        } else {
            helperResolution = try Self.resolveHelperURL()
        }
        self.helperURL = helperResolution.url
        self.lockScreenSaverInstaller =
            lockScreenSaverInstaller ?? LockScreenWallpaperInstaller()
        if helperResolution.didUpdateInstalledCopy {
            try restartRunningAgentAfterHelperUpdate()
        }
        recoverInterruptedWallpaperRemovalIfNeeded()
    }

    private static func resolveHelperURL() throws -> RuntimeHelperResolution {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["AURAFLOW_AGENT_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return RuntimeHelperResolution(
                url: URL(fileURLWithPath: override),
                didUpdateInstalledCopy: false
            )
        }

        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AuraWallpaperAgent"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AuraWallpaperAgent")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return try installRuntimeHelper(from: candidate)
        }

        throw NativeWallpaperControllerError.unavailable("Native wallpaper agent is not bundled with AuraFlow.")
    }

    private static func installRuntimeHelper(
        from bundledHelperURL: URL
    ) throws -> RuntimeHelperResolution {
        let fileManager = FileManager.default
        let runtimeDirectory = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("Runtime", isDirectory: true)
        let helperURL = runtimeDirectory.appendingPathComponent("AuraWallpaperAgent")
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let shouldCopy: Bool
        if fileManager.fileExists(atPath: helperURL.path) {
            let bundledAttributes = try fileManager.attributesOfItem(atPath: bundledHelperURL.path)
            let installedAttributes = try fileManager.attributesOfItem(atPath: helperURL.path)
            shouldCopy = bundledAttributes[.size] as? NSNumber != installedAttributes[.size] as? NSNumber ||
                bundledAttributes[.modificationDate] as? Date != installedAttributes[.modificationDate] as? Date
        } else {
            shouldCopy = true
        }

        if shouldCopy {
            let temporaryURL = runtimeDirectory.appendingPathComponent(".AuraWallpaperAgent.\(UUID().uuidString).tmp")
            try? fileManager.removeItem(at: temporaryURL)
            try fileManager.copyItem(at: bundledHelperURL, to: temporaryURL)
            _ = try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: helperURL.path) {
                _ = try fileManager.replaceItemAt(helperURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: helperURL)
            }
        }

        return RuntimeHelperResolution(
            url: helperURL,
            didUpdateInstalledCopy: shouldCopy
        )
    }

    private func restartRunningAgentAfterHelperUpdate() throws {
        guard store.processIsAlive(pid: store.loadPID()) else { return }
        let config = store.loadConfig()
        let lockScreenOnlyAgent = store.isLockScreenOnlyAgent()
        guard store.terminateDaemon(timeout: 1.0) else {
            throw NativeWallpaperControllerError.unavailable(
                "The previous wallpaper agent did not stop during the update."
            )
        }
        guard lockScreenOnlyAgent
            ? store.effectiveLockScreenSourceURL(for: config) != nil
            : !config.video_path.isEmpty
                && FileManager.default.fileExists(atPath: config.video_path)
        else {
            return
        }
        try launchAgentIfNeeded(lockScreenOnly: lockScreenOnlyAgent)
        try send(.reload, config: config)
    }

    private func recoverInterruptedWallpaperRemovalIfNeeded() {
        guard store.appSupportURL.standardizedFileURL
            == WallpaperRuntimeStore.defaultAppSupportURL()
                .standardizedFileURL
        else {
            return
        }
        let config = store.loadConfig()
        guard config.video_path.isEmpty,
              config.show_on_lock_screen != true
        else {
            return
        }
        if store.restoreWallpaperBackup() {
            store.removeManagedFallback()
        } else {
            _ = WallpaperDesktopSupport
                .repairCurrentDesktopWallpaperIfNeeded()
        }
    }

    private func updateConfig(_ block: (inout ControlConfig) -> Void) throws -> ControlConfig {
        var config = store.loadConfig()
        block(&config)
        let normalized = store.normalized(config)
        try store.saveConfig(normalized)
        return normalized
    }

    private func send(_ action: WallpaperRuntimeCommandAction, config: ControlConfig? = nil) throws {
        try store.saveCommand(WallpaperRuntimeCommand(action: action, config: config))
        DistributedNotificationCenter.default().post(
            name: WallpaperRuntimeNotifications.commandDidChange,
            object: nil,
            userInfo: nil
        )
    }

    private func launchAgentIfNeeded(lockScreenOnly: Bool = false) throws {
        if store.processIsAlive(pid: store.loadPID()) {
            return
        }

        store.removeCommand()
        store.removeHealth()
        if lockScreenOnly {
            store.markLockScreenAgentReady(false)
        }
        let task = Process()
        task.executableURL = helperURL
        task.arguments = [
            "--config",
            store.configURL.path,
        ] + (lockScreenOnly ? ["--lock-screen-only"] : [])
        try task.run()
        try store.savePID(task.processIdentifier)
        store.markLockScreenOnlyAgent(lockScreenOnly)
    }

    private func waitForLockScreenAgentReady() throws {
        // Test fixtures use lightweight helper processes instead of the real
        // lock-only agent. The readiness handshake is required only for the
        // production runtime, where returning Applied before the agent has
        // registered the shield callback creates the immediate-lock race.
        guard store.appSupportURL.standardizedFileURL
            == WallpaperRuntimeStore.defaultAppSupportURL()
                .standardizedFileURL
        else {
            return
        }

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            guard store.processIsAlive(pid: store.loadPID()) else {
                throw NativeWallpaperControllerError.unavailable(
                    "The Lock Screen agent stopped during initialization."
                )
            }
            if store.isLockScreenAgentReady() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NativeWallpaperControllerError.unavailable(
            "The Lock Screen agent did not finish initializing."
        )
    }

    func status() throws -> ControlStatus {
        store.status()
    }

    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus {
        let wasLockScreenOnlyAgent = store.isLockScreenOnlyAgent()
        if wasLockScreenOnlyAgent, store.processIsAlive(pid: store.loadPID()) {
            guard store.terminateDaemon(timeout: 2.0) else {
                throw NativeWallpaperControllerError.unavailable(
                    "The Lock Screen agent did not stop before starting desktop wallpaper."
                )
            }
            store.removeCommand()
            store.removeHealth()
        }
        store.markLockScreenOnlyAgent(false)
        let config = try updateConfig { config in
            if let videoURL {
                config.video_path = videoURL.path
            }
            if let speed {
                config.playback_speed = speed
            }
        }
        guard !config.video_path.isEmpty else {
            throw NativeWallpaperControllerError.unavailable("No video configured. Choose a wallpaper first.")
        }
        guard FileManager.default.fileExists(atPath: config.video_path) else {
            throw NativeWallpaperControllerError.unavailable("Video file not found: \(config.video_path)")
        }
        store.clearLockScreenOnlySource()
        _ = WallpaperDesktopSupport.captureCurrentDesktopWallpaperBackup(appSupportPath: store.appSupportURL.path)
        if config.show_on_lock_screen ?? true {
            try installLockScreenSaver(using: config)
        }
        store.markPaused(false)
        try launchAgentIfNeeded()
        try send(.reload, config: config)
        return store.status()
    }

    func resume() throws -> ControlStatus {
        let config = store.loadConfig()
        guard !config.video_path.isEmpty else {
            throw NativeWallpaperControllerError.unavailable("No video configured. Choose a wallpaper first.")
        }
        guard FileManager.default.fileExists(atPath: config.video_path) else {
            throw NativeWallpaperControllerError.unavailable("Video file not found: \(config.video_path)")
        }

        store.markPaused(false)
        try launchAgentIfNeeded()
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.resume, config: config)
        } else {
            try send(.reload, config: config)
        }
        return store.status()
    }

    func stop() throws -> ControlStatus {
        let config = store.loadConfig()
        let stoppingLockScreenOnly = store.isLockScreenOnlyAgent()
        store.markPaused(true)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.pause, config: config)
        }
        if stoppingLockScreenOnly, lockScreenSaverInstaller.isInstalled {
            try lockScreenSaverInstaller.uninstall()
        }
        return store.status()
    }

    func clearWallpaper() throws -> ControlStatus {
        let currentConfig = store.loadConfig()
        let removingLockScreenOnly =
            store.isLockScreenOnlyAgent()
            || store.loadLockScreenOnlySource() != nil
        let capturedLatestUserDesktop = removingLockScreenOnly
            && WallpaperDesktopSupport
                .captureLockScreenDesktopWallpaperBackup(
                    appSupportPath: store.appSupportURL.path
                )
        if store.processIsAlive(pid: store.loadPID()) {
            try? send(.terminate, config: currentConfig)
        }
        guard store.terminateDaemon(timeout: 2.0) else {
            throw NativeWallpaperControllerError.unavailable(
                "The wallpaper agent did not stop, so its desktop window could not be removed."
            )
        }
        store.removeCommand()
        store.removeHealth()
        if currentConfig.show_on_lock_screen == true
            || lockScreenSaverInstaller.isInstalled {
            try lockScreenSaverInstaller.uninstall()
        }
        store.clearLockScreenOnlySource()
        store.markLockScreenOnlyAgent(false)
        let restored: Bool
        if removingLockScreenOnly {
            // Lock-only mode never owns Desktop. The modern uninstaller has
            // already preserved the latest user Desktop modes; applying the
            // legacy Start backup here would roll them back.
            if capturedLatestUserDesktop {
                _ = WallpaperDesktopSupport
                    .restoreLockScreenDesktopWallpaperBackup(
                        appSupportPath: store.appSupportURL.path
                    )
            }
            WallpaperDesktopSupport.discardWallpaperBackupFiles(
                appSupportPath: store.appSupportURL.path
            )
            restored = false
        } else {
            restored = store.restoreWallpaperBackup()
        }
        _ = try updateConfig { config in
            config.video_path = ""
        }
        if restored {
            store.removeManagedFallback()
        }
        return store.status(wallpaperRestored: restored)
    }

    func setVideo(_ url: URL) throws -> ControlStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeWallpaperControllerError.unavailable("Video file not found: \(url.path)")
        }
        let config = try updateConfig { config in
            config.video_path = url.path
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.reload, config: config)
        }
        return store.status()
    }

    func installLockScreenOnly(videoURL: URL) throws -> ControlStatus {
        let normalizedURL = videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            throw NativeWallpaperControllerError.unavailable(
                "Video file not found: \(normalizedURL.path)"
            )
        }

        // Keep the selected source dedicated to Lock Screen. The runtime
        // temporarily promotes its Aerial route only during the lock handoff
        // and restores the user's Desktop route after unlock.

        do {
            try store.saveLockScreenOnlySource(normalizedURL)
            try installLockScreenSaver(
                videoURL: normalizedURL,
                ensureStillFrame: true,
                lockScreenOnly: true
            )
            guard lockScreenSaverInstaller.installationConfirmed else {
                throw NativeWallpaperControllerError.unavailable(
                    "macOS did not confirm the Lock Screen wallpaper configuration."
                )
            }
        } catch {
            store.clearLockScreenOnlySource()
            throw error
        }
        let config = try updateConfig { config in
            config.show_on_lock_screen = true
        }
        if store.processIsAlive(pid: store.loadPID()),
           !store.isLockScreenOnlyAgent() {
            // A normal desktop agent cannot be repurposed by a reload: it
            // would continue presenting AuraFlow windows on the Desktop.
            // Replace it with the dedicated lock-only agent so this button
            // never changes the user's Desktop wallpaper.
            guard store.terminateDaemon(timeout: 2.0) else {
                throw NativeWallpaperControllerError.unavailable(
                    "The desktop wallpaper agent did not stop before enabling Lock Screen only mode."
                )
            }
            store.removeCommand()
            store.removeHealth()
            store.markLockScreenOnlyAgent(false)
        }
        if store.processIsAlive(pid: store.loadPID()),
           store.isLockScreenOnlyAgent() {
            // The lock-only agent reads its source from the dedicated marker;
            // reload it when the user replaces that source so the next lock
            // cannot keep an old player item alive.
            store.markLockScreenAgentReady(false)
            try send(.reload, config: config)
        } else {
            try launchAgentIfNeeded(lockScreenOnly: true)
        }
        try waitForLockScreenAgentReady()
        return store.status()
    }

    func setSpeed(_ speed: Double) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.playback_speed = speed
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setInterpolation(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.blend_interpolation = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.pause_on_fullscreen = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setShowOnLockScreen(_ enabled: Bool) throws -> ControlStatus {
        let currentConfig = store.loadConfig()
        if enabled {
            if let sourceURL = store.effectiveLockScreenSourceURL(for: currentConfig) {
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw NativeWallpaperControllerError.unavailable(
                        "Video file not found: \(sourceURL.path)"
                    )
                }
                let backupURL = store.appSupportURL
                    .appendingPathComponent("wallpaper_backup.json")
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    _ = WallpaperDesktopSupport
                        .captureCurrentDesktopWallpaperBackup(
                            appSupportPath: store.appSupportURL.path
                        )
                }
                try installLockScreenSaver(
                    videoURL: sourceURL,
                    ensureStillFrame: store.loadLockScreenOnlySource() == nil,
                    lockScreenOnly: store.loadLockScreenOnlySource() != nil
                )
            }
        } else {
            store.clearLockScreenOnlySource()
            try lockScreenSaverInstaller.uninstall()
            if store.isLockScreenOnlyAgent() {
                if store.processIsAlive(pid: store.loadPID()) {
                    guard store.terminateDaemon(timeout: 2.0) else {
                        throw NativeWallpaperControllerError.unavailable(
                            "The Lock Screen agent did not stop after disabling Lock Screen wallpaper."
                        )
                    }
                }
                store.removeCommand()
                store.removeHealth()
                store.markLockScreenOnlyAgent(false)
            }
        }

        let config = try updateConfig { config in
            config.show_on_lock_screen = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func syncLockScreenSaver() throws {
        let config = store.loadConfig()
        guard config.show_on_lock_screen ?? true,
              let sourceURL = store.effectiveLockScreenSourceURL(for: config),
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            return
        }
        try installLockScreenSaver(
            videoURL: sourceURL,
            ensureStillFrame: store.loadLockScreenOnlySource() == nil,
            lockScreenOnly: store.loadLockScreenOnlySource() != nil
        )
    }

    func beginLockScreenPreview() throws -> ControlStatus {
        let config = store.loadConfig()
        guard config.show_on_lock_screen ?? true else {
            throw NativeWallpaperControllerError.unavailable(
                "Enable Lock Screen before previewing the transition."
            )
        }
        guard store.processIsAlive(pid: store.loadPID()) else {
            throw NativeWallpaperControllerError.unavailable(
                "Start the wallpaper before previewing the Lock Screen transition."
            )
        }
        try send(.previewLock, config: config)
        return store.status()
    }

    func endLockScreenPreview() throws -> ControlStatus {
        let config = store.loadConfig()
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.previewUnlock, config: config)
        }
        return store.status()
    }

    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.scale_mode = mode.commandValue
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setAutostart(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.autostart = enabled
        }
        if enabled {
            guard !config.video_path.isEmpty else {
                throw NativeWallpaperControllerError.unavailable("Choose a video before enabling launch at login.")
            }
            try store.enableLaunchAgent(helperPath: helperURL.path)
        } else {
            store.disableLaunchAgent()
        }
        return store.status()
    }

    func metrics() throws -> DaemonMetrics {
        store.metrics()
    }

    private func installLockScreenSaver(using config: ControlConfig) throws {
        let videoURL = URL(fileURLWithPath: config.video_path)
        try installLockScreenSaver(
            videoURL: videoURL,
            ensureStillFrame: true,
            lockScreenOnly: false
        )
    }

    private func installLockScreenSaver(
        videoURL: URL,
        ensureStillFrame: Bool,
        lockScreenOnly: Bool
    ) throws {
        // Keep a cached frame for the app's desktop recovery path, but do not
        // replace macOS's live Lock Screen descriptor with an image wallpaper.
        if ensureStillFrame {
            if lockScreenOnly {
                // A valid video is enough for the live saver. Treat frame
                // capture as a warm-up so a transient AVFoundation failure
                // cannot make the Lock button appear to do nothing.
                _ = try? store.ensureCurrentStillFrame(from: videoURL)
            } else {
                _ = try store.ensureCurrentStillFrame(from: videoURL)
            }
        }
        if lockScreenOnly {
            try lockScreenSaverInstaller.installLockScreenOnly(videoURL: videoURL)
        } else {
            try lockScreenSaverInstaller.install(videoURL: videoURL)
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    private struct WallpaperPreviewSeed: Codable, Equatable {
        let video_path: String
        let playback_speed: Double
        let scale_mode: String?
    }

    @Published private(set) var appliedVideoURL: URL?
    @Published private(set) var pendingPreviewVideoURL: URL?
    @Published var playbackSpeed: Double = 1.0
    @Published var isRunning: Bool = false
    @Published private(set) var isPlaybackActive: Bool = false
    @Published private(set) var isPlaybackPaused: Bool = false
    @Published private(set) var isLockScreenOnlyActive: Bool = false
    @Published var autostartEnabled: Bool = false
    @Published var blendInterpolationEnabled: Bool = false
    @Published var pauseOnFullscreenEnabled: Bool = true
    @Published var showOnLockScreenEnabled: Bool = true
    @Published private(set) var isLockScreenPreviewActive: Bool = false
    @Published var scaleMode: WallpaperScaleMode = .fill
    @Published var isSettingsOpen: Bool = false
    @Published var isMonitoringOpen: Bool = false
    @Published var monitoringSnapshot: DaemonMetrics?
    @Published var monitoringErrorMessage: String?
    @Published var isMonitoringRefreshing: Bool = false
    @Published var optimizationEnabled: Bool = true
    @Published var optimizationAllowAV1Passthrough: Bool = true
    @Published var optimizationTranscodeH264ToHEVC: Bool = true
    @Published var optimizationForceSoftwareAV1Encode: Bool = false
    @Published private(set) var optimizationHardwareAV1DecodeAvailable: Bool = false
    @Published var optimizationProfile: OptimizationProfile = .balanced
    @Published var optimizationInProgress: Bool = false
    @Published var optimizationProgress: Double = 0.0
    @Published var optimizationLabel: String?
    @Published var isBusy: Bool = false
    @Published var statusMessage: String?
    @Published var alertMessage: String?
    @Published var successBannerMessage: String?
    @Published var previewPlayer: AVPlayer?
    @Published var isCatalogOpen: Bool = false
    @Published var isDownloadedWallpapersOpen: Bool = false
    @Published var selectedCatalogWallpaper: CatalogWallpaper?
    @Published var catalogScrollTargetID: String?
    @Published var catalogSearchText: String = ""
    @Published var selectedCatalogGroup: CatalogWallpaperGroup?
    @Published var catalogDownloadID: String?
    @Published private(set) var catalogWallpapers: [CatalogWallpaper] = []
    @Published private(set) var catalogIsRefreshing: Bool = false
    @Published private(set) var downloadedCatalogWallpapers: [DownloadedCatalogWallpaper] = []
    @Published private(set) var controllerAvailable: Bool = false
    @Published private(set) var adaptiveGlassAppearance: AdaptiveGlassAppearance = .default

    private var controller: WallpaperControlling?
    private let catalogProvider: WallpaperCatalogProviding
    private let optimizer = VideoOptimizer()
    private let optimizationStore: VideoOptimizationStore
    private var previewEndObserver: NSObjectProtocol?
    private var previewStalledObserver: NSObjectProtocol?
    private var previewItemStatusObservation: NSKeyValueObservation?
    private var didAttemptAutostartOnLaunch = false
    private var healthMonitorTask: Task<Void, Never>?
    private var isHealthCheckInProgress = false
    private var bridgeFailureCount = 0
    private var daemonSuspiciousPolls = 0
    private var lowPowerAutoPauseActive = false
    private var fullscreenAutoPauseActive = false
    private var monitoringTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var isShuttingDown = false
    private var catalogRefreshTask: Task<Void, Never>?
    private var catalogDownloadTask: Task<Void, Never>?
    private var localWallpaperImportTask: Task<Void, Never>?
    private var localWallpaperImportGeneration = 0
    private var catalogNavigationLockedUntil: Date = .distantPast
    private var lastCatalogRefreshAt: Date?
    private var successBannerTask: Task<Void, Never>?
    private var controllerBootstrapTask: Task<Void, Never>?
    private var cacheClearTask: Task<Void, Never>?
    private var isControllerBootstrapInProgress = false
    private var previewRenderingSuspended = false
    private var suspendedPreviewRate: Float?
    private var glassAnalysisTask: Task<Void, Never>?
    private var glassAnalysisGeneration = 0
    private var cacheGeneration = 0

    private let expectedStatusContractVersion = 3
    private let bridgeFailureThreshold = 3
    private let daemonSuspiciousThreshold = 2
    private static let appSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)
    private static let startupConfigURL = appSupportDirectoryURL.appendingPathComponent("config.json")
    private static let defaultPreviewStateURL = appSupportDirectoryURL
        .appendingPathComponent("last_preview.json")

    private let previewStateURL: URL

    var isControllerAvailable: Bool {
        controllerAvailable
    }

    var selectedVideoName: String {
        selectedVideoURL?.lastPathComponent ?? "Not selected"
    }

    var currentVideoURL: URL? {
        selectedVideoURL
    }

    private var isPlaybackRunningForControls: Bool {
        isRunning && !isPlaybackPaused
    }

    var isStartButtonHighlighted: Bool {
        selectedVideoURL != nil
            && !isPlaybackRunningForControls
            && !isPlaybackPaused
    }

    var isStopButtonHighlighted: Bool {
        appliedVideoURL != nil && isPlaybackPaused
    }

    var canStart: Bool {
        isControllerAvailable && !isBusy && !isPlaybackRunningForControls && selectedVideoURL != nil
    }

    var canApplyLockScreenOnly: Bool {
        isControllerAvailable && !isBusy && selectedVideoURL != nil
    }

    var canStop: Bool {
        isControllerAvailable
            && !isBusy
            && (isPlaybackRunningForControls || isLockScreenOnlyActive)
    }

    var canClearWallpaper: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleAutostart: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleBlendInterpolation: Bool {
        isControllerAvailable && !isBusy
    }

    var canTogglePauseOnFullscreen: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleShowOnLockScreen: Bool {
        isControllerAvailable && !isBusy
    }

    var canPreviewLockScreen: Bool {
        isPlaybackRunningForControls
            && showOnLockScreenEnabled
            && !isLockScreenPreviewActive
    }

    var canToggleScaleMode: Bool {
        isControllerAvailable && !isBusy
    }

    var canOpenMonitoring: Bool {
        isControllerAvailable
    }

    var canChangeOptimizationSettings: Bool {
        !isBusy && !optimizationInProgress
    }

    var canApplyCatalogWallpaper: Bool {
        isControllerAvailable && !isBusy && catalogDownloadID == nil
    }

    var canClearCache: Bool {
        !isBusy
            && !optimizationInProgress
            && catalogDownloadID == nil
            && !catalogIsRefreshing
    }

    private var selectedVideoURL: URL? {
        pendingPreviewVideoURL ?? appliedVideoURL
    }

    private var previewPlayerURL: URL? {
        (previewPlayer?.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL
    }

    var filteredCatalogWallpapers: [CatalogWallpaper] {
        let groupFiltered = catalogWallpapers.filter { wallpaper in
            guard let selectedCatalogGroup else { return true }
            return wallpaper.catalogGroup == selectedCatalogGroup
        }
        let query = catalogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupFiltered }
        return groupFiltered.filter { wallpaper in
            wallpaper.title.localizedCaseInsensitiveContains(query)
                || wallpaper.category.localizedCaseInsensitiveContains(query)
        }
    }

    init(
        controller: WallpaperControlling? = nil,
        optimizationStore: VideoOptimizationStore = VideoOptimizationStore(),
        catalogProvider: WallpaperCatalogProviding = ManagedWallpaperCatalogProvider(),
        previewStateURL: URL? = nil
    ) {
        self.optimizationStore = optimizationStore
        self.catalogProvider = catalogProvider
        self.previewStateURL = previewStateURL ?? Self.defaultPreviewStateURL
        if let controller {
            self.controller = controller
            self.controllerAvailable = true
        } else {
            self.controller = nil
            self.controllerAvailable = false
            self.isControllerBootstrapInProgress = true
        }
        optimizationHardwareAV1DecodeAvailable = optimizer.supportsHardwareAV1Decode()
        applyOptimizationSettings(optimizationStore.load())
        restoreInitialPreviewFromSavedConfig()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginShutdown()
            }
        }
        Task { [weak self] in
            await self?.loadCatalogFromCache()
            await MainActor.run {
                self?.loadDownloadedCatalogWallpapers()
            }
        }
        bootstrapControllerIfNeeded()
        startHealthMonitor()
    }

    deinit {
        healthMonitorTask?.cancel()
        monitoringTask?.cancel()
        catalogRefreshTask?.cancel()
        catalogDownloadTask?.cancel()
        localWallpaperImportTask?.cancel()
        controllerBootstrapTask?.cancel()
        glassAnalysisTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
        }
        if let previewStalledObserver {
            NotificationCenter.default.removeObserver(previewStalledObserver)
        }
        previewItemStatusObservation?.invalidate()
        successBannerTask?.cancel()
    }

    func loadStatus() async {
        guard let controller else {
            if !isControllerBootstrapInProgress {
                alertMessage = "Native wallpaper runtime unavailable."
            }
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await runAsync { try controller.status() }
            apply(status: status)
            let needsNormalizationURL = configuredVideoNeedingCompatibilityNormalization(from: status)
            recordBridgeSuccess()
            await startFromAutostartIfNeeded(using: status)
            if status.config.show_on_lock_screen ?? true {
                do {
                    try await runAsync {
                        try controller.syncLockScreenSaver()
                    }
                } catch {
                    alertMessage =
                        "Lock Screen sync failed: \(error.localizedDescription)"
                    return
                }
            }
            if let needsNormalizationURL {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    await self?.applyVideoSelection(
                        needsNormalizationURL,
                        surfaceErrors: false
                    )
                }
            }
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "status")
        }
    }

    private func restoreInitialPreviewFromSavedConfig() {
        guard pendingPreviewVideoURL == nil else { return }
        let seeds = [
            Self.loadStartupPreviewSeed(),
            loadSavedPreviewSeed(),
        ].compactMap { $0 }
        guard let seed = seeds.first(where: {
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: $0.video_path).standardizedFileURL.path
            )
        }) else {
            return
        }
        let videoURL = URL(fileURLWithPath: seed.video_path).standardizedFileURL

        appliedVideoURL = videoURL
        playbackSpeed = seed.playback_speed
        if let rawScaleMode = seed.scale_mode,
           let restoredScaleMode = WallpaperScaleMode(rawValue: rawScaleMode) {
            scaleMode = restoredScaleMode
        }
        configurePreview(for: videoURL)
    }

    private func loadSavedPreviewSeed() -> WallpaperPreviewSeed? {
        guard let data = try? Data(contentsOf: previewStateURL) else { return nil }
        return try? JSONDecoder().decode(WallpaperPreviewSeed.self, from: data)
    }

    private func savePreviewSeed(for videoURL: URL) {
        let normalizedURL = videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return }
        let seed = WallpaperPreviewSeed(
            video_path: normalizedURL.path,
            playback_speed: playbackSpeed,
            scale_mode: scaleMode.rawValue
        )
        do {
            try FileManager.default.createDirectory(
                at: previewStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(seed)
            try data.write(to: previewStateURL, options: .atomic)
        } catch {
            // Preview persistence is best-effort and must not block playback.
        }
    }

    private static func loadStartupPreviewSeed() -> WallpaperPreviewSeed? {
        guard let data = try? Data(contentsOf: startupConfigURL) else { return nil }
        guard let config = try? JSONDecoder().decode(ControlConfig.self, from: data),
              !config.video_path.isEmpty
        else {
            return nil
        }
        return WallpaperPreviewSeed(
            video_path: config.video_path,
            playback_speed: config.playback_speed,
            scale_mode: config.scale_mode
        )
    }

    private func bootstrapControllerIfNeeded() {
        guard controller == nil else { return }
        guard controllerBootstrapTask == nil else { return }

        controllerBootstrapTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let controller = try NativeWallpaperController()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.controller = controller
                    self.controllerAvailable = true
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    Task { @MainActor [weak self] in
                        await self?.loadStatus()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.controller = nil
                    self.controllerAvailable = false
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func chooseVideo(force: Bool = false) {
        guard force || !isBusy else { return }
        let panel = NSOpenPanel()
        var types: [UTType] = [
            .mpeg4Movie,
            .quickTimeMovie,
            .gif,
            .png,
            .jpeg,
            .heic,
            .tiff,
            .bmp,
        ]
        if let m4v = UTType(filenameExtension: "m4v") {
            types.append(m4v)
        }
        if let webp = UTType(filenameExtension: "webp") {
            types.append(webp)
        }
        configureMediaOpenPanel(
            panel,
            title: "Choose Desktop Wallpaper",
            allowedContentTypes: types,
            preferredDirectory: "Movies"
        )
        if panel.runModal() == .OK, let url = panel.url {
            selectLocalVideoForPreview(url)
        }
    }

    private func configureMediaOpenPanel(
        _ panel: NSOpenPanel,
        title: String,
        allowedContentTypes: [UTType],
        preferredDirectory: String
    ) {
        panel.title = title
        panel.prompt = "Choose"
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let preferredURL = home.appendingPathComponent(preferredDirectory, isDirectory: true)
        let downloadsURL = home.appendingPathComponent("Downloads", isDirectory: true)
        if fileManager.fileExists(atPath: preferredURL.path) {
            panel.directoryURL = preferredURL
        } else if fileManager.fileExists(atPath: downloadsURL.path) {
            panel.directoryURL = downloadsURL
        } else {
            panel.directoryURL = home
        }
    }

    func chooseVideoFromMenuBar() {
        Task { @MainActor in
            var retries = 0
            while isBusy && retries < 20 {
                retries += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            chooseVideo(force: true)
        }
    }

    func openCatalog() {
        isSettingsOpen = false
        closeMonitoring()
        closeDownloadedWallpapers()
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        selectedCatalogGroup = nil
        isCatalogOpen = true
        refreshCatalogIfNeeded()
    }

    func openCatalogFromMenuBar() {
        isSettingsOpen = false
        closeMonitoring()
        closeDownloadedWallpapers()
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        selectedCatalogGroup = nil
        isCatalogOpen = true
        refreshCatalogIfNeeded()
    }

    func openDownloadedWallpapers() {
        isCatalogOpen = false
        selectedCatalogWallpaper = nil
        closeSettings()
        closeMonitoring()
        loadDownloadedCatalogWallpapers()
        isDownloadedWallpapersOpen = true
    }

    func closeDownloadedWallpapers() {
        isDownloadedWallpapersOpen = false
    }

    func applyDownloadedCatalogWallpaper(_ wallpaper: DownloadedCatalogWallpaper) {
        Task {
            let initialURL = wallpaper.localURL
            guard FileManager.default.fileExists(atPath: initialURL.path) else {
                loadDownloadedCatalogWallpapers()
                alertMessage = "Downloaded wallpaper file is missing. Re-download from catalog."
                return
            }

            do {
                let resolvedURL = try await resolveDownloadedCatalogWallpaperURL(wallpaper)
                closeDownloadedWallpapers()
                selectVideoForPreview(resolvedURL, summary: nil)
                applySelectionImmediately(
                    resolvedURL,
                    failureContext: "start",
                    catalogFastPath: true
                )
            } catch {
                alertMessage = "Failed to prepare downloaded wallpaper: \(error.localizedDescription)"
            }
        }
    }

    func openCatalogWallpaper(_ wallpaper: CatalogWallpaper) {
        guard Date() >= catalogNavigationLockedUntil else { return }
        catalogScrollTargetID = wallpaper.id
        selectedCatalogWallpaper = wallpaper
    }

    func navigateBackFromCatalog() {
        if selectedCatalogWallpaper != nil {
            selectedCatalogWallpaper = nil
            catalogNavigationLockedUntil = Date().addingTimeInterval(0.35)
            return
        }
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        isCatalogOpen = false
        catalogNavigationLockedUntil = Date().addingTimeInterval(0.2)
    }

    func isDownloading(_ wallpaper: CatalogWallpaper) -> Bool {
        catalogDownloadID == wallpaper.id
    }

    func toggleCatalogGroup(_ group: CatalogWallpaperGroup) {
        selectedCatalogGroup = selectedCatalogGroup == group ? nil : group
        catalogScrollTargetID = filteredCatalogWallpapers.first?.id
    }

    func catalogWallpaperCount(in group: CatalogWallpaperGroup) -> Int {
        catalogWallpapers.filter { $0.catalogGroup == group }.count
    }

    func applyCatalogWallpaper(_ wallpaper: CatalogWallpaper) {
        guard canApplyCatalogWallpaper else { return }
        if isCatalogWallpaperAlreadyApplied(wallpaper) {
            showSuccessBanner("Wallpaper is already applied.")
            return
        }
        catalogDownloadID = wallpaper.id
        let requestedCacheGeneration = cacheGeneration

        catalogDownloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                catalogDownloadID = nil
                catalogDownloadTask = nil
            }
            do {
                let localURL = try await downloadCatalogVideo(for: wallpaper)
                guard !Task.isCancelled, requestedCacheGeneration == cacheGeneration else {
                    try? FileManager.default.removeItem(at: localURL)
                    return
                }
                showSuccessBanner("Wallpaper downloaded. Applying…")
                do {
                    try await applyDownloadedCatalogWallpaperImmediately(wallpaper, localURL: localURL)
                    showSuccessBanner("Wallpaper downloaded and applied.")
                    alertMessage = nil
                } catch {
                    alertMessage = "Wallpaper downloaded, but apply failed: \(error.localizedDescription)"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                alertMessage = "Failed to download wallpaper: \(error.localizedDescription)"
            }
        }
    }

    func applyVideoSelection(_ url: URL, surfaceErrors: Bool = true) async {
        guard let controller else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let prepared = try await prepareVideoURLForPlayback(url)
            let status = try await runAsync { try controller.setVideo(prepared.url) }
            apply(status: status)
            recordBridgeSuccess()
            statusMessage = prepared.summary ?? "Wallpaper source updated."
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "set-video", surface: surfaceErrors)
            if surfaceErrors && bridgeFailureCount < bridgeFailureThreshold {
                alertMessage = "Failed to set video: \(error.localizedDescription)"
            }
        }
    }

    func start() {
        guard !isBusy else { return }
        guard !isPlaybackRunningForControls else { return }
        guard let selectedVideoURL else {
            alertMessage = "Choose a video before starting."
            return
        }

        Task {
            isBusy = true
            statusMessage = "Starting wallpaper…"
            alertMessage = nil
            defer { isBusy = false }
            do {
                if isPlaybackPaused && pendingPreviewVideoURL == nil {
                    guard let controller else {
                        throw NativeWallpaperControllerError.unavailable("Native wallpaper runtime unavailable.")
                    }
                    let status = try await runAsync { try controller.resume() }
                    apply(status: status)
                    recordBridgeSuccess()
                    statusMessage = "Wallpaper resumed."
                    alertMessage = nil
                } else {
                    try await startWallpaper(using: selectedVideoURL, statusSummary: "Wallpaper started.")
                }
            } catch {
                recordBridgeFailure(error, context: "start")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to start: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyLockScreenOnly() {
        guard !isBusy else { return }
        guard let selectedVideoURL else {
            alertMessage = "Choose a video before applying it to the Lock Screen."
            return
        }
        guard let controller else {
            alertMessage = "Native wallpaper runtime unavailable."
            return
        }

        Task {
            isBusy = true
            statusMessage = "Applying live wallpaper to Lock Screen…"
            alertMessage = nil
            defer { isBusy = false }
            do {
                let prepared = try await prepareVideoURLForPlayback(selectedVideoURL)
                let status = try await runAsync {
                    try controller.installLockScreenOnly(videoURL: prepared.url)
                }
                apply(status: status, refreshPreview: false)
                recordBridgeSuccess()
                showSuccessBanner("Lock Screen wallpaper confirmed by macOS.")
                statusMessage = prepared.summary.map {
                    "Lock Screen wallpaper confirmed. \($0)"
                } ?? "Lock Screen wallpaper confirmed by macOS."
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "lock-screen-only")
                alertMessage = "Failed to apply Lock Screen wallpaper: \(error.localizedDescription)"
                statusMessage = "Lock Screen wallpaper was not installed."
            }
        }
    }

    func stop() {
        guard let controller else { return }
        guard !isBusy else { return }
        guard isPlaybackRunningForControls || isLockScreenOnlyActive else {
            return
        }
        let stoppingLockScreenOnly = isLockScreenOnlyActive
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.stop() }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = stoppingLockScreenOnly
                    ? "Lock Screen wallpaper stopped."
                    : "Paused on current frame."
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "pause")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to pause: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearWallpaper() {
        guard let controller else { return }
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.clearWallpaper() }
                apply(status: status)
                recordBridgeSuccess()
                if let restored = status.wallpaper_restored {
                    statusMessage = restored ? "Original wallpaper restored." : "Wallpaper backup not found."
                } else {
                    statusMessage = "Removing live wallpaper."
                }
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "clear-wallpaper")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to restore wallpaper: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateSpeed(_ speed: Double) {
        setPreviewPlaybackSpeed(speed)
        guard let controller else { return }
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setSpeed(speed) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = "Speed updated."
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "set-speed")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update speed: \(error.localizedDescription)"
                }
            }
        }
    }

    func setPreviewPlaybackSpeed(_ speed: Double) {
        guard abs(playbackSpeed - speed) > 0.0001 else { return }
        playbackSpeed = speed
        syncPreviewPlaybackRate()
    }

    func toggleAutostart(_ enabled: Bool) {
        guard !isBusy else {
            autostartEnabled = !enabled
            return
        }
        if enabled && selectedVideoURL == nil {
            autostartEnabled = false
            alertMessage = "Choose a video before enabling launch at login."
            return
        }

        let previous = autostartEnabled
        autostartEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setAutostart(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled ? "Launch at login enabled." : "Launch at login disabled."
                alertMessage = nil
            } catch {
                autostartEnabled = previous
                recordBridgeFailure(error, context: "set-autostart")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update launch at login: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleBlendInterpolation(_ enabled: Bool) {
        guard !isBusy else {
            blendInterpolationEnabled = !enabled
            return
        }

        let previous = blendInterpolationEnabled
        blendInterpolationEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setInterpolation(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled
                    ? "Blend interpolation enabled."
                    : "Blend interpolation disabled."
                alertMessage = nil
            } catch {
                blendInterpolationEnabled = previous
                recordBridgeFailure(error, context: "set-interpolation")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update interpolation: \(error.localizedDescription)"
                }
            }
        }
    }

    func togglePauseOnFullscreen(_ enabled: Bool) {
        guard !isBusy else {
            pauseOnFullscreenEnabled = !enabled
            return
        }

        let previous = pauseOnFullscreenEnabled
        pauseOnFullscreenEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setPauseOnFullscreen(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled
                    ? "Auto-pause on fullscreen enabled."
                    : "Auto-pause on fullscreen disabled."
                alertMessage = nil
            } catch {
                pauseOnFullscreenEnabled = previous
                recordBridgeFailure(error, context: "set-fullscreen-pause")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update fullscreen policy: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleShowOnLockScreen(_ enabled: Bool) {
        guard !isBusy else {
            showOnLockScreenEnabled = !enabled
            return
        }

        let previous = showOnLockScreenEnabled
        showOnLockScreenEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync {
                    try controller.setShowOnLockScreen(enabled)
                }
                apply(status: status)
                recordBridgeSuccess()
                if enabled, status.config.video_path.isEmpty {
                    statusMessage = "Lock Screen enabled; it will activate when wallpaper starts."
                } else {
                    statusMessage = enabled
                        ? "AuraFlow Lock Screen installed and selected."
                        : "AuraFlow Lock Screen removed."
                }
                alertMessage = nil
            } catch {
                showOnLockScreenEnabled = previous
                recordBridgeFailure(error, context: "set-lock-screen")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update Lock Screen: \(error.localizedDescription)"
                }
            }
        }
    }

    func previewLockScreenTransition() {
        guard canPreviewLockScreen, let controller else { return }

        Task {
            isBusy = true
            isLockScreenPreviewActive = true
            defer {
                isLockScreenPreviewActive = false
                isBusy = false
            }

            do {
                _ = try await runAsync {
                    try controller.beginLockScreenPreview()
                }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let status = try await runAsync {
                    try controller.endLockScreenPreview()
                }
                apply(status: status, refreshPreview: false)
                recordBridgeSuccess()
                statusMessage = "No-flash layer test completed."
                alertMessage = nil
            } catch {
                _ = try? await runAsync {
                    try controller.endLockScreenPreview()
                }
                recordBridgeFailure(error, context: "preview-lock-screen")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Lock Screen preview failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func openScreenSaverSettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect",
        ]
        for destination in destinations {
            guard let url = URL(string: destination) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        alertMessage =
            "Open System Settings → Wallpaper to inspect the active Lock Screen wallpaper."
    }

    func startSystemScreenSaver() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            alertMessage =
                "macOS could not start the Lock Screen test."
            return
        }
        guard task.terminationStatus == 0 else {
            alertMessage =
                "macOS did not accept the Lock Screen test request."
            return
        }
        statusMessage = "Lock Screen test started. Unlock the Mac manually to return."
        alertMessage = nil
    }

    func setScaleMode(_ mode: WallpaperScaleMode) {
        guard !isBusy else { return }
        let previous = scaleMode
        scaleMode = mode
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setScaleMode(mode) }
                apply(status: status)
                if showOnLockScreenEnabled {
                    try await runAsync {
                        try controller.syncLockScreenSaver()
                    }
                }
                recordBridgeSuccess()
                statusMessage = "Scale mode: \(mode.title)."
                alertMessage = nil
            } catch {
                scaleMode = previous
                recordBridgeFailure(error, context: "set-scale")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update scale mode: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshMonitoring() {
        Task {
            await refreshMonitoringSnapshot(surfaceErrors: true)
        }
    }

    func openSettings() {
        closeDownloadedWallpapers()
        closeMonitoring()
        isSettingsOpen = true
    }

    func closeSettings() {
        isSettingsOpen = false
    }

    func openMonitoring() {
        closeDownloadedWallpapers()
        closeSettings()
        isMonitoringOpen = true
        monitoringErrorMessage = nil
        startMonitoringLoop()
    }

    func closeMonitoring() {
        isMonitoringOpen = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func setOptimizationEnabled(_ enabled: Bool) {
        optimizationEnabled = enabled
        persistOptimizationSettings()
    }

    func setOptimizationAllowAV1Passthrough(_ enabled: Bool) {
        optimizationAllowAV1Passthrough = enabled
        persistOptimizationSettings()
    }

    func setOptimizationTranscodeH264ToHEVC(_ enabled: Bool) {
        optimizationTranscodeH264ToHEVC = enabled
        persistOptimizationSettings()
    }

    func setOptimizationForceSoftwareAV1Encode(_ enabled: Bool) {
        if enabled && !optimizationHardwareAV1DecodeAvailable {
            optimizationForceSoftwareAV1Encode = false
            statusMessage = "AV1 force encode unavailable: no hardware AV1 decode."
            return
        }
        optimizationForceSoftwareAV1Encode = enabled
        persistOptimizationSettings()
    }

    func setOptimizationProfile(_ profile: OptimizationProfile) {
        optimizationProfile = profile
        persistOptimizationSettings()
    }

    func clearCache() {
        if let cacheClearTask, !cacheClearTask.isCancelled {
            return
        }
        cancelLocalWallpaperImport()

        cacheClearTask = Task {
            isBusy = true
            defer {
                isBusy = false
                cacheClearTask = nil
            }

            do {
                cacheGeneration &+= 1
                catalogRefreshTask?.cancel()
                catalogDownloadTask?.cancel()
                catalogDownloadID = nil
                let refreshTask = catalogRefreshTask
                let downloadTask = catalogDownloadTask
                await refreshTask?.value
                await downloadTask?.value

                let appliedVideoIsManaged = appliedVideoURL.map(isManagedCacheURL) ?? false
                let pendingPreviewIsManaged = pendingPreviewVideoURL.map(isManagedCacheURL) ?? false

                // A downloaded wallpaper can still be the active source. Stop
                // it before deleting the file, otherwise the daemon keeps the
                // item alive and the cache appears to survive the cleanup.
                if appliedVideoIsManaged {
                    // Clearing the active managed wallpaper also clears any
                    // preview layer; otherwise `apply(status:)` intentionally
                    // keeps a pending preview alive.
                    pendingPreviewVideoURL = nil
                } else if pendingPreviewIsManaged {
                    pendingPreviewVideoURL = nil
                }
                if appliedVideoIsManaged {
                    guard let controller else {
                        throw NativeWallpaperControllerError.unavailable(
                            "Cannot clear the active downloaded wallpaper while the wallpaper runtime is unavailable."
                        )
                    }
                    let status = try await runAsync { try controller.clearWallpaper() }
                    apply(status: status)
                    recordBridgeSuccess()
                } else if pendingPreviewIsManaged {
                    configurePreview(for: selectedVideoURL)
                }

                try clearCatalogCache()
                try clearOptimizedVideoCache()
                try clearRuntimePreviewCache()
                URLCache.shared.removeAllCachedResponses()
                CatalogPreviewImageLoader.clearCache()

                if let cacheClearingProvider = catalogProvider as? CatalogCacheClearing {
                    await cacheClearingProvider.clearCache()
                }

                downloadedCatalogWallpapers = []

                catalogWallpapers = []
                selectedCatalogWallpaper = nil
                lastCatalogRefreshAt = nil
                statusMessage = "Cache and downloaded wallpapers cleared."
                alertMessage = nil
            } catch {
                alertMessage = "Failed to clear cache: \(error.localizedDescription)"
            }
        }
    }

    private func cancelLocalWallpaperImport() {
        localWallpaperImportGeneration &+= 1
        localWallpaperImportTask?.cancel()
        localWallpaperImportTask = nil
    }

    func preview() {
        configurePreview(for: selectedVideoURL)
    }

    private func currentOptimizationSettings() -> VideoOptimizationSettings {
        VideoOptimizationSettings(
            enabled: optimizationEnabled,
            allowAV1PassthroughOnHardwareDecode: optimizationAllowAV1Passthrough,
            transcodeH264ToHEVC: optimizationTranscodeH264ToHEVC,
            forceSoftwareAV1Encode: (
                optimizationForceSoftwareAV1Encode
                && optimizationHardwareAV1DecodeAvailable
            ),
            profile: optimizationProfile
        )
    }

    private func applyOptimizationSettings(_ settings: VideoOptimizationSettings) {
        optimizationEnabled = settings.enabled
        optimizationAllowAV1Passthrough = settings.allowAV1PassthroughOnHardwareDecode
        optimizationTranscodeH264ToHEVC = settings.transcodeH264ToHEVC
        optimizationForceSoftwareAV1Encode = (
            settings.forceSoftwareAV1Encode && optimizationHardwareAV1DecodeAvailable
        )
        optimizationProfile = settings.profile
    }

    private func persistOptimizationSettings() {
        optimizationStore.save(currentOptimizationSettings())
    }

    private func prepareVideoURLForPlayback(_ sourceURL: URL) async throws -> (url: URL, summary: String?) {
        if WallpaperMediaKind.forURL(sourceURL).isStaticImage {
            return (sourceURL.standardizedFileURL, nil)
        }
        let settings = currentOptimizationSettings()
        guard settings.enabled else {
            return (sourceURL, nil)
        }

        optimizationInProgress = true
        optimizationProgress = 0
        optimizationLabel = "Preparing optimization..."
        defer {
            optimizationInProgress = false
            optimizationProgress = 0
            optimizationLabel = nil
        }

        let result = try await optimizer.optimizeIfNeeded(
            inputURL: sourceURL,
            settings: settings,
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    let value = min(max(progress, 0), 1)
                    self?.optimizationProgress = value
                    let percent = Int((value * 100).rounded())
                    self?.optimizationLabel = "Optimizing video: \(percent)%"
                }
            }
        )

        switch result.decision {
        case .passthrough(let reason):
            return (result.outputURL, reason)
        case .transcode(let reason):
            let summary: String
            if result.fromCache {
                summary = "Using cached optimized video. \(reason)"
            } else {
                summary = "Video optimized for macOS playback. \(reason)"
            }
            return (result.outputURL, summary)
        }
    }

    private func prepareCatalogVideoURLForPlayback(_ sourceURL: URL) async throws -> (url: URL, summary: String?) {
        if WallpaperMediaKind.forURL(sourceURL).isStaticImage {
            return (sourceURL.standardizedFileURL, nil)
        }

        // GIF is deliberately kept on the compatibility path. AVPlayer can
        // inspect it, but the desktop agent needs the optimizer's MP4 output
        // for reliable looping.
        let isGIF = sourceURL.pathExtension.lowercased() == "gif"
        if !isGIF, await isPreviewPlayableVideo(at: sourceURL) {
            // A native MP4/MOV/M4V source is already ready to render. Do not
            // make a catalog download wait for the user's optional HEVC or
            // 1080p optimization pass.
            return (sourceURL.standardizedFileURL, nil)
        }

        var settings = currentOptimizationSettings()
        settings.enabled = true
        // Catalog application should not transcode an otherwise playable
        // H.264 source just because the global optimization preference is on.
        // This flag still leaves WebM/MKV/GIF compatibility conversion active.
        settings.transcodeH264ToHEVC = false

        let result = try await optimizer.optimizeIfNeeded(
            inputURL: sourceURL,
            settings: settings,
            progress: { _ in }
        )

        let outputIsPlayable: Bool
        if WallpaperMediaKind.forURL(result.outputURL).isStaticImage {
            outputIsPlayable = true
        } else {
            outputIsPlayable = await isPreviewPlayableVideo(at: result.outputURL)
        }
        guard outputIsPlayable else {
            throw URLError(.cannotDecodeContentData)
        }

        switch result.decision {
        case .passthrough(let reason):
            return (result.outputURL, reason)
        case .transcode(let reason):
            let summary = result.fromCache
                ? "Using cached compatible wallpaper. \(reason)"
                : "Wallpaper converted for macOS playback. \(reason)"
            return (result.outputURL, summary)
        }
    }

    private func apply(
        status: ControlStatus,
        refreshPreview: Bool = true,
        backgroundUpdate: Bool = false
    ) {
        let hasConfiguredVideo = !status.config.video_path.isEmpty
        let paused = status.paused ?? false
        let effectiveRunning = statusIndicatesActivePlayback(status)
        let lockScreenOnlyActive = !status.running
            && !paused
            && status.health?.available == true
            && status.health?.suspicious != true
        Self.setIfChanged(&isRunning, to: status.running)
        Self.setIfChanged(&isPlaybackActive, to: effectiveRunning)
        Self.setIfChanged(&isPlaybackPaused, to: paused && hasConfiguredVideo && !effectiveRunning)
        Self.setIfChanged(
            &isLockScreenOnlyActive,
            to: lockScreenOnlyActive
        )
        Self.setIfChanged(&playbackSpeed, to: status.config.playback_speed)
        Self.setIfChanged(&autostartEnabled, to: status.autostart ?? status.config.autostart ?? false)
        Self.setIfChanged(&blendInterpolationEnabled, to: status.config.blend_interpolation ?? false)
        Self.setIfChanged(&pauseOnFullscreenEnabled, to: status.config.pause_on_fullscreen ?? true)
        Self.setIfChanged(&showOnLockScreenEnabled, to: status.config.show_on_lock_screen ?? true)
        let previousScaleMode = scaleMode
        let resolvedScaleMode = WallpaperScaleMode(rawValue: status.config.scale_mode ?? "fill") ?? .fill
        Self.setIfChanged(&scaleMode, to: resolvedScaleMode)
        if hasConfiguredVideo {
            let currentURL = URL(fileURLWithPath: status.config.video_path)
            let hasVideoChanged = appliedVideoURL?.path != currentURL.path
            Self.setIfChanged(&appliedVideoURL, to: currentURL)
            if pendingPreviewVideoURL == nil,
               refreshPreview && (hasVideoChanged || previewPlayer?.currentItem == nil || previousScaleMode != scaleMode) {
                configurePreview(for: currentURL)
            }
            if pendingPreviewVideoURL == nil {
                savePreviewSeed(for: currentURL)
            }
        } else {
            if pendingPreviewVideoURL == nil {
                if let currentURL = appliedVideoURL?.standardizedFileURL,
                   FileManager.default.fileExists(atPath: currentURL.path) {
                    if refreshPreview && previewPlayer?.currentItem == nil {
                        configurePreview(for: currentURL)
                    }
                } else {
                    Self.setIfChanged(&appliedVideoURL, to: nil)
                    if previewPlayer != nil {
                        previewPlayer = nil
                    }
                }
            }
        }
        syncPreviewPlaybackRate()
        evaluateStatusContract(status, backgroundUpdate: backgroundUpdate)
        evaluateDaemonHealth(status.health, backgroundUpdate: backgroundUpdate)
    }

    private static func setIfChanged<Value: Equatable>(_ current: inout Value, to newValue: Value) {
        guard current != newValue else { return }
        current = newValue
    }

    private func startHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self?.recoverPlaybackIfUnexpectedlyStopped()
            }
        }
    }

    private func recoverPlaybackIfUnexpectedlyStopped() async {
        guard !isShuttingDown else { return }
        guard let controller else { return }
        guard !isBusy else { return }
        guard !isHealthCheckInProgress else { return }

        isHealthCheckInProgress = true
        defer { isHealthCheckInProgress = false }

        do {
            let status = try await runAsync { try controller.status() }
            let hasVideo = !status.config.video_path.isEmpty
            let paused = status.paused ?? false
            let shouldRecover = isRunning && !status.running && !paused && hasVideo
            apply(status: status, refreshPreview: false, backgroundUpdate: true)

            let healthSuspicious = status.health?.suspicious ?? false
            let shouldRecoverSuspiciousDaemon = (
                isRunning
                && status.running
                && !paused
                && hasVideo
                && healthSuspicious
                && daemonSuspiciousPolls >= daemonSuspiciousThreshold
            )

            if shouldRecover || shouldRecoverSuspiciousDaemon {
                let recoveredStatus = try await runAsync {
                    try controller.start(videoURL: nil, speed: nil)
                }
                apply(status: recoveredStatus, refreshPreview: false, backgroundUpdate: true)
                recordBridgeSuccess()
                if shouldRecoverSuspiciousDaemon {
                    statusMessage = "Daemon recovered from suspicious state."
                } else {
                    statusMessage = "Playback recovered after interruption."
                }
                alertMessage = nil
            }
        } catch {
            recordBridgeFailure(error, context: "background-health", surface: false)
        }
    }

    private func startMonitoringLoop() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMonitoringSnapshot(surfaceErrors: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isMonitoringOpen else { return }
                await self.refreshMonitoringSnapshot(surfaceErrors: false)
            }
        }
    }

    private func refreshMonitoringSnapshot(surfaceErrors: Bool) async {
        guard !isShuttingDown else { return }
        guard isMonitoringOpen else { return }
        guard let controller else {
            monitoringErrorMessage = "Native wallpaper runtime unavailable."
            return
        }
        if isMonitoringRefreshing {
            return
        }

        isMonitoringRefreshing = true
        defer { isMonitoringRefreshing = false }

        do {
            let metrics = try await runAsync { try controller.metrics() }
            monitoringSnapshot = metrics
            monitoringErrorMessage = nil
        } catch {
            monitoringErrorMessage = error.localizedDescription
            if surfaceErrors {
                alertMessage = "Failed to refresh monitoring: \(error.localizedDescription)"
            }
        }
    }

    private func loadCatalogFromCache() async {
        if let cached = await catalogProvider.loadCachedCatalog(), !cached.isEmpty {
            catalogWallpapers = cached
        }
    }

    private func loadDownloadedCatalogWallpapers() {
        let inMemory = downloadedCatalogWallpapers
        let loaded: [DownloadedCatalogWallpaper]
        do {
            let manifestURL = try downloadedCatalogManifestURL()
            guard let data = try? Data(contentsOf: manifestURL) else {
                let inferred = inferredDownloadedCatalogWallpapersFromDisk()
                let merged = mergeDownloadedCatalogWallpapers(
                    inferred,
                    preserving: inMemory
                )
                downloadedCatalogWallpapers = merged
                if !merged.isEmpty {
                    try? persistDownloadedCatalogWallpapers(merged)
                }
                return
            }
            loaded = try JSONDecoder().decode([DownloadedCatalogWallpaper].self, from: data)
        } catch {
            downloadedCatalogWallpapers = mergeDownloadedCatalogWallpapers(
                inferredDownloadedCatalogWallpapersFromDisk(),
                preserving: inMemory
            )
            return
        }

        let existing = loaded.compactMap { item -> DownloadedCatalogWallpaper? in
            guard FileManager.default.fileExists(atPath: item.localURL.path) else {
                return nil
            }

            let repairedPreviewPath = item.localPreviewPath.flatMap { localPreviewPath in
                FileManager.default.fileExists(atPath: localPreviewPath) ? localPreviewPath : nil
            }

            return DownloadedCatalogWallpaper(
                id: item.id,
                wallpaperID: item.wallpaperID,
                title: item.title,
                category: item.category,
                attribution: item.attribution,
                previewImageURL: item.previewImageURL,
                localPreviewPath: repairedPreviewPath,
                sourcePageURL: item.sourcePageURL,
                localPath: item.localPath,
                downloadedAt: item.downloadedAt
            )
        }
        var sorted = existing.sorted(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
        if sorted.isEmpty {
            sorted = inferredDownloadedCatalogWallpapersFromDisk()
        }
        sorted = mergeDownloadedCatalogWallpapers(sorted, preserving: inMemory)
        downloadedCatalogWallpapers = sorted

        if existing.count != loaded.count {
            try? persistDownloadedCatalogWallpapers(sorted)
        }
    }

    private func mergeDownloadedCatalogWallpapers(
        _ loaded: [DownloadedCatalogWallpaper],
        preserving inMemory: [DownloadedCatalogWallpaper]
    ) -> [DownloadedCatalogWallpaper] {
        var merged = loaded
        let loadedIDs = Set(loaded.map(\.id))
        merged.append(contentsOf: inMemory.filter { item in
            !loadedIDs.contains(item.id)
                && FileManager.default.fileExists(atPath: item.localURL.path)
        })
        return merged.sorted(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
    }

    private func refreshCatalogIfNeeded(force: Bool = false) {
        if catalogRefreshTask != nil {
            return
        }
        if !force,
           let lastCatalogRefreshAt,
           Date().timeIntervalSince(lastCatalogRefreshAt) < 60 * 60 * 6 {
            return
        }

        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            catalogIsRefreshing = true
            defer {
                catalogIsRefreshing = false
                catalogRefreshTask = nil
            }

            do {
                let fetched = try await catalogProvider.fetchCatalog { [weak self] partial in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.catalogWallpapers = partial
                        if let selectedCatalogWallpaper = self.selectedCatalogWallpaper {
                            self.selectedCatalogWallpaper = partial.first(where: { $0.id == selectedCatalogWallpaper.id })
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                guard !fetched.isEmpty else {
                    catalogWallpapers = []
                    selectedCatalogWallpaper = nil
                    statusMessage = "Wallpaper catalog returned no wallpapers."
                    lastCatalogRefreshAt = Date()
                    return
                }
                catalogWallpapers = fetched
                if let selectedCatalogWallpaper {
                    self.selectedCatalogWallpaper = fetched.first(where: { $0.id == selectedCatalogWallpaper.id })
                }
                statusMessage = nil
                lastCatalogRefreshAt = Date()
            } catch {
                guard !Task.isCancelled else { return }
                if catalogWallpapers.isEmpty {
                    selectedCatalogWallpaper = nil
                }
                statusMessage = "Wallpaper catalog unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func downloadCatalogVideo(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let existing = downloadedCatalogWallpapers.first(where: { $0.wallpaperID == wallpaper.id }),
           hasUsableCatalogFile(at: existing.localURL) {
            return existing.localURL.standardizedFileURL
        } else if let existing = downloadedCatalogWallpapers.first(where: { $0.wallpaperID == wallpaper.id }) {
            try? FileManager.default.removeItem(at: existing.localURL)
        }

        var lastError: Error?

        if isMoeWallsWallpaper(wallpaper) {
            do {
                if let detailSource = try await moeWallsDetailDownloadSource(for: wallpaper) {
                    return try await downloadCatalogSource(detailSource, for: wallpaper)
                }
            } catch {
                lastError = error
            }
        }

        do {
            let sources = try await catalogSources(for: wallpaper)

            for source in sources {
                do {
                    // Try the direct CDN URL first. This is much faster than
                    // opening a WKWebView and still works with browser-style
                    // headers/cookies for protected catalog hosts.
                    return try await downloadCatalogSource(source, for: wallpaper)
                } catch {
                    lastError = error
                }
            }
        } catch {
            lastError = error
        }

        // MoeWalls' browser flow remains a compatibility fallback for pages
        // whose direct CDN URL requires a token generated by JavaScript.
        if isMoeWallsWallpaper(wallpaper),
           let pageURL = wallpaper.sourcePageURL {
            do {
                return try await downloadMoeWallsVideo(for: wallpaper, pageURL: pageURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.badURL)
    }

    private func moeWallsDetailDownloadSource(for wallpaper: CatalogWallpaper) async throws -> CatalogVideoSource? {
        guard let pageURL = wallpaper.sourcePageURL else { return nil }
        guard let moeWallsSource = catalogProvider as? MoeWallsSource else { return nil }

        let details = try await moeWallsSource.fetchDetails(pageURL: pageURL)
        guard details.hasExplicitPlayableSource == true,
              let downloadURL = details.downloadURL else {
            return nil
        }
        let width = details.resolution?.width ?? 0
        let height = details.resolution?.height ?? 0
        return CatalogVideoSource(url: downloadURL, width: width, height: height)
    }

    private func downloadCatalogSource(_ source: CatalogVideoSource, for wallpaper: CatalogWallpaper) async throws -> URL {
        let widthLabel = source.width > 0 ? String(source.width) : "auto"
        let heightLabel = source.height > 0 ? String(source.height) : "auto"
        let directory = try catalogDirectoryURL()
        let fileStem = "\(wallpaper.id)-\(widthLabel)x\(heightLabel)"
        let cachedDestination = directory.appendingPathComponent(
            "\(fileStem).\(downloadFileExtension(for: source.url))"
        )

        if hasUsableCatalogFile(at: cachedDestination) {
            return cachedDestination.standardizedFileURL
        } else if FileManager.default.fileExists(atPath: cachedDestination.path) {
            try? FileManager.default.removeItem(at: cachedDestination)
        }

        let useBrowserStyleHeaders = shouldUseBrowserStyleHeaders(for: source.url, wallpaper: wallpaper)
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 45
        request.setValue(
            useBrowserStyleHeaders
                ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
                : "AuraFlow/1.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if useBrowserStyleHeaders {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if let sourcePageURL = wallpaper.sourcePageURL {
            request.setValue(sourcePageURL.absoluteString, forHTTPHeaderField: "Referer")
            if source.url.host?.contains("moewalls.com") == true,
               let origin = catalogOriginHeaderValue(for: sourcePageURL) {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
        }

        let configuration = useBrowserStyleHeaders
            ? URLSessionConfiguration.ephemeral
            : URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if useBrowserStyleHeaders {
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
        }
        let session = URLSession(configuration: configuration)

        let (temporaryURL, response) = try await CatalogFileDownloader.download(
            request: request,
            session: session
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CatalogDownloadError.badStatus(url: source.url, statusCode: httpResponse.statusCode)
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/") || mimeType.contains("html") {
            throw CatalogDownloadError.htmlResponse(url: source.url)
        }
        guard isLikelyCatalogMediaResponse(response: response, sourceURL: source.url) else {
            throw CatalogDownloadError.unsupportedResponse(url: source.url)
        }

        let destination = directory.appendingPathComponent(
            "\(fileStem).\(downloadFileExtension(for: source.url, response: response))"
        )

        if destination != cachedDestination {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        return destination.standardizedFileURL
    }

    private func downloadMoeWallsVideo(for wallpaper: CatalogWallpaper, pageURL: URL) async throws -> URL {
        let resolver = await MainActor.run {
            let resolver = MoeWallsBrowserResolver()
            return resolver
        }
        let destination = try catalogDirectoryURL().appendingPathComponent("\(wallpaper.id).mp4")
        try? FileManager.default.removeItem(at: destination)
        let downloadedURL = try await resolver.downloadWallpaper(from: pageURL, to: destination)
        guard await isPreviewPlayableVideo(at: downloadedURL) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw URLError(.cannotDecodeContentData)
        }
        return downloadedURL
    }

    private func catalogSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        if !wallpaper.sources.isEmpty {
            var ordered = wallpaper.sources
            if let preferred = preferredSource(for: wallpaper),
               let preferredIndex = ordered.firstIndex(of: preferred),
               preferredIndex != 0 {
                ordered.remove(at: preferredIndex)
                ordered.insert(preferred, at: 0)
            }
            return ordered
        }

        let resolvedURL = try await catalogProvider.resolveDownloadURL(for: wallpaper)
        return [CatalogVideoSource(url: resolvedURL, width: 0, height: 0)]
    }

    private func downloadFileExtension(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.isEmpty {
            return "mp4"
        }
        return ext
    }

    private func downloadFileExtension(for url: URL, response: URLResponse) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownExtensions = Set([
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ])
        if knownExtensions.contains(ext) {
            return ext
        }

        switch response.mimeType?.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/webp": return "webp"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }

    private func isLikelyCatalogMediaResponse(response: URLResponse, sourceURL: URL) -> Bool {
        if let mime = response.mimeType?.lowercased() {
            if mime.hasPrefix("video/") || mime.hasPrefix("image/")
                || mime == "application/octet-stream" || mime == "binary/octet-stream" {
                return true
            }
            if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") {
                return false
            }
        }
        let ext = sourceURL.pathExtension.lowercased()
        return [
            "mp4", "webm", "mov", "m4v", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ].contains(ext)
    }

    private func hasUsableCatalogFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    private func isMoeWallsWallpaper(_ wallpaper: CatalogWallpaper) -> Bool {
        wallpaper.attribution == "MoeWalls" || wallpaper.sourcePageURL?.host?.contains("moewalls.com") == true
    }

    private func preferredSource(for wallpaper: CatalogWallpaper) -> CatalogVideoSource? {
        guard !wallpaper.sources.isEmpty else { return nil }
        guard wallpaper.sources.count > 1 else { return wallpaper.sources.first }

        let nativeSources = wallpaper.sources.filter { source in
            isNativePlaybackContainer(source.url)
        }
        let candidateSources = nativeSources.isEmpty ? wallpaper.sources : nativeSources

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let targetWidth = Int(screenFrame.width)
        let targetHeight = Int(screenFrame.height)

        let largerOrEqual = candidateSources.filter { source in
            source.width >= targetWidth && source.height >= targetHeight
        }

        if let best = largerOrEqual.min(by: { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }) {
            return best
        }

        return candidateSources.max(by: { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        })
    }

    private func isNativePlaybackContainer(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v":
            return true
        default:
            return false
        }
    }

    private func shouldUseBrowserStyleHeaders(for sourceURL: URL, wallpaper: CatalogWallpaper) -> Bool {
        guard isMoeWallsWallpaper(wallpaper) else {
            return false
        }

        guard let host = sourceURL.host?.lowercased() else {
            return false
        }

        return host.contains("moewalls.com")
            || host.contains("media.moewalls.com")
            || host.contains("cdn.moewalls.com")
    }

    private func catalogDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func optimizedVideosDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("OptimizedVideos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func downloadedCatalogManifestURL() throws -> URL {
        try catalogDirectoryURL().appendingPathComponent("downloaded-catalog.json")
    }

    private func catalogPreviewImagesDirectoryURL() throws -> URL {
        let directory = try catalogDirectoryURL().appendingPathComponent("PreviewImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localPreviewImageURL(for previewKey: String) throws -> URL {
        try catalogPreviewImagesDirectoryURL().appendingPathComponent("\(previewKey).jpg")
    }

    private func previewImageKey(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.deletingPathExtension().lastPathComponent
    }

    private func existingLocalPreviewImageURL(for previewKey: String) -> URL? {
        guard let url = try? localPreviewImageURL(for: previewKey) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func scheduleLocalPreviewImageGeneration(
        for videoURL: URL,
        legacyWallpaperID: String?,
        wallpaperID: String
    ) {
        let previewKey = previewImageKey(for: videoURL)

        guard existingLocalPreviewImageURL(for: previewKey) == nil else { return }
        guard let destinationURL = try? localPreviewImageURL(for: previewKey) else { return }
        let legacyURL = legacyWallpaperID.flatMap { existingLocalPreviewImageURL(for: $0) }
        let requestedCacheGeneration = cacheGeneration

        Task.detached(priority: .utility) { [weak self] in
            guard let generatedURL = Self.generateLocalPreviewImage(
                for: videoURL,
                destinationURL: destinationURL,
                legacyURL: legacyURL
            ) else {
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.cacheGeneration == requestedCacheGeneration else {
                    if generatedURL.standardizedFileURL == destinationURL.standardizedFileURL {
                        try? FileManager.default.removeItem(at: generatedURL)
                    }
                    return
                }
                self.storeGeneratedPreview(generatedURL, wallpaperID: wallpaperID)
            }
        }
    }

    nonisolated private static func generateLocalPreviewImage(
        for videoURL: URL,
        destinationURL: URL,
        legacyURL: URL?
    ) -> URL? {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        if let legacyURL {
            do {
                try FileManager.default.copyItem(at: legacyURL, to: destinationURL)
                return destinationURL
            } catch {
                return legacyURL
            }
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 960, height: 540)

        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            return nil
        }
    }

    private func storeGeneratedPreview(_ previewURL: URL, wallpaperID: String) {
        var updated = downloadedCatalogWallpapers
        guard let index = updated.firstIndex(where: { $0.wallpaperID == wallpaperID }) else {
            return
        }
        let current = updated[index]
        guard current.localPreviewPath != previewURL.path else { return }

        updated[index] = DownloadedCatalogWallpaper(
            id: current.id,
            wallpaperID: current.wallpaperID,
            title: current.title,
            category: current.category,
            attribution: current.attribution,
            previewImageURL: current.previewImageURL,
            localPreviewPath: previewURL.path,
            sourcePageURL: current.sourcePageURL,
            localPath: current.localPath,
            downloadedAt: current.downloadedAt
        )
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)
    }

    private func registerDownloadedCatalogWallpaper(for wallpaper: CatalogWallpaper, localURL: URL) {
        let normalizedPath = localURL.standardizedFileURL.path
        let previewKey = previewImageKey(for: localURL)
        let localPreviewPath = existingLocalPreviewImageURL(for: previewKey)?.path
        var updated = downloadedCatalogWallpapers

        let entry = DownloadedCatalogWallpaper(
            id: wallpaper.id,
            wallpaperID: wallpaper.id,
            title: wallpaper.title,
            category: wallpaper.category,
            attribution: wallpaper.attribution,
            previewImageURL: wallpaper.previewImageURL,
            localPreviewPath: localPreviewPath,
            sourcePageURL: wallpaper.sourcePageURL,
            localPath: normalizedPath,
            downloadedAt: Date()
        )

        if let existingIndex = updated.firstIndex(where: { $0.id == entry.id || $0.localPath == entry.localPath }) {
            updated[existingIndex] = entry
        } else {
            updated.append(entry)
        }

        updated.sort(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)
        if localPreviewPath == nil {
            scheduleLocalPreviewImageGeneration(
                for: localURL,
                legacyWallpaperID: wallpaper.id,
                wallpaperID: wallpaper.id
            )
        }
    }

    private func persistDownloadedCatalogWallpapers(_ wallpapers: [DownloadedCatalogWallpaper]) throws {
        let data = try JSONEncoder().encode(wallpapers)
        try data.write(to: try downloadedCatalogManifestURL(), options: .atomic)
    }

    private func syncDownloadedCatalogWallpaperAfterApply(
        wallpaperID: String,
        requestedURL: URL,
        previousVideoPath: String?
    ) {
        guard let appliedURL = appliedVideoURL?.standardizedFileURL else {
            return
        }
        let appliedPath = appliedURL.path
        if let previousVideoPath, previousVideoPath == appliedPath {
            return
        }

        var updated = downloadedCatalogWallpapers
        guard let index = updated.firstIndex(where: { $0.wallpaperID == wallpaperID }) else {
            return
        }

        let normalizedRequestedPath = requestedURL.standardizedFileURL.path
        let normalizedExistingPath = updated[index].localURL.standardizedFileURL.path
        if normalizedExistingPath == appliedPath {
            return
        }

        let normalizedPathToStore: String
        if FileManager.default.fileExists(atPath: appliedPath) {
            normalizedPathToStore = appliedPath
        } else {
            normalizedPathToStore = normalizedRequestedPath
        }

        let current = updated[index]
        updated[index] = DownloadedCatalogWallpaper(
            id: current.id,
            wallpaperID: current.wallpaperID,
            title: current.title,
            category: current.category,
            attribution: current.attribution,
            previewImageURL: current.previewImageURL,
            localPreviewPath: current.localPreviewPath,
            sourcePageURL: current.sourcePageURL,
            localPath: normalizedPathToStore,
            downloadedAt: current.downloadedAt
        )
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)
    }

    private func inferredDownloadedCatalogWallpapersFromDisk() -> [DownloadedCatalogWallpaper] {
        guard let directory = try? catalogDirectoryURL() else {
            return []
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let validExtensions = Set([
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ])
        let ignoredNames: Set<String> = [
            "waifu-anime-cache.json",
            "waifu-download-links.json",
            "downloaded-catalog.json",
        ]

        let mapped: [DownloadedCatalogWallpaper] = files.compactMap { fileURL in
            let name = fileURL.lastPathComponent
            guard !ignoredNames.contains(name) else { return nil }
            let ext = fileURL.pathExtension.lowercased()
            guard validExtensions.contains(ext) else { return nil }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let downloadedAt = values?.contentModificationDate ?? Date()
            let fileName = fileURL.deletingPathExtension().lastPathComponent

            return DownloadedCatalogWallpaper(
                id: "local-\(fileName)",
                wallpaperID: "local-\(fileName)",
                title: inferredTitleFromDownloadedFileName(fileName),
                category: "Downloaded",
                attribution: "Catalog Cache",
                previewImageURL: nil,
                localPreviewPath: existingLocalPreviewImageURL(
                    for: previewImageKey(for: fileURL)
                )?.path,
                sourcePageURL: nil,
                localPath: fileURL.standardizedFileURL.path,
                downloadedAt: downloadedAt
            )
        }

        return mapped.sorted(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
    }

    private func inferredTitleFromDownloadedFileName(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { part in
                let word = String(part)
                guard let first = word.first else { return word }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func isCatalogWallpaperAlreadyApplied(_ wallpaper: CatalogWallpaper) -> Bool {
        guard let appliedPath = appliedVideoURL?.standardizedFileURL.path else {
            return false
        }
        guard let downloaded = downloadedCatalogWallpapers.first(where: { $0.wallpaperID == wallpaper.id }) else {
            return false
        }
        return downloaded.localURL.standardizedFileURL.path == appliedPath
    }

    private func showSuccessBanner(_ message: String) {
        successBannerTask?.cancel()
        successBannerMessage = message
        alertMessage = nil
        successBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.successBannerMessage == message {
                self?.successBannerMessage = nil
            }
        }
    }

    private func isManagedCacheURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let managedDirectories = [
            try? catalogDirectoryURL(),
            try? optimizedVideosDirectoryURL(),
        ].compactMap { $0?.standardizedFileURL.path }

        return managedDirectories.contains { directoryPath in
            path == directoryPath || path.hasPrefix(directoryPath + "/")
        }
    }

    private func clearCatalogCache() throws {
        let directory = try catalogDirectoryURL()
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }

        downloadedCatalogWallpapers = []
    }

    private func clearOptimizedVideoCache() throws {
        let directory = try optimizedVideosDirectoryURL()
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private func clearRuntimePreviewCache() throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: Self.appSupportDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for entry in entries {
            let name = entry.lastPathComponent
            let isGeneratedStillFrame = name == "last_frame.png"
                || name == "last_frame_source.json"
                || (name.hasPrefix("last_frame_") && name.hasSuffix(".png"))
            if isGeneratedStillFrame {
                try fileManager.removeItem(at: entry)
            }
        }
    }

    private func selectVideoForPreview(_ url: URL, summary: String?) {
        pendingPreviewVideoURL = url
        configurePreview(for: url)
        savePreviewSeed(for: url)
        statusMessage = summary
        alertMessage = nil
    }

    func stageCatalogWallpaperForPreview(_ wallpaper: CatalogWallpaper, localURL: URL) {
        registerDownloadedCatalogWallpaper(for: wallpaper, localURL: localURL)
        selectVideoForPreview(localURL, summary: "Wallpaper downloaded. Press Start to apply.")
    }

    private func applyDownloadedCatalogWallpaperImmediately(_ wallpaper: CatalogWallpaper, localURL: URL) async throws {
        stageCatalogWallpaperForPreview(wallpaper, localURL: localURL)

        let previousVideoPath = appliedVideoURL?.standardizedFileURL.path
        guard !isBusy else {
            throw NativeWallpaperControllerError.unavailable("AuraFlow is busy right now. Try applying the wallpaper again.")
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await startWallpaper(
                using: localURL,
                statusSummary: "Wallpaper downloaded and applied.",
                catalogFastPath: true
            )
            syncDownloadedCatalogWallpaperAfterApply(
                wallpaperID: wallpaper.id,
                requestedURL: localURL,
                previousVideoPath: previousVideoPath
            )
        } catch {
            statusMessage = "Wallpaper downloaded. Press Start to apply."
            throw error
        }
    }

    func selectLocalVideoForPreview(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        scheduleLocalWallpaperImport(for: normalizedURL)

        let hasCurrentWallpaper = isPlaybackActive || isPlaybackPaused
        guard hasCurrentWallpaper else {
            selectVideoForPreview(normalizedURL, summary: "Video loaded into preview. Press Start to apply.")
            return
        }

        applySelectionImmediately(
            normalizedURL,
            failureContext: "change-wallpaper",
            statusSummary: "Wallpaper changed.",
            successMessage: "Wallpaper changed."
        )
    }

    private func scheduleLocalWallpaperImport(for sourceURL: URL) {
        guard !isManagedCacheURL(sourceURL) else { return }

        localWallpaperImportTask?.cancel()
        let requestedGeneration = localWallpaperImportGeneration
        localWallpaperImportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var copiedResult: (url: URL, created: Bool)?

            do {
                copiedResult = try await copyLocalWallpaperToCatalog(from: sourceURL)
                try Task.checkCancellation()
                guard requestedGeneration == localWallpaperImportGeneration else {
                    if copiedResult?.created == true {
                        try? FileManager.default.removeItem(at: copiedResult!.url)
                    }
                    return
                }
                if let copiedResult {
                    registerLocalWallpaperCopy(
                        originalURL: sourceURL,
                        copiedURL: copiedResult.url
                    )
                }
            } catch is CancellationError {
                if copiedResult?.created == true {
                    try? FileManager.default.removeItem(at: copiedResult!.url)
                }
            } catch {
                if copiedResult?.created == true {
                    try? FileManager.default.removeItem(at: copiedResult!.url)
                }
                guard requestedGeneration == localWallpaperImportGeneration else { return }
                statusMessage = "Wallpaper selected, but its copy could not be saved."
            }

            if requestedGeneration == localWallpaperImportGeneration {
                localWallpaperImportTask = nil
            }
        }
    }

    private func copyLocalWallpaperToCatalog(from sourceURL: URL) async throws -> (url: URL, created: Bool) {
        guard !isManagedCacheURL(sourceURL) else {
            return (sourceURL, false)
        }

        if let existing = downloadedCatalogWallpapers.first(where: {
            isImportedLocalWallpaper($0, from: sourceURL)
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }) {
            return (existing.localURL.standardizedFileURL, false)
        }

        let directory = try catalogDirectoryURL()
        let extensionName = sourceURL.pathExtension.isEmpty
            ? "mp4"
            : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent(
            "local-\(UUID().uuidString.lowercased()).\(extensionName)"
        )

        do {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }.value
            try Task.checkCancellation()
            return (destination.standardizedFileURL, true)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func isImportedLocalWallpaper(
        _ wallpaper: DownloadedCatalogWallpaper,
        from sourceURL: URL
    ) -> Bool {
        guard wallpaper.attribution == "This Mac",
              let originalURL = wallpaper.sourcePageURL,
              originalURL.isFileURL else {
            return false
        }
        return originalURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }

    private func registerLocalWallpaperCopy(originalURL: URL, copiedURL: URL) {
        let normalizedOriginalURL = originalURL.standardizedFileURL
        let normalizedCopiedURL = copiedURL.standardizedFileURL
        let previewKey = previewImageKey(for: normalizedCopiedURL)
        let localPreviewPath = existingLocalPreviewImageURL(for: previewKey)?.path
        var updated = downloadedCatalogWallpapers
        let existingIndex = updated.firstIndex {
            isImportedLocalWallpaper($0, from: normalizedOriginalURL)
        }
        let existing = existingIndex.map { updated[$0] }
        let localID = existing?.id ?? "local-\(UUID().uuidString.lowercased())"
        let entry = DownloadedCatalogWallpaper(
            id: localID,
            wallpaperID: existing?.wallpaperID ?? localID,
            title: inferredTitleFromDownloadedFileName(
                normalizedOriginalURL.deletingPathExtension().lastPathComponent
            ),
            category: "Local",
            attribution: "This Mac",
            previewImageURL: nil,
            localPreviewPath: localPreviewPath,
            sourcePageURL: normalizedOriginalURL,
            localPath: normalizedCopiedURL.path,
            downloadedAt: existing?.downloadedAt ?? Date()
        )

        if let existingIndex {
            updated[existingIndex] = entry
        } else {
            updated.append(entry)
        }
        updated.sort(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)

        if localPreviewPath == nil {
            scheduleLocalPreviewImageGeneration(
                for: normalizedCopiedURL,
                legacyWallpaperID: nil,
                wallpaperID: entry.wallpaperID
            )
        }
    }

    private func applySelectionImmediately(
        _ sourceURL: URL,
        failureContext: String,
        statusSummary: String = "Wallpaper started.",
        successMessage: String? = nil,
        catalogFastPath: Bool = false
    ) {
        guard !isBusy else { return }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await startWallpaper(
                    using: sourceURL,
                    statusSummary: statusSummary,
                    catalogFastPath: catalogFastPath
                )
                if let successMessage {
                    showSuccessBanner(successMessage)
                }
            } catch {
                recordBridgeFailure(error, context: failureContext)
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to start: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startWallpaper(
        using sourceURL: URL,
        statusSummary: String,
        catalogFastPath: Bool = false
    ) async throws {
        guard let controller else {
            throw NativeWallpaperControllerError.unavailable("Native wallpaper runtime unavailable.")
        }

        let prepared = catalogFastPath
            ? try await prepareCatalogVideoURLForPlayback(sourceURL)
            : try await prepareVideoURLForPlayback(sourceURL)
        let finalStatus = try await runAsync { try controller.start(videoURL: prepared.url, speed: nil) }

        pendingPreviewVideoURL = nil
        apply(status: finalStatus, refreshPreview: false)
        let configuredPreviewURL = finalStatus.config.video_path.isEmpty
            ? prepared.url
            : URL(fileURLWithPath: finalStatus.config.video_path)
        if previewPlayerURL != configuredPreviewURL.standardizedFileURL {
            configurePreview(for: configuredPreviewURL)
        }
        recordBridgeSuccess()
        statusMessage = prepared.summary ?? statusSummary
        alertMessage = nil
        if showOnLockScreenEnabled {
            do {
                try await runAsync {
                    try controller.syncLockScreenSaver()
                }
            } catch {
                alertMessage = "Wallpaper started, but Lock Screen sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func resolveDownloadedCatalogWallpaperURL(_ wallpaper: DownloadedCatalogWallpaper) async throws -> URL {
        // The file was already downloaded and is managed by the catalog.
        // Compatibility conversion, when needed, belongs to the catalog
        // application path; never re-download a cached WebM/GIF/image just
        // because AVFoundation cannot inspect it directly.
        return wallpaper.localURL.standardizedFileURL
    }

    private func isPreviewPlayableVideo(at url: URL) async -> Bool {
        if url.pathExtension.lowercased() == "gif" {
            return true
        }

        let asset = AVURLAsset(url: url)

        do {
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return playable && !tracks.isEmpty
        } catch {
            return false
        }
    }

    private func configurePreview(for url: URL?) {
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
            self.previewEndObserver = nil
        }
        if let previewStalledObserver {
            NotificationCenter.default.removeObserver(previewStalledObserver)
            self.previewStalledObserver = nil
        }
        previewItemStatusObservation?.invalidate()
        previewItemStatusObservation = nil

        guard let url else {
            previewPlayer?.pause()
            previewPlayer?.replaceCurrentItem(with: nil)
            previewPlayer = nil
            adaptiveGlassAppearance = .default
            return
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.35
        let player: AVPlayer
        if let existingPlayer = previewPlayer {
            player = existingPlayer
            player.pause()
            // Keep one AVPlayer attached to AVPlayerLayer and replace its item
            // directly. Inserting an empty item or swapping player identities can
            // leave the layer displaying its opaque black backing surface.
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
            previewPlayer = player
        }
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = true

        previewItemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak player, weak item] _, _ in
            Task { @MainActor [weak self, weak player, weak item] in
                guard let self, let player, let item else { return }
                guard player.currentItem === item else { return }
                guard item.status == .readyToPlay else { return }
                self.applyPreviewPlaybackRate(to: player)
            }
        }

        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            player.seek(to: .zero)
            Task { @MainActor [weak self] in
                self?.applyPreviewPlaybackRate(to: player)
            }
        }

        previewStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak player, weak item] _ in
            Task { @MainActor [weak self, weak player, weak item] in
                guard let self, let player, let item else { return }
                guard player.currentItem === item else { return }
                self.applyPreviewPlaybackRate(to: player)
            }
        }

        applyPreviewPlaybackRate(to: player)
        scheduleAdaptiveGlassRefresh(for: url)
    }

    private func scheduleAdaptiveGlassRefresh(for url: URL) {
        glassAnalysisTask?.cancel()
        let requestedURL = url.standardizedFileURL
        let requestedScaleMode = scaleMode

        glassAnalysisTask = Task.detached(priority: .utility) { [requestedURL, requestedScaleMode] in
            let appearance = Self.adaptiveGlassAppearance(for: requestedURL, scaleMode: requestedScaleMode)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentURL = self.selectedVideoURL?.standardizedFileURL
                let appliedURL = self.appliedVideoURL?.standardizedFileURL
                let pendingURL = self.pendingPreviewVideoURL?.standardizedFileURL
                guard currentURL == requestedURL || appliedURL == requestedURL || pendingURL == requestedURL else {
                    return
                }
                self.adaptiveGlassAppearance = appearance
            }
        }
    }

    nonisolated static func adaptiveGlassAppearance(for url: URL, scaleMode: WallpaperScaleMode) -> AdaptiveGlassAppearance {
        if WallpaperMediaKind.forURL(url).isStaticImage,
           let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ) {
            return adaptiveGlassAppearance(for: cgImage)
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 240, height: 135)

        let sampleTime: Double
        switch scaleMode {
        case .fill:
            sampleTime = 0.5
        case .fit, .stretch:
            sampleTime = 0.2
        }

        let time = CMTime(seconds: sampleTime, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return .default
        }
        return adaptiveGlassAppearance(for: cgImage)
    }

    nonisolated static func adaptiveGlassAppearance(for cgImage: CGImage) -> AdaptiveGlassAppearance {
        let width = 120
        let height = 68
        guard let pixels = rgbaPixels(from: cgImage, width: width, height: height) else {
            return .default
        }

        let topStats = luminanceStats(
            pixels: pixels,
            width: width,
            height: height,
            region: CGRect(x: 0.26, y: 0.04, width: 0.48, height: 0.10)
        )
        let bottomStats = luminanceStats(
            pixels: pixels,
            width: width,
            height: height,
            region: CGRect(x: 0.08, y: 0.80, width: 0.84, height: 0.16)
        )
        // Text is one visual system across the app. Sample the three places
        // where glass controls actually live, then choose the tone with the
        // best worst-case contrast. A full-frame average is misleading for a
        // bright sky beside a dark subject and was the source of the old
        // black-Speed/white-buttons mismatch.
        let sharedTextRegions = [
            textLuminanceStats(
                pixels: pixels,
                width: width,
                height: height,
                region: regionFromTop(CGRect(x: 0.20, y: 0.02, width: 0.60, height: 0.18))
            ),
            textLuminanceStats(
                pixels: pixels,
                width: width,
                height: height,
                region: regionFromTop(CGRect(x: 0.05, y: 0.76, width: 0.90, height: 0.22))
            ),
            textLuminanceStats(
                pixels: pixels,
                width: width,
                height: height,
                region: regionFromTop(CGRect(x: 0.08, y: 0.18, width: 0.84, height: 0.58))
            ),
        ]
        let sharedTextTone = textTone(for: sharedTextRegions)

        let topProtection = protectionLevel(for: topStats)
        let bottomProtection = protectionLevel(for: bottomStats)

        return AdaptiveGlassAppearance(
            topGlassAlpha: 1.0 - (0.08 * topProtection),
            bottomGlassAlpha: 1.0 - (0.10 * bottomProtection),
            topProtectionOverlayOpacity: 0.016 * topProtection,
            bottomProtectionOverlayOpacity: 0.020 * bottomProtection,
            bottomButtonProtectionOpacity: 0.014 * bottomProtection,
            bottomButtonHighlightOpacity: max(0.018, 0.055 - (0.040 * bottomProtection)),
            topTextTone: sharedTextTone,
            bottomTextTone: sharedTextTone,
            centerTextTone: sharedTextTone
        )
    }

    nonisolated private static func regionFromTop(_ region: CGRect) -> CGRect {
        CGRect(
            x: region.minX,
            y: 1.0 - region.maxY,
            width: region.width,
            height: region.height
        )
    }

    nonisolated private static func textTone(for stats: TextLuminanceStats) -> AdaptiveTextTone {
        let darkBackground = (stats.lowerQuartile * 0.70) + (stats.median * 0.30)
        let lightBackground = (stats.upperQuartile * 0.70) + (stats.median * 0.30)
        let darkContrast = (darkBackground + 0.05) / 0.05
        let lightContrast = 1.05 / (lightBackground + 0.05)

        // A bright highlight such as a moon must not force black text over a
        // mostly dark panel. The reverse protects black text on mostly white
        // snow or sky.
        if stats.darkCoverage >= 0.36, stats.lightCoverage < 0.36 {
            return .light
        }
        if stats.lightCoverage >= 0.36, stats.darkCoverage < 0.36 {
            return .dark
        }

        return lightContrast > darkContrast ? .light : .dark
    }

    nonisolated private static func textTone(for regions: [TextLuminanceStats]) -> AdaptiveTextTone {
        guard !regions.isEmpty else { return .light }

        let worstDarkContrast = regions
            .map { textContrast(for: .dark, stats: $0) }
            .min() ?? 0.0
        let worstLightContrast = regions
            .map { textContrast(for: .light, stats: $0) }
            .min() ?? 0.0

        return worstLightContrast > worstDarkContrast ? .light : .dark
    }

    nonisolated private static func textContrast(
        for tone: AdaptiveTextTone,
        stats: TextLuminanceStats
    ) -> CGFloat {
        switch tone {
        case .dark:
            let darkBackground = (stats.lowerQuartile * 0.70) + (stats.median * 0.30)
            return (darkBackground + 0.05) / 0.05
        case .light:
            let lightBackground = (stats.upperQuartile * 0.70) + (stats.median * 0.30)
            return 1.05 / (lightBackground + 0.05)
        }
    }

    nonisolated private static func protectionLevel(for stats: LuminanceStats) -> CGFloat {
        let bright = normalized(stats.mean, lower: 0.72, upper: 0.96)
        let flat = 1.0 - normalized(stats.standardDeviation, lower: 0.07, upper: 0.24)
        let protection = bright * (0.35 + (flat * 0.65))
        return min(max(protection, 0.0), 1.0)
    }

    nonisolated private static func normalized(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0.0), 1.0)
    }

    nonisolated private static func rgbaPixels(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    nonisolated private static func luminanceStats(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: CGRect
    ) -> LuminanceStats {
        let minX = max(Int(CGFloat(width) * region.minX), 0)
        let maxX = min(Int(CGFloat(width) * region.maxX), width)
        let minY = max(Int(CGFloat(height) * region.minY), 0)
        let maxY = min(Int(CGFloat(height) * region.maxY), height)

        var luminanceValues: [CGFloat] = []
        luminanceValues.reserveCapacity(max((maxX - minX) * (maxY - minY), 1))

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = ((y * width) + x) * 4
                let red = CGFloat(pixels[offset]) / 255.0
                let green = CGFloat(pixels[offset + 1]) / 255.0
                let blue = CGFloat(pixels[offset + 2]) / 255.0
                let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                luminanceValues.append(luminance)
            }
        }

        guard !luminanceValues.isEmpty else {
            return LuminanceStats(mean: 0.0, standardDeviation: 0.0)
        }

        let mean = luminanceValues.reduce(0, +) / CGFloat(luminanceValues.count)
        let variance = luminanceValues.reduce(0) { partialResult, value in
            let delta = value - mean
            return partialResult + (delta * delta)
        } / CGFloat(luminanceValues.count)

        return LuminanceStats(mean: mean, standardDeviation: sqrt(variance))
    }

    nonisolated private static func textLuminanceStats(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: CGRect
    ) -> TextLuminanceStats {
        let minX = max(Int(CGFloat(width) * region.minX), 0)
        let maxX = min(Int(CGFloat(width) * region.maxX), width)
        let minY = max(Int(CGFloat(height) * region.minY), 0)
        let maxY = min(Int(CGFloat(height) * region.maxY), height)

        var luminanceValues: [CGFloat] = []
        luminanceValues.reserveCapacity(max((maxX - minX) * (maxY - minY), 1))

        guard minX < maxX, minY < maxY else {
            return .default
        }

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = ((y * width) + x) * 4
                let red = linearizeSRGB(CGFloat(pixels[offset]) / 255.0)
                let green = linearizeSRGB(CGFloat(pixels[offset + 1]) / 255.0)
                let blue = linearizeSRGB(CGFloat(pixels[offset + 2]) / 255.0)
                luminanceValues.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }

        guard !luminanceValues.isEmpty else {
            return .default
        }

        luminanceValues.sort()
        let darkCount = luminanceValues.reduce(into: 0) { count, luminance in
            if luminance < 0.18 { count += 1 }
        }
        let lightCount = luminanceValues.reduce(into: 0) { count, luminance in
            if luminance > 0.65 { count += 1 }
        }

        return TextLuminanceStats(
            lowerQuartile: percentile(luminanceValues, at: 0.25),
            median: percentile(luminanceValues, at: 0.50),
            upperQuartile: percentile(luminanceValues, at: 0.75),
            darkCoverage: CGFloat(darkCount) / CGFloat(luminanceValues.count),
            lightCoverage: CGFloat(lightCount) / CGFloat(luminanceValues.count)
        )
    }

    nonisolated private static func linearizeSRGB(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    nonisolated private static func percentile(_ values: [CGFloat], at fraction: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0.0 }
        let clampedFraction = min(max(fraction, 0.0), 1.0)
        let index = Int((CGFloat(values.count - 1) * clampedFraction).rounded())
        return values[min(max(index, 0), values.count - 1)]
    }

    private struct LuminanceStats {
        let mean: CGFloat
        let standardDeviation: CGFloat
    }

    private struct TextLuminanceStats {
        let lowerQuartile: CGFloat
        let median: CGFloat
        let upperQuartile: CGFloat
        let darkCoverage: CGFloat
        let lightCoverage: CGFloat

        static let `default` = TextLuminanceStats(
            lowerQuartile: 0.18,
            median: 0.18,
            upperQuartile: 0.18,
            darkCoverage: 0.0,
            lightCoverage: 0.0
        )
    }

    private func previewPlaybackRate() -> Float {
        Float(max(0.1, min(playbackSpeed, 4.0)))
    }

    private func statusIndicatesActivePlayback(_ status: ControlStatus) -> Bool {
        let paused = status.paused ?? false
        let healthSuspicious = status.health?.suspicious ?? false
        return status.running && !paused && !healthSuspicious
    }

    nonisolated static func previewPlaybackNeedsRestart(
        currentRate: Float,
        desiredRate: Float,
        timeControlStatus: AVPlayer.TimeControlStatus
    ) -> Bool {
        timeControlStatus != .playing || abs(currentRate - desiredRate) > 0.001
    }

    private func applyPreviewPlaybackRate(to player: AVPlayer) {
        guard !previewRenderingSuspended else { return }
        let rate = previewPlaybackRate()
        guard Self.previewPlaybackNeedsRestart(
            currentRate: player.rate,
            desiredRate: rate,
            timeControlStatus: player.timeControlStatus
        ) else {
            return
        }
        player.playImmediately(atRate: rate)
    }

    private func syncPreviewPlaybackRate() {
        guard let previewPlayer else { return }
        applyPreviewPlaybackRate(to: previewPlayer)
    }

    func suspendPreviewRenderingForWindowDrag() {
        guard !previewRenderingSuspended else { return }
        guard let previewPlayer else { return }
        previewRenderingSuspended = true
        suspendedPreviewRate = previewPlayer.rate
        previewPlayer.pause()
    }

    func resumePreviewRenderingAfterWindowDrag() {
        guard previewRenderingSuspended else { return }
        previewRenderingSuspended = false
        suspendedPreviewRate = nil
        syncPreviewPlaybackRate()
    }

    private func startFromAutostartIfNeeded(using status: ControlStatus) async {
        guard !isShuttingDown else { return }
        guard let controller else { return }
        guard !didAttemptAutostartOnLaunch else { return }
        didAttemptAutostartOnLaunch = true

        let autostart = status.autostart ?? status.config.autostart ?? false
        guard autostart else { return }
        guard !status.running else { return }
        guard !status.config.video_path.isEmpty else { return }

        do {
            let updatedStatus = try await runAsync {
                try controller.start(videoURL: nil, speed: nil)
            }
            apply(status: updatedStatus)
            recordBridgeSuccess()
            statusMessage = "Launch at login: wallpaper started."
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "autostart-start")
            if bridgeFailureCount < bridgeFailureThreshold {
                alertMessage = "Launch at login error: \(error.localizedDescription)"
            }
        }
    }

    private func evaluateStatusContract(
        _ status: ControlStatus,
        backgroundUpdate: Bool
    ) {
        guard let version = status.contract_version else { return }
        guard version < expectedStatusContractVersion else { return }

        daemonSuspiciousPolls = max(daemonSuspiciousPolls, daemonSuspiciousThreshold)
        let message = "Control contract mismatch (expected \(expectedStatusContractVersion), got \(version))."
        if !backgroundUpdate {
            alertMessage = message
        } else {
            statusMessage = "Daemon contract warning."
        }
    }

    private func evaluateDaemonHealth(
        _ health: DaemonHealth?,
        backgroundUpdate: Bool
    ) {
        guard let health else {
            daemonSuspiciousPolls = 0
            lowPowerAutoPauseActive = false
            fullscreenAutoPauseActive = false
            return
        }

        let autoPausedForLowPower = health.auto_paused_for_low_power ?? false
        if autoPausedForLowPower && !lowPowerAutoPauseActive {
            lowPowerAutoPauseActive = true
            statusMessage = "Low Power Mode: wallpaper paused automatically."
        } else if !autoPausedForLowPower && lowPowerAutoPauseActive {
            lowPowerAutoPauseActive = false
            statusMessage = "Low Power Mode off: wallpaper resumed."
        }

        let autoPausedForFullscreen = health.auto_paused_for_fullscreen ?? false
        if autoPausedForFullscreen && !fullscreenAutoPauseActive {
            fullscreenAutoPauseActive = true
            statusMessage = "Fullscreen app detected: wallpaper paused."
        } else if !autoPausedForFullscreen && fullscreenAutoPauseActive {
            fullscreenAutoPauseActive = false
            statusMessage = "Fullscreen app closed: wallpaper resumed."
        }

        let suspicious = health.suspicious ?? false
        if suspicious {
            daemonSuspiciousPolls += 1
            if daemonSuspiciousPolls == daemonSuspiciousThreshold {
                let reason = normalizedDaemonReason(health.reason)
                let warning = "Daemon warning: \(reason)."
                if backgroundUpdate {
                    statusMessage = warning
                } else {
                    alertMessage = warning
                }
            }
        } else {
            daemonSuspiciousPolls = 0
        }
    }

    private func normalizedDaemonReason(_ reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "unknown issue"
        }
        return trimmed.replacingOccurrences(of: ",", with: ", ")
    }

    private func configuredVideoNeedingCompatibilityNormalization(from status: ControlStatus) -> URL? {
        let path = status.config.video_path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["webm", "mkv"].contains(ext) {
            return url
        }
        return nil
    }

    private func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        healthMonitorTask?.cancel()
        monitoringTask?.cancel()
    }

    private func recordBridgeSuccess() {
        if bridgeFailureCount >= bridgeFailureThreshold {
            statusMessage = "Native wallpaper runtime recovered."
        }
        bridgeFailureCount = 0
    }

    private func recordBridgeFailure(
        _ error: Error,
        context: String,
        surface: Bool = true
    ) {
        bridgeFailureCount += 1
        let description = error.localizedDescription

        if bridgeFailureCount >= bridgeFailureThreshold {
            alertMessage = "Native wallpaper runtime unstable (\(context)): \(description)"
            statusMessage = "Bridge health warning."
            return
        }

        if surface {
            alertMessage = description
        }
    }

    private func runAsync<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
