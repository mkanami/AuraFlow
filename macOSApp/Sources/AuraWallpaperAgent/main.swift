import AppKit
import AuraWallpaperCore
import AVFoundation
import Foundation
import QuartzCore

private final class WallpaperLayerView: NSView {
    override var isOpaque: Bool { true }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }
}

private final class WallpaperAgentDelegate: NSObject, NSApplicationDelegate {
    private struct LockScreenRearmToken: Equatable {
        let sessionGeneration: UInt64
        let wallpaperRevision: UInt64
        let videoPath: String
    }

    private let store = WallpaperRuntimeStore()
    private let lockScreenOnlyMode = CommandLine.arguments.contains("--lock-screen-only")
    private let lockScreenInstaller = AerialLockScreenInstaller()
    private let lockScreenRepairQueue = DispatchQueue(
        label: "com.auraflow.lock-screen-repair",
        qos: .utility
    )
    private var config: ControlConfig
    private var windows: [NSWindow] = []
    private var playerLayers: [AVPlayerLayer] = []
    private var fallbackImage: CGImage?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playbackTimeObserver: Any?
    private var commandTimer: Timer?
    private var healthTimer: Timer?
    private var fullscreenTimer: Timer?
    private var lastCommandID: String?
    private var manualPaused = false
    private var sleeping = false
    private var sessionInactive = false
    private var autoPausedForFullscreen = false
    private var fullscreenAppDetected = false
    private var consecutiveFullscreenSamples = 0
    private var consecutiveWindowedSamples = 0
    private var lastSpaceChangeUptime = -Double.infinity
    private var signalSources: [DispatchSourceSignal] = []
    private var lockScreenState: LockScreenStateMachine
    private var transitionGeneration = 0
    private var lockSessionGeneration: UInt64 = 0
    private var wallpaperRevision: UInt64 = 0
    private var pendingRearmToken: LockScreenRearmToken?
    private var lastRearmedToken: LockScreenRearmToken?
    private var lastSessionTransitionUptime = -Double.infinity
    private var lockTransitionCount = 0
    private var lastLockTransitionMilliseconds: Double?
    private var lastPlaybackProgressUptime: TimeInterval?
    private var consecutiveStallPolls = 0
    private var stallEvents = 0
    private var recoveryEvents = 0
    private var lockScreenRepairInProgress = false
    private var isTerminating = false

    private let spaceTransitionGracePeriod: TimeInterval = 0.75
    private let fullscreenConfirmationSamples = 2
    private let stallRecoveryThreshold = 2

