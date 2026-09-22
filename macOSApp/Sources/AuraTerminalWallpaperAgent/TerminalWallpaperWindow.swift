import AppKit
import AuraTerminalWallpaperCore
import Metal
import MetalKit

final class TerminalWallpaperWindow: NSWindow {
    private let terminalView: TerminalMetalView

    init(screen: NSScreen, device: MTLDevice) {
        terminalView = TerminalMetalView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            logicalSize: screen.frame.size,
            device: device
        )
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
        contentView = terminalView
    }

    func update(snapshot: TerminalGridSnapshot, configuration: TerminalRenderConfiguration) {
        terminalView.update(snapshot: snapshot, configuration: configuration)
    }
}
