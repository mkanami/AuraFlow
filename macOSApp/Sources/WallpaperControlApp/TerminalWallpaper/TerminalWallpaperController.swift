import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation
import AuraWallpaperEngineCore

protocol TerminalWallpaperControlling: Sendable {
    func reconcileLockScreenIfRunning() throws
    func ensureCanStart() throws
    func status() throws -> TerminalWallpaperStatus
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func stop() throws -> TerminalWallpaperStatus
    func setPlaybackPaused(_ paused: Bool) throws -> TerminalWallpaperStatus
    func terminate() throws -> TerminalWallpaperStatus
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func updateScaleMode(_ mode: TerminalScaleMode) throws -> TerminalWallpaperStatus
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus
}

protocol TerminalLockScreenCoordinating: Sendable {
    func activate() throws
    func restore() throws
    func restoreUserWallpaper() throws
}

extension TerminalLockScreenCoordinating {
    func restoreUserWallpaper() throws { try restore() }
}

private final class SystemTerminalLockScreenCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    private let installer = LockScreenSaverInstaller()

    func activate() throws {
        try installer.activateForTerminal()
        DistributedNotificationCenter.default().postNotificationName(
            TerminalWallpaperRuntimeNotifications.lockScreenRouteDidChange,
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }
    func restore() throws { try installer.restoreAfterTerminal() }
    func restoreUserWallpaper() throws { try installer.restoreAfterTerminal(preferCurrentDesktop: true) }
}

extension TerminalWallpaperControlling {
    func ensureCanStart() throws {}
    func reconcileLockScreenIfRunning() throws {}
    func setPlaybackPaused(_ paused: Bool) throws -> TerminalWallpaperStatus {
        throw TerminalWallpaperControllerError.unavailable("Playback controls are unavailable.")
    }
    func updateScaleMode(_ mode: TerminalScaleMode) throws -> TerminalWallpaperStatus {
        throw TerminalWallpaperControllerError.unavailable("Scale updates are unavailable.")
    }
}

enum TerminalWallpaperControllerError: LocalizedError, Equatable {
    case unavailable(String)
    case videoWallpaperAlreadyRunning
    case lockScreenVideoAlreadyRunning
    case lockScreenFrameNotReady
    case guiApplicationNotSupported

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .videoWallpaperAlreadyRunning:
            return "Stop the video wallpaper before starting Terminal Wallpaper."
        case .lockScreenVideoAlreadyRunning:
            return "Stop the Lock Screen-only video before using Terminal Wallpaper on the Lock Screen."
        case .lockScreenFrameNotReady:
            return "Terminal Wallpaper is running on the desktop, but has not published a fresh Lock Screen frame yet. Check Runtime health and try Restart."
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
    private let lockScreenFrameReadinessWaiter: (TimeInterval, String?) -> Bool
    // Preview speed updates use a separate controller instance. Serialize them
    // with Start/Remove so a stale slider event cannot restore an old command.
    private static let runtimeMutationLock = NSRecursiveLock()
    private var lockScreenOperationLock: NSRecursiveLock { Self.runtimeMutationLock }

    init(
        store: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        helperURL: URL? = nil,
        videoRuntimeIsRunning: (() -> Bool)? = nil,
        lockScreenVideoIsActive: (() -> Bool)? = nil,
        lockScreenCoordinator: (any TerminalLockScreenCoordinating)? = nil,
        lockScreenFrameReadinessWaiter: ((TimeInterval, String?) -> Bool)? = nil
    ) throws {
        self.store = store
        self.helperURL = try Self.resolveHelperURL(explicitURL: helperURL)
        self.videoRuntimeIsRunning = videoRuntimeIsRunning ?? {
            WallpaperRuntimeStore().status().running
        }
        self.lockScreenVideoIsActive = lockScreenVideoIsActive ?? {
            let videoStore = WallpaperRuntimeStore()
            return videoStore.loadConfig().show_on_lock_screen != false
                && videoStore.loadLockScreenOnlySource() != nil
        }
        self.lockScreenCoordinator = lockScreenCoordinator ?? SystemTerminalLockScreenCoordinator()
        self.lockScreenFrameReadinessWaiter = lockScreenFrameReadinessWaiter ?? {
            [store] startedAt, previousRevision in
            Self.waitForLockScreenFrame(
                in: store,
                startedAt: startedAt,
                previousRevision: previousRevision
            )
        }
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
        let startedAt = Date().timeIntervalSince1970
        let previousFrameRevision = Self.lockScreenFrameRevision(in: store)
        do {
            try store.setPlaybackPaused(false)
            try store.saveConfig(normalized)
            try applyLaunchAtLogin(normalized)
            if wasRunning {
                try send(.restart, config: normalized)
            } else {
                try launchAgent()
                try send(.start, config: normalized)
            }
            // Match the ordinary wallpaper Start sequence: first make the new
            // source available, then re-arm WallpaperAgent so its secure
            // Lock Screen surface binds to that source instead of a stale one.
            if store.lockScreenPlaybackEnabled {
                guard lockScreenFrameReadinessWaiter(startedAt, previousFrameRevision) else {
                    throw TerminalWallpaperControllerError.lockScreenFrameNotReady
                }
                try lockScreenCoordinator.activate()
            }
        } catch {
            if !wasRunning { try? lockScreenCoordinator.restore() }
            throw error
        }
        return store.status()
    }

