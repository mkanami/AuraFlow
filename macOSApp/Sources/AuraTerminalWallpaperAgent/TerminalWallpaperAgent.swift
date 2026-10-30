import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import AuraWallpaperCore
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
    private let managesLockScreenPresentation: Bool
    private var lockScreenPresentation: TerminalLockScreenPresentation?
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var config: TerminalWallpaperConfig
    private var parser: VTParser?
    private var parserSize: (columns: Int, rows: Int)?
    private let parserQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-parser", qos: .userInitiated)
    private let parserDirtyLock = NSLock()
    private var parserHasPendingData = false
    private var parserGeneration: UInt64 = 0 // Accessed only on parserQueue.
    private var publishedParserRevision: UInt64? // Accessed only on parserQueue.
    private var childGeneration: UInt64 = 0
    private var displayGeneration: UInt64 = 0
    private var snapshotRequestInFlight = false
    private let session = TerminalPTYSession()
    private var windows: [TerminalWallpaperWindow] = []
    private var retainedLockScreenWindows: [TerminalWallpaperWindow] = []
    private var displayRecoveryPending = false
    private let screensProvider: () -> [NSScreen]
    private let executableFingerprint = RuntimeExecutableFingerprint.digest(at: URL(fileURLWithPath: CommandLine.arguments[0]))
    private var latestSnapshot: TerminalGridSnapshot?
    private var commandTimer: Timer?
    private var healthTimer: Timer?
    private var frameTimer: Timer?
    private var fullscreenTimer: Timer?
    private var fullscreenPausePolicy = TerminalFullscreenPausePolicy()
    private var lockScreenIsLocked = false
    private var lockScreenPlaybackEnabled = false
    private var outputPublication = TerminalOutputPublicationState()
    private var lastCommandID: String?
    private var frames = 0
    private var renderedFrames = 0
    private var lastError: String?
    private var childStartedAt: Date?
    private var framesAtChildStart = 0
    private var reportedNoOutput = false
    private var terminating = false
    private var publishedSharedFrameDescriptor: TerminalSharedFrameDescriptor?

    init(configurationURL: URL, managesLockScreenPresentation: Bool = true,
         screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
         framePublisher: TerminalLockScreenFramePublisher? = nil) {
        let supportURL = configurationURL.deletingLastPathComponent()
        store = TerminalWallpaperRuntimeStore(appSupportURL: supportURL)
        self.framePublisher = framePublisher ?? TerminalLockScreenFramePublisher(store: store)
        self.managesLockScreenPresentation = managesLockScreenPresentation
        self.screensProvider = screensProvider
        config = store.loadConfig()
        fullscreenPausePolicy.manuallyPaused = store.isPlaybackPaused
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Saved commands belong to the previous process. In particular an old
        // Stop or Update must not kill or overwrite this fresh login session.
        lastCommandID = store.loadCommand()?.id
        framePublisher.revoke()
        store.removeSharedFrameDescriptor()
        logger.info("Terminal Wallpaper agent started")
        try? store.savePID()
        installNotifications()
        lockScreenPresentation = managesLockScreenPresentation ? TerminalLockScreenPresentation() : nil
        lockScreenPresentation?.onLockStateChange = { [weak self] locked in
            self?.lockScreenIsLocked = locked
            self?.lockScreenStateChanged(locked)
        }
        syncLockScreenPlaybackPolicy()
        framePublisher.configure(maxFPS: config.render.maxFPS)
        rebuildRuntime()
        startFrameTimer()
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateFullscreenPausePolicy()
        }
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollCommand()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if let self, self.displayRecoveryPending, !self.screensProvider().isEmpty { self.screensChanged() }
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
        fullscreenTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        session.stop()
        framePublisher.revoke()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        retainedLockScreenWindows.removeAll()
        store.removePID()
        store.removeHealth()
    }

    @objc private func screensChanged() {
        guard !terminating else { return }
        guard !screensProvider().isEmpty else {
            displayRecoveryPending = true
            logger.notice("Preserving Lock Screen frames while displays are unavailable")
            return
        }
        displayRecoveryPending = false
        if config.render.columns == nil || config.render.rows == nil {
            if session.childPID != nil {
                rebuildRuntime(restartChild: false)
            } else {
                // A finished static command cannot redraw on SIGWINCH. Keep
                // its complete snapshot instead of truncating or rerunning it.
                rebuildWindows()
            }
        } else {
            rebuildWindows()
        }
        updateFullscreenPausePolicy()
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
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(restoreDesktopPresentation), name: name, object: nil
            )
        }
    }

    @objc private func restoreDesktopPresentation() {
        guard !terminating else { return }
        // WindowServer can detach desktop windows during sleep, session and
        // Spaces transitions. Restore the existing surfaces without restarting
        // the command (which may have completed successfully) or losing pause.
        for window in windows { window.restoreDesktopPresentation() }
    }

    private func pollCommand() {
        guard !terminating,
              let command = store.loadCommand(),
              command.id != lastCommandID
        else { return }
        lastCommandID = command.id
        let previousConfiguration = config
        // Ordinary settings and compatibility login metadata must not revoke
        // or reseed the current saver publication. Only its own toggle asks
        // for an explicit fresh Lock Screen seed.
        let lockScreenSync = command.action == .syncLockScreen || (command.action == .update && command.config == nil)
        syncLockScreenPlaybackPolicy(forceSeed: lockScreenSync)
        if let commandConfig = command.config {
            let oldFPS = config.render.maxFPS
            config = commandConfig.normalized()
            try? store.saveConfig(config)
            framePublisher.configure(maxFPS: config.render.maxFPS)
            if oldFPS != config.render.maxFPS { startFrameTimer() }
        }
        fullscreenPausePolicy.manuallyPaused = store.isPlaybackPaused
        switch command.action {
        case .start, .restart:
            rebuildRuntime()
        case .update:
            var previousWithoutRate = previousConfiguration
            previousWithoutRate.playbackSpeed = config.playbackSpeed
            previousWithoutRate.nativeSpeed = config.nativeSpeed
            previousWithoutRate.render.scaleMode = config.render.scaleMode
            previousWithoutRate.behavior.launchAtLogin = config.behavior.launchAtLogin
            if previousWithoutRate != config {
                rebuildRuntime(restartChild: previousConfiguration.command != config.command)
            } else if previousConfiguration.render.scaleMode != config.render.scaleMode {
                // Scale belongs to presentation, not the PTY/parser or source
                // canvas. This also redraws the retained frame after EOF.
                applyLatestSnapshot()
            }
            if TerminalNativeSpeed.changed(from: previousConfiguration, to: config),
               let profile = TerminalNativeSpeed.profile(for: config.command) {
                if let input = profile.input(for: config), session.childPID != nil {
                    do { try session.writeInput(input) }
                    catch { lastError = error.localizedDescription }
                } else {
                    rebuildRuntime(preserveWindows: true)
                }
            }
        case .pause, .resume, .syncLockScreen:
            // Read the latest persisted intent, including when a newer Update
            // supersedes a Pause notification. Never recreate the PTY here.
            break
        case .resize:
            restartSessionForCurrentGeometry()
        case .stop, .terminate:
            NSApp.terminate(nil)
        }
        updateFullscreenPausePolicy()
        synchronizePlaybackPause()
        writeHealth()
    }

    private func rebuildRuntime(restartChild: Bool = true, preserveWindows: Bool = false) {
        if !preserveWindows { displayGeneration &+= 1 }
        snapshotRequestInFlight = false
        parserDirtyLock.lock()
        parserHasPendingData = false
        parserDirtyLock.unlock()
        guard !config.command.executable.isEmpty else {
            lastError = "No executable configured."
            childGeneration &+= 1
            outputPublication = TerminalOutputPublicationState()
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
            outputPublication = TerminalOutputPublicationState()
        }
        if restartChild || parserSize == nil {
            // Retained windows reject older revisions. A new child must begin
            // after the last displayed snapshot, even though its grid is new.
            let initialRevision = preserveWindows ? (latestSnapshot?.revision ?? 0) &+ 1 : 0
            parserQueue.sync {
                parserGeneration = childGeneration
                parser = VTParser(columns: geometry.columns, rows: geometry.rows, initialRevision: initialRevision)
                if !preserveWindows { latestSnapshot = parser?.grid.snapshot() }
                publishedParserRevision = parser?.grid.currentRevision
            }
            parserSize = geometry
        } else if parserSize?.columns != geometry.columns || parserSize?.rows != geometry.rows {
            parserQueue.sync {
                parser?.resize(columns: geometry.columns, rows: geometry.rows)
                latestSnapshot = parser?.grid.snapshot()
                publishedParserRevision = parser?.grid.currentRevision
            }
            if session.childPID != nil {
                try? session.resize(columns: geometry.columns, rows: geometry.rows)
            }
            parserSize = geometry
        }
        if !preserveWindows { rebuildWindows() }
        guard restartChild || session.childPID != nil else { return }
        if restartChild {
            childStartedAt = Date()
            framesAtChildStart = frames
            reportedNoOutput = false
            let generation = childGeneration
            do {
                _ = try session.start(
                    command: TerminalNativeSpeed.launchCommand(for: config),
                    columns: geometry.columns,
                    rows: geometry.rows,
                    onData: { [weak self] data in self?.consume(data, generation: generation) },
                    onExit: { [weak self] code in
                        DispatchQueue.main.async {
                            guard self?.childGeneration == generation else { return }
                            self?.childExited(code: code)
                        }
                    }
                )
                lastError = nil
                if fullscreenPausePolicy.playbackIsPaused {
                    try? session.setPaused(true)
                }
            } catch {
                lastError = error.localizedDescription
                logger.error("Could not start child process: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !preserveWindows { applyLatestSnapshot() }
    }

    private func restartSessionForCurrentGeometry() {
        guard session.childPID != nil || outputPublication.exitCode == 0 else {
            rebuildRuntime()
            return
        }
        rebuildRuntime(restartChild: false)
    }

    private func consume(_ data: Data, generation: UInt64) {
        parserQueue.async { [weak self] in
            guard let self, self.parserGeneration == generation else { return }
            self.parser?.feed(data)
            // Do not let the timer consume the dirty flag before the bytes
            // have entered the parser (a single static chunk may be the last).
            self.parserDirtyLock.lock()
            self.parserHasPendingData = true
            self.parserDirtyLock.unlock()
        }
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        guard !fullscreenPausePolicy.playbackIsPaused else { return }
        let interval = 1.0 / Double(max(config.render.maxFPS, 1))
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.publishLatestSnapshot()
        }
        frameTimer?.tolerance = interval * 0.1
    }

    private func publishLatestSnapshot() {
        requestDesktopSeedIfNeeded()
        guard !terminating, !snapshotRequestInFlight else { return }
        parserDirtyLock.lock()
        let hasPendingData = parserHasPendingData
        parserHasPendingData = false
        parserDirtyLock.unlock()
        guard hasPendingData else { return }
        snapshotRequestInFlight = true
        let generation = displayGeneration
        let requestedChildGeneration = childGeneration
        parserQueue.async { [weak self] in
            guard let self else { return }
            var snapshot: TerminalGridSnapshot?
            if let parser = self.parser,
               parser.grid.currentRevision != self.publishedParserRevision {
                snapshot = parser.grid.snapshot()
                self.publishedParserRevision = snapshot?.revision
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation,
                      self.childGeneration == requestedChildGeneration else { return }
                self.snapshotRequestInFlight = false
                guard let snapshot,
                      snapshot.revision > (self.latestSnapshot?.revision ?? 0) ||
                      snapshot.columns != self.latestSnapshot?.columns ||
                      snapshot.rows != self.latestSnapshot?.rows
                else { return }
                self.latestSnapshot = snapshot
                self.outputPublication.receive(snapshot)
                self.frames += 1
                if self.frames == self.framesAtChildStart + 1, self.outputPublication.exitCode == nil {
                    self.lastError = nil
                    self.reportedNoOutput = false
                }
                self.applyLatestSnapshot()
            }
        }
    }

    private func childExited(code: Int32) {
        guard !terminating else { return }
        // EOF follows all PTY data. Drain the parser before deciding whether
        // this is a successful static wallpaper, even if no timer has fired.
        let previousRevision = latestSnapshot?.revision
        parserQueue.sync {
            latestSnapshot = parser?.grid.snapshot()
            publishedParserRevision = latestSnapshot?.revision
        }
        if let latestSnapshot { outputPublication.receive(latestSnapshot) }
        if latestSnapshot?.revision != previousRevision { frames += 1 }
        outputPublication.finish(code)
        lastError = outputPublication.error
        if lastError == nil {
            logger.info("Terminal program completed successfully; retaining static output")
            // A multi-chunk static program may have seeded the Lock Screen
            // with its first partial frame. Replace that seed with the final
            // snapshot, invalidating any readback still owned by the old one.
            framePublisher.beginDesktopGeneration()
            applyLatestSnapshot()
            if lockScreenPlaybackEnabled {
                windows.first?.requestLockScreenSeedCapture(refresh: true)
            }
        } else {
            logger.error("Terminal program exited with status \(code)")
        }
        writeHealth()
    }

    private func rebuildWindows() {
        let availableScreens = screensProvider()
        guard !availableScreens.isEmpty else {
            displayRecoveryPending = true
            return
        }
        guard let metalDevice else {
            lastError = "Metal is unavailable on this Mac."
            return
        }
        displayRecoveryPending = false
        displayGeneration &+= 1
        framePublisher.beginDesktopGeneration()
        // The saver may still be reading this IOSurface. Keep its owner and
        // descriptor alive until a replacement GPU frame has completed.
        if retainedLockScreenWindows.isEmpty { retainedLockScreenWindows = windows }
        for window in windows {
            window.onLockScreenFrame = nil
            window.onSharedFrame = nil
            window.orderOut(nil)
        }
        windows.removeAll()
        let screens = config.behavior.allDisplays ? availableScreens : Array(availableScreens.prefix(1))
        windows = screens.map { TerminalWallpaperWindow(screen: $0, device: metalDevice) }
        if let firstWindow = windows.first {
            let generation = displayGeneration
            firstWindow.onLockScreenFrame = { [weak self] bytes, width, height in
                guard let self,
                      self.displayGeneration == generation,
                      !self.terminating,
                      self.lockScreenPlaybackEnabled,
                      self.store.lockScreenPlaybackEnabled,
                      self.outputPublication.canPublish(childRunning: self.session.childPID != nil) else { return }
                if self.lockScreenIsLocked {
                    self.framePublisher.publish(bytes, width: width, height: height)
                } else {
                    self.framePublisher.publishDesktopSeed(bytes, width: width, height: height)
                }
            }
            firstWindow.onSharedFrame = { [weak self] descriptor, sequence in
                guard let self,
                      self.displayGeneration == generation,
                      !self.terminating,
                      self.outputPublication.canPublish(childRunning: self.session.childPID != nil) else { return }
                if self.publishedSharedFrameDescriptor != descriptor {
                    do {
                        try self.store.saveSharedFrameDescriptor(descriptor)
                        self.publishedSharedFrameDescriptor = descriptor
                        self.retainedLockScreenWindows.removeAll()
                    } catch {
                        self.logger.error("Could not publish terminal preview surface: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                }
                DistributedNotificationCenter.default().postNotificationName(
                    TerminalWallpaperRuntimeNotifications.sharedFrameDidUpdate,
                    object: nil,
                    userInfo: [
                        "surface_id": NSNumber(value: descriptor.surfaceID),
                        "width": NSNumber(value: descriptor.width),
                        "height": NSNumber(value: descriptor.height),
                        "agent_pid": NSNumber(value: descriptor.agentPID),
                        "generation": descriptor.generation,
                        "sequence": NSNumber(value: sequence),
                    ],
                    deliverImmediately: true
                )
            }
        }
        for window in windows {
            window.setRendererPaused(fullscreenPausePolicy.playbackIsPaused)
            window.setLockScreenCaptureEnabled(lockScreenIsLocked)
            if !window.isVisible { window.orderBack(nil); window.orderFrontRegardless() }
        }
        applyLatestSnapshot()
    }

    private func applyLatestSnapshot() {
        guard let latestSnapshot else { return }
        let render = TerminalWallpaperCanvas.renderConfiguration(
            command: config.command, render: config.render, snapshot: latestSnapshot)
        let background = TerminalRGBA(red: config.render.background.red * config.render.backgroundOpacity,
            green: config.render.background.green * config.render.backgroundOpacity,
            blue: config.render.background.blue * config.render.backgroundOpacity)
        for window in windows {
            window.update(snapshot: latestSnapshot, configuration: render, presentationBackground: background)
            renderedFrames += 1
        }
        requestDesktopSeedIfNeeded()
    }

    private func requestDesktopSeedIfNeeded() {
        guard !terminating,
              lockScreenPlaybackEnabled,
              framePublisher.needsDesktopSeed,
              outputPublication.canPublish(childRunning: session.childPID != nil),
              store.lockScreenPlaybackEnabled,
              let firstWindow = windows.first else { return }
        firstWindow.requestLockScreenSeedCapture()
    }

    private func lockScreenStateChanged(_ locked: Bool) {
        guard lockScreenPlaybackEnabled, store.lockScreenPlaybackEnabled else { return }
        lockScreenIsLocked = locked
        framePublisher.setLockScreenActive(locked)
        for window in windows { window.setLockScreenCaptureEnabled(locked) }
        updateFullscreenPausePolicy()
        if !locked { restoreDesktopPresentation() }
    }

    private func syncLockScreenPlaybackPolicy(forceSeed: Bool = false) {
        let enabled = store.lockScreenPlaybackEnabled
        guard enabled != lockScreenPlaybackEnabled || (enabled && forceSeed) else { return }
        let changed = enabled != lockScreenPlaybackEnabled
        lockScreenPlaybackEnabled = enabled
        if enabled {
            if changed { MainActor.assumeIsolated { lockScreenPresentation?.start() } }
            framePublisher.beginDesktopGeneration()
            if outputPublication.canPublish(childRunning: session.childPID != nil) {
                // A static command has already exited. Redraw its retained
                // composition rather than waiting for new PTY bytes.
                applyLatestSnapshot()
                windows.first?.requestLockScreenSeedCapture(refresh: true)
            }
            framePublisher.refreshHeartbeat()
        } else {
            MainActor.assumeIsolated { lockScreenPresentation?.stop() }
            lockScreenIsLocked = false
            framePublisher.revoke()
            for window in windows { window.setLockScreenCaptureEnabled(false) }
            updateFullscreenPausePolicy()
        }
    }

    private func updateFullscreenPausePolicy() {
        guard !terminating else { return }
        let screenLocked = lockScreenIsLocked
        let enabled = config.behavior.pauseOnFullscreen
        let foregroundIsFullscreen = enabled && !screenLocked
            ? Self.detectFullscreenApplication()
            : false
        guard let paused = fullscreenPausePolicy.update(
            enabled: enabled,
            screenLocked: screenLocked,
            foregroundIsFullscreen: foregroundIsFullscreen
        ) else { return }

        let playbackPaused = fullscreenPausePolicy.playbackIsPaused
        if let childPID = session.childPID {
            do {
                try session.setPaused(playbackPaused)
                logger.notice("Terminal wallpaper fullscreen pause=\(paused), child=\(childPID)")
            } catch {
                logger.error("Could not change terminal process pause state: \(error.localizedDescription, privacy: .public)")
                fullscreenPausePolicy.restoreAfterFailedProcessSignal(to: !paused)
                return
            }
        }
        synchronizePlaybackPause()
    }

    private func synchronizePlaybackPause() {
        let paused = fullscreenPausePolicy.playbackIsPaused
        if session.childPID != nil {
            do { try session.setPaused(paused) }
            catch { lastError = error.localizedDescription; return }
        }
        for window in windows { window.setRendererPaused(paused) }
        if paused {
            frameTimer?.invalidate()
            frameTimer = nil
        } else if frameTimer == nil {
            startFrameTimer()
            applyLatestSnapshot()
        }
    }

    private static func detectFullscreenApplication() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        let tolerance: CGFloat = 3
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmost.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else {
                continue
            }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if displays.contains(where: { display in
                abs(rect.minX - display.minX) <= tolerance
                    && abs(rect.minY - display.minY) <= tolerance
                    && abs(rect.maxX - display.maxX) <= tolerance
                    && abs(rect.maxY - display.maxY) <= tolerance
            }) {
                return true
            }
        }
        return false
    }

    private func logicalGeometry() -> (columns: Int, rows: Int) {
        let screen = screensProvider().first
        if screen == nil, let parserSize { return parserSize }
        let cellMetrics = TerminalFontMetrics.cellMetrics(for: config.render)
        return TerminalRenderGeometry.viewportGrid(
            configuration: config.render,
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
           !fullscreenPausePolicy.playbackIsPaused,
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
            running: childPID != nil || outputPublication.canPublish(childRunning: false),
            childRunning: childPID != nil,
            childPID: childPID,
            screens: windows.count,
            columns: geometry.columns,
            rows: geometry.rows,
            frames: frames,
            renderedFrames: renderedFrames,
            lastError: lastError,
            agentPID: Int(getpid()),
            executableFingerprint: executableFingerprint
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
