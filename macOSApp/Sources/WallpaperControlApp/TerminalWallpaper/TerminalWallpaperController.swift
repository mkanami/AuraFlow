import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation

protocol TerminalWallpaperControlling: Sendable {
    func reconcileLockScreenIfRunning() throws
    func ensureCanStart() throws
    func status() throws -> TerminalWallpaperStatus
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func stop() throws -> TerminalWallpaperStatus
    func terminate() throws -> TerminalWallpaperStatus
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
}

protocol TerminalLockScreenCoordinating: Sendable {
    func activate() throws
    func restore() throws
}

private final class SystemTerminalLockScreenCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    private let installer = LockScreenSaverInstaller()

    func activate() throws { try installer.activateForTerminal() }
    func restore() throws { try installer.restoreAfterTerminal() }
}

extension TerminalWallpaperControlling {
    func ensureCanStart() throws {}
    func reconcileLockScreenIfRunning() throws {}
}

enum TerminalWallpaperControllerError: LocalizedError, Equatable {
    case unavailable(String)
    case videoWallpaperAlreadyRunning
    case lockScreenVideoAlreadyRunning
    case guiApplicationNotSupported

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .videoWallpaperAlreadyRunning:
            return "Stop the video wallpaper before starting Terminal Wallpaper."
        case .lockScreenVideoAlreadyRunning:
            return "Stop the Lock Screen-only video before using Terminal Wallpaper on the Lock Screen."
        case .guiApplicationNotSupported:
            return "A GUI .app cannot be rendered as a terminal wallpaper. Choose a command-line executable or TUI app."
        }
    }
}

final class NativeTerminalWallpaperController: TerminalWallpaperControlling, @unchecked Sendable {
    private let store: TerminalWallpaperRuntimeStore
    private let helperURL: URL
    private let videoRuntimeIsRunning: () -> Bool
    private let lockScreenVideoIsActive: () -> Bool
    private let lockScreenCoordinator: any TerminalLockScreenCoordinating
    private let lockScreenOperationLock = NSLock()

    init(
        store: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        helperURL: URL? = nil,
        videoRuntimeIsRunning: (() -> Bool)? = nil,
        lockScreenVideoIsActive: (() -> Bool)? = nil,
        lockScreenCoordinator: (any TerminalLockScreenCoordinating)? = nil
    ) throws {
        self.store = store
        self.helperURL = try Self.resolveHelperURL(explicitURL: helperURL)
        self.videoRuntimeIsRunning = videoRuntimeIsRunning ?? {
            WallpaperRuntimeStore().status().running
        }
        self.lockScreenVideoIsActive = lockScreenVideoIsActive ?? {
            FileManager.default.fileExists(
                atPath: WallpaperRuntimeStore.defaultAppSupportURL()
                    .appendingPathComponent("lock_screen_only_source.json").path
            )
        }
        self.lockScreenCoordinator = lockScreenCoordinator ?? SystemTerminalLockScreenCoordinator()
    }

