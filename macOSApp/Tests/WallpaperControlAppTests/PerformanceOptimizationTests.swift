import AppKit
import AVFoundation
import AuraTerminalWallpaperCore
import CoreText
import Darwin
import Foundation
import Testing
@testable import AuraTerminalRendering
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Test func performanceSignatureCacheExpiresAndExplicitChecksAlwaysRead() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("source".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var time = 0.0, reads = 0
    let cache = AerialFileSignatureCache(clock: { time })
    func read(_ cached: Bool) -> String {
        cache.signature(at: file, allowCached: cached) { reads += 1; return "signature-\(reads)" }
    }
    #expect(read(false) == "signature-1")
    for _ in 0..<100 { #expect(read(true) == "signature-1") }
    #expect(reads == 1)
    time = 60
    #expect(read(true) == "signature-2")
    #expect(read(false) == "signature-3")
    time = 59 // A clock regression cannot prolong the lease.
    #expect(read(true) == "signature-4")
}

@Test func performanceSignatureCacheDetectsSameSizeEditsReplacementAndMissingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source")
    try Data("before".utf8).write(to: file)
    let date = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    let cache = AerialFileSignatureCache()
    var reads = 0
    func read() throws -> String {
        try cache.signature(at: file, allowCached: true) {
            reads += 1
            return try String(contentsOf: file, encoding: .utf8)
        }
    }
    #expect(try read() == "before")
    #expect(try read() == "before" && reads == 1)
    try Data("edited".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    #expect(try read() == "edited" && reads == 2)
    try Data("swap!!".utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    #expect(try read() == "swap!!" && reads == 3)
    try FileManager.default.removeItem(at: file)
    #expect(throws: (any Error).self) { try read() }
}

@Test func performanceSignatureCacheKeepsExistingHashFormatAndTaskScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source")
    try Data(repeating: 0x41, count: 256 * 1024).write(to: file)
    let preparer = AerialMediaPreparer(fileManager: .default, usesCanonicalWallpaperStore: false,
        preparedCacheDirectoryURL: root)
    let full = try preparer.fileSignature(at: file)
    let reused = try await AerialFileSignatureValidation.$allowsCachedRead.withValue(true) {
        #expect(AerialFileSignatureValidation.allowsCachedRead)
        return try await Task { try preparer.fileSignature(at: file) }.value
    }
    #expect(full == reused && full.count == 16)
    #expect(!AerialFileSignatureValidation.allowsCachedRead)
}

@Test func performanceCachedFontMetricsRemainExactForChangedSettings() {
    for family in ["System Monospace", "Menlo"] {
        for size in [12.0, 18.0, 27.5] {
            for spacing in [0.0, 2.5] {
                let font = TerminalFontResolver.font(family: family, size: size)
                let expected = TerminalFontMetrics.cellMetrics(font: font, cellSpacing: spacing)
                for _ in 0..<100 {
                    let actual = TerminalFontMetrics.cellMetrics(family: family, pointSize: size, cellSpacing: spacing)
                    #expect(actual == expected)
                    #expect(TerminalFontResolver.font(family: family, size: size) === font)
                }
            }
        }
    }
}

private final class PerformancePreviewPlayer: AVPlayer {
    var starts = 0
    var pauses = 0
    override func playImmediately(atRate rate: Float) { starts += 1 }
    override func pause() { pauses += 1 }
}

@Test @MainActor func performanceHiddenOrDifferentPreviewDoesNotRestartVideoOrChangeInstalledWallpaper() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let controller = PerformancePreviewController()
    let app = AppViewModel(controller: controller, appSupportDirectoryURL: root, previewSelectionStore: selection)
    defer { try? FileManager.default.removeItem(at: root) }
    let player = PerformancePreviewPlayer()
    app.previewPlayer = player
    for _ in 0..<50 {
        app.setPreviewWindowVisible(false)
        let starts = player.starts
        app.suspendPreviewRenderingForWindowDrag()
        app.resumePreviewRenderingAfterWindowDrag()
        #expect(player.starts == starts)
        app.setPreviewWindowVisible(true)
        #expect(player.starts > starts)
        selection.selectTerminal(.init(command: .init(executable: "/bin/echo")))
        try await Task.sleep(for: .milliseconds(1))
        let terminalStarts = player.starts
        app.setPreviewWindowVisible(false)
        app.setPreviewWindowVisible(true)
        #expect(player.starts == terminalStarts)
        selection.selectVideo()
        try await Task.sleep(for: .milliseconds(1))
        #expect(player.starts > terminalStarts)
        #expect(app.previewPlayer === player)
    }
    #expect(controller.mutations == 0)
}

