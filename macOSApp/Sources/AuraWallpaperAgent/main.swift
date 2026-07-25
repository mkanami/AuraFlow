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
    private let store = WallpaperRuntimeStore()
    private var config: ControlConfig
    private var windows: [NSWindow] = []
    private var playerLayers: [AVPlayerLayer] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var commandTimer: Timer?
    private var healthTimer: Timer?
    private var fullscreenTimer: Timer?
    private var lastCommandID: String?
    private var manualPaused = false
    private var autoPausedForFullscreen = false
    private var fullscreenAppDetected = false
    private var consecutiveFullscreenSamples = 0
    private var consecutiveWindowedSamples = 0
    private var lastSpaceChangeUptime = -Double.infinity
    private var signalSources: [DispatchSourceSignal] = []

    private let spaceTransitionGracePeriod: TimeInterval = 0.75
    private let fullscreenConfirmationSamples = 2

    override init() {
        self.config = store.loadConfig()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? store.savePID()
        store.markPaused(false)
        installSignalHandlers()
        rebuildPlayback(from: config, keepPaused: false)
        startTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        writeHealth(reason: "terminating")
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tearDownPlayback()
        store.removePID()
        store.markPaused(false)
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

        // Cross-process notifications handle the normal fast path. This low-frequency
        // timer is only a safety net for a notification missed during process startup.
        commandTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCommand()
        }
        commandTimer?.tolerance = 0.20
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.writeHealth(reason: "ok")
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
        writeHealth(reason: "ok")
    }

    @objc private func runtimeCommandDidChange(_ notification: Notification) {
        pollCommand()
    }

    @objc private func screensChanged() {
        rebuildWindows()
        writeHealth(reason: "screen-change")
    }

    @objc private func activeSpaceDidChange() {
        lastSpaceChangeUptime = ProcessInfo.processInfo.systemUptime
        consecutiveFullscreenSamples = 0
        consecutiveWindowedSamples = 0
    }

    private func pollCommand() {
        guard let command = store.loadCommand(), command.id != lastCommandID else { return }
        lastCommandID = command.id
        if let newConfig = command.config {
            config = store.normalized(newConfig)
        }

        switch command.action {
        case .reload:
            rebuildPlayback(from: config, keepPaused: false)
            manualPaused = false
            store.markPaused(false)
        case .update:
            applyRuntimeSettings()
        case .resume:
            showWindows()
            manualPaused = false
            store.markPaused(false)
            applyPlaybackRate()
        case .pause:
            pauseAndCommitStillFrame()
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

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [])
        player.actionAtItemEnd = .none
        player.volume = Float(max(0, min(config.volume ?? 0, 1)))
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
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

        guard let existingPlayer else { return }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
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
            window.level = NSWindow.Level(rawValue: desktopLevel)
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = behavior
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.canHide = false
            window.isExcludedFromWindowsMenu = true

            let content = WallpaperLayerView(frame: screen.frame)
            content.wantsLayer = true
            content.autoresizingMask = [.width, .height]
            let playerLayer = AVPlayerLayer(player: existingPlayer)
            playerLayer.frame = content.bounds
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            playerLayer.videoGravity = videoGravity(for: config.scale_mode)
            content.layer?.addSublayer(playerLayer)
            playerLayers.append(playerLayer)
            window.contentView = content

            if !manualPaused {
                window.orderBack(nil)
                window.orderFrontRegardless()
            }
            windows.append(window)
        }
    }

    private func tearDownPlayback() {
        player?.pause()
        looper = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        playerLayers.removeAll()
        player = nil
    }

    private func showWindows() {
        for window in windows where !window.isVisible {
            window.orderBack(nil)
            window.orderFrontRegardless()
        }
    }

    private func pauseAndCommitStillFrame() {
        manualPaused = true
        store.markPaused(true)
        player?.pause()
        showWindows()
    }

    private func applyPlaybackRate() {
        guard !manualPaused && !autoPausedForFullscreen else { return }
        let rate = Float(max(0.1, min(config.playback_speed, 4.0)))
        player?.playImmediately(atRate: rate)
    }

    private func applyRuntimeSettings() {
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
            suspicious: false,
            reason: reason,
            updated_at: Date().timeIntervalSince1970,
            lag_seconds: 0,
            screens: NSScreen.screens.count,
            windows: windows.count,
            player_rate: Double(player?.rate ?? 0),
            stall_events: 0,
            recovery_events: 0,
            consecutive_stall_polls: 0,
            paused: paused,
            manual_paused: manualPaused,
            low_power_mode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            auto_paused_for_low_power: false,
            pause_on_fullscreen: config.pause_on_fullscreen ?? true,
            fullscreen_app_detected: fullscreenAppDetected,
            auto_paused_for_fullscreen: autoPausedForFullscreen,
            blend_interpolation_enabled: config.blend_interpolation ?? false,
            blend_interpolation_active: false,
            scale_mode: config.scale_mode
        )
        try? store.saveHealth(health)
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
