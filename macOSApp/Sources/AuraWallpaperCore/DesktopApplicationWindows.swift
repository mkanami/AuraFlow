import AppKit
import CoreGraphics
import Foundation

/// A single WindowServer snapshot serves both video coverage and music gating.
/// Desktop icons, Dock, menus and tooltips are not document windows.
public enum DesktopApplicationWindows {
    public struct State: Equatable, Sendable {
        public let count: Int
        public let fullscreen: Bool
        public let known: Bool
        public var blocksMusic: Bool { !known || count > 0 }
        public static let unknown = State(count: 0, fullscreen: false, known: false)
        public init(count: Int, fullscreen: Bool, known: Bool = true) {
            self.count = count; self.fullscreen = fullscreen; self.known = known
        }
    }

    @MainActor public static func currentState() -> State {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return .unknown }
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }.map(\.processIdentifier))
        let displays = NSScreen.screens.compactMap { screen -> FullscreenApplicationDetector.Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return FullscreenApplicationDetector.displayGeometry(bounds: CGDisplayBounds(number.uint32Value),
                appKitFrame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        guard !displays.isEmpty else { return .unknown }
        return State(count: visibleCount(applicationPIDs: pids, windowInfo: windows, displays: displays.map(\.bounds)),
            fullscreen: FullscreenApplicationDetector.isFullscreen(applicationPIDs: pids, windowInfo: windows, displays: displays))
    }

    public static func visibleCount(applicationPIDs: Set<pid_t>, windowInfo: [[String: Any]], displays: [CGRect]) -> Int {
        windowInfo.filter { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, applicationPIDs.contains(pid),
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= 0 && layer <= Int(CGWindowLevelForKey(.modalPanelWindow)),
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber else { return false }
            let rect = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return false }
            return displays.contains { display in
                let visible = display.intersection(rect)
                // Show Desktop can park narrow strips at screen edges. They
                // have no visible application content and must not mute music.
                return !visible.isNull && visible.width >= 24 && visible.height >= 24
            }
        }.count
    }
}
