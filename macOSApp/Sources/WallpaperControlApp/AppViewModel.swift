import AppKit
@_exported import AuraWallpaperCore
import AVKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

private let lockScreenLifecycleLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenLifecycle"
)
private let adaptiveContrastLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "AdaptiveContrast"
)

enum WallpaperLifecycleState: String, Equatable {
    case idle
    case preparing
    case ready
    case paused
    case removing
    case failed
}

private enum WallpaperLifecycleIntent: Equatable {
    case start(URL, resume: Bool)
    case lock(URL)
    case stop(lockScreenOnly: Bool, staticImage: Bool)
    case remove(lockScreenOnly: Bool)

    var name: String {
        switch self {
        case .start: return "start"
        case .lock: return "lock"
        case .stop: return "stop"
        case .remove: return "remove"
        }
    }
}

enum AdaptiveTextTone: Equatable {
    case dark
    case light
}

struct AdaptiveGlassAppearance: Equatable {
    var topGlassAlpha: CGFloat
    var bottomGlassAlpha: CGFloat
    var centerGlassAlpha: CGFloat
    var topProtectionOverlayOpacity: CGFloat
    var bottomProtectionOverlayOpacity: CGFloat
    var centerProtectionOverlayOpacity: CGFloat
    var bottomButtonProtectionOpacity: CGFloat
    var bottomButtonHighlightOpacity: CGFloat
    /// One tone is intentionally shared by every text-bearing surface. The
    /// backing/protection strength can still vary by region, but the text
    /// never changes polarity between a button and a panel.
    var textTone: AdaptiveTextTone

    var topTextTone: AdaptiveTextTone { textTone }
    var bottomTextTone: AdaptiveTextTone { textTone }
    var centerTextTone: AdaptiveTextTone { textTone }

    /// Used only before the first valid frame is available. It intentionally
    /// favors a readable black palette and local light backing instead of
    /// briefly rendering the old white-on-wallpaper palette.
    static let safeFallback = AdaptiveGlassAppearance(
        topGlassAlpha: 0.92,
        bottomGlassAlpha: 0.88,
        centerGlassAlpha: 0.90,
        topProtectionOverlayOpacity: 0.54,
        bottomProtectionOverlayOpacity: 0.62,
        centerProtectionOverlayOpacity: 0.58,
        bottomButtonProtectionOpacity: 0.56,
        bottomButtonHighlightOpacity: 0.018,
        textTone: .dark
    )

    static let `default` = safeFallback
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
    var lockScreenCapabilities: PlatformCapabilities { get }
    func status() throws -> ControlStatus
    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus
    func resume() throws -> ControlStatus
    func stop() throws -> ControlStatus
    func clearWallpaper() throws -> ControlStatus
    func setVideo(_ url: URL) throws -> ControlStatus
    func installLockScreenOnly(videoURL: URL) throws -> ControlStatus
    func prepareLockScreenMedia(videoURL: URL) throws
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
    var lockScreenCapabilities: PlatformCapabilities {
        .legacyMacOS
    }
}

