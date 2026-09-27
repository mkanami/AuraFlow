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
    private let framePublisher: TerminalLockScreenFramePublisher
    private var lockScreenPresentation: TerminalLockScreenPresentation?
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var config: TerminalWallpaperConfig
    private var parser: VTParser?
    private var parserSize: (columns: Int, rows: Int)?
    private let parserQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-parser", qos: .userInitiated)
    private var parserGeneration: UInt64 = 0 // Accessed only on parserQueue.
    private var childGeneration: UInt64 = 0
    private var displayGeneration: UInt64 = 0
    private var snapshotRequestInFlight = false
    private let session = TerminalPTYSession()
    private var windows: [TerminalWallpaperWindow] = []
    private var latestSnapshot: TerminalGridSnapshot?
    private var commandTimer: Timer?
    private var healthTimer: Timer?
    private var frameTimer: Timer?
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
        framePublisher = TerminalLockScreenFramePublisher(store: store)
        config = store.loadConfig()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        framePublisher.revoke()
        logger.info("Terminal Wallpaper agent started")
        try? store.savePID()
        installNotifications()
        lockScreenPresentation = TerminalLockScreenPresentation()
        lockScreenPresentation?.start()
        rebuildRuntime()
        startFrameTimer()
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollCommand()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.writeHealth()
        }
        writeHealth()
        DistributedNotificationCenter.default().post(
            name: TerminalWallpaperRuntimeNotifications.agentDidStart,
            object: nil,
            userInfo: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        lockScreenPresentation?.stop()
        commandTimer?.invalidate()
        healthTimer?.invalidate()
        frameTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        session.stop()
        framePublisher.revoke()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        store.removePID()
        store.removeHealth()
    }

    @objc private func screensChanged() {
        if config.render.columns == nil || config.render.rows == nil {
            restartSessionForCurrentGeometry()
        } else {
            rebuildWindows()
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
            let oldFPS = config.render.maxFPS
            config = commandConfig.normalized()
            try? store.saveConfig(config)
            if oldFPS != config.render.maxFPS { startFrameTimer() }
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
        displayGeneration &+= 1
        snapshotRequestInFlight = false
        guard !config.command.executable.isEmpty else {
            lastError = "No executable configured."
            session.stop()
            rebuildWindows()
            return
        }
        let geometry = logicalGeometry()
        if restartChild {
            // Keep the last published image while replacing the child. The
            // Lock Screen runs in a separate process and otherwise briefly
            // loses its only content source before the new PTY paints a frame.
            childGeneration &+= 1
            session.stop()
        }
        if restartChild || parserSize == nil {
            parserQueue.sync {
                parserGeneration = childGeneration
                parser = VTParser(columns: geometry.columns, rows: geometry.rows)
                latestSnapshot = parser?.grid.snapshot()
            }
            parserSize = geometry
        } else if parserSize?.columns != geometry.columns || parserSize?.rows != geometry.rows {
            if session.childPID != nil {
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
            parserSize = geometry
        }
        rebuildWindows()
        guard restartChild || session.childPID != nil else { return }
        if restartChild {
            childStartedAt = Date()
            framesAtChildStart = frames
            reportedNoOutput = false
            let generation = childGeneration
            do {
                _ = try session.start(
                    command: config.command,
                    columns: geometry.columns,
                    rows: geometry.rows,
                    onData: { [weak self] data in self?.consume(data, generation: generation) },
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

    private func consume(_ data: Data, generation: UInt64) {
        parserQueue.async { [weak self] in
            guard let self, self.parserGeneration == generation else { return }
            self.parser?.feed(data)
        }
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        let interval = 1.0 / Double(max(config.render.maxFPS, 1))
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.publishLatestSnapshot()
        }
        frameTimer?.tolerance = interval * 0.1
    }

    private func publishLatestSnapshot() {
        guard !terminating, !snapshotRequestInFlight else { return }
        snapshotRequestInFlight = true
        let generation = displayGeneration
        parserQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.parser?.grid.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation else { return }
                self.snapshotRequestInFlight = false
                guard let snapshot,
                      snapshot.revision != self.latestSnapshot?.revision ||
                      snapshot.columns != self.latestSnapshot?.columns ||
                      snapshot.rows != self.latestSnapshot?.rows
                else { return }
                self.latestSnapshot = snapshot
                self.frames += 1
                if self.frames == self.framesAtChildStart + 1 {
                    self.lastError = nil
                    self.reportedNoOutput = false
                }
                self.applyLatestSnapshot()
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
        for window in windows {
            window.onRasterizedFrame = nil
            window.orderOut(nil)
        }
        windows.removeAll()
        guard let metalDevice else {
            lastError = "Metal is unavailable on this Mac."
            framePublisher.revoke()
            return
        }
        let screens = config.behavior.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        windows = screens.map { TerminalWallpaperWindow(screen: $0, device: metalDevice) }
        if windows.isEmpty { framePublisher.revoke() }
        if let firstWindow = windows.first {
            let generation = displayGeneration
            firstWindow.onRasterizedFrame = { [weak self] bytes, width, height in
                guard let self,
                      self.displayGeneration == generation,
                      !self.terminating,
                      self.frames > self.framesAtChildStart else { return }
                self.framePublisher.publish(bytes, width: width, height: height)
            }
        }
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
        let cellMetrics = TerminalFontMetrics.cellMetrics(for: config.render)
        return TerminalRenderGeometry.automaticGrid(
            logicalWidth: Double(screen?.frame.width ?? 1920),
            logicalHeight: Double(screen?.frame.height ?? 1080),
            cellWidth: cellMetrics.width,
            lineHeight: cellMetrics.height
        )
    }

    private func writeHealth() {
        framePublisher.refreshHeartbeat()
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
