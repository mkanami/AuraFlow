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
    private let sessionIdentifier: () -> String?
    private let registrationUpdater: ((Bool) throws -> Void)?

    public init(
        store: WallpaperRuntimeStore,
        helperURL: URL,
        nativeBridgeURL: URL? = nil,
        sessionIdentifier: @escaping () -> String? = { LockScreenSession.currentIdentifier() },
        registrationUpdater: ((Bool) throws -> Void)? = nil
    ) {
        self.store = store
        self.helperURL = helperURL.standardizedFileURL
        self.nativeBridgeURL = nativeBridgeURL?.standardizedFileURL
        self.sessionIdentifier = sessionIdentifier
        self.registrationUpdater = registrationUpdater
    }

    public func migrateExistingLaunchAgentIfNeeded() throws {
        let config = store.loadConfig()
        guard config.autostart == true,
              !config.isAutostartDeferred(in: sessionIdentifier()),
              let source = store.effectiveLockScreenSourceURL(for: config),
              FileManager.default.fileExists(atPath: source.path)
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
            guard let source = store.effectiveLockScreenSourceURL(for: config),
                  FileManager.default.fileExists(atPath: source.path)
            else {
                throw WallpaperRuntimeError.unavailable(
                    "Choose an existing video before enabling launch at login."
                )
            }

            config.autostart = true
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
        if enabled {
            try store.registerLaunchAtLogin(helperPath: helperURL.path, nativeBridgePath: nativeBridgeURL?.path)
        } else {
            try store.removeLaunchAtLogin()
        }
    }
}
