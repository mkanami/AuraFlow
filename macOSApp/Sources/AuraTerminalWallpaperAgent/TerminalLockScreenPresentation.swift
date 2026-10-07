import AppKit
import AuraTerminalWallpaperCore
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
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var observer: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    var onLockStateChange: ((Bool) -> Void)?

    #if canImport(Wallpaper)
    // Erased storage avoids resolving private Swift type metadata at helper
    // startup on older macOS. The frameworks are weak-linked and gated below.
    private var displays: [AnyObject] = []
    private var displayIDs: [UInt32] = []
    private var presentations: [AnyObject] = []
    #endif

    func start() {
        guard !started else { return }
        started = true
        transition = TerminalLockTransition()
        notifiedLockState = nil
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
            Task { @MainActor in self?.prepare(reloadRoute: true) }
        }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [
            (Notification.Name("com.apple.screenIsLocked"), true),
            (Notification.Name("com.apple.screenIsUnlocked"), false),
            (Notification.Name("com.apple.shieldWindowRaised"), true),
            (Notification.Name("com.apple.sessionagent.shieldWindowRaised"), true),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleLockNotification(locked) }
            }
            sessionObservers.append(token)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleLockNotification(false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSession() }
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
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        generation &+= 1
        task?.cancel()
        task = nil
        #if canImport(Wallpaper)
        presentations.removeAll()
        displays.removeAll()
        displayIDs.removeAll()
        #endif
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func pollSession() {
        guard started else { return }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session.map { ($0["CGSSessionScreenIsLocked"] as? Bool) ?? false }
        let resolved = notifiedLockState ?? locked
        guard let changed = transition.update(resolved) else { return }
        logger.notice("Terminal Lock Screen session locked=\(changed)")
        onLockStateChange?(changed)
        if changed { startSaver() }
        prepare()
    }

    private var sessionObservers: [NSObjectProtocol] = []

    private func handleLockNotification(_ locked: Bool) {
        guard started else { return }
        notifiedLockState = locked
        guard let changed = transition.update(locked) else { return }
        logger.notice("Terminal Lock Screen notification locked=\(changed)")
        onLockStateChange?(changed)
        if changed { startSaver() }
        // Lock changes presentation, not the selected saver route. Reuse the
        // display assertions prepared on the desktop; rebuilding them here
        // puts provider startup on the first-frame path.
        prepare()
    }

    private func prepare(reloadRoute: Bool = false) {
        guard started else { return }
        #if canImport(Wallpaper)
        if reloadRoute {
            // A Lock arriving during reload must not reuse the display
            // assertion bound to the user's previous Idle provider.
            presentations.removeAll()
            displays.removeAll()
            displayIDs.removeAll()
        }
        #endif
        generation &+= 1
        let requestedGeneration = generation
        let locked = transition.locked
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            #if canImport(Wallpaper)
            guard #available(macOS 26, *) else { return }
            do {
                var nextDisplays: [WallpaperDisplayAssertion] = []
                var nextIDs: [UInt32] = []
                var nextPresentations: [WallpaperPresentationModeAssertion] = []
                for screen in NSScreen.screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                    let display: WallpaperDisplayAssertion
                    if !reloadRoute,
                       let index = self.displayIDs.firstIndex(of: id.uint32Value),
                       let warm = self.displays[index] as? WallpaperDisplayAssertion {
                        display = warm
                    } else {
                        display = try await self.makeDisplay(id.uint32Value)
                    }
                    guard !Task.isCancelled, self.generation == requestedGeneration else { return }
                    let presentation = try await Self.presentation(for: DisplayBox(display), locked: locked)
                    guard !Task.isCancelled, self.generation == requestedGeneration else { return }
                    nextDisplays.append(display)
                    nextIDs.append(id.uint32Value)
                    nextPresentations.append(presentation.value)
                }
                self.displays = nextDisplays
                self.displayIDs = nextIDs
                self.presentations = nextPresentations
                self.logger.notice("Terminal native presentation ready: locked=\(locked), displays=\(nextDisplays.count)")
            } catch {
                guard self.generation == requestedGeneration else { return }
                self.logger.error("Terminal native presentation failed: \(error.localizedDescription, privacy: .public)")
            }
            #else
            #endif
        }
    }

    private func startSaver() {
        // Never call this from app startup or an unconfirmed workspace event.
        guard started, transition.locked else { return }
        guard let function = Self.startFunction else {
            logger.error("SACScreenSaverStartNow is unavailable")
            return
        }
        let result = function()
        logger.notice("Terminal system saver start result=\(result)")
    }

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
