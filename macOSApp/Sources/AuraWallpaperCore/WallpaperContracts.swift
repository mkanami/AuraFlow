import AVFoundation
import Foundation

public struct ControlConfig: Codable, Equatable {
    public var video_path: String
    public var playback_speed: Double
    public var volume: Double?
    public var autostart: Bool?
    public var blend_interpolation: Bool?
    public var pause_on_fullscreen: Bool?
    public var show_on_lock_screen: Bool?
    public var lock_screen_preference_configured: Bool?
    public var scale_mode: String?

    public init(
        video_path: String,
        playback_speed: Double,
        volume: Double? = 0,
        autostart: Bool? = false,
        blend_interpolation: Bool? = false,
        pause_on_fullscreen: Bool? = true,
        show_on_lock_screen: Bool? = false,
        lock_screen_preference_configured: Bool? = false,
        scale_mode: String? = WallpaperScaleMode.fill.rawValue
    ) {
        self.video_path = video_path
        self.playback_speed = playback_speed
        self.volume = volume
        self.autostart = autostart
        self.blend_interpolation = blend_interpolation
        self.pause_on_fullscreen = pause_on_fullscreen
        self.show_on_lock_screen = show_on_lock_screen
        self.lock_screen_preference_configured =
            lock_screen_preference_configured
        self.scale_mode = scale_mode
    }

    public static let defaultConfig = ControlConfig(
        video_path: "",
        playback_speed: 1.0,
        show_on_lock_screen: true,
        lock_screen_preference_configured: false
    )
}

public struct ControlStatus: Codable, Equatable {
    public var contract_version: Int?
    public var running: Bool
    public var config: ControlConfig
    public var pid: Int?
    public var autostart: Bool?
    public var paused: Bool?
    public var wallpaper_restored: Bool?
    public var wallpaper: String?
    public var health: DaemonHealth?

    public init(
        contract_version: Int? = AuraWallpaperContract.statusVersion,
        running: Bool,
        config: ControlConfig,
        pid: Int? = nil,
        autostart: Bool? = nil,
        paused: Bool? = nil,
        wallpaper_restored: Bool? = nil,
        wallpaper: String? = nil,
        health: DaemonHealth? = nil
    ) {
        self.contract_version = contract_version
        self.running = running
        self.config = config
        self.pid = pid
        self.autostart = autostart
        self.paused = paused
        self.wallpaper_restored = wallpaper_restored
        self.wallpaper = wallpaper
        self.health = health
    }
}

public struct DaemonHealth: Codable, Equatable {
    public var contract_version: Int?
    public var available: Bool?
    public var fresh: Bool?
    public var suspicious: Bool?
    public var reason: String?
    public var updated_at: Double?
    public var lag_seconds: Double?
    public var screens: Int?
    public var windows: Int?
    public var player_rate: Double?
    public var stall_events: Int?
    public var recovery_events: Int?
    public var consecutive_stall_polls: Int?
    public var paused: Bool?
    public var manual_paused: Bool?
    public var low_power_mode: Bool?
    public var auto_paused_for_low_power: Bool?
    public var pause_on_fullscreen: Bool?
    public var fullscreen_app_detected: Bool?
    public var auto_paused_for_fullscreen: Bool?
    public var lock_screen_enabled: Bool?
    public var session_inactive: Bool?
    public var lock_screen_preview_active: Bool?
    public var presentation_mode: String?
    public var lock_transition_count: Int?
    public var last_lock_transition_ms: Double?
    public var blend_interpolation_enabled: Bool?
    public var blend_interpolation_active: Bool?
    public var scale_mode: String?

