import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Metal
import MetalKit

final class TerminalWallpaperWindow: NSWindow {
    private let terminalView: TerminalMetalView
    private let effectsView: WallpaperEffectsView
    private var effectsPaused = false

    var onLockScreenFrame: ((Data, Int, Int) -> Void)? {
        get { terminalView.onLockScreenFrame }
        set { terminalView.onLockScreenFrame = newValue }
    }

    var onSharedFrame: ((TerminalSharedFrameDescriptor, UInt64) -> Void)?

    init(screen: NSScreen, device: MTLDevice, effectsStore: WallpaperEffectsStore = WallpaperEffectsStore()) {
        terminalView = TerminalMetalView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            logicalSize: screen.frame.size,
            device: device
        )
        effectsView = WallpaperEffectsView(content: terminalView, store: effectsStore)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        animationBehavior = .none
        hidesOnDeactivate = false
        canHide = false
        isExcludedFromWindowsMenu = true
        effectsView.playbackIsPaused = { [weak self] in self?.effectsPaused ?? true }
        contentView = effectsView
        terminalView.onSharedFrame = { [weak self] descriptor, sequence in
            self?.effectsView.rainLightingSurfaceID = descriptor.surfaceID
            self?.onSharedFrame?(descriptor, sequence)
        }
    }

    func update(snapshot: TerminalGridSnapshot, configuration: TerminalRenderConfiguration,
                presentationBackground: TerminalRGBA? = nil) {
        terminalView.update(snapshot: snapshot, configuration: configuration,
                            presentationBackground: presentationBackground)
    }

    func setRendererPaused(_ paused: Bool) {
        terminalView.setRendererPaused(paused)
    }

    func setDesktopPresentationPaused(_ paused: Bool) {
        effectsPaused = paused
        terminalView.setDesktopPresentationPaused(paused)
    }

    func setLockScreenCaptureEnabled(_ enabled: Bool) {
        terminalView.setLockScreenCaptureEnabled(enabled)
    }

    func requestLockScreenSeedCapture(refresh: Bool = false) {
        terminalView.requestLockScreenSeedCapture(refresh: refresh)
    }

    func restoreDesktopPresentation() {
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        orderBack(nil)
        orderFrontRegardless()
        terminalView.needsDisplay = true
        terminalView.draw()
    }
}
