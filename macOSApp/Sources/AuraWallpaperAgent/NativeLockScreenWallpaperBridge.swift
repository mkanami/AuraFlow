import AppKit
import CoreGraphics
import OSLog
import QuartzCore
import Wallpaper

final class NativeLockScreenWallpaperBridge {
    private static let logger = Logger(
        subsystem: "com.auraflow.wallpaper",
        category: "native-lock-screen"
    )

    private var displayAssertion: WallpaperDisplayAssertion?
    private var presentationAssertion: WallpaperPresentationModeAssertion?
    private var window: NSWindow?
    private var preparing = false
    private var showing = false
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
        guard !showing, let displayAssertion, let window else { return }
        showing = true
        window.alphaValue = 1
        window.orderFrontRegardless()
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
    }

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
