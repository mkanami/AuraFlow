import AppKit
import CoreGraphics
import Darwin
import OSLog
import QuartzCore
import Wallpaper

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
    private var pendingCompletions: [(Bool) -> Void] = []

    var isReady: Bool {
        displayAssertion != nil && window != nil
    }

    func prepare(completion: @escaping (Bool) -> Void) {
        if isReady {
            completion(true)
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
                self.finishPreparation(succeeded: true)
                Self.logger.notice("Native Lock Screen layer prepared")
            } catch {
                Self.logger.error(
                    "Native Lock Screen preparation failed: \(error.localizedDescription, privacy: .public)"
                )
                self.finishPreparation(succeeded: false)
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

    func showForLockTransition() {
        guard !paused, !showing else { return }
        showing = true
        startSystemScreenSaverNow()
        guard let displayAssertion else { return }
        // Keep the prewarmed layer hidden. Making it visible here creates a
        // three-frame transition: Aura, loginwindow's Desktop snapshot, then
        // the real Aura Lock Screen. loginwindow owns the secure surface and
        // presents the prepared screen-saver route itself.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.presentationAssertion = try await
                    WallpaperPresentationModeAssertion.takeLockedAssertion(
                        displayAssertion: displayAssertion
                    )
            } catch {
                Self.logger.error(
                    "Native locked presentation failed: \(error.localizedDescription, privacy: .public)"
                )
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
        guard !paused else { return }
        paused = true
        if let layer = displayAssertion?.layer, layer.speed != 0 {
            let pausedTime = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            )
            layer.speed = 0
            layer.timeOffset = pausedTime
        }
        Self.logger.notice("Native Lock Screen layer paused")
    }

    func hideAfterUnlock() {
        showing = false
        window?.alphaValue = 0
        guard let displayAssertion else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentationAssertion = try? await
                WallpaperPresentationModeAssertion.takeIdleAssertion(
                    displayAssertion: displayAssertion
                )
        }
    }

    func shutdown() {
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
            "/System/Library/PrivateFrameworks/login.framework/login",
            RTLD_NOW | RTLD_LOCAL
        ),
        let symbol = dlsym(handle, "SACScreenSaverStartNow")
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

    private func finishPreparation(succeeded: Bool) {
        preparing = false
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        for completion in completions {
            completion(succeeded)
        }
    }
}
