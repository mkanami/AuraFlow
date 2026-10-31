import AuraWallpaperCore
import CoreGraphics
import Foundation
import Testing

private func foregroundWindow(_ rect: CGRect, pid: Int = 42, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
    [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
     kCGWindowAlpha as String: NSNumber(value: alpha), kCGWindowBounds as String: [
        "X": NSNumber(value: rect.minX), "Y": NSNumber(value: rect.minY),
        "Width": NSNumber(value: rect.width), "Height": NSNumber(value: rect.height)]]
}

struct FullscreenApplicationDetectorTests {
    private let display = FullscreenApplicationDetector.Display(bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleBounds: CGRect(x: 0, y: 32, width: 1600, height: 910))

    @Test(arguments: [false, true])
    func detectsFullscreenAndMaximizedDesktopWindows(maximized: Bool) {
        let rect = maximized ? display.visibleBounds : display.bounds
        #expect(FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
            windowInfo: [foregroundWindow(rect)], displays: [display]))
    }

    @Test func maximizedWindowMayLeaveASmallResizeBorder() {
        let rect = CGRect(x: 0, y: 32, width: 1591, height: 910)
        #expect(FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
            windowInfo: [foregroundWindow(rect)], displays: [display]))
    }

    @Test func aLargeWindowThatLeavesDesktopVisibleDoesNotPause() {
        for rect in [CGRect(x: 60, y: 32, width: 1540, height: 910), CGRect(x: 0, y: 32, width: 1600, height: 800)] {
            #expect(!FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
                windowInfo: [foregroundWindow(rect)], displays: [display]))
        }
    }

    @Test func onlyAVisibleNormalWindowOfTheForegroundApplicationCanPause() {
        for info in [foregroundWindow(display.bounds, pid: 99), foregroundWindow(display.bounds, layer: 103),
                     foregroundWindow(display.bounds, alpha: 0), foregroundWindow(.zero)] {
            #expect(!FullscreenApplicationDetector.isFullscreen(frontmostPID: 42, windowInfo: [info], displays: [display]))
        }
    }

    @Test func workAreaConversionHandlesDisplaysAboveAndBesideTheMainDisplay() throws {
        let geometry = try #require(FullscreenApplicationDetector.displayGeometry(
            bounds: CGRect(x: 1600, y: -900, width: 1400, height: 900),
            appKitFrame: CGRect(x: 1600, y: 1000, width: 1400, height: 900),
            visibleFrame: CGRect(x: 1648, y: 1000, width: 1352, height: 872)))
        #expect(geometry.visibleBounds == CGRect(x: 1648, y: -872, width: 1352, height: 872))
        #expect(FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
            windowInfo: [foregroundWindow(geometry.visibleBounds)], displays: [display, geometry]))
    }

    @Test func invalidOrUnavailableWindowGeometryDoesNotPause() {
        #expect(FullscreenApplicationDetector.displayGeometry(bounds: .zero, appKitFrame: .zero, visibleFrame: .zero) == nil)
        #expect(!FullscreenApplicationDetector.isFullscreen(frontmostPID: 42, windowInfo: [], displays: [display]))
        #expect(!FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
            windowInfo: [foregroundWindow(display.bounds)], displays: []))
    }

    @Test func convertsWorkAreaInsetsWhenDisplayCoordinateScalesDiffer() throws {
        let geometry = try #require(FullscreenApplicationDetector.displayGeometry(
            bounds: CGRect(x: -1800, y: 0, width: 1800, height: 1200),
            appKitFrame: CGRect(x: -900, y: 0, width: 900, height: 600),
            visibleFrame: CGRect(x: -900, y: 30, width: 900, height: 550)))
        #expect(geometry.visibleBounds == CGRect(x: -1800, y: 40, width: 1800, height: 1100))
        #expect(FullscreenApplicationDetector.isFullscreen(frontmostPID: 42,
            windowInfo: [foregroundWindow(geometry.visibleBounds)], displays: [geometry]))
    }
}
