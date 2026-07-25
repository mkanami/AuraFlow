import Testing
import AppKit
@testable import WallpaperControlApp

@MainActor
@Test func configureWindowForClientSideDecoration() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )

    configureWindowForClientDecorations(window)

    #expect(window.titleVisibility == .hidden)
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.isOpaque == true)
    #expect(window.backgroundColor == .black)
    #expect(window.animationBehavior == .none)
    #expect((window.standardWindowButton(.closeButton)?.isHidden ?? true) == false)
    #expect((window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true) == false)
    #expect((window.standardWindowButton(.zoomButton)?.isHidden ?? true) == false)
}
