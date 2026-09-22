import AppKit
import AuraTerminalWallpaperCore
import Foundation
import Metal
import OSLog

final class TerminalWallpaperAgentDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.andrijvergeles.auraflow",
        category: "terminal-wallpaper"
    )
    private let store: TerminalWallpaperRuntimeStore
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var config: TerminalWallpaperConfig
    private var parser: VTParser?
    private let parserQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-parser", qos: .userInitiated)
    private let session = TerminalPTYSession()
    private var windows: [TerminalWallpaperWindow] = []
    private var latestSnapshot: TerminalGridSnapshot?
    private var commandTimer: Timer?
    private var healthTimer: Timer?
    private var lastCommandID: String?
    private var frames = 0
    private var renderedFrames = 0
    private var lastError: String?
    private var childStartedAt: Date?
    private var framesAtChildStart = 0
    private var reportedNoOutput = false
    private var terminating = false

    init(configurationURL: URL) {
        let supportURL = configurationURL.deletingLastPathComponent()
        store = TerminalWallpaperRuntimeStore(appSupportURL: supportURL)
        config = store.loadConfig()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        logger.info("Terminal Wallpaper agent started")
        try? store.savePID()
        installNotifications()
        rebuildRuntime()
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollCommand()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.writeHealth()
        }
        writeHealth()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        commandTimer?.invalidate()
        healthTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        session.stop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        store.removePID()
        store.removeHealth()
    }

    @objc private func screensChanged() {
        rebuildWindows()
        if config.render.columns == nil || config.render.rows == nil {
            restartSessionForCurrentGeometry()
        }
        writeHealth()
    }

    @objc private func commandChanged() {
        pollCommand()
    }

    private func installNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(commandChanged),
            name: TerminalWallpaperRuntimeNotifications.commandDidChange,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func pollCommand() {
        guard !terminating,
              let command = store.loadCommand(),
              command.id != lastCommandID
        else { return }
        lastCommandID = command.id
        if let commandConfig = command.config {
            config = commandConfig.normalized()
            try? store.saveConfig(config)
        }
        switch command.action {
        case .start, .restart:
            rebuildRuntime()
        case .update:
            rebuildRuntime(restartChild: false)
        case .resize:
            restartSessionForCurrentGeometry()
        case .stop, .terminate:
            NSApp.terminate(nil)
        }
        writeHealth()
    }

    private func rebuildRuntime(restartChild: Bool = true) {
        guard !config.command.executable.isEmpty else {
            lastError = "No executable configured."
            session.stop()
            rebuildWindows()
            return
        }
        let geometry = logicalGeometry()
        if restartChild {
            session.stop()
        }
        if parser == nil || parser?.grid.columns != geometry.columns || parser?.grid.rows != geometry.rows {
            if !restartChild, session.childPID != nil {
                parserQueue.sync {
                    parser?.resize(columns: geometry.columns, rows: geometry.rows)
                    latestSnapshot = parser?.grid.snapshot()
                }
                try? session.resize(columns: geometry.columns, rows: geometry.rows)
            } else {
                parserQueue.sync {
                    parser = VTParser(columns: geometry.columns, rows: geometry.rows)
                    latestSnapshot = parser?.grid.snapshot()
                }
            }
        }
        rebuildWindows()
        guard restartChild || session.childPID != nil else { return }
        if restartChild {
            childStartedAt = Date()
            framesAtChildStart = frames
            reportedNoOutput = false
            do {
                _ = try session.start(
                    command: config.command,
                    columns: geometry.columns,
                    rows: geometry.rows,
                    onData: { [weak self] data in self?.consume(data) },
                    onExit: { [weak self] _ in
                        DispatchQueue.main.async { self?.childExited() }
                    }
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                logger.error("Could not start child process: \(error.localizedDescription, privacy: .public)")
            }
        }
        applyLatestSnapshot()
    }

    private func restartSessionForCurrentGeometry() {
        guard session.childPID != nil else {
            rebuildRuntime()
            return
        }
        rebuildRuntime(restartChild: false)
    }

    private func consume(_ data: Data) {
        parserQueue.async { [weak self] in
            guard let self else { return }
            self.parser?.feed(data)
            let snapshot = self.parser?.grid.snapshot()
            guard let snapshot else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                latestSnapshot = snapshot
                frames += 1
                childStartedAt = childStartedAt ?? Date()
                if frames == framesAtChildStart + 1 {
                    lastError = nil
                    reportedNoOutput = false
                }
                applyLatestSnapshot()
            }
        }
    }

    private func childExited() {
        guard !terminating else { return }
        lastError = "The terminal process exited."
        logger.error("Terminal child process exited; retaining the last valid frame")
        writeHealth()
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        guard let metalDevice else {
            lastError = "Metal is unavailable on this Mac."
            return
        }
        let screens = config.behavior.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        windows = screens.map { TerminalWallpaperWindow(screen: $0, device: metalDevice) }
        for window in windows {
            if !window.isVisible { window.orderBack(nil); window.orderFrontRegardless() }
        }
        applyLatestSnapshot()
    }

    private func applyLatestSnapshot() {
        guard let latestSnapshot else { return }
        for window in windows {
            window.update(snapshot: latestSnapshot, configuration: config.render)
            renderedFrames += 1
        }
    }

    private func logicalGeometry() -> (columns: Int, rows: Int) {
        if let columns = config.render.columns, let rows = config.render.rows {
            return (columns, rows)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        return TerminalRenderGeometry.automaticGrid(
            logicalWidth: Double(screen?.frame.width ?? 1920),
            logicalHeight: Double(screen?.frame.height ?? 1080),
            fontSize: config.render.effectiveFontSize
        )
    }

    private func writeHealth() {
        let geometry = logicalGeometry()
        let childPID = session.childPID.map(Int.init)
        if let childStartedAt,
           childPID != nil,
           frames == framesAtChildStart,
           !reportedNoOutput,
           Date().timeIntervalSince(childStartedAt) >= 3 {
            lastError = "The child is running but produced no terminal output. Choose a TUI or command-line program, not a GUI app."
            reportedNoOutput = true
            logger.error("Terminal child produced no output after 3 seconds")
        }
        let health = TerminalWallpaperHealth(
            available: true,
            fresh: true,
            running: childPID != nil,
            childRunning: childPID != nil,
            childPID: childPID,
            screens: windows.count,
            columns: geometry.columns,
            rows: geometry.rows,
            frames: frames,
            renderedFrames: renderedFrames,
            lastError: lastError
        )
        try? store.saveHealth(health)
    }
}

@main
struct AuraTerminalWallpaperAgentMain {
    static func main() {
        let arguments = CommandLine.arguments
        let configurationURL: URL
        if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count {
            configurationURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            configurationURL = TerminalWallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent("config.json")
        }
        let app = NSApplication.shared
        let delegate = TerminalWallpaperAgentDelegate(configurationURL: configurationURL)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
