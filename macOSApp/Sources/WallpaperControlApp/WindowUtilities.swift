import AppKit

@MainActor
let auraFlowMainWindowIdentifier = NSUserInterfaceItemIdentifier("AuraFlowMainWindow")
@MainActor
private var auraFlowStoredWindowFrames: [ObjectIdentifier: NSRect] = [:]

@MainActor
private final class AuraFlowMainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private let auraFlowMainWindowDelegate = AuraFlowMainWindowDelegate()

@MainActor
func configureWindowForClientDecorations(_ window: NSWindow) {
    window.identifier = auraFlowMainWindowIdentifier
    window.isReleasedWhenClosed = false
    window.delegate = auraFlowMainWindowDelegate
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.titled)
    window.styleMask.insert(.closable)
    window.styleMask.insert(.miniaturizable)
    window.styleMask.insert(.resizable)
    window.styleMask.insert(.fullSizeContentView)
    window.isMovableByWindowBackground = false
    // The preview covers the complete content area. Declaring the window opaque lets
    // WindowServer skip blending the full video-sized surface with every window below it.
    window.isOpaque = true
    window.backgroundColor = .black
    applyStandardWindowButtonAppearance(for: window)
}

@MainActor
func applyStandardWindowButtonAppearance(for window: NSWindow) {
    let buttonColors: [(NSWindow.ButtonType, NSColor)] = [
        (.closeButton, NSColor(srgbRed: 1.0, green: 95.0 / 255.0, blue: 87.0 / 255.0, alpha: 1.0)),
        (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 189.0 / 255.0, blue: 46.0 / 255.0, alpha: 1.0)),
        (.zoomButton, NSColor(srgbRed: 40.0 / 255.0, green: 205.0 / 255.0, blue: 65.0 / 255.0, alpha: 1.0))
    ]
    for (buttonType, color) in buttonColors {
        guard let button = window.standardWindowButton(buttonType) else { continue }
        button.isHidden = false
        button.alphaValue = 1.0
        button.wantsLayer = true
        button.isBordered = false
        button.image = nil
        button.alternateImage = nil
        button.contentTintColor = .clear
        button.bezelColor = .clear
        button.layer?.shadowOpacity = 0
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = max(button.bounds.height * 0.5, 0)
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 0
        if #available(macOS 10.14, *) {
            button.appearance = NSAppearance(named: .aqua)
        }
        button.needsDisplay = true
    }
}

@MainActor
func mainScreenAspectRatio() -> CGFloat {
    let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    guard frame.height != 0 else { return 16.0 / 9.0 }
    return frame.width / frame.height
}

@MainActor
func preferredWindowSize() -> CGSize {
    let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let aspect = mainScreenAspectRatio()
    let width = max(frame.width * 0.5, 960)
    let height = width / aspect
    return CGSize(width: width, height: height)
}

@discardableResult
@MainActor
func bringMainWindowToFront() -> Bool {
    NSApp.activate(ignoringOtherApps: true)

    let mainWindows = NSApp.windows.filter { $0.identifier == auraFlowMainWindowIdentifier }
    let targetWindow = mainWindows.first(where: { $0.isVisible }) ?? mainWindows.first
    guard let window = targetWindow else {
        return false
    }

    removeDuplicateMainWindows(keeping: window)

    if window.isMiniaturized {
        window.deminiaturize(nil)
    }

    ensureWindowIsVisibleOnScreen(window)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    return true
}

@MainActor
func removeDuplicateMainWindows(keeping targetWindow: NSWindow) {
    for window in NSApp.windows where window.identifier == auraFlowMainWindowIdentifier && window !== targetWindow {
        window.delegate = nil
        window.close()
    }
}

@MainActor
func hasVisibleAuraFlowMainWindow() -> Bool {
    NSApp.windows.contains { window in
        window.identifier == auraFlowMainWindowIdentifier && window.isVisible
    }
}

@MainActor
func ensureWindowIsVisibleOnScreen(_ window: NSWindow) {
    let currentFrame = window.frame
    let screens = NSScreen.screens

    let intersectsVisibleScreen = screens.contains { screen in
        currentFrame.intersects(screen.visibleFrame.insetBy(dx: -40, dy: -40))
    }

    guard !intersectsVisibleScreen else { return }

    let targetScreen = window.screen ?? NSScreen.main ?? screens.first
    guard let targetScreen else { return }

    let visible = targetScreen.visibleFrame
    var targetSize = currentFrame.size
    targetSize.width = min(max(targetSize.width, 760), visible.width)
    targetSize.height = min(max(targetSize.height, 480), visible.height)

    let origin = CGPoint(
        x: visible.midX - (targetSize.width * 0.5),
        y: visible.midY - (targetSize.height * 0.5)
    )
    let targetFrame = NSRect(origin: origin, size: targetSize).integral
    window.setFrame(targetFrame, display: false)
}

@MainActor
func toggleFastWindowZoom(_ window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    let targetFrame: NSRect

    if let restoredFrame = auraFlowStoredWindowFrames.removeValue(forKey: windowID) {
        targetFrame = restoredFrame
    } else {
        let currentFrame = window.frame
        let targetVisibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? currentFrame
        let needsZoom = !currentFrame.equalTo(targetVisibleFrame)

        guard needsZoom else { return }

        auraFlowStoredWindowFrames[windowID] = currentFrame
        targetFrame = targetVisibleFrame
    }

    window.setFrame(targetFrame, display: false, animate: true)
}