    override init() {
        self.config = store.loadConfig()
        self.lockScreenState = LockScreenStateMachine(
            isEnabled: self.config.show_on_lock_screen ?? true
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? store.savePID()
        store.markPaused(false)
        installSignalHandlers()
        if !lockScreenOnlyMode {
            rebuildPlayback(from: config, keepPaused: false)
        } else {
            restoreDesktopStoreAfterSession()
        }
        startTimers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            [weak self] in
            self?.reconcileSystemSessionState()
            self?.rearmModernLockScreenForNextSession()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        transitionGeneration += 1
        lockSessionGeneration &+= 1
        pendingRearmToken = nil
        writeHealth(reason: "terminating")
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        commandTimer?.invalidate()
        healthTimer?.invalidate()
        fullscreenTimer?.invalidate()
        commandTimer = nil
        healthTimer = nil
        fullscreenTimer = nil
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        tearDownPlayback()
        store.removePID()
        store.markPaused(false)
        if lockScreenOnlyMode {
            store.markLockScreenOnlyAgent(false)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startTimers() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runtimeCommandDidChange),
            name: WallpaperRuntimeNotifications.commandDidChange,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // Cross-process notifications handle the normal fast path. This low-frequency
        // timer is only a safety net for a notification missed during process startup.
        commandTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCommand()
        }
        commandTimer?.tolerance = 0.20
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.samplePlaybackHealth()
        }
        healthTimer?.tolerance = 0.30
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.applyFullscreenPolicy()
        }
        fullscreenTimer?.tolerance = 0.15
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        writeHealth(reason: "ok")
    }

    @objc private func runtimeCommandDidChange(_ notification: Notification) {
        pollCommand()
    }

    @objc private func screensChanged() {
        guard !isTerminating else { return }
        if !lockScreenOnlyMode {
            rebuildWindows()
        }
        writeHealth(reason: "screen-change")
    }

    @objc private func activeSpaceDidChange() {
        guard !isTerminating else { return }
        if lockScreenOnlyMode {
            showWindows(forceOrder: true)
            return
        }
        lastSpaceChangeUptime = ProcessInfo.processInfo.systemUptime
        consecutiveFullscreenSamples = 0
        consecutiveWindowedSamples = 0
        showWindows(forceOrder: true)
        let generation = transitionGeneration

        // WindowServer can briefly detach desktop-level windows while the
        // Spaces animation is finishing. Reassert them on the next run-loop
        // pass as well, without rebuilding the player or its layers.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isTerminating,
                  self.transitionGeneration == generation
            else {
                return
            }
            self.showWindows(forceOrder: true)
        }
    }

    @objc private func sessionDidResignActive() {
        handleSessionNotification(expectedLocked: true)
    }

    @objc private func sessionDidBecomeActive() {
        handleSessionNotification(expectedLocked: false)
    }

    private func handleSessionNotification(expectedLocked: Bool) {
        guard !isTerminating else { return }
        let actualLocked = systemSessionIsLocked()
        if actualLocked == nil || actualLocked == expectedLocked {
            applySystemSessionState(locked: expectedLocked)
        }

        // CGSession can lag either notification center by a run-loop turn.
        // Reconcile again instead of permanently dropping a valid transition.
        for delay in [0.10, 0.35, 1.0] {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay
            ) { [weak self] in
                self?.reconcileSystemSessionState()
            }
        }
    }

    private func reconcileSystemSessionState() {
        guard !isTerminating,
              let locked = systemSessionIsLocked()
        else {
            return
        }
        applySystemSessionState(locked: locked)
    }

    private func applySystemSessionState(locked: Bool) {
        if locked {
            guard !sessionInactive else { return }
            lockSessionGeneration &+= 1
            pendingRearmToken = nil
            sessionInactive = true
            lastSessionTransitionUptime =
                ProcessInfo.processInfo.systemUptime
            activateLockScreenStoreForSession()
            syncLockScreenSetting(reason: "lock-setting")
            handleLockScreenEvent(.sessionLocked, reason: "session-locked")
            scheduleLockScreenStoreReassertion()
            writeHealth(reason: "session-inactive")
            return
        }

        guard sessionInactive else { return }
        lockSessionGeneration &+= 1
        restoreDesktopStoreAfterSession()
        sessionInactive = false
        lastSessionTransitionUptime =
            ProcessInfo.processInfo.systemUptime
        handleLockScreenEvent(.sessionUnlocked, reason: "session-unlocked")
        if !lockScreenOnlyMode {
            showWindows(forceOrder: true)
            applyPlaybackRate()
        }
        writeHealth(reason: "session-active")
        scheduleDesktopStoreRestoration()
        rearmModernLockScreenForNextSession()
    }

    private func activateLockScreenStoreForSession() {
        guard config.show_on_lock_screen == true,
              lockScreenInstaller.requiresLockScreenSessionPromotion
        else {
            return
        }
        do {
            _ = try lockScreenInstaller.activateLockScreenForCurrentSession()
        } catch {
            writeHealth(
                reason:
                    "lock-screen-session-activation-failed: "
                    + error.localizedDescription
            )
        }
    }

    private func scheduleLockScreenStoreReassertion() {
        guard config.show_on_lock_screen == true,
              lockScreenInstaller.requiresLockScreenSessionPromotion
        else {
            return
        }
        for delay in [0.15, 0.45, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      !self.isTerminating,
                      self.sessionInactive,
                      self.systemSessionIsLocked() == true
                else {
                    return
                }
                self.activateLockScreenStoreForSession()
            }
        }
    }

    private func restoreDesktopStoreAfterSession() {
        guard config.show_on_lock_screen == true,
              lockScreenInstaller.requiresLockScreenSessionPromotion
        else {
            return
        }
        do {
            _ = try lockScreenInstaller.restoreDesktopAfterLockScreenSession()
        } catch {
            writeHealth(
                reason:
                    "desktop-store-restoration-failed: "
                    + error.localizedDescription
            )
        }
    }

    private func scheduleDesktopStoreRestoration() {
        guard config.show_on_lock_screen == true,
              lockScreenInstaller.requiresLockScreenSessionPromotion
        else {
            return
        }
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      !self.isTerminating,
                      !self.sessionInactive,
                      self.systemSessionIsLocked() == false
                else {
                    return
                }
                self.restoreDesktopStoreAfterSession()
            }
        }
    }

    @objc private func systemWillSleep() {
        guard !isTerminating, !sleeping else { return }
        sleeping = true
        player?.pause()
        writeHealth(reason: "sleeping")
    }

    @objc private func systemDidWake() {
        recoverAfterWake(reason: "wake")
    }

    @objc private func screensDidWake() {
        recoverAfterWake(reason: "screens-wake")
    }

    private func recoverAfterWake(reason: String) {
        guard !isTerminating else { return }
        sleeping = false
        if !lockScreenOnlyMode {
            showWindows(forceOrder: true)
            applyPlaybackRate()
        }
        writeHealth(reason: reason)
    }

    private func pollCommand() {
        guard !isTerminating else { return }
        guard let command = store.loadCommand(), command.id != lastCommandID else { return }
        lastCommandID = command.id
        if let newConfig = command.config {
            config = store.normalized(newConfig)
        }
        let wallpaperReloaded =
            command.action == .reload && !config.video_path.isEmpty
        if wallpaperReloaded {
            // A rearm is tied to the exact video, not just the lock-session
            // generation. Every reload gets a new revision so even replacing
            // a file in-place cannot let an older provider completion win.
            wallpaperRevision &+= 1
            pendingRearmToken = nil
            lastRearmedToken = nil
        }

        switch command.action {
        case .reload:
            _ = lockScreenState.apply(
                .setEnabled(config.show_on_lock_screen ?? true)
            )
            manualPaused = false
            store.markPaused(false)
            if !lockScreenOnlyMode {
                rebuildPlayback(from: config, keepPaused: false)
            }
            if wallpaperReloaded, config.show_on_lock_screen == true {
                repairModernLockScreenIfNeeded(force: true)
                rearmModernLockScreenForNextSession()
            }
        case .update:
            applyRuntimeSettings()
        case .resume:
            if !lockScreenOnlyMode {
                showWindows()
            }
            manualPaused = false
            store.markPaused(false)
            if !lockScreenOnlyMode {
                applyPlaybackRate()
            }
        case .pause:
            pauseAndCommitStillFrame()
        case .previewLock:
            syncLockScreenSetting(reason: "lock-setting")
            handleLockScreenEvent(.beginPreview, reason: "lock-preview")
        case .previewUnlock:
            syncLockScreenSetting(reason: "lock-setting")
            handleLockScreenEvent(.endPreview, reason: "lock-preview-ended")
            rearmModernLockScreenForNextSession()
        case .terminate:
            NSApp.terminate(nil)
        }

        writeHealth(reason: "ok")
    }

    private func rebuildPlayback(from config: ControlConfig, keepPaused: Bool) {
        tearDownPlayback()
        guard !config.video_path.isEmpty else {
            writeHealth(reason: "missing-video")
            return
        }

        let url = URL(fileURLWithPath: config.video_path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeHealth(reason: "missing-video")
            return
        }

        prepareFallbackImage(from: url)
        if WallpaperMediaKind.forURL(url).isStaticImage {
            rebuildWindows()
            if keepPaused || manualPaused {
                showWindows()
            }
            lastPlaybackProgressUptime = nil
            writeHealth(reason: "ok")
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [])
        player.actionAtItemEnd = .none
        player.volume = Float(max(0, min(config.volume ?? 0, 1)))
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        lastPlaybackProgressUptime = ProcessInfo.processInfo.systemUptime
        playbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.lastPlaybackProgressUptime =
                ProcessInfo.processInfo.systemUptime
        }
        rebuildWindows()

        if keepPaused || manualPaused {
            player.pause()
        } else {
            applyPlaybackRate()
        }
    }

    private func rebuildWindows() {
        let existingPlayer = player
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        playerLayers.removeAll()

        guard existingPlayer != nil || fallbackImage != nil else { return }
        let behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.level = windowLevel(for: lockScreenState.presentationMode)
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = behavior
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.canHide = false
            window.isExcludedFromWindowsMenu = true

            let content = WallpaperLayerView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            content.wantsLayer = true
            content.autoresizingMask = [.width, .height]
            content.layer?.contents = fallbackImage
            content.layer?.contentsGravity = fallbackContentsGravity(
                for: config.scale_mode
            )
            if let existingPlayer {
                let playerLayer = AVPlayerLayer(player: existingPlayer)
                playerLayer.frame = content.bounds
                playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                playerLayer.videoGravity = videoGravity(for: config.scale_mode)
                content.layer?.addSublayer(playerLayer)
                playerLayers.append(playerLayer)
            }
            window.contentView = content

            windows.append(window)
            if !manualPaused {
                present(window, as: lockScreenState.presentationMode)
            }
        }
    }

    private func tearDownPlayback() {
        player?.pause()
        if let playbackTimeObserver, let player {
            player.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        looper = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        playerLayers.removeAll()
        player = nil
        lastPlaybackProgressUptime = nil
        consecutiveStallPolls = 0
    }

    private func showWindows(forceOrder: Bool = false) {
        for window in windows {
            guard forceOrder || !window.isVisible else { continue }
            present(window, as: lockScreenState.presentationMode)
        }
    }

    private func handleLockScreenEvent(
        _ event: LockScreenStateEvent,
        reason: String
    ) {
        guard !isTerminating else { return }
        let previousMode = lockScreenState.presentationMode
        let stateChanged = lockScreenState.apply(event)
        let modeChanged = previousMode != lockScreenState.presentationMode

        guard stateChanged else { return }
        if modeChanged {
            applyPresentationMode(reason: reason)
        } else {
            writeHealth(reason: reason)
        }
    }

    private func syncLockScreenSetting(reason: String) {
        let previousMode = lockScreenState.presentationMode
        let stateChanged = lockScreenState.apply(
            .setEnabled(config.show_on_lock_screen ?? true)
        )
        guard stateChanged else { return }
        if previousMode != lockScreenState.presentationMode {
            applyPresentationMode(reason: reason)
        } else {
            writeHealth(reason: reason)
        }
    }

    private func applyPresentationMode(reason: String) {
        let startedAt = CACurrentMediaTime()
        transitionGeneration += 1
        let mode = lockScreenState.presentationMode

        // Reuse the existing AVQueuePlayer and AVPlayerLayers. Changing only the
        // window level keeps playback time continuous and avoids a black startup
        // frame during lock and unlock transitions.
        for window in windows {
            present(window, as: mode)
        }

        lockTransitionCount += 1
        lastLockTransitionMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        if mode == .lockScreen {
            applyPlaybackRate()
        } else {
            applyFullscreenPolicy()
        }
        writeHealth(reason: reason)
    }

    private func present(
        _ window: NSWindow,
        as mode: WallpaperPresentationMode
    ) {
        // The secure Lock Screen is rendered by macOS's Aerial/legacy saver
        // route. An app-owned .screenSaver window is not composited reliably
        // by loginwindow and can cover the real wallpaper with black. Keep
        // the app window available for the in-app preview, but never place it
        // above the actual authentication surface.
        guard lockScreenState.sessionState != .locked else {
            window.orderOut(nil)
            return
        }
        window.level = windowLevel(for: mode)
        switch mode {
        case .desktop:
            window.orderBack(nil)
            window.orderFrontRegardless()
        case .lockScreen:
            window.orderFrontRegardless()
        }
    }

    private func windowLevel(
        for mode: WallpaperPresentationMode
    ) -> NSWindow.Level {
        switch mode {
        case .desktop:
            return NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.desktopWindow))
            )
        case .lockScreen:
            return .screenSaver
        }
    }

    private func pauseAndCommitStillFrame() {
        manualPaused = true
        store.markPaused(true)
        player?.pause()
        showWindows()
    }

    private func applyPlaybackRate() {
        guard !manualPaused && !sleeping else { return }
        if lockScreenState.presentationMode != .lockScreen {
            guard !autoPausedForFullscreen else { return }
        }
        let rate = Float(max(0.1, min(config.playback_speed, 4.0)))
        player?.playImmediately(atRate: rate)
    }

    private func prepareFallbackImage(from videoURL: URL) {
        let image: NSImage?
        if WallpaperMediaKind.forURL(videoURL).isStaticImage {
            image = NSImage(contentsOf: videoURL)
        } else if let frameURL = try? store.captureStillFrame(from: videoURL) {
            image = NSImage(contentsOf: frameURL)
        } else {
            image = nil
        }
        guard let image,
              let cgImage = image.cgImage(
                  forProposedRect: nil,
                  context: nil,
                  hints: nil
              )
        else {
            fallbackImage = nil
            return
        }

        fallbackImage = cgImage
    }

    private func fallbackContentsGravity(
        for rawMode: String?
    ) -> CALayerContentsGravity {
        switch WallpaperScaleMode(rawValue: rawMode ?? "") ?? .fill {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }

    private func applyRuntimeSettings() {
        syncLockScreenSetting(reason: "lock-setting")
        player?.volume = Float(max(0, min(config.volume ?? 0, 1)))
        let gravity = videoGravity(for: config.scale_mode)
        for layer in playerLayers {
            layer.videoGravity = gravity
        }
        if manualPaused {
            player?.pause()
        } else {
            applyPlaybackRate()
        }
        applyFullscreenPolicy()
    }

    private func applyFullscreenPolicy() {
        guard !lockScreenOnlyMode else { return }
        if WallpaperMediaKind.forURL(URL(fileURLWithPath: config.video_path)).isStaticImage {
            fullscreenAppDetected = false
            consecutiveFullscreenSamples = 0
            consecutiveWindowedSamples = 0
            writeHealth(reason: "ok")
            return
        }

        if lockScreenState.presentationMode == .lockScreen {
            fullscreenAppDetected = false
            consecutiveFullscreenSamples = 0
            consecutiveWindowedSamples = 0
            if autoPausedForFullscreen {
                autoPausedForFullscreen = false
            }
            applyPlaybackRate()
            return
        }

        let shouldPauseForFullscreen = config.pause_on_fullscreen ?? true
        guard shouldPauseForFullscreen else {
            fullscreenAppDetected = false
            consecutiveFullscreenSamples = 0
            consecutiveWindowedSamples = 0
            if autoPausedForFullscreen {
                autoPausedForFullscreen = false
                applyPlaybackRate()
            }
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastSpaceChangeUptime >= spaceTransitionGracePeriod else {
            return
        }

        fullscreenAppDetected = Self.detectFullscreenApplication()
        if fullscreenAppDetected {
            consecutiveFullscreenSamples = min(
                consecutiveFullscreenSamples + 1,
                fullscreenConfirmationSamples
            )
            consecutiveWindowedSamples = 0
        } else {
            consecutiveWindowedSamples = min(
                consecutiveWindowedSamples + 1,
                fullscreenConfirmationSamples
            )
            consecutiveFullscreenSamples = 0
        }

        let shouldAutoPause =
            fullscreenAppDetected &&
            consecutiveFullscreenSamples >= fullscreenConfirmationSamples &&
            !manualPaused
        let shouldResume =
            !fullscreenAppDetected &&
            consecutiveWindowedSamples >= fullscreenConfirmationSamples

        if shouldAutoPause && !autoPausedForFullscreen {
            autoPausedForFullscreen = true
            player?.pause()
        } else if shouldResume && autoPausedForFullscreen {
            autoPausedForFullscreen = false
            applyPlaybackRate()
        }
    }

    private static func detectFullscreenApplication() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular
        else {
            return false
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let displayBounds: [CGRect] = NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        }
        let tolerance: CGFloat = 3

        for window in list {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmost.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"]
            else {
                continue
            }

            let bounds = CGRect(x: x, y: y, width: width, height: height)
            for display in displayBounds {
                if abs(bounds.minX - display.minX) <= tolerance,
                   abs(bounds.minY - display.minY) <= tolerance,
                   abs(bounds.maxX - display.maxX) <= tolerance,
                   abs(bounds.maxY - display.maxY) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func writeHealth(reason: String) {
        let paused = manualPaused || autoPausedForFullscreen
        let health = DaemonHealth(
            available: true,
            fresh: true,
            suspicious: consecutiveStallPolls >= 2,
            reason: reason,
            updated_at: Date().timeIntervalSince1970,
            lag_seconds: 0,
            screens: NSScreen.screens.count,
            windows: windows.count,
            player_rate: Double(player?.rate ?? 0),
            stall_events: stallEvents,
            recovery_events: recoveryEvents,
            consecutive_stall_polls: consecutiveStallPolls,
            paused: paused,
            manual_paused: manualPaused,
            low_power_mode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            auto_paused_for_low_power: false,
            pause_on_fullscreen: config.pause_on_fullscreen ?? true,
            fullscreen_app_detected: fullscreenAppDetected,
            auto_paused_for_fullscreen: autoPausedForFullscreen,
            lock_screen_enabled: lockScreenState.isEnabled,
            session_inactive: sessionInactive,
            lock_screen_preview_active: lockScreenState.previewState == .active,
            presentation_mode: lockScreenState.presentationMode.rawValue,
            lock_transition_count: lockTransitionCount,
            last_lock_transition_ms: lastLockTransitionMilliseconds,
            blend_interpolation_enabled: config.blend_interpolation ?? false,
            blend_interpolation_active: false,
            scale_mode: config.scale_mode
        )
        try? store.saveHealth(health)
    }

    private func samplePlaybackHealth() {
        reconcileSystemSessionState()
        repairModernLockScreenIfNeeded()
        rearmModernLockScreenForNextSession()

        if lockScreenOnlyMode {
            writeHealth(reason: "lock-screen-only")
            return
        }

        if WallpaperMediaKind.forURL(URL(fileURLWithPath: config.video_path)).isStaticImage {
            consecutiveStallPolls = 0
            writeHealth(reason: "ok")
            return
        }

        guard !manualPaused,
              !sleeping,
              !autoPausedForFullscreen
        else {
            lastPlaybackProgressUptime = nil
            consecutiveStallPolls = 0
            writeHealth(reason: "ok")
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        var failureReason = "playback-stall"
        if let player {
            let itemStatus = player.currentItem?.status
            if itemStatus == .readyToPlay, player.rate <= 0 {
                applyPlaybackRate()
                failureReason = "playback-rate-zero"
            } else if itemStatus == .failed {
                failureReason = "playback-item-failed"
            } else if itemStatus != .readyToPlay {
                failureReason = "playback-item-not-ready"
            }
            if itemStatus == .readyToPlay,
               player.rate > 0,
               let lastProgress = lastPlaybackProgressUptime,
               uptime - lastProgress < 3.5 {
                consecutiveStallPolls = 0
                writeHealth(reason: "ok")
                return
            }
        } else {
            failureReason = "playback-player-missing"
        }

        if lastPlaybackProgressUptime == nil {
            lastPlaybackProgressUptime = uptime
        }

        consecutiveStallPolls += 1
        guard consecutiveStallPolls >= stallRecoveryThreshold else {
            writeHealth(reason: "\(failureReason)-suspected")
            return
        }

        stallEvents += 1
        recoveryEvents += 1
        consecutiveStallPolls = 0
        lastPlaybackProgressUptime = nil
        rebuildPlayback(from: config, keepPaused: false)
        writeHealth(reason: "playback-stall-recovered")
    }

    private func repairModernLockScreenIfNeeded(force: Bool = false) {
        guard config.show_on_lock_screen == true,
              let videoURL = effectiveLockScreenVideoURL(),
              lockScreenInstaller.isAvailable,
              !lockScreenRepairInProgress,
              !sessionInactive,
              lockScreenState.sessionState == .unlocked,
              systemSessionIsLocked() == false,
              force
                || ProcessInfo.processInfo.systemUptime
                    - lastSessionTransitionUptime > 1.0
        else {
            return
        }

        let token = currentRearmToken()
        lockScreenRepairInProgress = true
        lockScreenRepairQueue.async { [weak self] in
            guard let self else { return }
            let repairError: Error?
            do {
                _ = try self.lockScreenInstaller.repair(
                    videoURL: videoURL,
                    shouldProceed: { [weak self] in
                        guard let self else { return false }
                        return DispatchQueue.main.sync {
                            self.repairCanProceed(
                                token: token,
                                videoURL: videoURL,
                                allowRecentTransition: force
                            )
                        }
                    }
                )
                repairError = nil
            } catch {
                repairError = error
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lockScreenRepairInProgress = false
                if let repairError {
                    self.writeHealth(
                        reason:
                            "lock-screen-repair-failed: "
                            + repairError.localizedDescription
                    )
                }
                if let pendingToken = self.pendingRearmToken,
                   pendingToken == self.currentRearmToken() {
                    self.pendingRearmToken = nil
                    self.rearmModernLockScreenForNextSession()
                }
            }
        }
    }

    private func rearmModernLockScreenForNextSession() {
        guard config.show_on_lock_screen == true,
              let videoURL = effectiveLockScreenVideoURL(),
              lockScreenInstaller.isAvailable,
              !sessionInactive,
              lockScreenState.sessionState == .unlocked,
              lockScreenState.previewState == .inactive,
              systemSessionIsLocked() == false
        else {
            return
        }
        let token = currentRearmToken()
        if lockScreenRepairInProgress {
            pendingRearmToken = token
            return
        }
        guard pendingRearmToken != token,
              lastRearmedToken != token
        else {
            return
        }
        pendingRearmToken = token
        lockScreenRepairInProgress = true
        lockScreenRepairQueue.async { [weak self] in
            guard let self else { return }
            let didRearm: Bool
            let rearmError: Error?
            do {
                didRearm = try self.lockScreenInstaller.rearmForNextLock(
                    videoURL: videoURL,
                    shouldProceed: { [weak self] in
                        guard let self else { return false }
                        return DispatchQueue.main.sync {
                            self.rearmCanProceed(
                                token: token,
                                videoURL: videoURL
                            )
                        }
                    }
                )
                rearmError = nil
            } catch {
                didRearm = false
                rearmError = error
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lockScreenRepairInProgress = false
                if self.pendingRearmToken == token {
                    self.pendingRearmToken = nil
                }
                if didRearm,
                   self.currentRearmToken() == token,
                   !self.sessionInactive {
                    self.lastRearmedToken = token
                }
                if self.lockScreenInstaller.requiresLockScreenSessionPromotion,
                   !self.sessionInactive,
                   self.systemSessionIsLocked() == false {
                    do {
                        _ = try self.lockScreenInstaller
                            .restoreDesktopAfterLockScreenSession()
                    } catch {
                        self.writeHealth(
                            reason:
                                "desktop-store-restoration-failed: "
                                + error.localizedDescription
                        )
                    }
                }
                if let rearmError {
                    self.writeHealth(
                        reason:
                            "lock-screen-rearm-failed: "
                            + rearmError.localizedDescription
                    )
                }
                if let pendingToken = self.pendingRearmToken,
                   pendingToken == self.currentRearmToken() {
                    self.pendingRearmToken = nil
                    self.rearmModernLockScreenForNextSession()
                }
            }
        }
    }

    private func currentRearmToken() -> LockScreenRearmToken {
        LockScreenRearmToken(
            sessionGeneration: lockSessionGeneration,
            wallpaperRevision: wallpaperRevision,
            videoPath: effectiveLockScreenVideoURL()?.path ?? ""
        )
    }

    private func effectiveLockScreenVideoURL() -> URL? {
        guard let sourceURL = store.effectiveLockScreenSourceURL(for: config),
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            return nil
        }
        return sourceURL
    }

    private func repairCanProceed(
        token: LockScreenRearmToken,
        videoURL: URL,
        allowRecentTransition: Bool
    ) -> Bool {
        !isTerminating
            && currentRearmToken() == token
            && !sessionInactive
            && lockScreenState.sessionState == .unlocked
            && lockScreenState.previewState == .inactive
            && config.show_on_lock_screen == true
            && effectiveLockScreenVideoURL()?.path == videoURL.path
            && systemSessionIsLocked() == false
            && (
                allowRecentTransition
                    || ProcessInfo.processInfo.systemUptime
                        - lastSessionTransitionUptime > 1.0
            )
    }

    private func rearmCanProceed(
        token: LockScreenRearmToken,
        videoURL: URL
    ) -> Bool {
        !isTerminating
            && pendingRearmToken == token
            && currentRearmToken() == token
            && !sessionInactive
            && lockScreenState.sessionState == .unlocked
            && lockScreenState.previewState == .inactive
            && config.show_on_lock_screen == true
            && effectiveLockScreenVideoURL()?.path == videoURL.path
            && systemSessionIsLocked() == false
    }

    private func systemSessionIsLocked() -> Bool? {
        guard let session =
            CGSessionCopyCurrentDictionary() as? [String: Any]
        else {
            return nil
        }
        if let value =
            session["CGSSessionScreenIsLocked"] as? NSNumber {
            return value.boolValue
        }

        // On an unlocked console macOS omits the lock key instead of storing
        // `false`. Treat that omission as unlocked only when the same snapshot
        // confirms this is the active, fully logged-in console session.
        let onConsole =
            (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue
        let loginDone =
            (session["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue
        if onConsole == true, loginDone == true {
            return false
        }
        return nil
    }

    private func videoGravity(for rawMode: String?) -> AVLayerVideoGravity {
        switch WallpaperScaleMode(rawValue: rawMode ?? "") ?? .fill {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }
}

let app = NSApplication.shared
private let delegate = WallpaperAgentDelegate()
app.delegate = delegate
app.run()
