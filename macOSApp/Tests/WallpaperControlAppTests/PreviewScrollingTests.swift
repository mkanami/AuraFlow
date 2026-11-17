import AppKit
import Combine
import Testing
@testable import WallpaperControlApp

@Test @MainActor func previewRenderingGateCoalescesScrollAndDragWithoutPublishingEachWheelEvent() {
    let gate = PreviewRenderingActivity()
    var changes: [Bool] = []
    let subscription = gate.changes.sink { changes.append($0) }
    defer { subscription.cancel() }
    for _ in 0..<1_000 { gate.set(.scrolling, active: true) }
    gate.set(.windowDrag, active: true)
    gate.set(.scrolling, active: false)
    #expect(gate.isSuspended && changes == [true])
    gate.set(.windowDrag, active: false)
    for _ in 0..<1_000 { gate.set(.scrolling, active: false) }
    #expect(!gate.isSuspended && changes == [true, false])
}

@Test @MainActor func previewScrollingObservesOnlyItsWindowAndCoalescesBurstsOrCancellation() async throws {
    let center = NotificationCenter()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    window.contentView = scroll // Hidden test window: never ordered or activated.
    var changes: [Bool] = []
    let monitor = PreviewScrollMonitor(window: window, notifications: center,
        monitorEvents: false, onChange: { changes.append($0) })
    defer { monitor.cancel(); window.contentView = nil }
    center.post(name: NSScrollView.didLiveScrollNotification, object: NSScrollView())
    #expect(changes.isEmpty)
    center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    for _ in 0..<100 {
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    #expect(changes == [true], "Scroll callbacks must not repeatedly resume and suspend the background")
    let deadline = Date().addingTimeInterval(2)
    while changes.last != false, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(changes == [true, false], "A missing end notification must not leave the background frozen")
    center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(changes == [true, false, true, false])
    center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    monitor.cancel()
    center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    #expect(changes == [true, false, true, false, true, false])
}
