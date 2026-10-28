import Darwin
import Foundation

public enum TerminalWallpaperRuntimeNotifications {
    public static let lockScreenRouteDidChange = Notification.Name(
        "com.andrijvergeles.auraflow.terminal-lock-screen-route-did-change"
    )
    public static let commandDidChange = Notification.Name(
        "com.andrijvergeles.auraflow.terminal-runtime-command-did-change"
    )
    public static let agentDidStart = Notification.Name(
        "com.andrijvergeles.auraflow.terminal-agent-did-start"
    )
    public static let sharedFrameDidUpdate = Notification.Name(
        "com.andrijvergeles.auraflow.terminal-shared-frame-did-update"
    )
}

/// Identifies the live Metal surface produced by the current terminal agent.
/// The IOSurface is shared directly; this descriptor only carries its identity.
public struct TerminalSharedFrameDescriptor: Codable, Equatable, Sendable {
    public let surfaceID: UInt32
    public let width: Int
    public let height: Int
    public let agentPID: Int
    public let generation: String

    public init(
        surfaceID: UInt32,
        width: Int,
        height: Int,
        agentPID: Int,
        generation: String = UUID().uuidString
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.agentPID = agentPID
        self.generation = generation
    }
}

/// A short-lived publication lease for the separate screen-saver process.
/// The saver must not show a stale frame after the terminal agent exits.
public struct TerminalLockScreenHeartbeat: Codable, Equatable, Sendable {
    public let pid: Int
    public let updatedAt: TimeInterval

    public init(pid: Int, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.pid = pid
        self.updatedAt = updatedAt
    }

    public func isFresh(at time: TimeInterval, maxAge: TimeInterval = 6) -> Bool {
        pid > 0 && time >= updatedAt && time - updatedAt <= maxAge
    }
}

public final class TerminalWallpaperRuntimeStore: Sendable {
    private struct ProcessIdentity: Codable {
        let pid: Int32
        let startTimeMicros: UInt64
    }
    public let appSupportURL: URL
    private let launchAgentURL: URL

    public init(
        appSupportURL: URL = TerminalWallpaperRuntimeStore.defaultAppSupportURL(),
        launchAgentURL: URL? = nil
    ) {
        self.appSupportURL = appSupportURL
        self.launchAgentURL = launchAgentURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.andrijvergeles.auraflow.terminal-wallpaper.plist")
    }

