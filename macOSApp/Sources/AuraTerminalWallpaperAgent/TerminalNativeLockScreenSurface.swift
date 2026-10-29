import AppKit
import QuartzCore
#if canImport(Wallpaper)
@preconcurrency import Wallpaper
#endif

struct TerminalLockScreenDisplay {
    let id: UInt32
    let frame: NSRect

    @MainActor static func current() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Self(id: id.uint32Value, frame: screen.frame)
        }
    }
}

@MainActor
struct TerminalNativeDisplayLease {
    let assertion: AnyObject
    let layer: CALayer
}

/// Only the opaque system assertion calls are replaceable in tests. Display
/// selection, layer ownership and presentation ordering remain production code.
@MainActor
protocol TerminalLockScreenNativeDriving {
    func makeDisplay(_ id: UInt32) async throws -> TerminalNativeDisplayLease
    func makePresentation(for display: TerminalNativeDisplayLease, locked: Bool) async throws -> AnyObject
}

/// WallpaperDisplayAssertion's remote layer needs a client render tree even
/// though the protected wallpaper is presented by macOS. This transparent
/// host follows the video bridge; it never paints over the user's Desktop.
@MainActor
final class TerminalNativeWallpaperSurfaceHost {
    let window: NSWindow
    private let wallpaperLayer: CALayer

    init(layer: CALayer, frame: NSRect, orderWindow: @MainActor (NSWindow) -> Void) {
        wallpaperLayer = layer
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        layer.frame = content.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(layer)
        window.contentView = content
        window.alphaValue = 0
        orderWindow(window)
    }

    func close() {
        wallpaperLayer.removeFromSuperlayer()
        window.orderOut(nil)
        window.contentView = nil
    }

    deinit {
        // All owners are the main-actor presentation queue and its prepare
        // tasks, including failed/cancelled replacements.
        MainActor.assumeIsolated { close() }
    }
}

@MainActor
func terminalLockScreenNativeDriver() -> (any TerminalLockScreenNativeDriving)? {
    #if canImport(Wallpaper)
    if #available(macOS 26, *) { return SystemTerminalLockScreenNativeDriver() }
    #endif
    return nil
}

#if canImport(Wallpaper)
@available(macOS 26, *)
@MainActor
private final class SystemTerminalLockScreenNativeDriver: TerminalLockScreenNativeDriving {
    // Keep the exported allocator: the private framework's initializing entry
    // point is hidden and cannot be used by whole-module devirtualization.
    @_optimize(none)
    func makeDisplay(_ id: UInt32) async throws -> TerminalNativeDisplayLease {
        let assertion = try await WallpaperDisplayAssertion(displayID: id, attributes: .screenSaver)
        return TerminalNativeDisplayLease(assertion: assertion, layer: assertion.layer)
    }

    func makePresentation(for display: TerminalNativeDisplayLease, locked: Bool) async throws -> AnyObject {
        let assertion = display.assertion as! WallpaperDisplayAssertion
        return try await Self.presentation(for: DisplayBox(assertion), locked: locked).value
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
}
#endif
