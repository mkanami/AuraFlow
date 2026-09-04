import Darwin
import AppKit
import AVFoundation
import Foundation

public enum WallpaperRuntimeNotifications {
    public static let commandDidChange = Notification.Name(
        "com.andrijvergeles.auraflow.runtime-command-did-change"
    )
    public static let lockScreenProviderBecameUnavailable = Notification.Name(
        "com.andrijvergeles.auraflow.lock-screen-provider-became-unavailable"
    )
    public static let lockScreenFallbackReasonKey = "reason"
}

public enum DaemonTerminationResult: Equatable, Sendable {
    case terminated
    case alreadyExited
    case identityMismatch
    case failed

    public var succeeded: Bool {
        switch self {
        case .terminated, .alreadyExited:
            return true
        case .identityMismatch, .failed:
            return false
        }
    }
}

public struct LaunchctlResult: Equatable, Sendable {
    public let succeeded: Bool
    public let output: String
    public let terminationStatus: Int32

    public init(
        succeeded: Bool,
        output: String = "",
        terminationStatus: Int32 = 0
    ) {
        self.succeeded = succeeded
        self.output = output
        self.terminationStatus = terminationStatus
    }

    var isServiceNotLoaded: Bool {
        guard !succeeded else { return false }
        let normalized = output.lowercased()
        return normalized.contains("could not find service")
            || normalized.contains("could not find specified service")
            || normalized.contains("service is not loaded")
            || normalized.contains("no such process")
            || normalized.contains("domain does not exist")
    }
}

public struct LaunchAgentStatus: Equatable, Sendable {
    public let plistExists: Bool
    public let serviceLoaded: Bool
    public let serviceRunning: Bool

    public init(
        plistExists: Bool,
        serviceLoaded: Bool,
        serviceRunning: Bool
    ) {
        self.plistExists = plistExists
        self.serviceLoaded = serviceLoaded
        self.serviceRunning = serviceRunning
    }

    public var enabled: Bool {
        plistExists && serviceLoaded && serviceRunning
    }
}

public typealias LaunchctlRunner = ([String]) -> LaunchctlResult

public enum WallpaperRuntimeCommandAction: String, Codable, Equatable {
    case reload
    case update
    case pause
    case resume
    case previewLock
    case previewUnlock
    case terminate
    case terminatePreservingDesktop
}

public struct WallpaperRuntimeCommand: Codable, Equatable {
    public var id: String
    public var operationID: UInt64?
    public var action: WallpaperRuntimeCommandAction
    public var config: ControlConfig?
    public var created_at: Double

    public init(
        id: String = UUID().uuidString,
        operationID: UInt64? = nil,
        action: WallpaperRuntimeCommandAction,
        config: ControlConfig? = nil,
        created_at: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.operationID = operationID
        self.action = action
        self.config = config
        self.created_at = created_at
    }
}

public final class WallpaperRuntimeStore {
    private struct LockScreenOnlySource: Codable, Equatable {
        var path: String
    }

    private let fileStore: RuntimeFileStore
    private let launchctlRunner: LaunchctlRunner
    private let launchAgentFileRemover: (URL) throws -> Void

    public var appSupportURL: URL { fileStore.appSupportURL }

    public init(
        appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL(),
        launchAgentURL: URL? = nil,
        launchctlRunner: LaunchctlRunner? = nil,
        launchAgentFileRemover: ((URL) throws -> Void)? = nil
    ) {
        self.fileStore = RuntimeFileStore(
            appSupportURL: appSupportURL,
            launchAgentURL: launchAgentURL
        )
        self.launchctlRunner = launchctlRunner ?? LaunchAgentManager.executeLaunchctl
        self.launchAgentFileRemover = launchAgentFileRemover ?? {
            try FileManager.default.removeItem(at: $0)
        }
    }

