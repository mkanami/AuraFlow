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
    private var paused = false
    private var pendingCompletions: [(Bool, String?) -> Void] = []
    private var presentationRequestID: UInt64 = 0

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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let assertion = try await makeDisplayAssertion()
                let presentation = try await WallpaperPresentationModeAssertion
                    .takeIdleAssertion(displayAssertion: assertion)
                let window = makeWindow(for: assertion.layer)
                self.displayAssertion = assertion
                self.presentationAssertion = presentation
                self.window = window
                if self.paused {
                    self.pauseLayer(assertion.layer)
                }
                self.finishPreparation(succeeded: true)
                Self.logger.notice("Native Lock Screen layer prepared")
            } catch {
                Self.logger.error(
                    "Native Lock Screen preparation failed: \(error.localizedDescription, privacy: .public)"
                )
                self.finishPreparation(
                    succeeded: false,
                    errorDescription: error.localizedDescription
                )
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

    func showForLockTransition(completion: ((Bool, String?) -> Void)? = nil) {
        // Close the small Stop -> Lock race: the marker is committed before
        // the .pause command is delivered to the agent.
        if WallpaperRuntimeStore().isPaused() {
            paused = true
        }

        if showing {
            completion?(isReady, nil)
            return
        }
        showing = true
        presentationRequestID &+= 1
        let requestID = presentationRequestID
        startSystemScreenSaverNow()
        guard let displayAssertion else {
            showing = false
            completion?(false, "Native Lock Screen display assertion is not ready.")
            return
        }
        // Keep the prewarmed layer hidden. Making it visible here creates a
        // three-frame transition: Aura, loginwindow's Desktop snapshot, then
        // the real Aura Lock Screen. loginwindow owns the secure surface and
        // presents the prepared screen-saver route itself.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let assertion = try await
                    WallpaperPresentationModeAssertion.takeLockedAssertion(
                        displayAssertion: displayAssertion
                    )
                guard self.presentationRequestID == requestID,
                      self.showing
                else {
                    return
                }
                self.presentationAssertion = assertion
                if self.paused {
                    self.pauseLayer(displayAssertion.layer)
                }
                completion?(true, nil)
            } catch {
                Self.logger.error(
                    "Native locked presentation failed: \(error.localizedDescription, privacy: .public)"
                )
                self.showing = false
                completion?(false, error.localizedDescription)
            }
        }
    }

    func resumeAfterPause() {
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

    func pause() {
        let wasPaused = paused
        paused = true
        if let layer = displayAssertion?.layer {
            pauseLayer(layer)
        }
        if !wasPaused {
            Self.logger.notice("Native Lock Screen layer paused")
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
        showing = false
        presentationRequestID &+= 1
        let requestID = presentationRequestID
        window?.alphaValue = 0
        guard let displayAssertion else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let assertion = try? await
                WallpaperPresentationModeAssertion.takeIdleAssertion(
                    displayAssertion: displayAssertion
                ),
                self.presentationRequestID == requestID,
                !self.showing
            else {
                return
            }
            self.presentationAssertion = assertion
            if self.paused {
                self.pauseLayer(displayAssertion.layer)
            }
        }
    }

    func shutdown() {
        presentationRequestID &+= 1
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
        guard let function = Self.startScreenSaverFunction else {
            Self.logger.error("SACScreenSaverStartNow is unavailable")
            return
        }
        let result = function()
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
