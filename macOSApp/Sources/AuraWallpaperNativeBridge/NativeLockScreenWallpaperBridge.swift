import AppKit
import CoreGraphics
import Darwin
import OSLog
import QuartzCore
@preconcurrency import Wallpaper
import AuraWallpaperCore

@MainActor
final class NativeLockScreenWallpaperBridge {
    private typealias StartScreenSaverFunction = @convention(c) () -> Int32

    private static let logger = Logger(
        subsystem: "com.auraflow.wallpaper",
        category: "native-lock-screen"
    )

    private var displayAssertion: WallpaperDisplayAssertion?
    private var presentationAssertion: WallpaperPresentationModeAssertion?
    private var window: NSWindow?
    private var preparing = false
    private var showing = false
    private var lockedPresentationReady = false
    private var paused = false
    private var pauseEnforcementTask: Task<Void, Never>?
    private var pendingCompletions: [(Bool, String?) -> Void] = []
    private var pendingShowCompletions: [(Bool, String?) -> Void] = []
    private var recoveryTask: Task<Void, Never>?
    private var restartSaverWhenReady = false
    private var consecutivePresentationFailures = 0
    private let sessionIsLocked: () -> Bool?
    private let startScreenSaver: () -> Int32?

    init(
        sessionIsLocked: @escaping () -> Bool? = { LockScreenSession.currentIsLocked() },
        startScreenSaver: (() -> Int32?)? = nil
    ) {
        self.sessionIsLocked = sessionIsLocked
        self.startScreenSaver = startScreenSaver ?? { Self.startScreenSaverFunction?() }
    }

    private struct PresentationSurface {
        let display: WallpaperDisplayAssertion
        let presentation: WallpaperPresentationModeAssertion
        let window: NSWindow
    }
    private lazy var presentationQueue: LockScreenPresentationQueue<PresentationSurface> = {
        let queue = LockScreenPresentationQueue<PresentationSurface> { [weak self] request, previous in
            guard let self else { throw CancellationError() }
            guard !request.locked || self.sessionIsLocked() == true else { throw CancellationError() }
            let display: WallpaperDisplayAssertion
            let window: NSWindow
            if !request.reloadRoute, let previous {
                display = previous.display
                window = previous.window
            } else {
                display = try await self.makeDisplayAssertion()
                guard !Task.isCancelled, self.presentationQueue.isCurrent(request.id) else { throw CancellationError() }
                window = self.makeWindow(for: display.layer)
            }
            let box = DisplayAssertionBox(display)
            guard self.presentationQueue.isCurrent(request.id),
                  !request.locked || self.sessionIsLocked() == true else { throw CancellationError() }
            let presentation = try await request.locked
                ? Self.takeLockedAssertion(displayAssertion: box)
                : Self.takeIdleAssertion(displayAssertion: box)
            guard !request.locked || self.sessionIsLocked() == true else { throw CancellationError() }
            return PresentationSurface(display: display, presentation: presentation.value, window: window)
        }
        queue.onApplied = { [weak self] request in
            guard let self, let surface = self.presentationQueue.surface else { return }
            if self.window !== surface.window { self.window?.orderOut(nil) }
            self.displayAssertion = surface.display
            self.presentationAssertion = surface.presentation
            self.window = surface.window
            self.lockedPresentationReady = request.locked
            self.consecutivePresentationFailures = 0
            if self.paused {
                self.pauseLayer(surface.display.layer)
                self.startPauseEnforcement()
            }
            if self.preparing { self.finishPreparation(succeeded: true) }
            if request.locked {
                if self.restartSaverWhenReady { self.startSystemScreenSaverNow() }
                self.finishShowRequests(succeeded: true)
            }
            self.restartSaverWhenReady = false
        }
        queue.onFailure = { [weak self] _, error in
            guard let self else { return }
            if error is CancellationError {
                self.cancelUnconfirmedShow()
                return
            }
            Self.logger.error("Native presentation failed: \(error.localizedDescription, privacy: .public)")
            self.consecutivePresentationFailures += 1
            if self.isReady {
                // Keep any pending show alive through a transient display
                // failure; replying with failure would kill the client and
                // discard the retained surface before recovery can finish.
                self.recoverAfterSystemChange()
                return
            }
            if self.preparing {
                self.finishPreparation(succeeded: false, errorDescription: error.localizedDescription)
            }
            self.finishShowRequests(succeeded: false, errorDescription: error.localizedDescription)
        }
        return queue
    }()