    func setPlaybackPaused(_ paused: Bool) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        guard store.processIsAlive(pid: store.loadPID()) else { return store.status() }
        let previous = store.isPlaybackPaused
        guard previous != paused else { return store.status() }
        try store.setPlaybackPaused(paused)
        do {
            try send(paused ? .pause : .resume, config: store.loadConfig())
        } catch {
            try? store.setPlaybackPaused(previous)
            throw error
        }
        return store.status()
    }

    func stop() throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        // Keep the Desktop window and published frame alive while macOS
        // restores its provider. Closing them first exposes WallpaperAgent's
        // empty grey surface during its stop/start transaction.
        try lockScreenCoordinator.restore()
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.stop, config: store.loadConfig())
            guard store.terminateAgent(timeout: 2) else {
                throw TerminalWallpaperControllerError.unavailable(
                    "The Terminal Wallpaper agent did not stop."
                )
            }
        }
        try store.setPlaybackPaused(false)
        store.removeCommand()
        store.removeHealth()
        store.removeSharedFrameDescriptor()
        store.removeLockScreenPublication()
        return store.status()
    }

    func terminate() throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        try lockScreenCoordinator.restore()
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.terminate, config: store.loadConfig())
            guard store.terminateAgent(timeout: 2) else {
                throw TerminalWallpaperControllerError.unavailable(
                    "The Terminal Wallpaper agent did not terminate."
                )
            }
        }
        try store.setPlaybackPaused(false)
        store.removeCommand()
        store.removeHealth()
        store.removeSharedFrameDescriptor()
        store.removeLockScreenPublication()
        return store.status()
    }

    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        try start(config: config)
    }

    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
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

    func updateScaleMode(_ mode: TerminalScaleMode) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        // Read the applied configuration under the same lock as Start/Remove.
        // A late scale event must neither apply preview drafts nor revive an agent.
        let previous = store.loadConfig()
        guard store.processIsAlive(pid: store.loadPID()), previous.render.scaleMode != mode else {
            return store.status()
        }
        var current = previous
        current.render.scaleMode = mode
        try store.saveConfig(current)
        do {
            try send(.update, config: current)
        } catch {
            try? store.saveConfig(previous)
            throw error
        }
        return store.status()
    }

    func updateNativeSpeed(_ speed: Double, matching command: TerminalCommandConfiguration) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        var current = store.loadConfig()
        guard current.command == command, TerminalNativeSpeed.profile(for: command) != nil,
              store.processIsAlive(pid: store.loadPID()) else {
            return store.status()
        }
        let previousSpeed = current.nativeSpeed
        current.nativeSpeed = speed
        current = current.normalized()
        guard current.nativeSpeed != previousSpeed else { return store.status() }
        try store.saveConfig(current)
        try send(.update, config: current)
        return store.status()
    }

    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        let normalized = try validated(config)
        try store.saveConfig(normalized)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.resize, config: normalized)
        }
        return store.status()
    }

    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
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
        if WebWallpaperRuntime.active {
            throw TerminalWallpaperControllerError.unavailable("Remove the Web wallpaper before starting Terminal Wallpaper.")
        }
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
        guard store.lockScreenPlaybackEnabled else { return }
        try ensureCanStart()
        try lockScreenCoordinator.activate()
    }

    // The caller persists the shared checkbox before notifying the helper.
    // Leave its desktop PTY and preview surface alive on either transition.
    func setShowOnLockScreen(_ enabled: Bool) throws {
        lockScreenOperationLock.lock()
        defer { lockScreenOperationLock.unlock() }
        guard store.processIsAlive(pid: store.loadPID()) else { return }
        let startedAt = Date().timeIntervalSince1970
        let previousRevision = Self.lockScreenFrameRevision(in: store)
        try send(.update, config: store.loadConfig())
        if enabled {
            guard lockScreenFrameReadinessWaiter(startedAt, previousRevision) else {
                throw TerminalWallpaperControllerError.lockScreenFrameNotReady
            }
            try lockScreenCoordinator.activate()
        } else {
            try lockScreenCoordinator.restoreUserWallpaper()
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

    private static func waitForLockScreenFrame(
        in store: TerminalWallpaperRuntimeStore,
        startedAt: TimeInterval,
        previousRevision: String?
    ) -> Bool {
        let deadline = Date().addingTimeInterval(3.5)
        repeat {
            let now = Date().timeIntervalSince1970
            let expectedPID = store.loadPID()
            let heartbeat = store.loadLockScreenHeartbeat()
            let revision = lockScreenFrameRevision(in: store)
            if let expectedPID,
               store.processIsAlive(pid: expectedPID),
               heartbeat?.pid == expectedPID,
               let heartbeat,
               heartbeat.updatedAt > startedAt,
               heartbeat.isFresh(at: now),
               revision != nil,
               revision != previousRevision {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private static func lockScreenFrameRevision(in store: TerminalWallpaperRuntimeStore) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: store.lockScreenFrameURL.path
        ),
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        let fileNumber = String(describing: attributes[.systemFileNumber] ?? "?")
        let size = String(describing: attributes[.size] ?? "?")
        return "\(fileNumber):\(size):\(modifiedAt.timeIntervalSince1970)"
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