    public init(
        contract_version: Int? = AuraWallpaperContract.statusVersion,
        available: Bool? = nil,
        fresh: Bool? = nil,
        suspicious: Bool? = nil,
        reason: String? = nil,
        updated_at: Double? = nil,
        lag_seconds: Double? = nil,
        screens: Int? = nil,
        windows: Int? = nil,
        player_rate: Double? = nil,
        stall_events: Int? = nil,
        recovery_events: Int? = nil,
        consecutive_stall_polls: Int? = nil,
        paused: Bool? = nil,
        manual_paused: Bool? = nil,
        low_power_mode: Bool? = nil,
        auto_paused_for_low_power: Bool? = nil,
        pause_on_fullscreen: Bool? = nil,
        fullscreen_app_detected: Bool? = nil,
        auto_paused_for_fullscreen: Bool? = nil,
        lock_screen_enabled: Bool? = nil,
        session_inactive: Bool? = nil,
        lock_screen_preview_active: Bool? = nil,
        presentation_mode: String? = nil,
        lock_transition_count: Int? = nil,
        last_lock_transition_ms: Double? = nil,
        blend_interpolation_enabled: Bool? = nil,
        blend_interpolation_active: Bool? = nil,
        scale_mode: String? = nil
    ) {
        self.contract_version = contract_version
        self.available = available
        self.fresh = fresh
        self.suspicious = suspicious
        self.reason = reason
        self.updated_at = updated_at
        self.lag_seconds = lag_seconds
        self.screens = screens
        self.windows = windows
        self.player_rate = player_rate
        self.stall_events = stall_events
        self.recovery_events = recovery_events
        self.consecutive_stall_polls = consecutive_stall_polls
        self.paused = paused
        self.manual_paused = manual_paused
        self.low_power_mode = low_power_mode
        self.auto_paused_for_low_power = auto_paused_for_low_power
        self.pause_on_fullscreen = pause_on_fullscreen
        self.fullscreen_app_detected = fullscreen_app_detected
        self.auto_paused_for_fullscreen = auto_paused_for_fullscreen
        self.lock_screen_enabled = lock_screen_enabled
        self.session_inactive = session_inactive
        self.lock_screen_preview_active = lock_screen_preview_active
        self.presentation_mode = presentation_mode
        self.lock_transition_count = lock_transition_count
        self.last_lock_transition_ms = last_lock_transition_ms
        self.blend_interpolation_enabled = blend_interpolation_enabled
        self.blend_interpolation_active = blend_interpolation_active
        self.scale_mode = scale_mode
    }
}

public enum WallpaperScaleMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fill:
            return "Fill"
        case .fit:
            return "Fit"
        case .stretch:
            return "Stretch"
        }
    }

    public var commandValue: String { rawValue }

    public var previewGravity: AVLayerVideoGravity {
        switch self {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }
}

public struct DaemonMetrics: Codable, Equatable {
    public var contract_version: Int?
    public var updated_at: Double?
    public var running: Bool
    public var paused: Bool?
    public var pid: Int?
    public var daemon_pids: [Int]?
    public var process_count: Int?
    public var cpu_percent: Double?
    public var memory_mb: Double?
    public var virtual_memory_mb: Double?
    public var thread_count: Int?
    public var health: DaemonHealth?

    public init(
        contract_version: Int? = AuraWallpaperContract.statusVersion,
        updated_at: Double? = nil,
        running: Bool,
        paused: Bool? = nil,
        pid: Int? = nil,
        daemon_pids: [Int]? = nil,
        process_count: Int? = nil,
        cpu_percent: Double? = nil,
        memory_mb: Double? = nil,
        virtual_memory_mb: Double? = nil,
        thread_count: Int? = nil,
        health: DaemonHealth? = nil
    ) {
        self.contract_version = contract_version
        self.updated_at = updated_at
        self.running = running
        self.paused = paused
        self.pid = pid
        self.daemon_pids = daemon_pids
        self.process_count = process_count
        self.cpu_percent = cpu_percent
        self.memory_mb = memory_mb
        self.virtual_memory_mb = virtual_memory_mb
        self.thread_count = thread_count
        self.health = health
    }
}

public enum AuraWallpaperContract {
    public static let statusVersion = 3
}