    /// Performs a non-mutating startup probe. The bridge only reports itself
    /// as usable after dyld can load every framework it relies on and the
    /// symbols used by the imported Swift API are present. The probe
    /// deliberately does not create an assertion or touch the user's
    /// wallpaper state.
    static func runtimeCapabilities()
        -> NativeLockScreenBridgeRuntimeCapabilities
    {
        let frameworkHandles = nativeBridgePrivateFrameworkPaths
            .compactMap { path in
                openFramework(at: path)
            }
        let privateFrameworksLoaded = frameworkHandles.count
            == nativeBridgePrivateFrameworkPaths.count

        let requiredSymbolsResolved = privateFrameworksLoaded
            && requiredWallpaperSymbols.allSatisfy { symbol in
                hasSymbol(named: symbol, in: frameworkHandles[0])
            }
            && hasSymbol(
                named: WallpaperPlatformConstants.startScreenSaverSymbol,
                in: frameworkHandles.last
            )

        return NativeLockScreenBridgeRuntimeCapabilities(
            protocolVersion: NativeLockScreenBridgeRuntimeCapabilities
                .currentProtocolVersion,
            architecture: processArchitecture,
            privateFrameworksLoaded: privateFrameworksLoaded,
            requiredSymbolsResolved: requiredSymbolsResolved,
            supportedActions: NativeLockScreenBridgeRuntimeCapabilities
                .requiredActions
        )
    }

    private static let nativeBridgePrivateFrameworkPaths = [
        "/System/Library/PrivateFrameworks/Wallpaper.framework",
        "/System/Library/PrivateFrameworks/WallpaperTypes.framework",
        "/System/Library/PrivateFrameworks/login.framework",
    ]

    private static let requiredWallpaperSymbols = [
        "$s9Wallpaper0A16DisplayAssertionCMa",
        "$s9Wallpaper0A17DisplayAttributesV11screenSaverACvgZ",
        "$s9Wallpaper0A16DisplayAssertionC9displayID10attributesACs6UInt32V_AA0aB10AttributesVtYaKcfC",
        "$s9Wallpaper0A25PresentationModeAssertionC08takeIdleD007displayD0ACXDAA0a7DisplayD0C_tYaKFZ",
        "$s9Wallpaper0A25PresentationModeAssertionC010takeLockedD007displayD0ACXDAA0a7DisplayD0C_tYaKFZ",
    ]

    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func openFramework(at path: String) -> UnsafeMutableRawPointer? {
        let frameworkURL = URL(fileURLWithPath: path)
        let frameworkBinaryURL = frameworkURL.appendingPathComponent(
            frameworkURL.deletingPathExtension().lastPathComponent
        )
        for candidate in [path, frameworkBinaryURL.path] {
            if let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
        }
        return nil
    }

    private static func hasSymbol(
        named name: String,
        in handle: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let handle else { return false }
        // Mach-O tools display a leading underscore, while dlsym normally
        // accepts the source-level name. Accept both forms for SDK changes.
        return dlsym(handle, name) != nil
            || dlsym(handle, "_" + name) != nil
    }

    var isReady: Bool {
        displayAssertion != nil && window != nil
    }

    func prepare(completion: @escaping (Bool, String?) -> Void) {
        // Stop persists its marker before the runtime command reaches this
        // process. Pick it up before creating a new assertion so a late
        // preparation cannot start the Lock Screen video again.
        if WallpaperRuntimeStore().isPaused() {
            paused = true
        }

        if isReady {
            completion(true, nil)
            return
        }
        pendingCompletions.append(completion)
        guard !preparing else { return }
        preparing = true

        presentationQueue.request(locked: showing)
    }

