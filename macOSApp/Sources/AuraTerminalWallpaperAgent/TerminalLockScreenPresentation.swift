import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import CoreGraphics
import Darwin
import OSLog
#if canImport(Wallpaper)
@preconcurrency import Wallpaper
#endif

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
    private struct PresentationSurface {
        var displays: [AnyObject] = []
        var displayIDs: [UInt32] = []
        var presentations: [AnyObject] = []
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
        queue.onApplied = { [weak self] _ in
            guard let self, self.started else { return }
            if self.restartSaverWhenReady, self.sessionIsLocked() == true { self.startSaver() }
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
    private let uptime: () -> TimeInterval
    private let startScreenSaver: () -> Int32?
    private let routeRecovery: () throws -> Bool
    private var lastRouteCheck: TimeInterval = -.infinity
    private let presentationPreparer: ((Bool, Bool) async throws -> Void)?
    var onLockStateChange: ((Bool) -> Void)?

    init(
        sessionIsLocked: @escaping () -> Bool? = { LockScreenSession.currentIsLocked() },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        startScreenSaver: (() -> Int32?)? = nil,
        presentationPreparer: ((Bool, Bool) async throws -> Void)? = nil,
        routeRecovery: (() throws -> Bool)? = nil
    ) {
        self.sessionIsLocked = sessionIsLocked
        self.uptime = uptime
        self.startScreenSaver = startScreenSaver ?? { Self.startFunction?() }
        self.presentationPreparer = presentationPreparer
        let store = TerminalWallpaperRuntimeStore()
        let recovery = ScreenSaverRouteRecovery(journalURL: store.appSupportURL.appendingPathComponent("screen-saver-wallpaper-store-backup.json"))
        self.routeRecovery = routeRecovery ?? {
            // Injected presentation tests must never touch the live store.
            guard presentationPreparer == nil else { return false }
            return try recovery.recoverIfNeeded {
                store.lockScreenPlaybackEnabled && store.loadPID() == Int(getpid())
            }
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
        // Resolve the system entry point while the desktop is still visible,
        // rather than loading login.framework at the secure-screen boundary.
        _ = Self.startFunction
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
        prepare()
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
        presentationQueue.stop()
        systemRecoveryPending = false
        restartSaverWhenReady = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func pollSession() {
        guard started else { return }
        if uptime() - lastRouteCheck >= 1 {
            lastRouteCheck = uptime()
            do {
                if try routeRecovery() {
                    logger.notice("Restored Aura Lock Screen selection after system route drift")
                    prepare(reloadRoute: true, restartSaverAfterPreparation: transition.locked)
                }
            } catch {
                logger.error("Lock Screen route recovery deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        if systemRecoveryPending, sessionIsLocked() != nil {
            recoverAfterSystemChange()
            return
        }
        // Notifications can lead CGSession briefly, but must not override it
        // forever when an unlock notification is lost during sleep.
        if uptime() >= notificationExpiresAt { notifiedLockState = nil }
        if let changed = transition.update(notifiedLockState ?? sessionIsLocked()) {
            logger.notice("Terminal Lock Screen session locked=\(changed)")
            onLockStateChange?(changed)
            if !changed { saverStartNeedsRetry = false }
            if changed { startSaver() }
            prepare()
        } else if let retryAt, uptime() >= retryAt {
            prepare(reloadRoute: true, restartSaverAfterPreparation: sessionIsLocked() == true)
        }
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
        if let changed = transition.update(locked) { onLockStateChange?(changed) }
        if locked == false { saverStartNeedsRetry = false }
        prepare(reloadRoute: true, restartSaverAfterPreparation: locked == true)
    }

    private var sessionObservers: [NSObjectProtocol] = []

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
        guard let changed = transition.update(locked) else { return }
        logger.notice("Terminal Lock Screen notification locked=\(changed)")
        onLockStateChange?(changed)
        if !changed { saverStartNeedsRetry = false }
        if changed { startSaver() }
        // Lock changes presentation, not the selected saver route. Reuse the
        // display assertions prepared on the desktop; rebuilding them here
        // puts provider startup on the first-frame path.
        prepare()
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
        #if canImport(Wallpaper)
        if #available(macOS 26, *) {
            guard !NSScreen.screens.isEmpty else { throw PresentationError.noDisplays }
            var next = PresentationSurface()
            for screen in NSScreen.screens {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let display: WallpaperDisplayAssertion
                if !request.reloadRoute,
                   let previous, let index = previous.displayIDs.firstIndex(of: id.uint32Value),
                   let warm = previous.displays[index] as? WallpaperDisplayAssertion {
                    display = warm
                } else {
                    display = try await self.makeDisplay(id.uint32Value)
                }
                guard !Task.isCancelled, presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                let presentation = try await Self.presentation(for: DisplayBox(display), locked: request.locked)
                guard !Task.isCancelled, presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                next.displays.append(display)
                next.displayIDs.append(id.uint32Value)
                next.presentations.append(presentation.value)
            }
            guard !next.displays.isEmpty else { throw PresentationError.noDisplays }
            self.logger.notice("Terminal native presentation ready: locked=\(request.locked), displays=\(next.displays.count)")
            return next
        }
        #endif
        return PresentationSurface()
    }

    private func startSaver() {
        // Only a lock transition or a confirmed locked recovery may start it.
        guard started, transition.locked else { return }
        guard let result = startScreenSaver() else {
            logger.error("SACScreenSaverStartNow is unavailable")
            saverStartNeedsRetry = true
            return
        }
        logger.notice("Terminal system saver start result=\(result)")
        saverStartNeedsRetry = result != 0
    }

    private enum PresentationError: Error { case noDisplays }

    private static let startFunction: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "SACScreenSaverStartNow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    #if canImport(Wallpaper)
    // Use the exported allocator, not a devirtualized hidden initializer.
    @_optimize(none)
    private func makeDisplay(_ id: UInt32) async throws -> WallpaperDisplayAssertion {
        try await WallpaperDisplayAssertion(displayID: id, attributes: .screenSaver)
    }
    private final class DisplayBox: @unchecked Sendable {
        let value: WallpaperDisplayAssertion
        init(_ value: WallpaperDisplayAssertion) { self.value = value }
    }
    private final class PresentationBox: @unchecked Sendable {
        let value: WallpaperPresentationModeAssertion
        init(_ value: WallpaperPresentationModeAssertion) { self.value = value }
    }
    private nonisolated static func presentation(for display: DisplayBox, locked: Bool) async throws -> PresentationBox {
        if locked {
            return PresentationBox(try await WallpaperPresentationModeAssertion.takeLockedAssertion(displayAssertion: display.value))
        }
        return PresentationBox(try await WallpaperPresentationModeAssertion.takeIdleAssertion(displayAssertion: display.value))
    }
    #endif
}
