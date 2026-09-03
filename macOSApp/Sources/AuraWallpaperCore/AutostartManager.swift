import Foundation

/// Coordinates persisted autostart configuration with the user's LaunchAgent.
///
/// The config is written only after validation and is restored when launchctl
/// rejects the requested state. This keeps the UI from reporting a state that
/// the system did not actually accept.
public final class AutostartManager {
    private let store: WallpaperRuntimeStore
    private let helperURL: URL
    private let nativeBridgeURL: URL?

    public init(
        store: WallpaperRuntimeStore,
        helperURL: URL,
        nativeBridgeURL: URL? = nil
    ) {
        self.store = store
        self.helperURL = helperURL.standardizedFileURL
        self.nativeBridgeURL = nativeBridgeURL?.standardizedFileURL
    }

    public func migrateExistingLaunchAgentIfNeeded() throws {
        guard store.launchAgentPlistExists(),
              store.loadConfig().autostart == true
        else {
            return
        }

        try store.enableLaunchAgent(
            helperPath: helperURL.path,
            nativeBridgePath: nativeBridgeURL?.path
        )
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> ControlStatus {
        let previousConfig = store.loadConfig()
        var config = previousConfig

        if enabled {
            config = store.normalized(config)
            guard !config.video_path.isEmpty,
                  FileManager.default.fileExists(atPath: config.video_path)
            else {
                throw WallpaperRuntimeError.unavailable(
                    "Choose an existing video before enabling launch at login."
                )
            }

            config.autostart = true
            config = store.normalized(config)
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
            do {
                try store.disableLaunchAgent()
            } catch {
                try? store.saveConfig(previousConfig)
                throw error
            }
        }

        return store.status()
    }
}
