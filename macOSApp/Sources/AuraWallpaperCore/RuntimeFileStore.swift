import Foundation

/// Owns the filesystem layout and atomic JSON primitives for the wallpaper
/// runtime. Higher-level runtime components use this boundary instead of
/// reconstructing paths or implementing their own replacement writes.
public final class RuntimeFileStore {
    public let appSupportURL: URL
    public let launchAgentURL: URL

    public init(
        appSupportURL: URL,
        launchAgentURL: URL? = nil
    ) {
        self.appSupportURL = appSupportURL.standardizedFileURL
        self.launchAgentURL = launchAgentURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/LaunchAgents/com.andrijvergeles.auraflow.plist"
                )
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
    public var lockScreenAgentStartedURL: URL {
        appSupportURL.appendingPathComponent("lock_screen_agent_started")
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: readData(from: url))
    }

    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