    /// Lid wake can replace the display/provider without a new lock event.
    /// Rebind while retaining the previous surface, and restart the saver only
    /// after the replacement locked assertion is ready.
    func recoverAfterSystemChange() {
        guard isReady, WallpaperRuntimeStore().loadConfig().show_on_lock_screen != false else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            // Delay the first rebind until WindowServer has restored its
            // display list. Unknown session state must never imply unlock.
            var attempts = 0
            while !Task.isCancelled {
                let failures = self?.consecutivePresentationFailures ?? 0
                let delay = UInt64(min(max(failures, attempts / 10 + 1), 10)) * 100_000_000
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
                guard let self, !Task.isCancelled,
                      WallpaperRuntimeStore().loadConfig().show_on_lock_screen != false else { return }
                guard let locked = self.sessionIsLocked(),
                      !NSScreen.screens.isEmpty else {
                    attempts += 1
                    continue
                }
                self.showing = locked
                if !locked {
                    self.finishShowRequests(succeeded: false,
                        errorDescription: "Lock Screen presentation was cancelled by unlock.")
                }
                self.lockedPresentationReady = false
                self.restartSaverWhenReady = self.showing && locked
                self.presentationQueue.request(locked: self.showing, reloadRoute: true)
                self.recoveryTask = nil
                return
            }
        }
    }

    // Wallpaper is a private, library-evolution framework. Whole-module
    // optimization otherwise devirtualizes this allocation to its hidden
    // initializing entry point; keep the call on the exported allocator.
    @_optimize(none)
    private func makeDisplayAssertion() async throws
        -> WallpaperDisplayAssertion
    {
        try await WallpaperDisplayAssertion(
            displayID: CGMainDisplayID(),
            attributes: .screenSaver
        )
    }

    // These private framework assertions are opaque Objective-C handles with
    // no Sendable contract. The framework owns their cross-thread handoff;
    // these audited boxes keep that unavoidable boundary explicit and local.
    private final class DisplayAssertionBox: @unchecked Sendable {
        let value: WallpaperDisplayAssertion

        init(_ value: WallpaperDisplayAssertion) {
            self.value = value
        }
    }

    private final class PresentationAssertionBox: @unchecked Sendable {
        let value: WallpaperPresentationModeAssertion

        init(_ value: WallpaperPresentationModeAssertion) {
            self.value = value
        }
    }

    private nonisolated static func takeIdleAssertion(
        displayAssertion: DisplayAssertionBox
    ) async throws -> PresentationAssertionBox {
        PresentationAssertionBox(
            try await WallpaperPresentationModeAssertion.takeIdleAssertion(
                displayAssertion: displayAssertion.value
            )
        )
    }

    private nonisolated static func takeLockedAssertion(
        displayAssertion: DisplayAssertionBox
    ) async throws -> PresentationAssertionBox {
        PresentationAssertionBox(
            try await WallpaperPresentationModeAssertion.takeLockedAssertion(
                displayAssertion: displayAssertion.value
            )
        )
    }

    func showForLockTransition(completion: ((Bool, String?) -> Void)? = nil) {
        // Shield notifications and queued IPC can outlive an unlock. Starting
        // the saver on an active desktop locks the Mac, so only the current
        // WindowServer state may authorize this operation.
        guard sessionIsLocked() == true else {
            cancelUnconfirmedShow()
            completion?(false, "Lock Screen presentation was cancelled by unlock.")
            return
        }
        guard WallpaperRuntimeStore().loadConfig().show_on_lock_screen != false else {
            completion?(false, "Lock Screen is disabled.")
            return
        }
        // Close the small Stop -> Lock race: the marker is committed before
        // the .pause command is delivered to the agent.
        if WallpaperRuntimeStore().isPaused() {
            paused = true
        }

        if showing {
            if lockedPresentationReady {
                completion?(true, nil)
            } else if let completion {
                pendingShowCompletions.append(completion)
            }
            return
        }
        showing = true
        lockedPresentationReady = false
        if let completion {
            pendingShowCompletions.append(completion)
        }
        guard displayAssertion != nil else {
            showing = false
            finishShowRequests(
                succeeded: false,
                errorDescription: "Native Lock Screen display assertion is not ready."
            )
            return
        }
        startSystemScreenSaverNow()
        // Keep the prewarmed layer hidden. Making it visible here creates a
        // three-frame transition: Aura, loginwindow's Desktop snapshot, then
        // the real Aura Lock Screen. loginwindow owns the secure surface and
        // presents the prepared screen-saver route itself.
        presentationQueue.request(locked: true)
    }

    private func finishShowRequests(
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        let completions = pendingShowCompletions
        pendingShowCompletions.removeAll()
        for completion in completions {
            completion(succeeded, errorDescription)
        }
    }

    func resumeAfterPause() {
        pauseEnforcementTask?.cancel()
        pauseEnforcementTask = nil
        if let layer = displayAssertion?.layer, layer.speed == 0 {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let resumedTime = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            )
            layer.beginTime = resumedTime - pausedTime
        }
        paused = false
    }

    func setPlaybackSpeed(_ speed: Double) {
        // Retained as a wire-compatible no-op for already-running agents.
        // Apple owns the Aerial player's clock and ignores its host CALayer's
        // speed; AuraFlow now retimes the managed movie samples instead.
        _ = speed
    }

    func pause() {
        let wasPaused = paused
        paused = true
        if let layer = displayAssertion?.layer {
            pauseLayer(layer)
        }
        startPauseEnforcement()
        if !wasPaused {
            Self.logger.notice("Native Lock Screen layer paused")
        }
    }

    /// The secure Lock Screen can refresh or rebind the presentation layer
    /// while loginwindow is active. Re-apply the paused timing state so Stop
    /// remains equivalent to Desktop pause instead of being lost on one of
    /// those compositor refreshes.
    private func startPauseEnforcement() {
        guard pauseEnforcementTask == nil else { return }
        pauseEnforcementTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.paused else { return }
                if let layer = self.displayAssertion?.layer {
                    self.pauseLayer(layer)
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func pauseLayer(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let pausedTime = layer.convertTime(
            CACurrentMediaTime(),
            from: nil
        )
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    func hideAfterUnlock() {
        recoveryTask?.cancel()
        recoveryTask = nil
        showing = false
        lockedPresentationReady = false
        restartSaverWhenReady = false
        finishShowRequests(
            succeeded: false,
            errorDescription: "Lock Screen presentation was cancelled by unlock."
        )
        window?.alphaValue = 0
        guard displayAssertion != nil else { return }
        presentationQueue.request(locked: false)
    }

    private func cancelUnconfirmedShow() {
        if sessionIsLocked() == false {
            hideAfterUnlock()
        } else {
            showing = false
            lockedPresentationReady = false
            restartSaverWhenReady = false
            finishShowRequests(succeeded: false,
                errorDescription: "Lock Screen presentation was cancelled by unlock.")
        }
    }

    func shutdown() {
        pauseEnforcementTask?.cancel()
        pauseEnforcementTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        presentationQueue.stop()
        restartSaverWhenReady = false
        consecutivePresentationFailures = 0
        showing = false
        lockedPresentationReady = false
        finishShowRequests(
            succeeded: false,
            errorDescription: "Native Lock Screen bridge is shutting down."
        )
        window?.orderOut(nil)
        window = nil
        presentationAssertion = nil
        displayAssertion = nil
        pendingCompletions.removeAll()
        preparing = false
        showing = false
        paused = false
    }

    private func startSystemScreenSaverNow() {
        // Recheck at the side-effect boundary, including delayed wake/rebind
        // completions. Cached `showing` state is never proof of a lock.
        guard showing, sessionIsLocked() == true else { return }
        guard let result = startScreenSaver() else {
            Self.logger.error("SACScreenSaverStartNow is unavailable")
            return
        }
        if result != 0 {
            Self.logger.error(
                "SACScreenSaverStartNow failed: \(result, privacy: .public)"
            )
        }
    }

    private static let startScreenSaverFunction: StartScreenSaverFunction? = {
        guard let handle = dlopen(
            WallpaperPlatformConstants.loginFrameworkPath,
            RTLD_NOW | RTLD_LOCAL
        ),
        let symbol = dlsym(
            handle,
            WallpaperPlatformConstants.startScreenSaverSymbol
        )
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: StartScreenSaverFunction.self)
    }()

    private func makeWindow(for wallpaperLayer: CALayer) -> NSWindow {
        let frame = NSScreen.main?.frame
            ?? NSScreen.screens.first?.frame
            ?? .zero
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.canHide = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        let content = NSView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        content.wantsLayer = true
        wallpaperLayer.frame = content.bounds
        wallpaperLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(wallpaperLayer)
        window.contentView = content
        window.alphaValue = 0
        window.orderFrontRegardless()
        return window
    }

    private func finishPreparation(
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        preparing = false
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        for completion in completions {
            completion(succeeded, errorDescription)
        }
    }
}
