import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct CatalogCardInteractionTests {
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