    public static func defaultAppSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuraFlow/terminal-wallpaper", isDirectory: true)
    }

    public var configURL: URL { appSupportURL.appendingPathComponent("config.json") }
    public var commandURL: URL { appSupportURL.appendingPathComponent("command.json") }
    public var healthURL: URL { appSupportURL.appendingPathComponent("health.json") }
    public var pauseURL: URL { appSupportURL.appendingPathComponent("paused") }
    public var pidURL: URL { appSupportURL.appendingPathComponent("agent.pid") }
    private var identityURL: URL { appSupportURL.appendingPathComponent("agent-identity.json") }
    public var lockScreenFrameURL: URL { appSupportURL.appendingPathComponent("lock-screen-frame.png") }
    public var lockScreenHeartbeatURL: URL { appSupportURL.appendingPathComponent("lock-screen-heartbeat.json") }
    public var sharedFrameDescriptorURL: URL { appSupportURL.appendingPathComponent("shared-frame.json") }
    public var launchAgentFileURL: URL { launchAgentURL }

    // Both runtimes use the application's checkbox. Keep this outside the
    // terminal command config so an old saved preset cannot re-enable Lock.
    public var lockScreenPlaybackEnabled: Bool {
        let url = appSupportURL.deletingLastPathComponent().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return config["show_on_lock_screen"] as? Bool ?? true
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupportURL.path)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func saveLockScreenHeartbeat(_ heartbeat: TerminalLockScreenHeartbeat) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(heartbeat)
        try data.write(to: lockScreenHeartbeatURL, options: .atomic)
    }

    public func loadLockScreenHeartbeat() -> TerminalLockScreenHeartbeat? {
        guard let data = try? Data(contentsOf: lockScreenHeartbeatURL) else { return nil }
        return try? JSONDecoder().decode(TerminalLockScreenHeartbeat.self, from: data)
    }

    public func removeLockScreenPublication() {
        try? FileManager.default.removeItem(at: lockScreenHeartbeatURL)
        try? FileManager.default.removeItem(at: lockScreenFrameURL)
    }

    public func saveSharedFrameDescriptor(_ descriptor: TerminalSharedFrameDescriptor) throws {
        try ensureDirectories()
        let data = try JSONEncoder.terminalEncoder.encode(descriptor)
        try data.write(to: sharedFrameDescriptorURL, options: .atomic)
    }

    public func loadSharedFrameDescriptor() -> TerminalSharedFrameDescriptor? {
        guard let data = try? Data(contentsOf: sharedFrameDescriptorURL) else { return nil }
        return try? JSONDecoder.terminalDecoder.decode(TerminalSharedFrameDescriptor.self, from: data)
    }

    public func removeSharedFrameDescriptor() {
        try? FileManager.default.removeItem(at: sharedFrameDescriptorURL)
    }

    public func loadConfig() -> TerminalWallpaperConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(TerminalWallpaperConfig.self, from: data)
        else {
            return .defaultConfig
        }
        return config.normalized()
    }

    public func saveConfig(_ config: TerminalWallpaperConfig) throws {
        try ensureDirectories()
        let data = try JSONEncoder.terminalEncoder.encode(config.normalized())
        try data.write(to: configURL, options: .atomic)
    }

    public func loadCommand() -> TerminalWallpaperRuntimeCommand? {
        guard let data = try? Data(contentsOf: commandURL) else { return nil }
        return try? JSONDecoder.terminalDecoder.decode(TerminalWallpaperRuntimeCommand.self, from: data)
    }

    public func saveCommand(_ command: TerminalWallpaperRuntimeCommand) throws {
        try ensureDirectories()
        let data = try JSONEncoder.terminalEncoder.encode(command)
        try data.write(to: commandURL, options: .atomic)
    }

    public func removeCommand() {
        try? FileManager.default.removeItem(at: commandURL)
    }

    public func loadHealth() -> TerminalWallpaperHealth? {
        guard let data = try? Data(contentsOf: healthURL) else { return nil }
        return try? JSONDecoder.terminalDecoder.decode(TerminalWallpaperHealth.self, from: data)
    }

    public func saveHealth(_ health: TerminalWallpaperHealth) throws {
        try ensureDirectories()
        let data = try JSONEncoder.terminalEncoder.encode(health)
        try data.write(to: healthURL, options: .atomic)
    }

    public func removeHealth() {
        try? FileManager.default.removeItem(at: healthURL)
    }

    public func loadPID() -> Int? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func savePID(_ pid: Int32 = getpid()) throws {
        try ensureDirectories()
        guard let start = Self.processStartTime(pid) else {
            throw CocoaError(.fileReadUnknown)
        }
        try JSONEncoder().encode(ProcessIdentity(pid: pid, startTimeMicros: start))
            .write(to: identityURL, options: .atomic)
        try "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    public func removePID() {
        try? FileManager.default.removeItem(at: pidURL)
        try? FileManager.default.removeItem(at: identityURL)
    }

    public func processIsAlive(pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        guard kill(pid_t(pid), 0) == 0 || errno == EPERM else { return false }
        if let data = try? Data(contentsOf: identityURL) {
            guard let identity = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
                  identity.pid == pid,
                  let actual = Self.processStartTime(pid_t(pid)) else { return false }
            return identity.startTimeMicros == actual
        }
        // Compatibility with older helpers: existence alone is not ownership.
        // A reboot can reuse the persisted PID for an unrelated application.
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid_t(pid), &path, UInt32(path.count)) > 0 &&
            URL(fileURLWithPath: String(cString: path)).lastPathComponent == "AuraTerminalWallpaperAgent"
    }

    private static func processStartTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    public var isPlaybackPaused: Bool { FileManager.default.fileExists(atPath: pauseURL.path) }

    public func setPlaybackPaused(_ paused: Bool) throws {
        if paused {
            try ensureDirectories()
            try Data().write(to: pauseURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: pauseURL.path) {
            try FileManager.default.removeItem(at: pauseURL)
        }
    }

    public func status() -> TerminalWallpaperStatus {
        let config = loadConfig()
        let pid = loadPID()
        let running = processIsAlive(pid: pid)
        return TerminalWallpaperStatus(
            running: running,
            paused: running && isPlaybackPaused,
            pid: running ? pid : nil,
            config: config,
            health: loadHealth()
        )
    }

    public func launchAgentEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func enableLaunchAgent(helperPath: String) throws {
        try ensureDirectories()
        let label = "com.andrijvergeles.auraflow.terminal-wallpaper"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(helperPath.xmlEscaped)</string>
            <string>--config</string>
            <string>\(configURL.path.xmlEscaped)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <false/>
        </dict>
        </plist>
        """
        // launchd reads ~/Library/LaunchAgents on the next login. Registering
        // it now would create a second helper alongside a manually started CLI.
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
    }

    public func disableLaunchAgent() {
        try? removeLoginLaunchAgent()
    }

    public func removeLoginLaunchAgent() throws {
        // Removing future startup must leave this session's CLI and frame alive.
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        try FileManager.default.removeItem(at: launchAgentURL)
    }

    @discardableResult
    public func terminateAgent(timeout: TimeInterval = 1.5) -> Bool {
        guard let pid = loadPID(), processIsAlive(pid: pid) else {
            removePID()
            return true
        }
        kill(pid_t(pid), SIGTERM)
        let deadline = Date().addingTimeInterval(max(timeout, 0.2))
        while Date() < deadline {
            if !processIsAlive(pid: pid) {
                removePID()
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid_t(pid), SIGKILL)
        removePID()
        return !processIsAlive(pid: pid)
    }
}

private extension JSONEncoder {
    static var terminalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var terminalDecoder: JSONDecoder { JSONDecoder() }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