extension WallpaperControlling {
    func installLockScreenOnly(videoURL: URL) throws -> ControlStatus {
        throw NativeWallpaperControllerError.unavailable(
            "Lock Screen-only wallpaper is unavailable."
        )
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
        // Controllers without a native Aerial implementation do not need a
        // separate media cache.
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

    private struct RuntimeBinaryResolution {
        let url: URL
        let didUpdateInstalledCopy: Bool
    }

    private let store: WallpaperRuntimeStore
    private let helperURL: URL
    private let nativeBridgeURL: URL?
    private let lockScreenPlatform: LockScreenPlatformOperating
    private let lifecycleLock = NSRecursiveLock()
    private var nextRuntimeOperationID: UInt64 = 0

    var lockScreenCapabilities: PlatformCapabilities {
        let capabilities = lockScreenPlatform.capabilities
        guard nativeBridgeRequired, nativeBridgeURL == nil else {
            return capabilities
        }
        return PlatformCapabilities(
            platformName: capabilities.platformName,
            minimumMajorOSVersion: capabilities.minimumMajorOSVersion,
            supportsLockScreen: false,
            supportsLockScreenOnly: false,
            supportsSecureLockScreen: false,
            supportsAnimatedMedia: false,
            usesPrivateWallpaperFramework: capabilities.usesPrivateWallpaperFramework,
            availabilityMessage:
                "Native Lock Screen bridge is unavailable in this AuraFlow build."
        )
    }

    init(
        store: WallpaperRuntimeStore = WallpaperRuntimeStore(),
        helperURL: URL? = nil,
        lockScreenSaverInstaller: LockScreenPlatformOperating? = nil,
        nativeBridgeURL: URL? = nil
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
        self.nativeBridgeURL = nativeBridgeURL ?? Self.resolveNativeBridgeURL()
        self.lockScreenPlatform =
            lockScreenSaverInstaller ?? WallpaperPlatformAdapter()
        self.nextRuntimeOperationID =
            store.loadCommand()?.operationID ?? 0
        migrateExistingLaunchAgentIfNeeded()
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

    private static func resolveNativeBridgeURL() -> URL? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            return nil
        }
        let fileManager = FileManager.default
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["AURAFLOW_NATIVE_BRIDGE_PATH"] {
            let overrideURL = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: overrideURL.path) {
                return overrideURL
            }
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/AuraWallpaperNativeBridge")
        )
        if let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent()
        {
            candidates.append(
                executableDirectory
                    .appendingPathComponent("AuraWallpaperNativeBridge")
            )
        }
        if let bundledURL = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return try? installRuntimeBinary(
                from: bundledURL,
                named: "AuraWallpaperNativeBridge"
            ).url
        }

        let runtimeURL = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("Runtime/AuraWallpaperNativeBridge")
        return fileManager.isExecutableFile(atPath: runtimeURL.path)
            ? runtimeURL
            : nil
    }

    private func migrateExistingLaunchAgentIfNeeded() {
        guard store.launchAgentPlistExists(),
              store.loadConfig().autostart == true
        else {
            return
        }

        do {
            try store.enableLaunchAgent(
                helperPath: helperURL.path,
                nativeBridgePath: nativeBridgeURL?.path
            )
        } catch {
            lockScreenLifecycleLogger.error(
                "Could not migrate the existing LaunchAgent: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func installRuntimeHelper(
        from bundledHelperURL: URL
    ) throws -> RuntimeHelperResolution {
        let resolution = try installRuntimeBinary(
            from: bundledHelperURL,
            named: "AuraWallpaperAgent"
        )
        return RuntimeHelperResolution(
            url: resolution.url,
            didUpdateInstalledCopy: resolution.didUpdateInstalledCopy
        )
    }

    private static func installRuntimeBinary(
        from bundledURL: URL,
        named name: String
    ) throws -> RuntimeBinaryResolution {
        let fileManager = FileManager.default
        let runtimeDirectory = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("Runtime", isDirectory: true)
        let installedURL = runtimeDirectory.appendingPathComponent(name)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let shouldCopy: Bool
        if fileManager.fileExists(atPath: installedURL.path) {
            let bundledAttributes = try fileManager.attributesOfItem(atPath: bundledURL.path)
            let installedAttributes = try fileManager.attributesOfItem(atPath: installedURL.path)
            shouldCopy = bundledAttributes[.size] as? NSNumber != installedAttributes[.size] as? NSNumber ||
                bundledAttributes[.modificationDate] as? Date != installedAttributes[.modificationDate] as? Date
        } else {
            shouldCopy = true
        }

        if shouldCopy {
            let temporaryURL = runtimeDirectory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
            try? fileManager.removeItem(at: temporaryURL)
            try fileManager.copyItem(at: bundledURL, to: temporaryURL)
            _ = try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: installedURL.path) {
                _ = try fileManager.replaceItemAt(installedURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: installedURL)
            }
        }

        return RuntimeBinaryResolution(
            url: installedURL,
            didUpdateInstalledCopy: shouldCopy
        )
    }

    private var nativeBridgeRequired: Bool {
        // The selected adapter is the source of truth for private-framework
        // usage. The factory never selects this capability before macOS 26,
        // while injected adapters remain testable on the host OS.
        lockScreenPlatform.capabilities.usesPrivateWallpaperFramework
    }

    private func restartRunningAgentAfterHelperUpdate() throws {
        guard store.processIsAlive(pid: store.loadPID()) else { return }
        let config = store.loadConfig()
        let lockScreenOnlyAgent = store.isLockScreenOnlyAgent()
        guard store.terminateDaemon(
            timeout: 1.0,
            expectedExecutableURL: helperURL
        ).succeeded else {
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
        if store.isWallpaperRestorePending() {
            let restoreStatus = store.restoreWallpaperBackup()
            switch restoreStatus {
            case .restored, .notNeeded:
                store.markWallpaperRestorePending(false)
                store.removeManagedFallback()
            case .failed:
                lockScreenLifecycleLogger.error(
                    "Deferred Desktop wallpaper restore failed; keeping the backup for retry"
                )
            }
            return
        }
        let config = store.loadConfig()
        guard config.video_path.isEmpty,
              config.show_on_lock_screen != true
        else {
            return
        }
        let restoreStatus = store.restoreWallpaperBackup()
        if restoreStatus != .failed {
            store.removeManagedFallback()
        } else {
            _ = WallpaperDesktopPlatform
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
        nextRuntimeOperationID &+= 1
        try store.saveCommand(
            WallpaperRuntimeCommand(
                operationID: nextRuntimeOperationID,
                action: action,
                config: config
            )
        )
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
        var arguments = [
            "--config",
            store.configURL.path,
        ]
        if lockScreenOnly {
            arguments.append("--lock-screen-only")
        }
        if let nativeBridgeURL {
            arguments.append("--native-bridge-path")
            arguments.append(nativeBridgeURL.path)
        }
        task.arguments = arguments
        // The agent is a background runtime process. Do not let an orphaned
        // child keep the app's stdout/stderr pipes open during shutdown or
        // test teardown; runtime diagnostics are written through OSLog.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
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

    private func waitForLockScreenGenerationReady(videoURL: URL) throws {
        // The agent-ready marker only says that its run loop is alive. The
        // selected generation must also be valid and owned by the provider;
        // otherwise the Apply button can report success while the next lock
        // still falls back to the macOS wallpaper.
        guard store.appSupportURL.standardizedFileURL
            == WallpaperRuntimeStore.defaultAppSupportURL()
                .standardizedFileURL
        else {
            return
        }

        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            guard store.processIsAlive(pid: store.loadPID()) else {
                throw NativeWallpaperControllerError.unavailable(
                    "The Lock Screen agent stopped before the wallpaper was ready."
                )
            }

            let status = lockScreenPlatform.lockScreenOnlyStatus(
                videoURL: videoURL
            )
            if status.isReady,
               status.providerRunning,
               store.isLockScreenAgentReady() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw NativeWallpaperControllerError.unavailable(
            "The Lock Screen provider did not confirm the selected wallpaper."
        )
    }

    func status() throws -> ControlStatus {
        store.status()
    }

    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let previousConfig = store.loadConfig()
        let previousPaused = store.isPaused()
        let previousLockScreenOnlySource = store.loadLockScreenOnlySource()
        let previousLockScreenOnlyAgent = store.isLockScreenOnlyAgent()
        let previousPID = store.loadPID()
        let previousAgentWasAlive = store.processIsAlive(pid: previousPID)
        let previousCommand = store.loadCommand()
        let previousHealth = store.loadHealth()

        // Resolve and validate the next configuration before touching the
        // running lock-only agent or any persistent runtime state. A failed
        // file selection must leave the previous working configuration intact.
        var nextConfig = previousConfig
        if let videoURL {
            nextConfig.video_path = videoURL.path
        }
        if let speed {
            nextConfig.playback_speed = speed
        }
        nextConfig = store.normalized(nextConfig)
        guard !nextConfig.video_path.isEmpty else {
            throw NativeWallpaperControllerError.unavailable(
                "No video configured. Choose a wallpaper first."
            )
        }
        guard FileManager.default.fileExists(atPath: nextConfig.video_path) else {
            throw NativeWallpaperControllerError.unavailable(
                "Video file not found: \(nextConfig.video_path)"
            )
        }

        // The desktop backup is the last operation that can fail without
        // requiring a rollback. Keep the old lock-only route alive until this
        // succeeds, otherwise Start could destroy a working Lock Screen mode
        // and then return an error.
        let didCaptureDesktopBackup =
            WallpaperDesktopPlatform.captureCurrentDesktopWallpaperBackup(
                appSupportPath: store.appSupportURL.path
            )
        if !didCaptureDesktopBackup,
           !WallpaperDesktopPlatform.hasWallpaperBackupFiles(
               appSupportPath: store.appSupportURL.path
           ),
           !NSScreen.screens.isEmpty {
            lockScreenLifecycleLogger.error(
                "Desktop wallpaper backup could not be captured before Start"
            )
            throw NativeWallpaperControllerError.unavailable(
                "AuraFlow could not save the current Desktop wallpaper before starting."
            )
        }

        var previousAgentWasStopped = false
        do {
            if previousLockScreenOnlyAgent, previousAgentWasAlive {
                guard store.terminateDaemon(
                    timeout: 2.0,
                    expectedExecutableURL: helperURL
                ).succeeded else {
                    throw NativeWallpaperControllerError.unavailable(
                        "The Lock Screen agent did not stop before starting desktop wallpaper."
                    )
                }
                previousAgentWasStopped = true
            }
            if previousLockScreenOnlyAgent {
                store.removeCommand()
                store.removeHealth()
                store.markLockScreenOnlyAgent(false)
            }

            try store.saveConfig(nextConfig)
            store.clearLockScreenOnlySource()

            // Start keeps the original all-surfaces behavior: the selected
            // wallpaper is applied to the Desktop and Lock Screen together.
            // The separate Lock button uses installLockScreenOnly() and is the
            // only path that leaves the user's Desktop untouched.
            try installLockScreenSaver(using: nextConfig)
            guard lockScreenPlatform.installationConfirmed else {
                throw NativeWallpaperControllerError.unavailable(
                    "macOS did not confirm the Desktop and Lock Screen wallpaper configuration."
                )
            }
            store.markPaused(false)
            try launchAgentIfNeeded()
            try send(.reload, config: nextConfig)
            return store.status()
        } catch {
            let rollbackFailures = rollbackStart(
                previousConfig: previousConfig,
                previousLockScreenOnlySource: previousLockScreenOnlySource,
                previousLockScreenOnlyAgent: previousLockScreenOnlyAgent,
                previousAgentWasAlive: previousAgentWasAlive,
                previousAgentWasStopped: previousAgentWasStopped,
                previousPaused: previousPaused,
                previousPID: previousPID,
                previousCommand: previousCommand,
                previousHealth: previousHealth
            )
            if !rollbackFailures.isEmpty {
                throw NativeWallpaperControllerError.unavailable(
                    "Start failed: \(error.localizedDescription); "
                        + "rollback failed: "
                        + rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    func resume() throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = store.loadConfig()
        if store.isLockScreenOnlyAgent(),
           let sourceURL = store.effectiveLockScreenSourceURL(for: config),
           WallpaperMediaKind.forURL(sourceURL).isStaticImage {
            return store.status()
        }
        store.markPaused(true)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.pause, config: config)
        }
        return store.status()
    }

    func clearWallpaper() throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let currentConfig = store.loadConfig()
        let removingLockScreenOnly =
            store.isLockScreenOnlyAgent()
            || store.loadLockScreenOnlySource() != nil
        if store.processIsAlive(pid: store.loadPID()) {
            try? send(
                removingLockScreenOnly
                    ? .terminatePreservingDesktop
                    : .terminate,
                config: currentConfig
            )
        }
        guard store.terminateDaemon(
            timeout: 2.0,
            expectedExecutableURL: helperURL
        ).succeeded else {
            throw NativeWallpaperControllerError.unavailable(
                "The wallpaper agent did not stop, so its desktop window could not be removed."
            )
        }
        store.removeCommand()
        store.removeHealth()
        if currentConfig.show_on_lock_screen == true
            || lockScreenPlatform.isInstalled {
            if removingLockScreenOnly {
                try lockScreenPlatform
                    .uninstallLockScreenOnlyPreservingCurrentDesktop()
            } else {
                try lockScreenPlatform.uninstall()
            }
        }
        store.clearLockScreenOnlySource()
        store.markLockScreenOnlyAgent(false)
        let restoreStatus: WallpaperRestoreStatus
        if removingLockScreenOnly {
            // Lock-only mode never owns Desktop. The modern uninstaller has
            // already preserved every current Desktop/Space in one wallpaper
            // store update. Reapplying URL backups here would affect only the
            // active Space and would visibly switch the Desktop a second time.
            WallpaperDesktopPlatform.discardWallpaperBackupFiles(
                appSupportPath: store.appSupportURL.path
            )
            store.markWallpaperRestorePending(false)
            restoreStatus = .notNeeded
        } else {
            if WallpaperDesktopPlatform.hasWallpaperBackupFiles(
                appSupportPath: store.appSupportURL.path
            ) {
                store.markWallpaperRestorePending(true)
            }
            restoreStatus = store.restoreWallpaperBackup()
            if restoreStatus != .failed {
                store.markWallpaperRestorePending(false)
            }
        }
        _ = try updateConfig { config in
            config.video_path = ""
        }
        if !removingLockScreenOnly, restoreStatus != .failed {
            store.removeManagedFallback()
        }
        return store.status(
            wallpaperRestored: restoreStatus == .failed ? nil : restoreStatus == .restored,
            wallpaperRestoreStatus: restoreStatus
        )
    }

    func setVideo(_ url: URL) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lockScreenPlatform.capabilities.supportsLockScreenOnly else {
            throw NativeWallpaperControllerError.unavailable(
                lockScreenPlatform.capabilities.availabilityMessage
                    ?? "Lock Screen-only wallpaper is unavailable."
            )
        }
        let normalizedURL = videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            throw NativeWallpaperControllerError.unavailable(
                "Video file not found: \(normalizedURL.path)"
            )
        }

        // Keep the selected source dedicated to Lock Screen. The runtime
        // temporarily promotes its Aerial route only during the lock handoff
        // and restores the user's Desktop route after unlock.

        let previousSource = store.loadLockScreenOnlySource()
        do {
            try installLockScreenSaver(
                videoURL: normalizedURL,
                ensureStillFrame: true,
                lockScreenOnly: true
            )
            guard lockScreenPlatform.installationConfirmed else {
                throw NativeWallpaperControllerError.unavailable(
                    "macOS did not confirm the Lock Screen wallpaper configuration."
                )
            }
            try store.saveLockScreenOnlySource(normalizedURL)
        } catch {
            store.restoreLockScreenOnlySource(previousSource)
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
            guard store.terminateDaemon(
                timeout: 2.0,
                expectedExecutableURL: helperURL
            ).succeeded else {
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
        try waitForLockScreenGenerationReady(videoURL: normalizedURL)
        return store.status()
    }

    func prepareLockScreenMedia(videoURL: URL) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try requireNativeBridgeIfNeeded()
        try lockScreenPlatform.prepareLockScreenMedia(videoURL: videoURL)
    }

    func setSpeed(_ speed: Double) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = try updateConfig { config in
            config.playback_speed = speed
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setInterpolation(_ enabled: Bool) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = try updateConfig { config in
            config.blend_interpolation = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = try updateConfig { config in
            config.pause_on_fullscreen = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setShowOnLockScreen(_ enabled: Bool) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let currentConfig = store.loadConfig()
        var migratedLockScreenOnlySource: URL?
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
                    let didCaptureDesktopBackup =
                        WallpaperDesktopPlatform
                            .captureCurrentDesktopWallpaperBackup(
                                appSupportPath: store.appSupportURL.path
                            )
                    if !didCaptureDesktopBackup,
                       !NSScreen.screens.isEmpty {
                        throw NativeWallpaperControllerError.unavailable(
                            "AuraFlow could not save the current Desktop wallpaper before enabling Lock Screen."
                        )
                    }
                }
                let lockScreenOnlySource = store.loadLockScreenOnlySource()
                let useLockScreenOnly = lockScreenOnlySource != nil
                    && lockScreenPlatform.capabilities.supportsLockScreenOnly
                if let lockScreenOnlySource,
                   !useLockScreenOnly,
                   lockScreenOnlySource.standardizedFileURL == sourceURL {
                    migratedLockScreenOnlySource = lockScreenOnlySource
                }
                try installLockScreenSaver(
                    videoURL: sourceURL,
                    ensureStillFrame: true,
                    lockScreenOnly: useLockScreenOnly
                )
            }
        } else {
            try lockScreenPlatform.uninstall()
            if store.isLockScreenOnlyAgent() {
                if store.processIsAlive(pid: store.loadPID()) {
                    guard store.terminateDaemon(
                        timeout: 2.0,
                        expectedExecutableURL: helperURL
                    ).succeeded else {
                        throw NativeWallpaperControllerError.unavailable(
                            "The Lock Screen agent did not stop after disabling Lock Screen wallpaper."
                        )
                    }
                }
                store.removeCommand()
                store.removeHealth()
                store.markLockScreenOnlyAgent(false)
            }
            store.clearLockScreenOnlySource()
        }

        let config = try updateConfig { config in
            config.show_on_lock_screen = enabled
            if let migratedLockScreenOnlySource {
                config.video_path = migratedLockScreenOnlySource.path
            }
        }
        if migratedLockScreenOnlySource != nil {
            store.clearLockScreenOnlySource()
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func syncLockScreenSaver() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = store.loadConfig()
        var lockScreenOnlySource = store.loadLockScreenOnlySource()
        let supportsLockScreenOnly =
            lockScreenPlatform.capabilities.supportsLockScreenOnly
        let hasUsableLockScreenOnlySource = lockScreenOnlySource.map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true
        let lockScreenEnabled = config.show_on_lock_screen ?? false
        let lockScreenOnlyStatus: LockScreenOnlyGenerationStatus?
        if lockScreenEnabled,
           supportsLockScreenOnly,
           let lockScreenOnlySource,
           hasUsableLockScreenOnlySource {
            lockScreenOnlyStatus = lockScreenPlatform.lockScreenOnlyStatus(
                videoURL: lockScreenOnlySource
            )
        } else {
            lockScreenOnlyStatus = nil
        }
        let lockScreenOnlyProviderAvailable =
            lockScreenOnlyStatus?.providerAvailable == true

        // A stale lock-only agent must not survive merely because the source
        // disappeared or Lock Screen was disabled before this sync reached
        // its normal source guard.
        if store.isLockScreenOnlyAgent(),
           (!lockScreenEnabled
                || !hasUsableLockScreenOnlySource
                || !supportsLockScreenOnly
                || !lockScreenOnlyProviderAvailable) {
            let terminationResult = store.terminateDaemon(
                timeout: 2.0,
                expectedExecutableURL: helperURL
            )
            guard terminationResult.succeeded else {
                throw NativeWallpaperControllerError.unavailable(
                    "The Lock Screen agent did not stop during fallback cleanup (\(terminationResult))."
                )
            }
            store.removeCommand()
            store.removeHealth()
            store.markLockScreenOnlyAgent(false)
        }
        if lockScreenOnlySource != nil,
           (!lockScreenEnabled || !hasUsableLockScreenOnlySource) {
            store.clearLockScreenOnlySource()
            lockScreenOnlySource = nil
        }

        guard lockScreenEnabled,
              let sourceURL = store.effectiveLockScreenSourceURL(for: config),
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            return
        }
        try requireNativeBridgeIfNeeded()
        let useLockScreenOnly = lockScreenOnlySource != nil
            && supportsLockScreenOnly
            && lockScreenOnlyProviderAvailable
        if lockScreenOnlySource != nil, !useLockScreenOnly {
            // A lock-only marker can survive a downgrade or removal of the
            // modern provider. Migrate it through the explicit legacy route
            // so the modern adapter cannot accidentally install a shared
            // wallpaper and alter the user's Desktop.
            if store.isLockScreenOnlyAgent() {
                guard store.terminateDaemon(
                    timeout: 2.0,
                    expectedExecutableURL: helperURL
                ).succeeded else {
                    throw NativeWallpaperControllerError.unavailable(
                        "The Lock Screen agent did not stop during legacy fallback."
                    )
                }
                store.removeCommand()
                store.removeHealth()
                store.markLockScreenOnlyAgent(false)
            }
            _ = try store.ensureCurrentStillFrame(from: sourceURL)
            try lockScreenPlatform.installLegacyLockScreenFallback(
                videoURL: sourceURL,
                restoringLockScreenOnlyVideoURL: lockScreenOnlySource
            )
            if lockScreenOnlySource?.standardizedFileURL == sourceURL {
                _ = try updateConfig { config in
                    config.video_path = sourceURL.path
                }
            }
            store.clearLockScreenOnlySource()
            return
        }
        try installLockScreenSaver(
            videoURL: sourceURL,
            ensureStillFrame: true,
            lockScreenOnly: useLockScreenOnly
        )
    }

    func beginLockScreenPreview() throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = store.loadConfig()
        guard config.show_on_lock_screen ?? false else {
            throw NativeWallpaperControllerError.unavailable(
                "Enable Lock Screen before previewing the transition."
            )
        }
        guard lockScreenCapabilities.supportsSecureLockScreen else {
            throw NativeWallpaperControllerError.unavailable(
                lockScreenCapabilities.availabilityMessage
                    ?? "Lock Screen transition preview is unavailable."
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = store.loadConfig()
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.previewUnlock, config: config)
        }
        return store.status()
    }

    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let config = try updateConfig { config in
            config.scale_mode = mode.commandValue
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setAutostart(_ enabled: Bool) throws -> ControlStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let previousConfig = store.loadConfig()
        var config = previousConfig
        if enabled {
            config = store.normalized(config)
            guard !config.video_path.isEmpty,
                  FileManager.default.fileExists(atPath: config.video_path)
            else {
                throw NativeWallpaperControllerError.unavailable(
                    "Choose an existing video before enabling launch at login."
                )
            }
            config.autostart = true
            config = store.normalized(config)
            // Persist only after validation. If launchctl rejects the new
            // service, restore the previous config so Autostart cannot appear
            // enabled without a registered LaunchAgent.
            try store.saveConfig(config)
            do {
                try store.enableLaunchAgent(
                    helperPath: helperURL.path,
                    nativeBridgePath: nativeBridgeURL?.path
                )
            } catch {
                try? store.saveConfig(previousConfig)
                throw error
            }
        } else {
            config.autostart = false
            config = store.normalized(config)
            try store.saveConfig(config)
            guard store.disableLaunchAgent() else {
                try? store.saveConfig(previousConfig)
                throw NativeWallpaperControllerError.unavailable(
                    "Could not disable the AuraFlow LaunchAgent."
                )
            }
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

    private func rollbackStart(
        previousConfig: ControlConfig,
        previousLockScreenOnlySource: URL?,
        previousLockScreenOnlyAgent: Bool,
        previousAgentWasAlive: Bool,
        previousAgentWasStopped: Bool,
        previousPaused: Bool,
        previousPID: Int?,
        previousCommand: WallpaperRuntimeCommand?,
        previousHealth: DaemonHealth?
    ) -> [String] {
        var rollbackFailures: [String] = []

        do {
            try store.saveConfig(previousConfig)
        } catch {
            rollbackFailures.append("config: \(error.localizedDescription)")
        }
        store.markPaused(previousPaused)
        store.restoreLockScreenOnlySource(previousLockScreenOnlySource)

        // An identity mismatch means the persisted PID no longer belongs to
        // AuraFlow. Never start a replacement while the old process could
        // still be alive; preserve the old marker and leave ownership-safe
        // cleanup to the next explicit recovery attempt.
        if previousLockScreenOnlyAgent,
           previousAgentWasAlive,
           !previousAgentWasStopped {
            store.markLockScreenOnlyAgent(true)
            restoreStartRuntimeMetadata(
                previousCommand: previousCommand,
                previousHealth: previousHealth
            )
            reportStartRollbackFailures(rollbackFailures)
            return rollbackFailures
        }

        // If Start launched a replacement desktop agent before failing, stop
        // it before restoring the previous route. This also prevents the
        // replacement from racing the old lock-only state during rollback.
        let currentPID = store.loadPID()
        if currentPID != previousPID,
           store.processIsAlive(pid: currentPID) {
            if !store.terminateDaemon(
                timeout: 2.0,
                expectedExecutableURL: helperURL
            ).succeeded {
                rollbackFailures.append("replacement agent did not stop")
            }
        }

        if previousLockScreenOnlyAgent {
            guard let sourceURL = previousLockScreenOnlySource
                ?? (previousConfig.video_path.isEmpty
                    ? nil
                    : URL(fileURLWithPath: previousConfig.video_path))
            else {
                store.markLockScreenOnlyAgent(previousAgentWasAlive)
                rollbackFailures.append("previous Lock Screen source is unavailable")
                restoreStartRuntimeMetadata(
                    previousCommand: previousCommand,
                    previousHealth: previousHealth
                )
                reportStartRollbackFailures(rollbackFailures)
                return rollbackFailures
            }

            if previousAgentWasAlive {
                do {
                    try installLockScreenSaver(
                        videoURL: sourceURL,
                        ensureStillFrame: true,
                        lockScreenOnly: true
                    )
                    guard lockScreenPlatform.installationConfirmed else {
                        throw NativeWallpaperControllerError.unavailable(
                            "macOS did not confirm the previous Lock Screen configuration."
                        )
                    }
                    try store.saveLockScreenOnlySource(sourceURL)
                    store.markLockScreenOnlyAgent(false)
                    try launchAgentIfNeeded(lockScreenOnly: true)
                    try send(.reload, config: previousConfig)
                    if previousPaused {
                        try send(.pause, config: previousConfig)
                    } else {
                        store.markPaused(false)
                    }
                } catch {
                    rollbackFailures.append(
                        "previous Lock Screen route: \(error.localizedDescription)"
                    )
                    // Preserve the configured route for the next recovery
                    // attempt when reinstalling the previous route fails.
                    store.markLockScreenOnlyAgent(true)
                    restoreStartRuntimeMetadata(
                        previousCommand: previousCommand,
                        previousHealth: previousHealth
                    )
                }
            } else {
                // Preserve the pre-existing configured/stale state. A failed
                // Start must not silently remove a Lock Screen-only selection.
                store.markLockScreenOnlyAgent(true)
            }
        } else {
            store.clearLockScreenOnlySource()
            store.markLockScreenOnlyAgent(false)
            if previousAgentWasAlive,
               !previousConfig.video_path.isEmpty,
               FileManager.default.fileExists(atPath: previousConfig.video_path) {
                do {
                    try installLockScreenSaver(using: previousConfig)
                    guard lockScreenPlatform.installationConfirmed else {
                        throw NativeWallpaperControllerError.unavailable(
                            "macOS did not confirm the previous wallpaper configuration."
                        )
                    }
                    try launchAgentIfNeeded()
                    try send(.reload, config: previousConfig)
                    if previousPaused {
                        try send(.pause, config: previousConfig)
                    } else {
                        store.markPaused(false)
                    }
                } catch {
                    rollbackFailures.append(
                        "previous wallpaper route: \(error.localizedDescription)"
                    )
                }
            }
        }

        if !previousAgentWasAlive {
            restoreStartRuntimeMetadata(
                previousCommand: previousCommand,
                previousHealth: previousHealth
            )
        }
        reportStartRollbackFailures(rollbackFailures)
        return rollbackFailures
    }

    private func restoreStartRuntimeMetadata(
        previousCommand: WallpaperRuntimeCommand?,
        previousHealth: DaemonHealth?
    ) {
        if let previousCommand {
            try? store.saveCommand(previousCommand)
        } else {
            store.removeCommand()
        }
        if let previousHealth {
            try? store.saveHealth(previousHealth)
        } else {
            store.removeHealth()
        }
    }

    private func reportStartRollbackFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        lockScreenLifecycleLogger.error(
            "Start failed and rollback was incomplete: \(failures.joined(separator: "; "), privacy: .public)"
        )
    }

    private func installLockScreenSaver(
        videoURL: URL,
        ensureStillFrame: Bool,
        lockScreenOnly: Bool
    ) throws {
        try requireNativeBridgeIfNeeded()
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
            try lockScreenPlatform.installLockScreenOnly(videoURL: videoURL)
        } else {
            try lockScreenPlatform.install(videoURL: videoURL)
        }
    }

    private func requireNativeBridgeIfNeeded() throws {
        guard !nativeBridgeRequired || nativeBridgeURL != nil else {
            throw NativeWallpaperControllerError.unavailable(
                "Native Lock Screen bridge is unavailable in this AuraFlow build."
            )
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

    private struct LifecycleRequest: Equatable {
        let id: UInt64
        let intent: WallpaperLifecycleIntent
    }

    private struct LifecycleResult {
        let status: ControlStatus
        let state: WallpaperLifecycleState
        let statusMessage: String
        let successMessage: String?
        let previewURL: URL?
        let clearPendingPreview: Bool
        let refreshPreview: Bool
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
    @Published var showOnLockScreenEnabled: Bool = false
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
    @Published private(set) var lockScreenCapabilities: PlatformCapabilities = .legacyMacOS
    @Published private(set) var adaptiveGlassAppearance: AdaptiveGlassAppearance = .default
    @Published private(set) var lifecycleState: WallpaperLifecycleState = .idle
    @Published private(set) var isLifecycleBusy = false

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
    private var lockScreenProviderUnavailableObserver: NSObjectProtocol?
    private var pendingLockScreenProviderFallback = false
    private var pendingLockScreenProviderFallbackReason: String?
    private var lockScreenProviderFallbackRetryTask: Task<Void, Never>?
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
    private var lastKnownGoodAdaptiveGlassAppearance: AdaptiveGlassAppearance = .safeFallback
    private var cacheGeneration = 0
    private var previewPreparationTask: Task<Void, Never>?
    private var previewPreparationGeneration = 0
    private var lockScreenPreparationTask: Task<Void, Never>?
    private var lockScreenPreparationGeneration = 0
    private var lifecycleTask: Task<Void, Never>?
    private var activeLifecycleIntent: WallpaperLifecycleIntent?
    private var pendingLifecycleRequest: LifecycleRequest?
    private var latestLifecycleOperationID: UInt64 = 0

    private let expectedStatusContractVersion = 3
    private let bridgeFailureThreshold = 3
    private let daemonSuspiciousThreshold = 2
    private static let defaultAppSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)

    private static func defaultAppSupportDirectoryForCurrentProcess() -> URL {
        let isTestProcess = CommandLine.arguments.contains { $0.contains(".xctest") }
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || NSClassFromString("XCTestCase") != nil
        guard isTestProcess else {
            return defaultAppSupportDirectoryURL
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlow-AppViewModelTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private let appSupportDirectoryURL: URL
    private let previewStateURL: URL

    var isControllerAvailable: Bool {
        controllerAvailable
    }

    var lockScreenCapabilityMessage: String {
        if lockScreenCapabilities.supportsSecureLockScreen {
            return "On macOS 26 and later, AuraFlow uses Apple's native Aerial Lock Screen. Lock Screen-only mode leaves Desktop unchanged."
        }
        return lockScreenCapabilities.availabilityMessage
            ?? "Lock Screen is unavailable on this macOS version."
    }

    var selectedVideoName: String {
        selectedVideoURL?.lastPathComponent ?? "Not selected"
    }

    var currentVideoURL: URL? {
        selectedVideoURL
    }

    var appSupportDirectoryURLForTesting: URL {
        appSupportDirectoryURL
    }

    private var isPlaybackRunningForControls: Bool {
        isRunning && !isPlaybackPaused
    }

    private var isLockScreenOnlyModeActiveForControls: Bool {
        isLockScreenOnlyActive
            || activeLifecycleIntent?.name == "lock"
            || pendingLifecycleRequest?.intent.name == "lock"
    }

    private var isDesktopAndLockModeActiveForControls: Bool {
        isPlaybackRunningForControls
            || activeLifecycleIntent?.name == "start"
            || pendingLifecycleRequest?.intent.name == "start"
    }

    var isStartButtonHighlighted: Bool {
        selectedVideoURL != nil
            && (!isPlaybackRunningForControls
                || pendingPreviewVideoURL != nil)
            && !isPlaybackPaused
    }

    var isStopButtonHighlighted: Bool {
        appliedVideoURL != nil && isPlaybackPaused
    }

    var canStart: Bool {
        isControllerAvailable
            && !isLockScreenOnlyModeActiveForControls
            && (!isPlaybackRunningForControls
                || pendingPreviewVideoURL != nil)
            && selectedVideoURL != nil
    }

    var canApplyLockScreenOnly: Bool {
        isControllerAvailable
            && lockScreenCapabilities.supportsLockScreenOnly
            && !isDesktopAndLockModeActiveForControls
            && selectedVideoURL != nil
    }

    var canStop: Bool {
        isControllerAvailable
            && (isPlaybackRunningForControls
                || isLockScreenOnlyActive
                || activeLifecycleIntent?.name == "lock"
                || pendingLifecycleRequest?.intent.name == "lock")
    }

    var canClearWallpaper: Bool {
        isControllerAvailable
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
        isControllerAvailable
            && lockScreenCapabilities.supportsLockScreen
            && !isBusy
    }

    var canPreviewLockScreen: Bool {
        isPlaybackRunningForControls
            && lockScreenCapabilities.supportsLockScreen
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

    var canDownloadCatalogWallpaper: Bool {
        !isBusy && catalogDownloadID == nil
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
        appSupportDirectoryURL: URL? = nil,
        previewStateURL: URL? = nil
    ) {
        self.optimizationStore = optimizationStore
        self.catalogProvider = catalogProvider
        let resolvedAppSupportURL = appSupportDirectoryURL
            ?? Self.defaultAppSupportDirectoryForCurrentProcess()
        self.appSupportDirectoryURL = resolvedAppSupportURL
        self.previewStateURL = previewStateURL
            ?? resolvedAppSupportURL.appendingPathComponent("last_preview.json")
        if let controller {
            self.controller = controller
            self.controllerAvailable = true
            self.lockScreenCapabilities = controller.lockScreenCapabilities
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
        lockScreenProviderUnavailableObserver =
            DistributedNotificationCenter.default().addObserver(
                forName: WallpaperRuntimeNotifications
                    .lockScreenProviderBecameUnavailable,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let reason = notification.userInfo?[
                    WallpaperRuntimeNotifications.lockScreenFallbackReasonKey
                ] as? String
                Task { @MainActor [weak self] in
                    await self?.handleLockScreenProviderBecameUnavailable(
                        reason: reason
                    )
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
        lifecycleTask?.cancel()
        healthMonitorTask?.cancel()
        monitoringTask?.cancel()
        catalogRefreshTask?.cancel()
        catalogDownloadTask?.cancel()
        localWallpaperImportTask?.cancel()
        controllerBootstrapTask?.cancel()
        glassAnalysisTask?.cancel()
        previewPreparationTask?.cancel()
        lockScreenPreparationTask?.cancel()
        lockScreenProviderFallbackRetryTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let lockScreenProviderUnavailableObserver {
            DistributedNotificationCenter.default().removeObserver(
                lockScreenProviderUnavailableObserver
            )
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
        lockScreenCapabilities = controller.lockScreenCapabilities
        guard !isBusy, !isLifecycleBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            if pendingLockScreenProviderFallback {
                scheduleLockScreenProviderFallbackRetry()
            }
        }

        do {
            let status = try await runAsync { try controller.status() }
            apply(status: status)
            let needsNormalizationURL = configuredVideoNeedingCompatibilityNormalization(from: status)
            recordBridgeSuccess()
            await startFromAutostartIfNeeded(using: status)
            do {
                try await runAsync {
                    try controller.syncLockScreenSaver()
                }
            } catch {
                alertMessage =
                    "Lock Screen sync failed: \(error.localizedDescription)"
                return
            }
            do {
                let synchronizedStatus = try await runAsync {
                    try controller.status()
                }
                apply(status: synchronizedStatus)
                if autostartWarning(for: synchronizedStatus) == nil {
                    alertMessage = nil
                }
            } catch {
                recordBridgeFailure(error, context: "status-after-lock-screen-sync")
                return
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
        } catch {
            recordBridgeFailure(error, context: "status")
        }
    }

    private func handleLockScreenProviderBecameUnavailable(
        reason: String? = nil
    ) async {
        if let reason, !reason.isEmpty {
            pendingLockScreenProviderFallbackReason = reason
        }
        guard !isShuttingDown else { return }
        guard controller != nil else {
            pendingLockScreenProviderFallback = true
            scheduleLockScreenProviderFallbackRetry()
            return
        }
        guard !isBusy, !isLifecycleBusy else {
            pendingLockScreenProviderFallback = true
            scheduleLockScreenProviderFallbackRetry()
            return
        }
        pendingLockScreenProviderFallback = false
        if let reason = pendingLockScreenProviderFallbackReason {
            lockScreenLifecycleLogger.notice(
                "Lock Screen fallback requested: \(reason, privacy: .public)"
            )
        }
        pendingLockScreenProviderFallbackReason = nil
        await loadStatus()
    }

    private func scheduleLockScreenProviderFallbackRetry() {
        guard pendingLockScreenProviderFallback,
              !isShuttingDown,
              lockScreenProviderFallbackRetryTask == nil
        else {
            return
        }

        lockScreenProviderFallbackRetryTask = Task { @MainActor [weak self] in
            defer {
                self?.lockScreenProviderFallbackRetryTask = nil
            }
            var retryDelay: UInt64 = 100_000_000
            var bootstrapRetryCount = 0
            let maximumBootstrapRetries = 8
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: retryDelay)
                guard let self, !Task.isCancelled else { return }
                guard self.pendingLockScreenProviderFallback,
                      !self.isShuttingDown
                else {
                    return
                }
                guard self.controller != nil else {
                    guard self.isControllerBootstrapInProgress else {
                        return
                    }
                    bootstrapRetryCount += 1
                    guard bootstrapRetryCount < maximumBootstrapRetries else {
                        return
                    }
                    retryDelay = min(retryDelay * 2, 2_000_000_000)
                    continue
                }
                guard !self.isBusy, !self.isLifecycleBusy else {
                    retryDelay = min(retryDelay * 2, 1_000_000_000)
                    continue
                }
                await self.handleLockScreenProviderBecameUnavailable()
                return
            }
        }
    }

    private func restoreInitialPreviewFromSavedConfig() {
        guard pendingPreviewVideoURL == nil else { return }
        let seeds = [
            loadStartupPreviewSeed(),
            loadSavedPreviewSeed(),
        ].compactMap { $0 }
        guard let seed = seeds.first(where: { Self.previewURL(for: $0) != nil }),
              let videoURL = Self.previewURL(for: seed)
        else {
            return
        }

        appliedVideoURL = videoURL
        playbackSpeed = seed.playback_speed
        if let rawScaleMode = seed.scale_mode,
           let restoredScaleMode = WallpaperScaleMode(rawValue: rawScaleMode) {
            scaleMode = restoredScaleMode
        }
        configurePreviewOrPrepare(for: videoURL)
    }

    private static func previewURL(for seed: WallpaperPreviewSeed) -> URL? {
        let path = seed.video_path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isReadableKey,
        ]),
        values.isRegularFile == true,
        values.isReadable != false
        else {
            return nil
        }
        return url
    }

    private func refreshPreviewFromSavedSeedIfNeeded(refreshPreview: Bool) -> Bool {
        guard let seed = loadSavedPreviewSeed(),
              let savedURL = Self.previewURL(for: seed)
        else {
            return false
        }

        let previewChanged = appliedVideoURL?.standardizedFileURL != savedURL
        if previewChanged {
            appliedVideoURL = savedURL
        }
        if previewChanged || (refreshPreview && previewPlayer?.currentItem == nil) {
            configurePreviewOrPrepare(for: savedURL)
        }
        return true
    }

    private func cancelPreviewPreparation() {
        previewPreparationGeneration &+= 1
        previewPreparationTask?.cancel()
        previewPreparationTask = nil
        lockScreenPreparationGeneration &+= 1
        lockScreenPreparationTask?.cancel()
        lockScreenPreparationTask = nil
    }

    private func configurePreviewOrPrepare(for url: URL) {
        guard !WallpaperMediaKind.forURL(url).isStaticImage else {
            cancelPreviewPreparation()
            configurePreview(for: url)
            scheduleLockScreenMediaPreparation(
                for: url,
                previewGeneration: previewPreparationGeneration
            )
            return
        }

        let isNativeContainer = isNativePlaybackContainer(url)
        if isNativeContainer {
            configurePreview(for: url)
        } else if previewPlayer == nil {
            // Keep the view attached to a real player while compatibility
            // conversion runs. Unsupported containers must never be handed to
            // AVPlayer as the final preview source.
            configurePreview(for: nil)
        }
        schedulePreviewPreparation(for: url)
    }

    private func schedulePreviewPreparation(for sourceURL: URL) {
        cancelPreviewPreparation()
        let requestedGeneration = previewPreparationGeneration
        let normalizedSourceURL = sourceURL.standardizedFileURL

        previewPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if isNativePlaybackContainer(normalizedSourceURL),
                   normalizedSourceURL.pathExtension.lowercased() != "gif",
                   await isPreviewPlayableVideo(at: normalizedSourceURL) {
                    scheduleLockScreenMediaPreparation(
                        for: normalizedSourceURL,
                        previewGeneration: requestedGeneration
                    )
                    if requestedGeneration == previewPreparationGeneration {
                        previewPreparationTask = nil
                    }
                    return
                }

                let prepared = try await prepareCatalogVideoURLForPlayback(normalizedSourceURL)
                guard !Task.isCancelled,
                      requestedGeneration == previewPreparationGeneration,
                      selectedVideoURL?.standardizedFileURL == normalizedSourceURL
                else {
                    return
                }

                configurePreview(for: prepared.url)
                savePreviewSeed(for: prepared.url)
                scheduleLockScreenMediaPreparation(
                    for: prepared.url,
                    previewGeneration: requestedGeneration
                )
                if let summary = prepared.summary {
                    statusMessage = summary
                }
            } catch is CancellationError {
                return
            } catch {
                guard requestedGeneration == previewPreparationGeneration,
                      selectedVideoURL?.standardizedFileURL == normalizedSourceURL
                else {
                    return
                }
                // Keep the current preview visible and let Start/Lock surface
                // the actionable conversion error at commit time.
                statusMessage = "Preview preparation failed. Press Start or Lock to retry."
            }

            if requestedGeneration == previewPreparationGeneration {
                previewPreparationTask = nil
            }
        }
    }

    private func scheduleLockScreenMediaPreparation(
        for sourceURL: URL,
        previewGeneration: Int
    ) {
        guard controller != nil else { return }

        lockScreenPreparationGeneration &+= 1
        let requestedGeneration = lockScreenPreparationGeneration
        lockScreenPreparationTask?.cancel()
        let normalizedSourceURL = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedSourceURL.path) else {
            return
        }
        let controller = self.controller

        lockScreenPreparationTask = Task { @MainActor [weak self] in
            guard let self, let controller else { return }
            do {
                try await self.runAsync {
                    try controller.prepareLockScreenMedia(
                        videoURL: normalizedSourceURL
                    )
                }
                try Task.checkCancellation()
                guard requestedGeneration == self.lockScreenPreparationGeneration,
                      previewGeneration == self.previewPreparationGeneration
                else {
                    return
                }
                self.lockScreenPreparationTask = nil
            } catch is CancellationError {
                return
            } catch {
                // Cache warming is best-effort. Lock keeps its existing
                // preparation and user-facing error path if needed.
                guard requestedGeneration == self.lockScreenPreparationGeneration,
                      previewGeneration == self.previewPreparationGeneration
                else {
                    return
                }
                lockScreenLifecycleLogger.debug(
                    "Lock Screen media cache warm-up deferred: \(error.localizedDescription, privacy: .public)"
                )
                self.lockScreenPreparationTask = nil
            }
        }
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

    private func loadStartupPreviewSeed() -> WallpaperPreviewSeed? {
        let startupConfigURL = appSupportDirectoryURL.appendingPathComponent("config.json")
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
                    self.lockScreenCapabilities = controller.lockScreenCapabilities
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    self.scheduleLockScreenMediaPreparationForCurrentPreview()
                    if self.pendingLockScreenProviderFallback {
                        self.scheduleLockScreenProviderFallbackRetry()
                    } else {
                        Task { @MainActor [weak self] in
                            await self?.loadStatus()
                        }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.controller = nil
                    self.controllerAvailable = false
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    self.pendingLockScreenProviderFallback = false
                    self.pendingLockScreenProviderFallbackReason = nil
                    self.lockScreenProviderFallbackRetryTask?.cancel()
                    self.lockScreenProviderFallbackRetryTask = nil
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func scheduleLockScreenMediaPreparationForCurrentPreview() {
        guard let sourceURL = selectedVideoURL else { return }
        let isStatic = WallpaperMediaKind.forURL(sourceURL).isStaticImage
        guard isStatic || isNativePlaybackContainer(sourceURL) else {
            // The preview preparation task will schedule the cache warm-up
            // after it produces a compatible file for non-native containers.
            return
        }
        scheduleLockScreenMediaPreparation(
            for: sourceURL,
            previewGeneration: previewPreparationGeneration
        )
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
                selectVideoForPreview(
                    resolvedURL,
                    summary: "Wallpaper loaded into preview. Press Start or Lock to apply."
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
        guard canDownloadCatalogWallpaper else { return }
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
                stageCatalogWallpaperForPreview(
                    wallpaper,
                    localURL: localURL
                )
                showSuccessBanner("Wallpaper downloaded to preview.")
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
        guard !isPlaybackRunningForControls
            || pendingPreviewVideoURL != nil
        else { return }
        guard let selectedVideoURL else {
            alertMessage = "Choose a video before starting."
            return
        }

        submitLifecycle(
            .start(
                selectedVideoURL,
                resume: isPlaybackPaused && pendingPreviewVideoURL == nil
            )
        )
    }

    func applyLockScreenOnly() {
        guard let selectedVideoURL else {
            alertMessage = "Choose a video before applying it to the Lock Screen."
            return
        }
        guard controller != nil else {
            alertMessage = "Native wallpaper runtime unavailable."
            return
        }
        submitLifecycle(.lock(selectedVideoURL))
    }

    func stop() {
        guard controller != nil else { return }
        guard isPlaybackRunningForControls
                || isLockScreenOnlyActive
                || activeLifecycleIntent?.name == "lock"
                || pendingLifecycleRequest?.intent.name == "lock"
        else {
            return
        }
        let stoppingLockScreenOnly = isLockScreenOnlyActive
            || activeLifecycleIntent?.name == "lock"
            || pendingLifecycleRequest?.intent.name == "lock"
        let staticImage = stoppingLockScreenOnly
            && selectedVideoURL.map {
                WallpaperMediaKind.forURL($0).isStaticImage
            } == true
        submitLifecycle(
            .stop(
                lockScreenOnly: stoppingLockScreenOnly,
                staticImage: staticImage
            )
        )
    }

    func clearWallpaper() {
        guard controller != nil else { return }
        submitLifecycle(.remove(lockScreenOnly: isLockScreenOnlyActive))
    }

    private func submitLifecycle(_ intent: WallpaperLifecycleIntent) {
        if activeLifecycleIntent == intent,
           pendingLifecycleRequest == nil {
            return
        }
        if pendingLifecycleRequest?.intent == intent {
            return
        }

        latestLifecycleOperationID &+= 1
        let request = LifecycleRequest(
            id: latestLifecycleOperationID,
            intent: intent
        )
        pendingLifecycleRequest = request
        lockScreenLifecycleLogger.notice(
            "Queued operation=\(request.id, privacy: .public) intent=\(intent.name, privacy: .public)"
        )
        switch intent {
        case .remove:
            lifecycleState = .removing
            statusMessage = "Removing wallpaper…"
        case .stop:
            statusMessage = "Pausing wallpaper…"
        case .start:
            lifecycleState = .preparing
            statusMessage = "Starting wallpaper…"
        case .lock:
            lifecycleState = .preparing
            statusMessage = "Preparing Lock Screen wallpaper…"
        }
        alertMessage = nil

        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            await self?.drainLifecycleQueue()
        }
    }

    private func drainLifecycleQueue() async {
        isLifecycleBusy = true
        defer {
            activeLifecycleIntent = nil
            lifecycleTask = nil
            isLifecycleBusy = false
            if pendingLockScreenProviderFallback {
                scheduleLockScreenProviderFallbackRetry()
            }
        }

        while !Task.isCancelled,
              let request = pendingLifecycleRequest {
            pendingLifecycleRequest = nil
            activeLifecycleIntent = request.intent
            let startedAt = ContinuousClock.now
            lockScreenLifecycleLogger.notice(
                "Started operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
            )
            do {
                let result = try await executeLifecycle(request)
                guard request.id == latestLifecycleOperationID,
                      pendingLifecycleRequest == nil
                else {
                    lockScreenLifecycleLogger.notice(
                        "Superseded operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
                    )
                    activeLifecycleIntent = nil
                    continue
                }
                applyLifecycleResult(result)
                recordBridgeSuccess()
                lifecycleState = result.state
                alertMessage = nil
                if let successMessage = result.successMessage {
                    showSuccessBanner(successMessage)
                }
                let elapsed = startedAt.duration(to: .now)
                lockScreenLifecycleLogger.notice(
                    "Completed operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
                )
            } catch is CancellationError {
                lockScreenLifecycleLogger.notice(
                    "Cancelled operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
                )
            } catch {
                guard request.id == latestLifecycleOperationID,
                      pendingLifecycleRequest == nil
                else {
                    activeLifecycleIntent = nil
                    continue
                }
                lifecycleState = .failed
                let context: String
                switch request.intent {
                case .start: context = "start"
                case .lock: context = "lock-screen-only"
                case .stop: context = "pause"
                case .remove: context = "clear-wallpaper"
                }
                recordBridgeFailure(error, context: context)
                alertMessage = "Failed to \(request.intent.name): \(error.localizedDescription)"
                lockScreenLifecycleLogger.error(
                    "Failed operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            activeLifecycleIntent = nil
        }
    }

    private func executeLifecycle(
        _ request: LifecycleRequest
    ) async throws -> LifecycleResult {
        guard let controller else {
            throw NativeWallpaperControllerError.unavailable(
                "Native wallpaper runtime unavailable."
            )
        }

        switch request.intent {
        case .start(let sourceURL, let resume):
            if resume {
                let status = try await runAsync { try controller.resume() }
                return LifecycleResult(
                    status: status,
                    state: .ready,
                    statusMessage: "Wallpaper resumed.",
                    successMessage: "Wallpaper started.",
                    previewURL: nil,
                    clearPendingPreview: false,
                    refreshPreview: true
                )
            }
            let prepared = isManagedCacheURL(sourceURL)
                ? try await prepareCatalogVideoURLForPlayback(sourceURL)
                : try await prepareVideoURLForPlayback(sourceURL)
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync {
                try controller.start(videoURL: prepared.url, speed: nil)
            }
            return LifecycleResult(
                status: status,
                state: .ready,
                statusMessage: prepared.summary ?? "Wallpaper started.",
                successMessage: "Wallpaper started.",
                previewURL: prepared.url,
                clearPendingPreview: true,
                refreshPreview: false
            )

        case .lock(let sourceURL):
            let prepared = try await prepareLockScreenVideoURLForPlayback(sourceURL)
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync {
                try controller.installLockScreenOnly(videoURL: prepared.url)
            }
            return LifecycleResult(
                status: status,
                state: .ready,
                statusMessage: prepared.summary.map {
                    "Lock Screen wallpaper confirmed. \($0)"
                } ?? "Lock Screen wallpaper confirmed by macOS.",
                successMessage: "Wallpaper started on Lock Screen.",
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: false
            )

        case .stop(let lockScreenOnly, let staticImage):
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync { try controller.stop() }
            return LifecycleResult(
                status: status,
                state: staticImage ? .ready : .paused,
                statusMessage: staticImage
                    ? "Static Lock Screen wallpaper is already still."
                    : lockScreenOnly
                        ? "Lock Screen wallpaper paused."
                        : "Paused on current frame.",
                successMessage: "Wallpaper stopped.",
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: true
            )

        case .remove:
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync {
                try controller.clearWallpaper()
            }
            let removalStatusMessage: String
            let removalSuccessMessage: String?
            switch status.wallpaper_restore_status {
            case .restored:
                removalStatusMessage = "Original wallpaper restored."
                removalSuccessMessage = "Wallpaper removed."
            case .failed:
                removalStatusMessage = "Wallpaper removed, but the original wallpaper could not be restored. AuraFlow will retry on the next launch."
                removalSuccessMessage = nil
            case .notNeeded, .none:
                removalStatusMessage = "Wallpaper removed."
                removalSuccessMessage = "Wallpaper removed."
            }
            return LifecycleResult(
                status: status,
                state: .idle,
                statusMessage: removalStatusMessage,
                successMessage: removalSuccessMessage,
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: true
            )
        }
    }

    private func ensureLifecycleMayCommit(
        _ request: LifecycleRequest
    ) throws {
        guard request.id == latestLifecycleOperationID,
              pendingLifecycleRequest == nil,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
    }

    private func applyLifecycleResult(_ result: LifecycleResult) {
        if result.clearPendingPreview {
            pendingPreviewVideoURL = nil
        }
        apply(status: result.status, refreshPreview: result.refreshPreview)
        if let previewURL = result.previewURL {
            let configuredURL = result.status.config.video_path.isEmpty
                ? previewURL
                : URL(fileURLWithPath: result.status.config.video_path)
            if previewPlayerURL != configuredURL.standardizedFileURL {
                configurePreview(for: configuredURL)
            }
        }
        statusMessage = result.statusMessage
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
                AdaptiveContrastAnalyzer.clearCache()
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
        if !isGIF,
           isNativePlaybackContainer(sourceURL),
           await isPreviewPlayableVideo(at: sourceURL) {
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

    private func prepareLockScreenVideoURLForPlayback(_ sourceURL: URL) async throws -> (url: URL, summary: String?) {
        // The native Lock Screen bridge prepares a still frame with avconvert.
        // Catalog files and non-native containers must therefore go through
        // the compatibility path first; passing a raw WebM/MKV/GIF here makes
        // Lock fail even when the same source already has a usable preview.
        if WallpaperMediaKind.forURL(sourceURL).isStaticImage {
            return (sourceURL.standardizedFileURL, nil)
        }

        if isManagedCacheURL(sourceURL) || !isNativePlaybackContainer(sourceURL) {
            return try await prepareCatalogVideoURLForPlayback(sourceURL)
        }

        // Preserve the existing user optimization behavior for external
        // native MP4/MOV/M4V sources while still guaranteeing compatibility
        // conversion for managed and unsupported sources above.
        return try await prepareVideoURLForPlayback(sourceURL)
    }

    private func apply(
        status: ControlStatus,
        refreshPreview: Bool = true,
        backgroundUpdate: Bool = false
    ) {
        let hasConfiguredVideo = !status.config.video_path.isEmpty
        let paused = status.paused ?? false
        let effectiveRunning = statusIndicatesActivePlayback(status)
        let lockScreenOnlyActive = status.lock_screen_only == true
            || (
                status.lock_screen_only == nil
                    && !status.running
                    && !paused
                    && status.health?.available == true
                    && status.health?.suspicious != true
            )
        Self.setIfChanged(&isRunning, to: status.running)
        Self.setIfChanged(&isPlaybackActive, to: effectiveRunning)
        Self.setIfChanged(&isPlaybackPaused, to: paused && hasConfiguredVideo && !effectiveRunning)
        Self.setIfChanged(
            &isLockScreenOnlyActive,
            to: lockScreenOnlyActive
        )
        Self.setIfChanged(&playbackSpeed, to: status.config.playback_speed)
        Self.setIfChanged(&autostartEnabled, to: status.autostart ?? status.config.autostart ?? false)
        if let warning = autostartWarning(for: status) {
            if backgroundUpdate {
                statusMessage = warning
            } else {
                alertMessage = warning
            }
        }
        Self.setIfChanged(&blendInterpolationEnabled, to: status.config.blend_interpolation ?? false)
        Self.setIfChanged(&pauseOnFullscreenEnabled, to: status.config.pause_on_fullscreen ?? true)
        Self.setIfChanged(&showOnLockScreenEnabled, to: status.config.show_on_lock_screen ?? false)
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
                if refreshPreviewFromSavedSeedIfNeeded(refreshPreview: refreshPreview) {
                    // Lock-only intentionally keeps config.video_path empty.
                    // Re-read the persisted preview so another AuraFlow window
                    // or a completed Lock operation cannot leave this window
                    // attached to a deleted/stale player item.
                } else if let currentURL = appliedVideoURL?.standardizedFileURL,
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

    private func autostartWarning(for status: ControlStatus) -> String? {
        guard status.config.autostart == true,
              status.autostart != true,
              status.autostart_plist_exists != nil
                || status.autostart_service_loaded != nil
        else {
            return nil
        }

        if status.autostart_plist_exists == false {
            return "Launch at Login is enabled, but its LaunchAgent plist is missing."
        }
        if status.autostart_service_loaded == false {
            return "Launch at Login is enabled, but the AuraFlow LaunchAgent is not loaded."
        }
        if status.autostart_service_running == false {
            return "Launch at Login is enabled, but the AuraFlow LaunchAgent is not running."
        }
        return "Launch at Login is enabled, but the AuraFlow LaunchAgent is unavailable."
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
        let directory = appSupportDirectoryURL
            .appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func optimizedVideosDirectoryURL() throws -> URL {
        let directory = appSupportDirectoryURL
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
            at: appSupportDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for entry in entries {
            let name = entry.lastPathComponent
            let isGeneratedStillFrame = name == "last_frame.png"
                || name == "last_frame_source.json"
                || (name.hasPrefix("last_frame_") && name.hasSuffix(".png"))
            let isPreparedLockScreenCache = name == "LockScreenMediaCache"
            if isGeneratedStillFrame || isPreparedLockScreenCache {
                try fileManager.removeItem(at: entry)
            }
        }
    }

    private func selectVideoForPreview(_ url: URL, summary: String?) {
        cancelPreviewPreparation()
        pendingPreviewVideoURL = url
        configurePreviewOrPrepare(for: url)
        savePreviewSeed(for: url)
        statusMessage = summary
        alertMessage = nil
    }

    func stageCatalogWallpaperForPreview(_ wallpaper: CatalogWallpaper, localURL: URL) {
        registerDownloadedCatalogWallpaper(for: wallpaper, localURL: localURL)
        selectVideoForPreview(
            localURL,
            summary: "Wallpaper downloaded to preview. Press Start or Lock to apply."
        )
    }

    func selectLocalVideoForPreview(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        scheduleLocalWallpaperImport(for: normalizedURL)
        selectVideoForPreview(
            normalizedURL,
            summary: "Video loaded into preview. Press Start or Lock to apply."
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

    private func startWallpaper(
        using sourceURL: URL,
        statusSummary: String
    ) async throws {
        guard let controller else {
            throw NativeWallpaperControllerError.unavailable("Native wallpaper runtime unavailable.")
        }

        let prepared = isManagedCacheURL(sourceURL)
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
        glassAnalysisGeneration &+= 1
        glassAnalysisTask?.cancel()
        glassAnalysisTask = nil

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
            adaptiveGlassAppearance = .safeFallback
            lastKnownGoodAdaptiveGlassAppearance = .safeFallback
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
        glassAnalysisGeneration &+= 1
        let requestedGeneration = glassAnalysisGeneration
        let requestedURL = url.standardizedFileURL
        let requestedScaleMode = scaleMode

        glassAnalysisTask = Task.detached(priority: .utility) { [requestedURL, requestedScaleMode, requestedGeneration] in
            let analysis = AdaptiveContrastAnalyzer.analyze(
                url: requestedURL,
                scaleMode: requestedScaleMode
            )
            guard !Task.isCancelled else { return }
            guard let analysis else {
                await MainActor.run { [weak self] in
                    guard let self,
                          requestedGeneration == self.glassAnalysisGeneration else {
                        return
                    }
                    // Keep the last valid palette while a source is temporarily
                    // undecodable. A failed analysis must never flash the old
                    // white default or a partially computed profile.
                    self.adaptiveGlassAppearance = self.lastKnownGoodAdaptiveGlassAppearance
                    adaptiveContrastLogger.debug(
                        "Appearance analysis deferred; last known good profile retained"
                    )
                }
                return
            }

            // A file can be replaced in place while the background decoder is
            // working. Recheck the signature before publishing the result so
            // an old frame can never win merely because its URL is unchanged.
            guard AdaptiveContrastAnalyzer.sourceSignature(for: requestedURL) == analysis.sourceSignature,
                  !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                guard let self,
                      requestedGeneration == self.glassAnalysisGeneration else {
                    return
                }

                let currentURL = self.selectedVideoURL?.standardizedFileURL
                let appliedURL = self.appliedVideoURL?.standardizedFileURL
                let pendingURL = self.pendingPreviewVideoURL?.standardizedFileURL
                guard currentURL == requestedURL || appliedURL == requestedURL || pendingURL == requestedURL else {
                    return
                }

                self.adaptiveGlassAppearance = analysis.appearance
                self.lastKnownGoodAdaptiveGlassAppearance = analysis.appearance
                adaptiveContrastLogger.debug(
                    "Appearance analysis accepted: samples=\(analysis.sampleCount, privacy: .public), cache_hit=\(analysis.cacheHit, privacy: .public), selected_score=\(analysis.selectedToneScore, privacy: .public), alternate_score=\(analysis.alternateToneScore, privacy: .public)"
                )
            }
        }
    }

    nonisolated static func adaptiveGlassAppearance(for url: URL, scaleMode: WallpaperScaleMode) -> AdaptiveGlassAppearance {
        AdaptiveContrastAnalyzer.analyze(url: url, scaleMode: scaleMode)?.appearance
            ?? AdaptiveGlassAppearance.safeFallback
    }

    nonisolated static func adaptiveGlassAppearance(for cgImage: CGImage) -> AdaptiveGlassAppearance {
        AdaptiveContrastAnalyzer.appearance(for: cgImage)
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
