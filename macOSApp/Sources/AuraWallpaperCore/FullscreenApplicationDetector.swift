import AppKit
import CoreGraphics
import Foundation

/// Shared foreground-window geometry for every wallpaper renderer.
public enum FullscreenApplicationDetector {
    public struct Display {
        public let bounds: CGRect
        public let visibleBounds: CGRect

        public init(bounds: CGRect, visibleBounds: CGRect) {
            self.bounds = bounds
            self.visibleBounds = visibleBounds
        }
    }

    @MainActor public static func currentIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let displays = NSScreen.screens.compactMap { screen -> Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return displayGeometry(bounds: CGDisplayBounds(number.uint32Value),
                appKitFrame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        return isFullscreen(frontmostPID: app.processIdentifier, windowInfo: windows, displays: displays)
    }

    /// AppKit uses an upward Y axis; WindowServer's window bounds use a
    /// downward Y axis. Convert in each display's own coordinate system.
    public static func displayGeometry(bounds: CGRect, appKitFrame: CGRect, visibleFrame: CGRect) -> Display? {
        guard isValid(bounds), isValid(appKitFrame), isValid(visibleFrame), appKitFrame.contains(visibleFrame) else { return nil }
        let scaleX = bounds.width / appKitFrame.width
        let scaleY = bounds.height / appKitFrame.height
        let visible = CGRect(x: bounds.minX + (visibleFrame.minX - appKitFrame.minX) * scaleX,
            y: bounds.minY + (appKitFrame.maxY - visibleFrame.maxY) * scaleY,
            width: visibleFrame.width * scaleX, height: visibleFrame.height * scaleY)
        return Display(bounds: bounds, visibleBounds: visible)
    }

    public static func isFullscreen(frontmostPID: pid_t, windowInfo: [[String: Any]], displays: [Display]) -> Bool {
        guard frontmostPID > 0 else { return false }
        for info in windowInfo {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let values = info[kCGWindowBounds as String] as? [String: Any],
                  let x = values["X"] as? NSNumber, let y = values["Y"] as? NSNumber,
                  let width = values["Width"] as? NSNumber, let height = values["Height"] as? NSNumber else { continue }
            let window = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            guard isValid(window) else { continue }
            if displays.contains(where: { display in
                covers(window, area: display.bounds, tolerance: 3) ||
                    covers(window, area: display.visibleBounds, tolerance: 12)
            }) { return true }
        }
        return false
    }

    private static func covers(_ window: CGRect, area: CGRect, tolerance: CGFloat) -> Bool {
        // A maximized app leaves the menu bar and Dock exposed, and can keep
        // a small resize border. It still covers the desktop working area.
        isValid(area) && window.minX <= area.minX + tolerance && window.minY <= area.minY + tolerance &&
            window.maxX >= area.maxX - tolerance && window.maxY >= area.maxY - tolerance
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width.isFinite && rect.height.isFinite &&
            rect.minX.isFinite && rect.minY.isFinite && rect.width > 0 && rect.height > 0
    }
}
