import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor func terminalScaleHtopKeepsItsSourceGridAfterViewportResize() async throws {
    guard let executable = TerminalExecutableLocator.resolve("htop") else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-htop-resize-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: selection,
        runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
    defer { selection.selectVideo() }
    let config = TerminalWallpaperConfig(command: .init(executable: executable),
        render: .init(columns: 153, rows: 48, fontSize: 18, textScale: 1))
    preview.updateViewportSize(CGSize(width: 760, height: 480))
    selection.selectTerminal(config)
    let metrics = TerminalFontMetrics.cellMetrics(for: config.render)
    for size in [CGSize(width: 760, height: 480), CGSize(width: 1710, height: 1040), CGSize(width: 480, height: 760)] {
        preview.updateViewportSize(size)
        let expected = TerminalRenderGeometry.viewportGrid(configuration: config.render,
            logicalWidth: 153 * metrics.width, logicalHeight: 48 * metrics.height, cellWidth: metrics.width, lineHeight: metrics.height)
        var complete = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let snapshot = preview.snapshot, snapshot.columns == expected.columns, snapshot.rows == expected.rows {
                let footer = (0..<snapshot.columns).map { snapshot.cell(column: $0, row: snapshot.rows - 1).text }.joined()
                complete = footer.contains("F10") && footer.contains("Quit")
                if complete { break }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(complete, "htop footer must be inside the current terminal viewport")
    }
    #expect(selection.terminalConfiguration == config.normalized())
    selection.selectVideo()
    try await Task.sleep(nanoseconds: 100_000_000)
}

@Test(arguments: [true, false]) @MainActor
func terminalScalePreviewKeepsGridAndChildAfterViewportResize(live: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-responsive-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let starts = root.appendingPathComponent("starts.txt")
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: selection, runtimeStore: runtime, windowIsVisible: { true })
    defer { selection.selectVideo() }
    preview.updateViewportSize(CGSize(width: 760, height: 480))
    let script = "printf START >> \"$1\"; printf READY; " + (live
        ? "trap '/bin/stty size' WINCH; while :; do /bin/sleep 0.05; done"
        : "exit 0")
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c", script, "fixture", starts.path]),
        render: .init(columns: 153, rows: 48, fontSize: 18, textScale: 1))
    selection.selectTerminal(config)
    let initialDeadline = Date().addingTimeInterval(3)
    while preview.snapshot?.hasVisibleContent != true, Date() < initialDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let initial = try #require(preview.snapshot)
    #expect(initial.hasVisibleContent)
    if !live { try await Task.sleep(nanoseconds: 150_000_000) }
    preview.updateViewportSize(CGSize(width: 480, height: 760))
    try await Task.sleep(nanoseconds: 150_000_000)
    let resized = try #require(preview.snapshot)
    #expect(resized.columns == initial.columns && resized.rows == initial.rows)
    if !live { #expect(resized == initial) }
    #expect(try String(contentsOf: starts, encoding: .utf8) == "START")
    #expect(selection.terminalConfiguration == config.normalized())
    #expect(!runtime.status().running)
    #expect(!FileManager.default.fileExists(atPath: runtime.configURL.path))
    selection.selectVideo()
    try await Task.sleep(nanoseconds: 100_000_000)
}