@Test @MainActor func performanceTerminalPreviewSurvivesFiftyHideAndSourceCyclesWithoutOrphanChildren() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    var visible = true
    let preview = TerminalWallpaperPreviewModel(selectionStore: selection,
        runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { visible })
    let pidFile = root.appendingPathComponent("pids")
    var allPIDs: [Int32] = []
    defer { selection.selectVideo() }
    for iteration in 0..<50 {
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' \"$$\" >> \"$1\"; printf 'frame-%s' \"$2\"; while :; do sleep 0.05; done", "audit", pidFile.path, String(iteration)]),
            render: .init(columns: 24, rows: 4))
        selection.selectTerminal(config)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let text = preview.snapshot?.cells.map(\.text).joined() ?? ""
            if text.contains("frame-\(iteration)") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(preview.snapshot?.cells.map(\.text).joined().contains("frame-\(iteration)") == true)
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == iteration + 1)
        let pid = try #require(pids.last)
        allPIDs.append(pid)
        visible = false
        preview.previewVisibilityDidChange()
        let frozen = preview.snapshot
        try await Task.sleep(for: .milliseconds(10))
        #expect(preview.snapshot == frozen)
        visible = true
        preview.previewVisibilityDidChange()
        #expect(kill(pid, 0) == 0) // Hide/show preserves this exact child.
        selection.selectVideo()
        let stopDeadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) != 0)
    }
    #expect(allPIDs.allSatisfy { kill($0, 0) != 0 })
}

@Test @MainActor func performanceRealVideoFreezesWhenHiddenAndResumesTheSameItem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("preview.mp4")
    let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    CVPixelBufferGetBaseAddress(pixels)?.initializeMemory(as: UInt8.self, repeating: 0xFF,
        count: CVPixelBufferGetBytesPerRow(pixels) * 32)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<90 {
        let deadline = Date().addingTimeInterval(3)
        while !input.isReadyForMoreMediaData && Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let controller = PerformancePreviewController()
    let app = AppViewModel(controller: controller, appSupportDirectoryURL: root, previewSelectionStore: selection)
    let player = AVPlayer(url: file)
    app.previewPlayer = player
    defer { player.pause() }
    app.setPreviewWindowVisible(false)
    app.setPreviewWindowVisible(true)
    let deadline = Date().addingTimeInterval(3)
    while player.currentTime().seconds < 0.1 && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(player.currentTime().seconds >= 0.1)
    let item = try #require(player.currentItem)
    app.setPreviewWindowVisible(false)
    let stopped = player.currentTime().seconds
    try await Task.sleep(for: .milliseconds(150))
    #expect(abs(player.currentTime().seconds - stopped) < 0.01)
    #expect(player.rate == 0)
    app.setPreviewWindowVisible(true)
    try await Task.sleep(for: .milliseconds(150))
    #expect(player.currentTime().seconds > stopped + 0.05)
    #expect(player.currentItem === item && app.previewPlayer === player)
    #expect(controller.mutations == 0)
}

@Test(arguments: [false, true]) @MainActor
func performanceHiddenInstallStillValidatesAndKeepsItsSource(live: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    var visible = false
    let preview = TerminalWallpaperPreviewModel(selectionStore: selection,
        runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { visible })
    defer { selection.selectVideo() }
    let starts = root.appendingPathComponent("starts")
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh",
        arguments: ["-c", "printf '%s\\n' \"$$\" >> \"$1\"; printf READY; " + (live ? "while :; do sleep 0.05; done" : "exit 0"), "audit", starts.path]))
    let operation = UUID()
    selection.beginTemporaryTerminal(config, operationID: operation)
    if live {
        try await preview.waitUntilReady(configuration: config, operationID: operation, timeout: 3)
    } else {
        let deadline = Date().addingTimeInterval(3)
        while preview.snapshot?.hasVisibleContent != true && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(preview.snapshot?.hasVisibleContent == true)
    try selection.commitTemporaryTerminal(operationID: operation)
    preview.previewVisibilityDidChange()
    let frame = preview.snapshot
    try await Task.sleep(for: .milliseconds(100))
    #expect(preview.snapshot == frame)
    visible = true
    preview.previewVisibilityDidChange()
    let pids = try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
    #expect(pids.count == 1)
    let pid = try #require(pids.first)
    #expect((kill(pid, 0) == 0) == live)
    #expect(preview.snapshot?.hasVisibleContent == true)
}

private final class PerformancePreviewController: WallpaperControlling, @unchecked Sendable {
    var mutations = 0
    func status() throws -> ControlStatus { .init(running: true, config: .defaultConfig) }
    func start(videoURL: URL?, speed: Double?) async throws -> ControlStatus { mutations += 1; return try status() }
    func resume() throws -> ControlStatus { mutations += 1; return try status() }
    func stop() throws -> ControlStatus { mutations += 1; return try status() }
    func clearWallpaper() async throws -> ControlStatus { mutations += 1; return try status() }
    func setVideo(_ url: URL) throws -> ControlStatus { mutations += 1; return try status() }
    func setSpeed(_ speed: Double) async throws -> ControlStatus { mutations += 1; return try status() }
    func setScaleMode(_ mode: WallpaperScaleMode) async throws -> ControlStatus { mutations += 1; return try status() }
    func setInterpolation(_ enabled: Bool) throws -> ControlStatus { try status() }
    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus { try status() }
    func setShowOnLockScreen(_ enabled: Bool) async throws -> ControlStatus { try status() }
    func syncLockScreenSaver() async throws {}
    func beginLockScreenPreview() throws -> ControlStatus { try status() }
    func endLockScreenPreview() throws -> ControlStatus { try status() }
    func setAutostart(_ enabled: Bool) throws -> ControlStatus { try status() }
    func metrics() throws -> DaemonMetrics { .init(running: true) }
}
