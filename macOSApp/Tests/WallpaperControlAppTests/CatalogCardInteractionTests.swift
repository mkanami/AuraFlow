import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct CatalogCardInteractionTests {
@MainActor
@Test func longCatalogKeepsBoundedViewportAndCanScrollBothWays() async throws {
    let wallpapers = (0..<200).map { index in
        CatalogWallpaper(id: "scroll-\(index)", title: "Wallpaper \(index)",
            category: "Anime", attribution: "Test", previewImageURL: nil,
            sourcePageURL: nil, sources: [])
    }
    let model = AppViewModel(controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: wallpapers))
    // Initial cache hydration intentionally displays only the first page.
    // Wait for it before supplying the long, already-loaded catalog fixture.
    for _ in 0..<100 where model.catalogWallpapers.isEmpty {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!model.catalogWallpapers.isEmpty)
    model.catalogWallpapers = wallpapers
    model.catalogHasMoreWallpapers = false
    let hosting = NSHostingView(rootView: WallpaperCatalogGridView(
        viewModel: model, catalogViewModel: model.catalogViewModel).frame(width: 500, height: 320))
    hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 320)
    let window = makeInteractionWindow(contentView: hosting, size: hosting.frame.size)
    defer { window.orderOut(nil); window.close() }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 100_000_000)

    func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScrollView).first
    }
    let scroll = try #require(findScrollView(hosting))
    #expect(scroll.contentView.bounds.height <= 321)
    #expect((scroll.documentView?.frame.height ?? 0) > 10_000)
    for _ in 0..<3 {
        let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(scroll.contentView.bounds.origin.y > 1_000)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(scroll.contentView.bounds.origin.y <= 2.5)
        #expect(scroll.contentView.bounds.height <= 321)
    }
}

@MainActor
@Test func respondsToFirstPhysicalClickAcrossFullWidth() async throws {
    let wallpaper = CatalogWallpaper(
        id: "first-click",
        title: "First Click Wallpaper",
        category: "Anime",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: nil,
        sources: []
    )
    var clickCount = 0
    let card = CatalogWallpaperCard(wallpaper: wallpaper) {
        clickCount += 1
    }
    .frame(width: 360, height: 150)

    let hostingView = NSHostingView(rootView: card)
    hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 150)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.close()
    }

    hostingView.layoutSubtreeIfNeeded()
    await Task.yield()

    for x in [30.0, 180.0, 330.0] {
        let expectedCount = clickCount + 1
        sendPhysicalClick(
            at: NSPoint(x: x, y: 75),
            in: window,
            eventNumber: clickCount * 2 + 1
        )

        for _ in 0..<20 where clickCount < expectedCount {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(clickCount == expectedCount)
    }
}

@MainActor
@Test func keepsFirstClickWhenCatalogAppendsBetweenMouseDownAndMouseUp() async throws {
    let first = CatalogWallpaper(
        id: "first",
        title: "First Wallpaper",
        category: "Anime",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: nil,
        sources: []
    )
    let appended = CatalogWallpaper(
        id: "appended",
        title: "Appended Wallpaper",
        category: "Anime",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: nil,
        sources: []
    )
    let viewModel = AppViewModel(
        controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: [first])
    )
    viewModel.catalogWallpapers = [first]
    viewModel.catalogHasMoreWallpapers = false

    let grid = WallpaperCatalogGridView(
        viewModel: viewModel,
        catalogViewModel: viewModel.catalogViewModel
    )
    .frame(width: 360, height: 190)
    let hostingView = NSHostingView(rootView: grid)
    hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 190)
    let window = makeInteractionWindow(contentView: hostingView, size: hostingView.frame.size)
    defer {
        window.orderOut(nil)
        window.close()
    }

    hostingView.layoutSubtreeIfNeeded()
    await Task.yield()

    let location = NSPoint(x: 180, y: 105)
    if let mouseDown = makeMouseEvent(
        type: .leftMouseDown,
        at: location,
        in: window,
        eventNumber: 1,
        pressure: 1
    ) {
        window.sendEvent(mouseDown)
    }

    viewModel.catalogWallpapers.append(appended)
    await Task.yield()

    if let mouseUp = makeMouseEvent(
        type: .leftMouseUp,
        at: location,
        in: window,
        eventNumber: 2,
        pressure: 0
    ) {
        window.sendEvent(mouseUp)
    }

    for _ in 0..<20 where viewModel.selectedCatalogWallpaper == nil {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(viewModel.selectedCatalogWallpaper?.id == first.id)
}
}

@MainActor
private func sendPhysicalClick(
    at location: NSPoint,
    in window: NSWindow,
    eventNumber: Int
) {
    guard let mouseDown = makeMouseEvent(
        type: .leftMouseDown,
        at: location,
        in: window,
        eventNumber: eventNumber,
        pressure: 1
    ), let mouseUp = makeMouseEvent(
        type: .leftMouseUp,
        at: location,
        in: window,
        eventNumber: eventNumber + 1,
        pressure: 0
    ) else {
        Issue.record("Unable to create physical mouse events")
        return
    }

    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
}

@MainActor
private func makeInteractionWindow<Content: View>(
    contentView: NSHostingView<Content>,
    size: NSSize
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private func makeMouseEvent(
    type: NSEvent.EventType,
    at location: NSPoint,
    in window: NSWindow,
    eventNumber: Int,
    pressure: Float
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: pressure
    )
}
