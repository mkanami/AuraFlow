import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import CoreGraphics
import Darwin
import OSLog

/// A session notification alone is not proof of a lock (launch and fast user
/// switching emit them too). Only the WindowServer session state may start
/// the saver. Keeping this separate makes duplicate/unknown states testable.
struct TerminalLockTransition {
    private(set) var locked = false
    mutating func update(_ confirmedLocked: Bool?) -> Bool? {
        guard let confirmedLocked, confirmedLocked != locked else { return nil }
        locked = confirmedLocked
        return confirmedLocked
    }
}

/// Owns the same native presentation mechanism as the video helper, without
/// its video config, pause markers, or Aerial installer. Selecting an Idle
/// provider does not itself ask loginwindow to present it after direct Lock.
@MainActor
final class TerminalLockScreenPresentation {
    private final class SaverActivity {
        var running = false
        var hasRun = false
    }
    private let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "terminal-lock-screen")
    private var timer: Timer?
    private var started = false
    private var transition = TerminalLockTransition()
    private var notifiedLockState: Bool?
    private var notificationExpiresAt: TimeInterval = 0
    private var retryAt: TimeInterval?
    private var saverStartNeedsRetry = false
    private var systemRecoveryPending = false
    private var restartSaverWhenReady = false
    private let saverActivity = SaverActivity()
    private var playbackActive = false
    private var lastSaverCheck: TimeInterval = -.infinity
    private struct PresentationSurface {
        var displays: [TerminalNativeDisplayLease] = []
        var displayIDs: [UInt32] = []
        var presentations: [AnyObject] = []
        var hosts: [TerminalNativeWallpaperSurfaceHost] = []
    }
    private lazy var presentationQueue: LockScreenPresentationQueue<PresentationSurface> = {
        let queue = LockScreenPresentationQueue<PresentationSurface> { [weak self] request, previous in
            guard let self else { throw CancellationError() }
            if let presentationPreparer = self.presentationPreparer {
                try await presentationPreparer(request.locked, request.reloadRoute)
                return PresentationSurface()
            }
            return try await self.prepareNativePresentation(request, previous: previous)
        }
        queue.onApplied = { [weak self] request in
            guard let self, self.started else { return }
            if request.locked, self.restartSaverWhenReady, self.sessionIsLocked() == true { self.startSaver() }
            self.restartSaverWhenReady = false
            if self.saverStartNeedsRetry { self.retryAt = self.uptime() + 5 }
        }
        queue.onFailure = { [weak self] _, error in
            guard let self, self.started else { return }
            self.retryAt = self.uptime() + 5
            self.logger.error("Terminal native presentation failed; retrying: \(error.localizedDescription, privacy: .public)")
        }
        return queue
    }()
    private var activity: NSObjectProtocol?
    private var observer: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private let sessionIsLocked: () -> Bool?
    private let screenSaverIsRunning: () -> Bool?
    private let uptime: () -> TimeInterval
    private let startScreenSaver: () -> Int32?
    private let routeRecovery: () throws -> Bool
    private let restoreUserDesktop: () throws -> Void
    private var lastRouteCheck: TimeInterval = -.infinity
    private let presentationPreparer: ((Bool, Bool) async throws -> Void)?
    private let nativeDriver: (any TerminalLockScreenNativeDriving)?
    private let displaysProvider: @MainActor () -> [TerminalLockScreenDisplay]
    private let orderNativeWindow: @MainActor (NSWindow) -> Void
    // Rendering/capture activity includes the OS saver before password lock.
    // Only sessionIsLocked may authorize a system saver-start side effect.
    var onLockStateChange: ((Bool) -> Void)?

    init(
        sessionIsLocked: @escaping () -> Bool? = { LockScreenSession.currentIsLocked() },
        screenSaverIsRunning: (() -> Bool?)? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        startScreenSaver: (() -> Int32?)? = nil,
        presentationPreparer: ((Bool, Bool) async throws -> Void)? = nil,
        routeRecovery: (() throws -> Bool)? = nil,
        restoreUserDesktop: (() throws -> Void)? = nil,
        nativeDriver: (any TerminalLockScreenNativeDriving)? = nil,
        displaysProvider: @escaping @MainActor () -> [TerminalLockScreenDisplay] = { TerminalLockScreenDisplay.current() },
        orderNativeWindow: @escaping @MainActor (NSWindow) -> Void = { $0.orderFrontRegardless() },
        runtimeStore: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        routeCoordinator: ScreenSaverRouteRecovery? = nil
    ) {
        self.sessionIsLocked = sessionIsLocked
        self.screenSaverIsRunning = screenSaverIsRunning ?? {
            guard presentationPreparer == nil, nativeDriver == nil, routeRecovery == nil else { return false }
            return Self.runningFunction?()
        }
        self.uptime = uptime
        self.startScreenSaver = startScreenSaver ?? { Self.startFunction?() }
        self.presentationPreparer = presentationPreparer
        self.nativeDriver = nativeDriver ?? terminalLockScreenNativeDriver()
        let hasNativePresentation = self.nativeDriver != nil
        self.displaysProvider = displaysProvider
        self.orderNativeWindow = orderNativeWindow
        let store = runtimeStore
        let saverActivity = self.saverActivity
        let recovery = routeCoordinator ?? ScreenSaverRouteRecovery(journalURL: store.appSupportURL.appendingPathComponent("screen-saver-wallpaper-store-backup.json"))
        self.routeRecovery = routeRecovery ?? {
            // Injected presentation tests must never touch the live store.
            guard presentationPreparer == nil else { return false }
            let ownsSource = {
                store.lockScreenPlaybackEnabled && store.loadPID() == Int(getpid())
            }
            guard ownsSource() else { return false }
            let needsDesktopHandoff = {
                sessionIsLocked() == true && !saverActivity.running && !saverActivity.hasRun
            }
            var changed = false
            if sessionIsLocked() != nil, !needsDesktopHandoff() {
                changed = try recovery.restoreDesktopAfterLockSession { ownsSource() && sessionIsLocked() != nil && !needsDesktopHandoff() }
            }
            if try recovery.recoverIfNeeded(shouldProceed: ownsSource) { changed = true }
            if hasNativePresentation, needsDesktopHandoff(),
               try recovery.activateDesktopForLockSession(shouldProceed: { ownsSource() && needsDesktopHandoff() }) { changed = true }
            return changed
        }
        self.restoreUserDesktop = restoreUserDesktop ?? {
            guard presentationPreparer == nil, routeRecovery == nil, store.loadPID() == Int(getpid()) else { return }
            _ = try recovery.restoreDesktopAfterLockSession()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        transition = TerminalLockTransition()
        notifiedLockState = nil
        retryAt = nil
        saverStartNeedsRetry = false
        systemRecoveryPending = false
        saverActivity.running = false
        saverActivity.hasRun = false
        playbackActive = false
        lastSaverCheck = -.infinity
        // Resolve the system entry point while the desktop is still visible,
        // rather than loading login.framework at the secure-screen boundary.
        _ = Self.startFunction
        _ = Self.runningFunction
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep terminal frames and Lock Screen handoff alive"
        )
        observer = DistributedNotificationCenter.default().addObserver(
            forName: TerminalWallpaperRuntimeNotifications.lockScreenRouteDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepare(reloadRoute: true) }
        }
        let center = DistributedNotificationCenter.default()
        for (name, running) in [("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            sessionObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleScreenSaverNotification(running) }
            })
        }
        for (name, locked) in [
            (Notification.Name("com.apple.screenIsLocked"), true),
            (Notification.Name("com.apple.screenIsUnlocked"), false),
            (Notification.Name("com.apple.shieldWindowRaised"), true),
            (Notification.Name("com.apple.sessionagent.shieldWindowRaised"), true),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleLockNotification(locked) }
            }
            sessionObservers.append(token)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recoverAfterSystemChange() }
            })
        }
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // CGSession may still report the lock while unlock completes.
                self?.handleLockNotification(false)
                self?.prepare(reloadRoute: true)
            }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.wallpaper.agent" else { return }
            Task { @MainActor [weak self] in self?.recoverAfterSystemChange() }
        })
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAfterSystemChange() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSession() }
        }
        // Login recovery can start this helper after the secure screen is
        // already visible. Use the same reconciler as manual/automatic lock
        // events, rather than first acquiring an unrelated idle assertion.
        reconcileSession(forcePreparation: true, forceSaverCheck: true)
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        for token in sessionObservers { DistributedNotificationCenter.default().removeObserver(token) }
        sessionObservers.removeAll()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        retryAt = nil
        saverStartNeedsRetry = false
        presentationQueue.surface?.hosts.forEach { $0.close() }
        presentationQueue.stop()
        systemRecoveryPending = false
        restartSaverWhenReady = false
        do { try restoreUserDesktop() }
        catch { logger.error("User Desktop restoration deferred: \(error.localizedDescription, privacy: .public)") }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func pollSession() {
        guard started else { return }
        if systemRecoveryPending, sessionIsLocked() != nil {
            recoverAfterSystemChange()
            return
        }
        reconcileSession()
    }

    /// Manual lock, OS idle saver, polling, and wake all converge here. Saver
    /// activity is distinct from CGSession's secure lock during password grace.
    private func reconcileSession(forceReload: Bool = false, forcePreparation: Bool = false, forceSaverCheck: Bool = false) {
        guard started else { return }
        let saverChanged = refreshSaverActivity(force: forceSaverCheck)
        // Notifications can lead CGSession briefly, but must not override it
        // forever when an unlock notification is lost during sleep.
        if uptime() >= notificationExpiresAt { notifiedLockState = nil }
        guard let confirmed = sessionIsLocked() else {
            // WindowServer may not be ready after login or wake. Retain an
            // existing assertion, but never invent an idle one for an unknown
            // session. A running automatic saver may still publish frames.
            systemRecoveryPending = true
            _ = updatePlaybackActivity()
            return
        }
        systemRecoveryPending = false
        let retainConfirmedLock = transition.locked && notifiedLockState == true && uptime() < notificationExpiresAt
        let changed = transition.update(retainConfirmedLock ? true : confirmed)
        if let changed { logger.notice("Terminal Lock Screen session locked=\(changed), systemSaver=\(self.saverActivity.running)") }
        let activityChanged = updatePlaybackActivity()
        if confirmed == false, !saverActivity.running { saverActivity.hasRun = false }
        if !transition.locked || saverActivity.running || (saverChanged && !saverActivity.running) {
            saverStartNeedsRetry = false
            restartSaverWhenReady = false
        }
        var reload = forceReload
        if forceReload || saverChanged || changed != nil || uptime() - lastRouteCheck >= 1 {
            lastRouteCheck = uptime()
            do {
                if try routeRecovery() {
                    logger.notice("Reconciled Aura wallpaper routes for the current presentation")
                    reload = true
                }
            } catch {
                logger.error("Lock Screen route recovery deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        let retry = retryAt.map { uptime() >= $0 } ?? false
        if forcePreparation || changed != nil || activityChanged || saverChanged || reload || retry {
            let startNeeded = transition.locked && !saverActivity.running &&
                (forceReload || (!saverActivity.hasRun && (changed == true || retry || saverStartNeedsRetry)))
            prepare(reloadRoute: reload || retry, restartSaverAfterPreparation: startNeeded)
        }
    }

    @discardableResult
    private func refreshSaverActivity(force: Bool) -> Bool {
        guard force || uptime() - lastSaverCheck >= 1 else { return false }
        lastSaverCheck = uptime()
        guard let running = screenSaverIsRunning() else { return false }
        let changed = running != saverActivity.running
        saverActivity.running = running
        if running { saverActivity.hasRun = true }
        return changed
    }

    @discardableResult
    private func updatePlaybackActivity() -> Bool {
        let active = transition.locked || saverActivity.running
        guard active != playbackActive else { return false }
        playbackActive = active
        onLockStateChange?(active)
        return true
    }

    func recoverAfterSystemChange() {
        guard started else { return }
        // Waking an already locked session emits no new lock transition.
        // Rebind its system surface and restart its saver explicitly, while
        // preserving the running PTY, parser, and manual pause intent.
        // WindowServer can be unavailable at the wake edge. Preserve the
        // current surface and retry on the session poll instead of replacing
        // it with an unconfirmed idle/locked assertion.
        guard let locked = sessionIsLocked() else {
            systemRecoveryPending = true
            return
        }
        if !locked, notifiedLockState == true, uptime() < notificationExpiresAt {
            systemRecoveryPending = true
            return
        }
        systemRecoveryPending = false
        notifiedLockState = nil
        logger.notice("Restoring terminal system presentation after wake or display change; locked=\(locked == true)")
        reconcileSession(forceReload: true, forceSaverCheck: true)
    }

    private var sessionObservers: [NSObjectProtocol] = []

    func handleScreenSaverNotification(_ running: Bool) {
        guard started else { return }
        // The actual loginwindow state wins over late/stale notifications.
        logger.notice("System screen saver notification running=\(running)")
        reconcileSession(forceSaverCheck: true)
    }

    func handleLockNotification(_ locked: Bool) {
        guard started else { return }
        // Unlock notifications can precede CGSession, including an unrelated
        // session-active callback during lid wake. Never release the secure
        // presentation until the system confirms that it is unlocked.
        if !locked, sessionIsLocked() != false {
            notifiedLockState = nil
            return
        }
        notifiedLockState = locked
        notificationExpiresAt = uptime() + 1
        guard !locked || sessionIsLocked() == true else { return }
        reconcileSession(forceSaverCheck: true)
    }

    private func prepare(reloadRoute: Bool = false, restartSaverAfterPreparation: Bool = false) {
        guard started else { return }
        restartSaverWhenReady = transition.locked && (restartSaverWhenReady || restartSaverAfterPreparation)
        retryAt = nil
        presentationQueue.request(locked: transition.locked, reloadRoute: reloadRoute)
    }

    private func prepareNativePresentation(
        _ request: LockScreenPresentationQueue<PresentationSurface>.Request,
        previous: PresentationSurface?
    ) async throws -> PresentationSurface {
        _ = try routeRecovery()
        if let nativeDriver {
            let screens = displaysProvider()
            guard !screens.isEmpty else { throw PresentationError.noDisplays }
            var next = PresentationSurface()
            for screen in screens {
                let display: TerminalNativeDisplayLease
                let host: TerminalNativeWallpaperSurfaceHost
                if !request.reloadRoute,
                   let previous, let index = previous.displayIDs.firstIndex(of: screen.id) {
                    display = previous.displays[index]
                    host = previous.hosts[index]
                } else {
                    display = try await nativeDriver.makeDisplay(screen.id)
                    guard !Task.isCancelled, presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                    host = TerminalNativeWallpaperSurfaceHost(layer: display.layer, frame: screen.frame, orderWindow: orderNativeWindow)
                }
                guard !Task.isCancelled, presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                let presentation = try await nativeDriver.makePresentation(for: display, locked: request.locked)
                guard !Task.isCancelled, presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                next.displays.append(display)
                next.displayIDs.append(screen.id)
                next.presentations.append(presentation)
                next.hosts.append(host)
            }
            guard !next.displays.isEmpty else { throw PresentationError.noDisplays }
            self.logger.notice("Terminal native presentation ready: locked=\(request.locked), displays=\(next.displays.count), hostedLayers=\(next.hosts.count)")
            return next
        }
        return PresentationSurface()
    }

    private func startSaver() {
        // Only a lock transition or a confirmed locked recovery may start it.
        guard started, transition.locked else { return }
        guard sessionIsLocked() == true else {
            saverStartNeedsRetry = true
            return
        }
        _ = refreshSaverActivity(force: true)
        if saverActivity.running {
            saverStartNeedsRetry = false
            return
        }
        guard let result = startScreenSaver() else {
            logger.error("SACScreenSaverStartNow is unavailable")
            saverStartNeedsRetry = true
            return
        }
        logger.notice("Terminal system saver start result=\(result)")
        saverStartNeedsRetry = result != 0
        if result == 0 { saverActivity.hasRun = true }
    }

    private enum PresentationError: Error { case noDisplays }

    private static let startFunction: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "SACScreenSaverStartNow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    private static let runningFunction: (@convention(c) () -> Bool)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "SACScreenSaverIsRunning") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()

}
