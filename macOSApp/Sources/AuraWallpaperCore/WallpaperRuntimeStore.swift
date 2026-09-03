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
    private struct LastFrameSourceRevision: Codable, Equatable {
        var path: String
        var size: UInt64?
        var modifiedAt: Double?
    }

    private struct LockScreenOnlySource: Codable, Equatable {
        var path: String
    }

    public let appSupportURL: URL
    private let launchAgentFileURL: URL
    private let launchctlRunner: LaunchctlRunner
    private let launchAgentFileRemover: (URL) throws -> Void

    public init(
        appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL(),
        launchAgentURL: URL? = nil,
        launchctlRunner: LaunchctlRunner? = nil,
        launchAgentFileRemover: ((URL) throws -> Void)? = nil
    ) {
        self.appSupportURL = appSupportURL
        self.launchAgentFileURL = launchAgentURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.andrijvergeles.auraflow.plist")
        self.launchctlRunner = launchctlRunner ?? WallpaperRuntimeStore.executeLaunchctl
        self.launchAgentFileRemover = launchAgentFileRemover ?? {
            try FileManager.default.removeItem(at: $0)
        }
    }

    public static func defaultAppSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)
    }

    public var configURL: URL { appSupportURL.appendingPathComponent("config.json") }
    public var commandURL: URL { appSupportURL.appendingPathComponent("daemon_command.json") }
    public var healthURL: URL { appSupportURL.appendingPathComponent("daemon_health.json") }
    public var pidURL: URL { appSupportURL.appendingPathComponent("wallpaper_daemon.pid") }
    public var pausedURL: URL { appSupportURL.appendingPathComponent("wallpaper_daemon.paused") }
    public var daemonIdentityURL: URL {
        appSupportURL.appendingPathComponent("wallpaper_daemon_identity.json")
    }
    public var wallpaperRestorePendingURL: URL {
        appSupportURL.appendingPathComponent("wallpaper_restore_pending")
    }
    public var lastFrameURL: URL { appSupportURL.appendingPathComponent("last_frame.png") }
    public var lastFrameSourceURL: URL {
        appSupportURL.appendingPathComponent("last_frame_source.json")
    }
    public var lockScreenOnlySourceURL: URL {
        appSupportURL.appendingPathComponent("lock_screen_only_source.json")
    }
    public var lockScreenOnlyAgentURL: URL {
        appSupportURL.appendingPathComponent("lock_screen_only_agent")
    }
    public var lockScreenAgentReadyURL: URL {
        appSupportURL.appendingPathComponent("lock_screen_agent_ready")
    }
    public var launchAgentURL: URL { launchAgentFileURL }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func loadConfig() -> ControlConfig {
        guard let data = try? Data(contentsOf: configURL),
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
        try writeJSON(normalized(config), to: configURL)
    }

    public func loadLockScreenOnlySource() -> URL? {
        guard let source = try? readJSON(
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
        try writeJSON(
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
        try? readJSON(DaemonHealth.self, from: healthURL)
    }

    public func saveHealth(_ health: DaemonHealth) throws {
        try writeJSON(health, to: healthURL)
    }

    public func removeHealth() {
        try? FileManager.default.removeItem(at: healthURL)
    }

    public func loadCommand() -> WallpaperRuntimeCommand? {
        try? readJSON(WallpaperRuntimeCommand.self, from: commandURL)
    }

    public func saveCommand(_ command: WallpaperRuntimeCommand) throws {
        try writeJSON(command, to: commandURL)
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
        let alive = processIsAlive(pid: pid)
        let paused = isPaused()
        let lockScreenOnly = isLockScreenOnlyAgent()
        let health = healthForStatus(alive: alive, paused: paused)
        let launchAgent = launchAgentStatus()
        return ControlStatus(
            running: alive && !paused && !lockScreenOnly,
            config: config,
            pid: alive && !lockScreenOnly ? pid : nil,
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
        let alive = processIsAlive(pid: pid)
        let paused = isPaused()
        let lockScreenOnly = isLockScreenOnlyAgent()
        return DaemonMetrics(
            updated_at: Date().timeIntervalSince1970,
            running: alive && !paused && !lockScreenOnly,
            paused: paused,
            pid: alive ? pid : nil,
            daemon_pids: alive ? pid.map { [$0] } : [],
            process_count: alive ? 1 : 0,
            cpu_percent: nil,
            memory_mb: nil,
            virtual_memory_mb: nil,
            thread_count: nil,
            health: healthForStatus(alive: alive, paused: paused)
        )
    }

    public func healthForStatus(alive: Bool, paused: Bool) -> DaemonHealth {
        let now = Date().timeIntervalSince1970
        let config = loadConfig()
        let saved = loadHealth()
        let lag = saved?.updated_at.map { max(now - $0, 0) }
        let fresh = alive && (lag ?? 0) < 6.0
        return DaemonHealth(
            available: alive,
            fresh: fresh,
            suspicious: alive && !fresh,
            reason: alive ? (fresh ? "ok" : "stale-health") : "not-running",
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
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func launchAgentStatus() -> LaunchAgentStatus {
        let plistExists = launchAgentPlistExists()
        let service = "gui/\(getuid())/com.andrijvergeles.auraflow"
        let result = launchctlRunner(["print", service])
        let serviceLoaded = result.succeeded
        let serviceRunning = serviceLoaded
            && result.output
                .split(whereSeparator: \.isNewline)
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "state = running" {
                        return true
                    }
                    guard trimmed.hasPrefix("pid = "),
                          let pid = Int(
                              trimmed.dropFirst("pid = ".count)
                                  .trimmingCharacters(in: .whitespaces)
                          )
                    else {
                        return false
                    }
                    return pid > 0
                }
        return LaunchAgentStatus(
            plistExists: plistExists,
            serviceLoaded: serviceLoaded,
            serviceRunning: serviceRunning
        )
    }

    public func launchAgentEnabled() -> Bool {
        launchAgentStatus().enabled
    }

    public func enableLaunchAgent(
        helperPath: String,
        nativeBridgePath: String? = nil
    ) throws {
        try ensureDirectories()
        let configPath = configURL.path
        let expectedArguments = launchAgentProgramArguments(
            helperPath: helperPath,
            configPath: configPath,
            nativeBridgePath: nativeBridgePath
        )
        let expectedPlist = try launchAgentPlistData(
            programArguments: expectedArguments
        )
        let service = "gui/\(getuid())/com.andrijvergeles.auraflow"
        let previousPlistData = try? Data(contentsOf: launchAgentURL)
        let currentPlistMatches = launchAgentPlistMatches(
            expectedProgramArguments: expectedArguments
        )
        let currentLaunchAgent = launchAgentStatus()

        // An unchanged plist and a loaded service need no migration. This is
        // the common path during every normal GUI launch and avoids restarting
        // playback merely because the controller was reconstructed.
        if currentPlistMatches,
           currentLaunchAgent.enabled {
            return
        }

        if !currentPlistMatches || currentLaunchAgent.serviceLoaded {
            let previousPID = loadPID()
            let bootout = launchctlRunner(["bootout", service])
            guard bootout.succeeded || bootout.isServiceNotLoaded else {
                throw WallpaperRuntimeError.unavailable(
                    "Could not stop the existing AuraFlow LaunchAgent: \(bootout.output)"
                )
            }
            if let previousPID,
               !DaemonProcessManager.waitForExit(pid: previousPID, timeout: 2.0) {
                // launchctl normally waits for the job, but older agents can
                // delay their termination handler. Never bootstrap a new job
                // while the old process can still mutate shared runtime files.
                guard DaemonProcessManager(
                    store: self,
                    expectedExecutableURL: URL(fileURLWithPath: helperPath)
                ).terminate(timeout: 1.0).succeeded,
                DaemonProcessManager.waitForExit(pid: previousPID, timeout: 1.0)
                else {
                    throw WallpaperRuntimeError.unavailable(
                        "The existing AuraFlow wallpaper agent did not stop during migration."
                    )
                }
            }
        }

        try expectedPlist.write(to: launchAgentURL, options: .atomic)
        let bootstrap = launchctlRunner([
            "bootstrap",
            "gui/\(getuid())",
            launchAgentURL.path
        ])
        guard bootstrap.succeeded else {
            var rollbackFailures: [String] = []
            if let previousPlistData {
                do {
                    try previousPlistData.write(to: launchAgentURL, options: .atomic)
                } catch {
                    rollbackFailures.append(
                        "restore plist: \(error.localizedDescription)"
                    )
                }
                if rollbackFailures.isEmpty {
                    let restoreBootstrap = launchctlRunner([
                        "bootstrap",
                        "gui/\(getuid())",
                        launchAgentURL.path
                    ])
                    if !restoreBootstrap.succeeded {
                        rollbackFailures.append(
                            "restore LaunchAgent: \(restoreBootstrap.output)"
                        )
                    }
                }
            } else {
                do {
                    try FileManager.default.removeItem(at: launchAgentURL)
                } catch CocoaError.fileNoSuchFile {
                    // The failed bootstrap did not leave a plist behind.
                } catch {
                    rollbackFailures.append(
                        "remove failed plist: \(error.localizedDescription)"
                    )
                }
            }
            let rollbackDescription = rollbackFailures.isEmpty
                ? ""
                : "; rollback failed: " + rollbackFailures.joined(separator: "; ")
            throw WallpaperRuntimeError.unavailable(
                "Could not start the AuraFlow LaunchAgent: \(bootstrap.output)"
                    + rollbackDescription
            )
        }
    }

    public func disableLaunchAgent() throws {
        let previousPlistData = try? Data(contentsOf: launchAgentURL)
        let bootout = launchctlRunner([
            "bootout",
            "gui/\(getuid())/com.andrijvergeles.auraflow"
        ])
        guard bootout.succeeded || bootout.isServiceNotLoaded else {
            throw WallpaperRuntimeError.unavailable(
                "Could not unload the AuraFlow LaunchAgent: \(bootout.output)"
            )
        }
        do {
            try launchAgentFileRemover(launchAgentURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            var rollbackFailures: [String] = []
            if let previousPlistData {
                do {
                    try previousPlistData.write(to: launchAgentURL, options: .atomic)
                } catch {
                    rollbackFailures.append(
                        "restore plist: \(error.localizedDescription)"
                    )
                }
            } else {
                rollbackFailures.append(
                    "restore plist: previous plist could not be read"
                )
            }

            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                let restoreBootstrap = launchctlRunner([
                    "bootstrap",
                    "gui/\(getuid())",
                    launchAgentURL.path
                ])
                if !restoreBootstrap.succeeded {
                    rollbackFailures.append(
                        "restore LaunchAgent: \(restoreBootstrap.output)"
                    )
                }
            } else {
                rollbackFailures.append("restore LaunchAgent: plist is missing")
            }

            throw WallpaperRuntimeError.launchAgentDisableFailed(
                removalError: error.localizedDescription,
                rollbackFailures: rollbackFailures
            )
        }
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

    public func captureStillFrame(from videoURL: URL, time: CMTime = CMTime(seconds: 0.2, preferredTimescale: 600)) throws -> URL {
        try ensureDirectories()
        let image: CGImage
        if WallpaperMediaKind.forURL(videoURL).isStaticImage {
            guard let sourceImage = NSImage(contentsOf: videoURL),
                  let decodedImage = sourceImage.cgImage(
                    forProposedRect: nil,
                    context: nil,
                    hints: nil
                  )
            else {
                throw WallpaperRuntimeError.unavailable(
                    "Could not decode wallpaper image."
                )
            }
            image = decodedImage
        } else {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2160)
            image = try generator.copyCGImage(at: time, actualTime: nil)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WallpaperRuntimeError.unavailable("Could not encode wallpaper frame.")
        }
        try data.write(to: lastFrameURL, options: .atomic)
        try writeJSON(
            sourceRevision(for: videoURL),
            to: lastFrameSourceURL
        )
        return lastFrameURL
    }

    public func ensureCurrentStillFrame(from videoURL: URL) throws -> URL {
        let expectedRevision = sourceRevision(for: videoURL)
        let savedRevision: LastFrameSourceRevision? =
            try? readJSON(
                LastFrameSourceRevision.self,
                from: lastFrameSourceURL
            )
        if FileManager.default.fileExists(atPath: lastFrameURL.path),
           savedRevision == expectedRevision {
            return lastFrameURL
        }
        return try captureStillFrame(from: videoURL)
    }

    public func removeManagedFallback() {
        try? FileManager.default.removeItem(at: lastFrameURL)
        try? FileManager.default.removeItem(at: lastFrameSourceURL)
    }

    @discardableResult
    public func applyStillWallpaper(from videoPath: String) -> String? {
        guard !videoPath.isEmpty else { return nil }
        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
        guard let frameURL = try? captureStillFrame(from: videoURL) else { return nil }
        WallpaperDesktopPlatform.applyToAllDesktops(imagePath: frameURL.path)
        return frameURL.path
    }

    @discardableResult
    public func restoreWallpaperBackup() -> WallpaperRestoreStatus {
        WallpaperDesktopPlatform.restoreFromBackupFilesResult(
            appSupportPath: appSupportURL.path
        )
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    private func sourceRevision(for videoURL: URL) -> LastFrameSourceRevision {
        let standardizedURL = videoURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        return LastFrameSourceRevision(
            path: standardizedURL.path,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modifiedAt: (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970
        )
    }

    private func launchAgentProgramArguments(
        helperPath: String,
        configPath: String,
        nativeBridgePath: String?
    ) -> [String] {
        var arguments = [helperPath, "--config", configPath]
        if let nativeBridgePath {
            arguments.append(contentsOf: ["--native-bridge-path", nativeBridgePath])
        }
        return arguments
    }

    private func launchAgentPlistData(programArguments: [String]) throws -> Data {
        let plist: [String: Any] = [
            "Label": "com.andrijvergeles.auraflow",
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private func launchAgentPlistMatches(
        expectedProgramArguments: [String]
    ) -> Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              plist["Label"] as? String == "com.andrijvergeles.auraflow",
              plist["ProgramArguments"] as? [String] == expectedProgramArguments,
              plist["RunAtLoad"] as? Bool == true,
              plist["KeepAlive"] as? Bool == false
        else {
            return false
        }
        return true
    }

    private static func executeLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile()
                    + errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return LaunchctlResult(
                succeeded: task.terminationStatus == 0,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                terminationStatus: task.terminationStatus
            )
        } catch {
            return LaunchctlResult(
                succeeded: false,
                output: error.localizedDescription,
                terminationStatus: -1
            )
        }
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