    public static func defaultAppSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)
    }

    public var configURL: URL { fileStore.configURL }
    public var commandURL: URL { fileStore.commandURL }
    public var healthURL: URL { fileStore.healthURL }
    public var pidURL: URL { fileStore.pidURL }
    public var pausedURL: URL { fileStore.pausedURL }
    public var daemonIdentityURL: URL { fileStore.daemonIdentityURL }
    public var wallpaperRestorePendingURL: URL { fileStore.wallpaperRestorePendingURL }
    public var lastFrameURL: URL { fileStore.lastFrameURL }
    public var lastFrameSourceURL: URL { fileStore.lastFrameSourceURL }
    public var lockScreenOnlySourceURL: URL { fileStore.lockScreenOnlySourceURL }
    public var lockScreenOnlyAgentURL: URL { fileStore.lockScreenOnlyAgentURL }
    public var lockScreenAgentReadyURL: URL { fileStore.lockScreenAgentReadyURL }
    public var launchAgentURL: URL { fileStore.launchAgentURL }

    public func ensureDirectories() throws {
        try fileStore.ensureDirectories()
    }

    public func loadConfig() -> ControlConfig {
        guard let data = try? fileStore.readData(from: configURL),
              var config = try? JSONDecoder().decode(ControlConfig.self, from: data)
        else {
            return .defaultConfig
        }
        if config.video_path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let legacyLockScreenPath = object["lock_screen_path"] as? String,
           !legacyLockScreenPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.video_path = legacyLockScreenPath
        }
        return normalized(config)
    }

    public func saveConfig(_ config: ControlConfig) throws {
        try fileStore.writeJSON(normalized(config), to: configURL)
    }

    public func loadLockScreenOnlySource() -> URL? {
        guard let source = try? fileStore.readJSON(
            LockScreenOnlySource.self,
            from: lockScreenOnlySourceURL
        ) else {
            return nil
        }
        let path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    public func saveLockScreenOnlySource(_ url: URL) throws {
        try ensureDirectories()
        try fileStore.writeJSON(
            LockScreenOnlySource(path: url.standardizedFileURL.path),
            to: lockScreenOnlySourceURL
        )
    }

    public func clearLockScreenOnlySource() {
        try? FileManager.default.removeItem(at: lockScreenOnlySourceURL)
    }

    public func restoreLockScreenOnlySource(_ url: URL?) {
        guard let url else {
            clearLockScreenOnlySource()
            return
        }
        try? saveLockScreenOnlySource(url)
    }

    public func markLockScreenOnlyAgent(_ enabled: Bool) {
        if enabled {
            try? ensureDirectories()
            FileManager.default.createFile(
                atPath: lockScreenOnlyAgentURL.path,
                contents: Data(),
                attributes: nil
            )
        } else {
            try? FileManager.default.removeItem(at: lockScreenOnlyAgentURL)
            markLockScreenAgentReady(false)
        }
    }

    public func isLockScreenOnlyAgent() -> Bool {
        FileManager.default.fileExists(atPath: lockScreenOnlyAgentURL.path)
    }

    public func markLockScreenAgentReady(_ ready: Bool) {
        if ready {
            try? ensureDirectories()
            FileManager.default.createFile(
                atPath: lockScreenAgentReadyURL.path,
                contents: Data(),
                attributes: nil
            )
        } else {
            try? FileManager.default.removeItem(at: lockScreenAgentReadyURL)
        }
    }

    public func isLockScreenAgentReady() -> Bool {
        FileManager.default.fileExists(atPath: lockScreenAgentReadyURL.path)
    }

    public func markWallpaperRestorePending(_ pending: Bool) {
        if pending {
            try? ensureDirectories()
            FileManager.default.createFile(
                atPath: wallpaperRestorePendingURL.path,
                contents: Data(),
                attributes: nil
            )
        } else {
            try? FileManager.default.removeItem(at: wallpaperRestorePendingURL)
        }
    }

    public func isWallpaperRestorePending() -> Bool {
        FileManager.default.fileExists(atPath: wallpaperRestorePendingURL.path)
    }

    public func effectiveLockScreenSourceURL(for config: ControlConfig) -> URL? {
        if let lockScreenOnlySource = loadLockScreenOnlySource(),
           FileManager.default.fileExists(atPath: lockScreenOnlySource.path) {
            return lockScreenOnlySource
        }
        let path = config.video_path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    public func loadHealth() -> DaemonHealth? {
        try? fileStore.readJSON(DaemonHealth.self, from: healthURL)
    }

    public func saveHealth(_ health: DaemonHealth) throws {
        try fileStore.writeJSON(health, to: healthURL)
    }

    public func removeHealth() {
        try? FileManager.default.removeItem(at: healthURL)
    }

    public func loadCommand() -> WallpaperRuntimeCommand? {
        try? fileStore.readJSON(WallpaperRuntimeCommand.self, from: commandURL)
    }

    public func saveCommand(_ command: WallpaperRuntimeCommand) throws {
        try fileStore.writeJSON(command, to: commandURL)
    }

    public func removeCommand() {
        try? FileManager.default.removeItem(at: commandURL)
    }

    public func loadPID() -> Int? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func savePID(_ pid: Int32 = getpid()) throws {
        try DaemonProcessManager(store: self).recordPID(pid)
    }

    public func removePID() {
        try? FileManager.default.removeItem(at: pidURL)
        try? FileManager.default.removeItem(at: daemonIdentityURL)
    }

    public func ownsRuntimeProcess(_ pid: Int32 = getpid()) -> Bool {
        DaemonProcessManager(store: self).ownsRuntimeProcess(pid)
    }

    public func markPaused(_ paused: Bool) {
        if paused {
            try? ensureDirectories()
            FileManager.default.createFile(atPath: pausedURL.path, contents: Data(), attributes: nil)
        } else {
            try? FileManager.default.removeItem(at: pausedURL)
        }
    }

    public func isPaused() -> Bool {
        FileManager.default.fileExists(atPath: pausedURL.path)
    }

    public func processIsAlive(pid: Int?) -> Bool {
        DaemonProcessManager.isProcessAlive(pid: pid)
    }

    /// Returns the verified ownership state of the persisted daemon PID.
    /// `status()` and `metrics()` deliberately use this instead of raw PID
    /// liveness so a reused PID cannot make a foreign process look like AuraFlow.
    public var daemonProcessStatus: DaemonProcessStatus {
        DaemonProcessManager(store: self).processStatus
    }

    public func normalized(_ config: ControlConfig) -> ControlConfig {
        var normalized = config
        normalized.playback_speed = max(0.1, min(config.playback_speed, 4.0))
        normalized.volume = max(0, min(config.volume ?? 0, 1))
        normalized.autostart = config.autostart ?? false
        normalized.blend_interpolation = config.blend_interpolation ?? false
        normalized.pause_on_fullscreen = config.pause_on_fullscreen ?? true
        normalized.show_on_lock_screen = config.show_on_lock_screen ?? false
        if WallpaperScaleMode(rawValue: config.scale_mode ?? "") == nil {
            normalized.scale_mode = WallpaperScaleMode.fill.rawValue
        }
        return normalized
    }

    public func status(
        wallpaperRestored: Bool? = nil,
        wallpaperRestoreStatus: WallpaperRestoreStatus? = nil,
        wallpaper: String? = nil
    ) -> ControlStatus {
        let config = loadConfig()
        let pid = loadPID()
        let processStatus = daemonProcessStatus
        let owned = processStatus.isOwned
        let paused = isPaused()
        let lockScreenOnly = isLockScreenOnlyAgent()
        let health = healthForStatus(processStatus: processStatus, paused: paused)
        let launchAgent = launchAgentStatus()
        return ControlStatus(
            running: owned && !paused && !lockScreenOnly,
            config: config,
            pid: owned && !lockScreenOnly ? pid : nil,
            autostart: launchAgent.enabled,
            paused: paused,
            wallpaper_restored: wallpaperRestored,
            wallpaper_restore_status: wallpaperRestoreStatus,
            wallpaper: wallpaper,
            health: health,
            lock_screen_only: lockScreenOnly,
            autostart_plist_exists: launchAgent.plistExists,
            autostart_service_loaded: launchAgent.serviceLoaded,
            autostart_service_running: launchAgent.serviceRunning
        )
    }

    public func metrics() -> DaemonMetrics {
        let pid = loadPID()
        let processStatus = daemonProcessStatus
        let owned = processStatus.isOwned
        let paused = isPaused()
        let lockScreenOnly = isLockScreenOnlyAgent()
        return DaemonMetrics(
            updated_at: Date().timeIntervalSince1970,
            running: owned && !paused && !lockScreenOnly,
            paused: paused,
            pid: owned ? pid : nil,
            daemon_pids: owned ? pid.map { [$0] } : [],
            process_count: owned ? 1 : 0,
            cpu_percent: nil,
            memory_mb: nil,
            virtual_memory_mb: nil,
            thread_count: nil,
            health: healthForStatus(processStatus: processStatus, paused: paused)
        )
    }

    public func healthForStatus(alive: Bool, paused: Bool) -> DaemonHealth {
        healthForStatus(
            processStatus: alive ? .owned : .noPID,
            paused: paused
        )
    }

    public func healthForStatus(
        processStatus: DaemonProcessStatus,
        paused: Bool
    ) -> DaemonHealth {
        let now = Date().timeIntervalSince1970
        let config = loadConfig()
        let saved = loadHealth()
        let lag = saved?.updated_at.map { max(now - $0, 0) }
        let owned = processStatus.isOwned
        let fresh = owned && (lag ?? 0) < 6.0
        let reason: String
        switch processStatus {
        case .noPID:
            reason = "not-running"
        case .owned:
            reason = fresh ? "ok" : "stale-health"
        case .stalePID:
            reason = "stale-pid"
        case .identityMismatch:
            reason = "identity-mismatch"
        case .unknown:
            reason = "unknown-process"
        }
        let suspicious = (!owned && processStatus != .noPID) || (owned && !fresh)
        return DaemonHealth(
            available: owned,
            fresh: fresh,
            suspicious: suspicious,
            reason: reason,
            updated_at: saved?.updated_at ?? now,
            lag_seconds: lag,
            screens: saved?.screens,
            windows: saved?.windows,
            player_rate: paused ? 0 : saved?.player_rate,
            stall_events: saved?.stall_events ?? 0,
            recovery_events: saved?.recovery_events ?? 0,
            consecutive_stall_polls: saved?.consecutive_stall_polls ?? 0,
            paused: paused,
            manual_paused: paused,
            low_power_mode: saved?.low_power_mode ?? false,
            auto_paused_for_low_power: saved?.auto_paused_for_low_power ?? false,
            pause_on_fullscreen: saved?.pause_on_fullscreen,
            fullscreen_app_detected: saved?.fullscreen_app_detected ?? false,
            auto_paused_for_fullscreen: saved?.auto_paused_for_fullscreen ?? false,
            lock_screen_enabled: saved?.lock_screen_enabled ?? config.show_on_lock_screen ?? false,
            session_inactive: saved?.session_inactive ?? false,
            lock_screen_preview_active: saved?.lock_screen_preview_active ?? false,
            presentation_mode: saved?.presentation_mode ?? WallpaperPresentationMode.desktop.rawValue,
            lock_transition_count: saved?.lock_transition_count ?? 0,
            last_lock_transition_ms: saved?.last_lock_transition_ms,
            blend_interpolation_enabled: saved?.blend_interpolation_enabled ?? false,
            blend_interpolation_active: saved?.blend_interpolation_active ?? false,
            scale_mode: saved?.scale_mode ?? loadConfig().scale_mode,
            visible_desktop_windows: saved?.visible_desktop_windows,
            native_lock_state: saved?.native_lock_state,
            active_source_signature: saved?.active_source_signature,
            applied_operation_id: saved?.applied_operation_id,
            active_generation: saved?.active_generation
        )
    }

    public func launchAgentPlistExists() -> Bool {
        launchAgentManager().launchAgentPlistExists()
    }

    public func launchAgentStatus() -> LaunchAgentStatus {
        launchAgentManager().launchAgentStatus()
    }

    public func launchAgentEnabled() -> Bool {
        launchAgentManager().launchAgentEnabled()
    }

    public func enableLaunchAgent(
        helperPath: String,
        nativeBridgePath: String? = nil
    ) throws {
        try launchAgentManager().enableLaunchAgent(
            helperPath: helperPath,
            nativeBridgePath: nativeBridgePath
        )
    }

    public func disableLaunchAgent() throws {
        try launchAgentManager().disableLaunchAgent()
    }

    @discardableResult
    public func terminateDaemon(
        timeout: TimeInterval = 1.0,
        expectedExecutableURL: URL? = nil
    ) -> DaemonTerminationResult {
        DaemonProcessManager(
            store: self,
            expectedExecutableURL: expectedExecutableURL
        ).terminate(timeout: timeout)
    }

    public func captureStillFrame(
        from videoURL: URL,
        time: CMTime = CMTime(seconds: 0.2, preferredTimescale: 600)
    ) throws -> URL {
        try ensureDirectories()
        return try stillFrameService().captureStillFrame(from: videoURL, time: time)
    }

    public func ensureCurrentStillFrame(from videoURL: URL) throws -> URL {
        try stillFrameService().ensureCurrentStillFrame(from: videoURL)
    }

    public func removeManagedFallback() {
        stillFrameService().removeManagedFallback()
    }

    @discardableResult
    public func applyStillWallpaper(from videoPath: String) -> String? {
        desktopWallpaperRecovery().applyStillWallpaper(from: videoPath)
    }

    @discardableResult
    public func restoreWallpaperBackup() -> WallpaperRestoreStatus {
        desktopWallpaperRecovery().restoreWallpaperBackup()
    }

    @discardableResult
    public func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        desktopWallpaperRecovery().repairCurrentDesktopWallpaperIfNeeded()
    }

    private func stillFrameService() -> StillFrameService {
        StillFrameService(appSupportURL: appSupportURL)
    }

    private func desktopWallpaperRecovery() -> DesktopWallpaperRecovery {
        DesktopWallpaperRecovery(
            appSupportURL: appSupportURL,
            stillFrameService: stillFrameService()
        )
    }

    private func launchAgentManager() -> LaunchAgentManager {
        LaunchAgentManager(
            store: self,
            launchAgentURL: fileStore.launchAgentURL,
            launchctlRunner: launchctlRunner,
            launchAgentFileRemover: launchAgentFileRemover
        )
    }
}

public enum WallpaperRuntimeError: LocalizedError {
    case unavailable(String)
    case launchAgentDisableFailed(
        removalError: String,
        rollbackFailures: [String]
    )

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case let .launchAgentDisableFailed(removalError, rollbackFailures):
            if rollbackFailures.isEmpty {
                return "Could not remove the AuraFlow LaunchAgent plist: \(removalError); previous service restored."
            }
            return "Could not remove the AuraFlow LaunchAgent plist: \(removalError); rollback failed: \(rollbackFailures.joined(separator: "; "))."
        }
    }
}
