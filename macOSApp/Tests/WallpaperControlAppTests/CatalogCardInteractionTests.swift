import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct CatalogCardInteractionTests {
@MainActor
@Test func cachedNextPageArrivesBeforeScrollingToTheLastRow() async throws {
    let wallpapers = (0..<36).map { index in
        CatalogWallpaper(id: "early-\(index)", title: "Wallpaper \(index)", category: "Anime",
            attribution: "Test", previewImageURL: nil, sourcePageURL: nil, sources: [])
    }
    let model = AppViewModel(controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: wallpapers))
    for _ in 0..<100 where model.catalogWallpapers.isEmpty {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    model.catalogIsRefreshing = true
    defer { model.catalogIsRefreshing = false }
    let hosting = NSHostingView(rootView: WallpaperCatalogGridView(viewModel: model,
        catalogViewModel: model.catalogViewModel).frame(width: 500, height: 220))
    hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 220)
    let window = makeInteractionWindow(contentView: hosting, size: hosting.frame.size)
    defer { window.orderOut(nil); window.close() }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 50_000_000)
    func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(hosting))
    // Enter the middle of page one, well before its sixth/final row.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 330))
    scroll.reflectScrolledClipView(scroll.contentView)
    for _ in 0..<100 where model.catalogWallpapers.count < 24 {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.catalogWallpapers.count >= 24)
    #expect(scroll.contentView.bounds.origin.y < 600)
}

@MainActor
@Test func downloadedLibraryScrollsBothWaysWithoutChangingItsViewport() async throws {
    let model = AppViewModel(controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: []))
    // Let the initial cache load finish before installing the test library.
    for _ in 0..<10 { await Task.yield() }
    try await Task.sleep(nanoseconds: 100_000_000)
    model.catalogViewModel.downloadedWallpapers = (0..<120).map { index in
        DownloadedCatalogWallpaper(id: "download-\(index)", wallpaperID: "download-\(index)",
            title: "Downloaded wallpaper \(index)", category: "Anime", attribution: "Test",
            previewImageURL: nil, localPreviewPath: nil, sourcePageURL: nil,
            localPath: "/tmp/panel-test-\(index).png", downloadedAt: Date(timeIntervalSince1970: 0))
    }
    let hosting = NSHostingView(rootView: DownloadedWallpapersCard(viewModel: model).frame(width: 860))
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = makeInteractionWindow(contentView: hosting, size: hosting.frame.size)
    defer { window.orderOut(nil); window.close() }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 100_000_000)
    func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(hosting))
    let height = scroll.contentView.bounds.height
    #expect(height > 100 && height <= 361)
    for _ in 0..<3 {
        scroll.contentView.scroll(to: NSPoint(x: 0,
            y: max(0, (scroll.documentView?.frame.height ?? 0) - height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(scroll.contentView.bounds.origin.y > 1_000)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(scroll.contentView.bounds.origin.y < 1)
        #expect(abs(scroll.contentView.bounds.height - height) < 1)
    }
}

@MainActor
@Test func downloadedRowPreviewRemainsClickableAfterUnrelatedStatusUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("wallpaper.png")
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 8, bitsPerPixel: 32))
    bitmap.bitmapData?.initialize(repeating: 255, count: 16)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    let model = AppViewModel(controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: []), appSupportDirectoryURL: root)
    let wallpaper = DownloadedCatalogWallpaper(id: "preview-click", wallpaperID: "preview-click",
        title: "Downloaded test", category: "Anime", attribution: "Test", previewImageURL: nil,
        localPreviewPath: nil, sourcePageURL: nil, localPath: file.path, downloadedAt: Date())
    let hosting = NSHostingView(rootView: DownloadedWallpaperRow(wallpaper: wallpaper, viewModel: model)
        .equatable().frame(width: 860, height: 110))
    hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 110)
    let window = makeInteractionWindow(contentView: hosting, size: hosting.frame.size)
    defer { window.orderOut(nil); window.close() }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 50_000_000)
    for index in 0..<20 { model.statusMessage = "Runtime status \(index)" }
    sendPhysicalClick(at: NSPoint(x: 780, y: 70), in: window, eventNumber: 1)
    for _ in 0..<100 where model.currentVideoURL != file {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.currentVideoURL == file)
}

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
