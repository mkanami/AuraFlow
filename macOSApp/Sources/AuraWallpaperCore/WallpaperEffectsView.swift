import AppKit
import QuartzCore

/// A click-through presentation wrapper. It never orders windows or changes system wallpaper or playback.
public final class WallpaperEffectsView: NSView {
    public let wallpaperContent: NSView
    public var playbackIsPaused: () -> Bool = { false }
    private let store: WallpaperEffectsStore?
    private let isPreview: Bool
    private let motionContainer = NSView()
    private let overlay = WallpaperEffectsOverlay()
    private(set) var settings = WallpaperEffectsSettings()
    private var motion = WallpaperEffectsMotion()
    private var animationTimer: Timer?
    private var statusTimer: Timer?
    private var lastFrameTime: CFTimeInterval?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspensionHints = WallpaperEffectsSuspensionHints()
    private var filtersApplied = false
    private var presentationActive = false
    var isAnimating: Bool { animationTimer != nil }

    public init(content: NSView, store: WallpaperEffectsStore? = WallpaperEffectsStore(), isPreview: Bool = false) {
        wallpaperContent = content
        self.store = store
        self.isPreview = isPreview
        super.init(frame: content.frame)
        wantsLayer = true
        layer?.masksToBounds = true
        content.wantsLayer = true
        motionContainer.wantsLayer = true
        motionContainer.frame = bounds
        content.frame = bounds
        motionContainer.addSubview(content)
        addSubview(motionContainer)
        layer?.addSublayer(overlay)
        overlay.isHidden = true
        autoresizingMask = [.width, .height]
        if let store { settings = store.load() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func update(settings: WallpaperEffectsSettings) {
        let next = settings.normalized()
        guard self.settings != next else { return }
        self.settings = next
        updateFilters(active: presentationActive)
        refreshActivity()
        needsLayout = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        motionContainer.frame = bounds
        wallpaperContent.frame = CGRect(origin: .zero, size: bounds.size)
        renderFrame(deltaTime: 0, cursor: nil)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { resetPresentation(); return }
        installObservers()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-read even without a notification (helper launch, coalescing, or a missed delivery).
                if let store = self.store { self.update(settings: store.load()) }
                self.refreshActivity()
            }
        }
        timer.tolerance = 0.05
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshActivity()
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let suspending = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                                      NSWorkspace.sessionDidResignActiveNotification].contains(note.name)
                    // A short hint covers notifications arriving before WindowServer changes state.
                    // Polling authoritative state prevents a missing wake/unlock notification from sticking.
                    if suspending { self.suspensionHints.systemWillSuspend(at: CACurrentMediaTime()) }
                    else { self.suspensionHints.systemDidResume() }
                    self.refreshActivity()
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in [WallpaperEffectsStore.didChange, Notification.Name("com.apple.screenIsLocked"),
                     Notification.Name("com.apple.screenIsUnlocked"), Notification.Name("com.apple.screensaver.didstart"),
                     Notification.Name("com.apple.screensaver.didstop")] {
            distributedObservers.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == WallpaperEffectsStore.didChange, let store = self.store { self.update(settings: store.load()) }
                    if note.name.rawValue == "com.apple.screensaver.didstart" { self.suspensionHints.saverDidStart(at: CACurrentMediaTime()) }
                    if note.name.rawValue == "com.apple.screensaver.didstop" { self.suspensionHints.saverDidStop() }
                    // Secure lock state always comes from WindowServer, including delayed notifications.
                    self.refreshActivity()
                }
            })
        }
    }

    private func refreshActivity() {
        var activity = WallpaperEffectsActivity()
        activity.windowVisible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        activity.sessionActive = (session?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true
            && (!isPreview || NSApp.isActive)
        activity.sleeping = suspensionHints.systemSuspended(at: CACurrentMediaTime())
        if let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            activity.sleeping = activity.sleeping || CGDisplayIsAsleep(number.uint32Value) != 0
        }
        // The visible saver also occludes the desktop; the hint only bridges its first compositor frame.
        activity.screenSaverActive = suspensionHints.saverSuspended(at: CACurrentMediaTime())
        activity.sessionLocked = LockScreenSession.isLocked(in: session)
        activity.playbackPaused = playbackIsPaused()
        activity.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        activity.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        applyActivity(activity)
    }

    func applyActivity(_ activity: WallpaperEffectsActivity) {
        guard settings.hasVisibleEffects && activity.canAnimate else {
            stopAnimation()
            resetPresentation()
            return
        }
        if !presentationActive { updateFilters(active: true) }
        presentationActive = true
        guard settings.hasAnimatedEffects else {
            stopAnimation()
            renderFrame(deltaTime: 0, cursor: nil)
            return
        }
        guard animationTimer == nil else { return }
        lastFrameTime = nil
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let now = CACurrentMediaTime()
                let delta = self.lastFrameTime.map { now - $0 } ?? 1.0 / 30
                self.lastFrameTime = now
                let screenPoint = NSEvent.mouseLocation
                let localPoint = self.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                let cursor = WallpaperEffectsMotion.normalizedCursor(localPoint, in: self.bounds)
                self.renderFrame(deltaTime: delta, cursor: cursor)
            }
        }
        timer.tolerance = 0.004
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func renderFrame(deltaTime: Double, cursor: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if settings.hasVisibleEffects && presentationActive {
            if animationTimer != nil { motion.advance(settings: settings, cursor: cursor, deltaTime: deltaTime) }
            let frame = motion.contentFrame(in: bounds.size, settings: settings)
            let scale = bounds.width > 0 ? frame.width / bounds.width : 1
            if let layer = motionContainer.layer {
                let anchor = layer.anchorPoint
                layer.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                    tx: frame.minX + (scale - 1) * bounds.width * anchor.x,
                    ty: frame.minY + (scale - 1) * bounds.height * anchor.y))
            }
            overlay.isHidden = !settings.hasAnimatedEffects
            if !overlay.isHidden {
                overlay.render(settings: settings, motion: motion, size: bounds.size, scale: window?.backingScaleFactor ?? 1)
            }
        } else {
            motionContainer.layer?.setAffineTransform(.identity)
            overlay.isHidden = true
        }
        CATransaction.commit()
    }

    private func resetPresentation() {
        presentationActive = false
        motion = WallpaperEffectsMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motionContainer.layer?.setAffineTransform(.identity)
        updateFilters(active: false)
        overlay.isHidden = true
        CATransaction.commit()
    }

    private func updateFilters(active: Bool) {
        guard active || filtersApplied else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let filters = active ? WallpaperEffectsFilters.make(settings: settings) : []
        if filters.isEmpty {
            motionContainer.layer?.filters = nil
            motionContainer.layerUsesCoreImageFilters = false
        } else {
            motionContainer.layerUsesCoreImageFilters = true
            motionContainer.layer?.filters = filters
        }
        filtersApplied = !filters.isEmpty
        CATransaction.commit()
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        lastFrameTime = nil
    }

    private func stopMonitoring() {
        stopAnimation()
        statusTimer?.invalidate()
        statusTimer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    deinit {
        animationTimer?.invalidate()
        statusTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
