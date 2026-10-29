import Foundation

public enum AutostartManagerError: LocalizedError {
    public enum Operation: String, Sendable {
        case enable
        case disable
    }

    case configurationRollbackFailed(
        operation: Operation,
        primaryError: Error,
        rollbackError: Error
    )

    public var errorDescription: String? {
        switch self {
        case let .configurationRollbackFailed(operation, primaryError, rollbackError):
            return "Could not \(operation.rawValue) AuraFlow launch at login: "
                + "\(primaryError.localizedDescription); "
                + "rollback failed: \(rollbackError.localizedDescription)."
        }
    }
}

/// Coordinates persisted autostart configuration with the user's LaunchAgent.
///
/// Registration changes apply to future logins. Runtime migration/launching
/// is a separate operation and must never be triggered by the checkbox.
public final class AutostartManager {
    private let store: WallpaperRuntimeStore
    private let helperURL: URL
    private let nativeBridgeURL: URL?
    private let terminalHelperURL: URL
    private let sessionIdentifier: () -> String?
    private let registrationUpdater: ((Bool) throws -> Void)?

    public init(
        store: WallpaperRuntimeStore,
        helperURL: URL,
        nativeBridgeURL: URL? = nil,
        terminalHelperURL: URL? = nil,
        sessionIdentifier: @escaping () -> String? = { LockScreenSession.currentIdentifier() },
        registrationUpdater: ((Bool) throws -> Void)? = nil
    ) {
        self.store = store
        self.helperURL = helperURL.standardizedFileURL
        self.nativeBridgeURL = nativeBridgeURL?.standardizedFileURL
        self.terminalHelperURL = terminalHelperURL ?? helperURL.deletingLastPathComponent()
            .appendingPathComponent("AuraTerminalWallpaperAgent.app/Contents/MacOS/AuraTerminalWallpaperAgent")
        self.sessionIdentifier = sessionIdentifier
        self.registrationUpdater = registrationUpdater
    }

    public func migrateExistingLaunchAgentIfNeeded() throws {
        var config = store.loadConfig()
        let runtime = WallpaperLoginSelection.runtime(in: store)
        guard WallpaperLoginSelection.enabled(in: store),
              !config.isAutostartDeferred(in: sessionIdentifier()),
              WallpaperLoginSelection.hasSource(in: store, runtime: runtime)
        else {
            return
        }

        config.autostart = true
        config.login_wallpaper_runtime = runtime
        try store.saveConfig(config)
        if runtime == .terminal {
            try updateRegistration(true)
            // Retire an old video login job left loaded by an earlier
            // version. The saved selection authorizes Terminal, and only a
            // helper with verified Aura ownership may be terminated here.
            if store.daemonProcessStatus.isOwned {
                guard DaemonProcessManager(store: store, expectedExecutableURL: helperURL)
                    .terminate(timeout: 1.0).succeeded else {
                    throw WallpaperRuntimeError.unavailable("The previous wallpaper runtime did not stop before login restoration.")
                }
            }
            if !WallpaperLoginSelection.terminalRuntimeIsLive(in: store) {
                try store.startTerminalLoginJob()
            }
        } else {
            try store.enableLaunchAgent(helperPath: helperURL.path, nativeBridgePath: nativeBridgeURL?.path)
            try WallpaperLoginSelection.removeRegistration(at: WallpaperLoginSelection.terminalLaunchAgentURL(in: store))
        }
    }

    /// Commit only an applied source. This writes future-login files and never
    /// loads or unloads the process serving the current session.
    public func selectRuntime(_ runtime: WallpaperLoginRuntime) throws {
        let previous = store.loadConfig()
        var config = previous
        config.autostart = WallpaperLoginSelection.enabled(in: store)
        config.login_wallpaper_runtime = runtime
        if runtime != .removed { config.autostart_deferred_session_id = nil }
        try store.saveConfig(config)
        do { try updateRegistration(config.autostart == true && runtime != .removed) }
        catch { try? store.saveConfig(previous); throw error }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, runtime: WallpaperLoginRuntime = .video) throws -> ControlStatus {
        let previousConfig = store.loadConfig()
        var config = previousConfig

        if enabled {
            config = store.normalized(config)
            guard WallpaperLoginSelection.hasSource(in: store, runtime: runtime)
            else {
                throw WallpaperRuntimeError.unavailable(
                    "Choose an existing video before enabling launch at login."
                )
            }

            config.autostart = true
            config.login_wallpaper_runtime = runtime
            config.autostart_deferred_session_id = sessionIdentifier() ?? "unknown-login-session"
            config = store.normalized(config)
            try store.saveConfig(config)
            do {
                try updateRegistration(true)
            } catch let primaryError {
                do {
                    try store.saveConfig(previousConfig)
                } catch let rollbackError {
                    throw AutostartManagerError.configurationRollbackFailed(
                        operation: .enable,
                        primaryError: primaryError,
                        rollbackError: rollbackError
                    )
                }
                throw primaryError
            }
        } else {
            config.autostart = false
            config.login_wallpaper_runtime = runtime
            config.autostart_deferred_session_id = nil
            config = store.normalized(config)
            try store.saveConfig(config)
            do {
                try updateRegistration(false)
            } catch let primaryError {
                do {
                    try store.saveConfig(previousConfig)
                } catch let rollbackError {
                    throw AutostartManagerError.configurationRollbackFailed(
                        operation: .disable,
                        primaryError: primaryError,
                        rollbackError: rollbackError
                    )
                }
                throw primaryError
            }
        }

        return store.status()
    }

    private func updateRegistration(_ enabled: Bool) throws {
        if let registrationUpdater { try registrationUpdater(enabled); return }
        let terminalURL = WallpaperLoginSelection.terminalLaunchAgentURL(in: store)
        let terminalConfigURL = store.appSupportURL.appendingPathComponent("terminal-wallpaper/config.json")
        let snapshots = [store.launchAgentURL, terminalURL, terminalConfigURL].map { ($0, try? Data(contentsOf: $0)) }
        do {
            if enabled, store.loadConfig().login_wallpaper_runtime == .terminal {
                try WallpaperLoginSelection.registerTerminal(in: store, helperURL: terminalHelperURL)
                try store.removeLaunchAtLogin()
            } else if enabled {
                try store.registerLaunchAtLogin(helperPath: helperURL.path, nativeBridgePath: nativeBridgeURL?.path)
                try WallpaperLoginSelection.removeRegistration(at: terminalURL)
            } else {
                try store.removeLaunchAtLogin()
                try WallpaperLoginSelection.removeRegistration(at: terminalURL)
            }
            // Keep old controller/helper versions from re-registering a second
            // login job from their engine-specific compatibility flag.
            if var terminal = WallpaperLoginSelection.terminalConfiguration(in: store) {
                var behavior = terminal["behavior"] as? [String: Any] ?? [:]
                behavior["launchAtLogin"] = enabled && store.loadConfig().login_wallpaper_runtime == .terminal
                terminal["behavior"] = behavior
                try JSONSerialization.data(withJSONObject: terminal, options: [.prettyPrinted, .sortedKeys])
                    .write(to: terminalConfigURL, options: .atomic)
            }
        } catch {
            for (url, data) in snapshots {
                if let data { try? data.write(to: url, options: .atomic) }
                else { try? WallpaperLoginSelection.removeRegistration(at: url) }
            }
            throw error
        }
    }
}
