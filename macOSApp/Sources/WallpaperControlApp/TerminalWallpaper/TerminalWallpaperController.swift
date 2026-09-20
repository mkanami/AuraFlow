import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation

protocol TerminalWallpaperControlling {
    func status() throws -> TerminalWallpaperStatus
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func stop() throws -> TerminalWallpaperStatus
    func terminate() throws -> TerminalWallpaperStatus
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
}

enum TerminalWallpaperControllerError: LocalizedError, Equatable {
    case unavailable(String)
    case videoWallpaperAlreadyRunning
    case guiApplicationNotSupported

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .videoWallpaperAlreadyRunning:
            return "Stop the video wallpaper before starting Terminal Wallpaper."
        case .guiApplicationNotSupported:
            return "A GUI .app cannot be rendered as a terminal wallpaper. Choose a command-line executable or TUI app."
        }
    }
}

final class NativeTerminalWallpaperController: TerminalWallpaperControlling {
    private let store: TerminalWallpaperRuntimeStore
    private let helperURL: URL
    private let videoRuntimeIsRunning: () -> Bool

    init(
        store: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        helperURL: URL? = nil,
        videoRuntimeIsRunning: (() -> Bool)? = nil
    ) throws {
        self.store = store
        self.helperURL = try Self.resolveHelperURL(explicitURL: helperURL)
        self.videoRuntimeIsRunning = videoRuntimeIsRunning ?? {
            WallpaperRuntimeStore().status().running
        }
    }

    func status() throws -> TerminalWallpaperStatus {
        store.status()
    }

    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        let normalized = try validated(config)
        if videoRuntimeIsRunning() {
            throw TerminalWallpaperControllerError.videoWallpaperAlreadyRunning
        }
        try store.saveConfig(normalized)
        try applyLaunchAtLogin(normalized)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.restart, config: normalized)
        } else {
            try launchAgent()
            try send(.start, config: normalized)
        }
        return store.status()
    }

    func stop() throws -> TerminalWallpaperStatus {
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
        return store.status()
    }

    func terminate() throws -> TerminalWallpaperStatus {
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
        return store.status()
    }

    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        let normalized = try validated(config)
        if videoRuntimeIsRunning() {
            throw TerminalWallpaperControllerError.videoWallpaperAlreadyRunning
        }
        try store.saveConfig(normalized)
        try applyLaunchAtLogin(normalized)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.restart, config: normalized)
        } else {
            try launchAgent()
            try send(.start, config: normalized)
        }
        return store.status()
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
        let bundleCandidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AuraTerminalWallpaperAgent")
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
}
