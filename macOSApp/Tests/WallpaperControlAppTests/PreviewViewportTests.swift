import AppKit
import AVFoundation
import AuraWallpaperEngineCore
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct PreviewViewportTests {
    @Test(arguments: [false, true])
    func videoUsesWindowBoundsAndKeepsPlayerAcrossResizes(isReady: Bool) async throws {
        let fixture = makePreview(isReady: isReady)
        let hosting = NSHostingView(rootView: fixture.preview)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        var originalView: AuraPreviewPlayerView?
        for size in [NSSize(width: 960, height: 540), NSSize(width: 640, height: 800),
                     NSSize(width: 1200, height: 400), NSSize(width: 400, height: 300),
                     NSSize(width: 960, height: 540)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
            hosting.layoutSubtreeIfNeeded()
            let view = try #require(findPlayerView(in: hosting))
            let layer = try #require(view.layer as? AVPlayerLayer)
            #expect(abs(view.bounds.width - size.width) < 1)
            #expect(abs(view.bounds.height - size.height) < 1)
            #expect(layer.videoGravity == .resize)
            #expect(layer.player === fixture.player)
            if let originalView { #expect(view === originalView) }
            else { originalView = view }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func imageAndPosterFillTallAndWideWindowsWithoutCropping(isPortrait: Bool, isPoster: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("edges.png")
        let width = isPortrait ? 90 : 160
        let height = isPortrait ? 160 : 90
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(NSColor(deviceRed: x < width * 3 / 4 ? 1 : 0,
                                        green: x >= width / 4 ? 1 : 0,
                                        blue: x >= width / 4 && x < width * 3 / 4 ? 1 : 0, alpha: 1), atX: x, y: y)
            }
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let fixture = makePreview(wallpaperURL: isPoster ? nil : imageURL,
                                  isReady: !isPoster, posterURL: isPoster ? imageURL : nil)
        let hosting = NSHostingView(rootView: fixture.preview)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        for size in [NSSize(width: 320, height: 480), NSSize(width: 640, height: 180),
                     NSSize(width: 400, height: 225), NSSize(width: 240, height: 400)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            hosting.layoutSubtreeIfNeeded()
            let rendered = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rendered)
            let left = try #require(rendered.colorAt(x: rendered.pixelsWide / 10,
                                                    y: rendered.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            let right = try #require(rendered.colorAt(x: rendered.pixelsWide * 9 / 10,
                                                     y: rendered.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(left.redComponent > 0.8 && left.greenComponent < 0.2)
            #expect(right.greenComponent > 0.8 && right.redComponent < 0.2)
            let corner = try #require(rendered.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
            #expect(corner.redComponent > 0.8 && corner.greenComponent < 0.2)
        }
    }

    private func makePreview(wallpaperURL: URL? = nil, isReady: Bool = true,
                             posterURL: URL? = nil) -> (preview: PreviewLayer, player: AVPlayer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        let terminal = TerminalWallpaperPreviewModel(selectionStore: selection, windowIsVisible: { false })
        let web = WallpaperEngineViewModel(selection: selection,
                                          library: WallpaperEngineLibrary(rootURL: root.appendingPathComponent("library")))
        let player = AVPlayer()
        return (PreviewLayer(previewSelectionStore: selection, terminalPreviewModel: terminal,
            wallpaperEngine: web, player: player, wallpaperURL: wallpaperURL,
            isVideoReadyForDisplay: isReady, posterURL: posterURL, posterRefererURL: nil,
            posterTitle: "Preview", onVideoReadyForDisplayChange: { _, _ in }), player)
    }

    private func findPlayerView(in view: NSView) -> AuraPreviewPlayerView? {
        if let player = view as? AuraPreviewPlayerView { return player }
        for child in view.subviews {
            if let player = findPlayerView(in: child) { return player }
        }
        return nil
    }
}