    func status() throws -> TerminalWallpaperStatus {
        store.status()
    }

    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        let normalized = try validated(config)
        try ensureCanStart()
        let wasRunning = store.processIsAlive(pid: store.loadPID())
        try lockScreenCoordinator.activate()
        do {
            try store.saveConfig(normalized)
            try applyLaunchAtLogin(normalized)
            if wasRunning {
                try send(.restart, config: normalized)
            } else {
                try launchAgent()
                try send(.start, config: normalized)
            }
        } catch {
            if !wasRunning { try? lockScreenCoordinator.restore() }
            throw error
        }
        return store.status()
    }

    func stop() throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.stop, config: store.loadConfig())
            guard store.terminateAgent(timeout: 2) else {
                throw TerminalWallpaperControllerError.unavailable(
                    "The Terminal Wallpaper agent did not stop."
                )
            }
        }
        store.removeCommand()
        store.removeHealth()
        store.removeLockScreenPublication()
        try lockScreenCoordinator.restore()
        return store.status()
    }

    func terminate() throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.terminate, config: store.loadConfig())
            guard store.terminateAgent(timeout: 2) else {
                throw TerminalWallpaperControllerError.unavailable(
                    "The Terminal Wallpaper agent did not terminate."
                )
            }
        }
        store.removeCommand()
        store.removeHealth()
        store.removeLockScreenPublication()
        try lockScreenCoordinator.restore()
        return store.status()
    }

    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        try start(config: config)
    }

    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        let normalized = try validated(config)
        let previous = store.loadConfig()
        try store.saveConfig(normalized)
        if store.processIsAlive(pid: store.loadPID()) {
            let action: TerminalWallpaperCommandAction = previous.command == normalized.command
                ? .update
                : .restart
            try send(action, config: normalized)
        }
        return store.status()
    }

    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        let normalized = try validated(config)
        try store.saveConfig(normalized)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.resize, config: normalized)
        }
        return store.status()
    }

    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        var normalized = try validated(config)
        normalized.behavior.launchAtLogin = enabled
        try store.saveConfig(normalized)
        if enabled {
            try store.enableLaunchAgent(helperPath: helperURL.path)
        } else {
            store.disableLaunchAgent()
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: normalized)
        }
        return store.status()
    }

    private func applyLaunchAtLogin(_ config: TerminalWallpaperConfig) throws {
        if config.behavior.launchAtLogin {
            try store.enableLaunchAgent(helperPath: helperURL.path)
        } else if store.launchAgentEnabled() {
            store.disableLaunchAgent()
        }
    }

    func ensureCanStart() throws {
        if videoRuntimeIsRunning() {
            throw TerminalWallpaperControllerError.videoWallpaperAlreadyRunning
        }
        if lockScreenVideoIsActive() {
            throw TerminalWallpaperControllerError.lockScreenVideoAlreadyRunning
        }
    }

    func reconcileLockScreenIfRunning() throws {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        guard store.processIsAlive(pid: store.loadPID()) else { return }
        try ensureCanStart()
        try lockScreenCoordinator.activate()
    }

    private func validated(_ config: TerminalWallpaperConfig) throws -> TerminalWallpaperConfig {
        let normalized = config.normalized()
        guard !normalized.command.executable.isEmpty else {
            throw TerminalWallpaperControllerError.unavailable("Enter an executable command first.")
        }
        if normalized.command.executable.lowercased().hasSuffix(".app") {
            throw TerminalWallpaperControllerError.guiApplicationNotSupported
        }
        if let catalogItemID = normalized.command.catalogItemID,
           let catalogItem = TerminalWallpaperCatalog.item(id: catalogItemID),
           catalogItem.resolvedExecutable() == nil {
            throw TerminalWallpaperControllerError.unavailable(
                "\(catalogItem.title) is not installed or is no longer available."
            )
        }
        return normalized
    }

    private func send(_ action: TerminalWallpaperCommandAction, config: TerminalWallpaperConfig) throws {
        try store.saveCommand(TerminalWallpaperRuntimeCommand(action: action, config: config))
        DistributedNotificationCenter.default().post(
            name: TerminalWallpaperRuntimeNotifications.commandDidChange,
            object: nil,
            userInfo: nil
        )
    }

    private func launchAgent() throws {
        let task = Process()
        task.executableURL = helperURL
        task.arguments = ["--config", store.configURL.path]
        do {
            try task.run()
            try store.savePID(task.processIdentifier)
        } catch {
            throw TerminalWallpaperControllerError.unavailable(
                "Could not launch Terminal Wallpaper agent: \(error.localizedDescription)"
            )
        }
    }

    private static func resolveHelperURL(explicitURL: URL?) throws -> URL {
        if let explicitURL {
            guard FileManager.default.isExecutableFile(atPath: explicitURL.path) else {
                throw TerminalWallpaperControllerError.unavailable(
                    "Terminal Wallpaper agent is not executable: \(explicitURL.path)"
                )
            }
            return explicitURL
        }
        if let override = ProcessInfo.processInfo.environment["AURAFLOW_TERMINAL_AGENT_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundleCandidate = bundledHelperURL(in: Bundle.main.bundleURL)
        if FileManager.default.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("AuraTerminalWallpaperAgent")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        throw TerminalWallpaperControllerError.unavailable(
            "Terminal Wallpaper agent is not bundled with AuraFlow."
        )
    }

    static func bundledHelperURL(in appURL: URL) -> URL {
        appURL.appendingPathComponent(
            "Contents/Helpers/AuraTerminalWallpaperAgent.app/Contents/MacOS/AuraTerminalWallpaperAgent"
        )
    }
}
