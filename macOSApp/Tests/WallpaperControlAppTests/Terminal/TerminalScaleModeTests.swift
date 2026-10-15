import AppKit
import AuraLockScreenRendering
import AuraTerminalWallpaperCore
import Foundation
import IOSurface
import Metal
import Testing
@testable import AuraTerminalRendering
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

private struct ScaleLockScreenCoordinator: TerminalLockScreenCoordinating {
    func activate() throws {}
    func restore() throws {}
}

// Five asymmetric color bands make a centered crop distinguishable from
// letterboxing, stretching, a vertical flip, or cropping the source twice.
private func scaleColor(x: Int, y: Int) -> [UInt8] {
    if x < 20 { return [0, 0, 255, 255] }
    if x >= 80 { return [0, 255, 0, 255] }
    if y < 20 { return [255, 0, 0, 255] }
    if y >= 80 { return [0, 255, 255, 255] }
    return [255, 255, 0, 255]
}

@Test(arguments: [(80, 40), (40, 80)]) @MainActor
func terminalScaleSharedGPUShowsEdgesOrCenteredCrop(width: Int, height: Int) throws {
    let renderer = AuraFlowTerminalSurfaceRenderer()
    let device = try #require(renderer.device), queue = try #require(device.makeCommandQueue())
    let rowStride = 448
    let surface = try #require(IOSurfaceCreate([
        kIOSurfaceWidth: 100, kIOSurfaceHeight: 100,
        kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: rowStride,
        kIOSurfaceAllocSize: rowStride * 100, kIOSurfacePixelFormat: UInt32(0x42475241),
    ] as CFDictionary))
    IOSurfaceLock(surface, [], nil)
    for y in 0..<100 {
        for x in 0..<100 {
            scaleColor(x: x, y: y).withUnsafeBytes {
                IOSurfaceGetBaseAddress(surface).advanced(by: y * rowStride + x * 4)
                    .copyMemory(from: $0.baseAddress!, byteCount: 4)
            }
        }
    }
    IOSurfaceUnlock(surface, [], nil)
    #expect(renderer.updateDescriptor([
        "surfaceID": IOSurfaceGetID(surface), "width": 100, "height": 100,
        "agentPID": Int(getpid()), "generation": UUID().uuidString,
    ], expectedAgentPID: getpid()))
    renderer.clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    texture.storageMode = .shared; texture.usage = .renderTarget
    let target = try #require(device.makeTexture(descriptor: texture))
    // Also revisit Fit after rapid mode changes: the latest presentation wins.
    for mode in TerminalScaleMode.allCases + [.fill, .stretch, .fit] {
        let command = try #require(queue.makeCommandBuffer())
        #expect(renderer.encode(to: target, commandBuffer: command, scaleMode: mode.rawValue))
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        let factor = mode == .fill ? Double(max(width, height)) / 100 : Double(min(width, height)) / 100
        let drawnWidth = mode == .stretch ? Double(width) : 100 * factor
        let drawnHeight = mode == .stretch ? Double(height) : 100 * factor
        for y in stride(from: 3, to: height, by: 8) {
            for x in stride(from: 3, to: width, by: 8) {
                let sx = (Double(x) + 0.5 - (Double(width) - drawnWidth) / 2) * 100 / drawnWidth
                let sy = (Double(y) + 0.5 - (Double(height) - drawnHeight) / 2) * 100 / drawnHeight
                // Avoid linear filtering across color-band boundaries.
                if [20.0, 80.0].contains(where: { abs(sx - $0) < 2 || abs(sy - $0) < 2 }) { continue }
                let expected = sx < 0 || sx >= 100 || sy < 0 || sy >= 100
                    ? [UInt8](arrayLiteral: 255, 0, 255, 255)
                    : scaleColor(x: Int(sx), y: Int(sy))
                var pixel = [UInt8](repeating: 0, count: 4)
                target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                #expect(pixel == expected, "\(mode) at \(x),\(y)")
            }
        }
    }
}

@Test(arguments: [TerminalPixelMode.native, .fixed]) @MainActor
func terminalScaleSourceAndPNGStayCompleteAcrossModes(pixelMode: TerminalPixelMode) async throws {
    var parser = VTParser(columns: 20, rows: 10)
    parser.feed(Data("\u{1b}[44m\u{1b}[2J\u{1b}[1;1H\u{1b}[41m \u{1b}[1;20H\u{1b}[42m \u{1b}[10;1H\u{1b}[43m \u{1b}[10;20H\u{1b}[45m ".utf8))
    var render = TerminalRenderConfiguration(pixelMode: pixelMode, fixedWidth: 320, fixedHeight: 240,
        columns: 20, rows: 10, fontSize: 18, textScale: 1)
    var original: Data?
    var sourceSize: TerminalPixelSize?
    for mode in TerminalScaleMode.allCases {
        render.scaleMode = mode
        let frame = try await terminalGPUFrame(parser.grid.snapshot(), width: 600, height: 300, render: render)
        if let original { #expect(frame.0 == original) }
        else { original = frame.0; sourceSize = .init(width: frame.1, height: frame.2) }
        #expect(sourceSize == TerminalPixelSize(width: frame.1, height: frame.2))
        if pixelMode == .fixed { #expect(frame.1 == 320 && frame.2 == 240) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: frame.1,
            pixelsHigh: frame.2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [.alphaFirst, .thirtyTwoBitLittleEndian],
            bytesPerRow: frame.1 * 4, bitsPerPixel: 32))
        frame.0.withUnsafeBytes { UnsafeMutableRawPointer(bitmap.bitmapData!).copyMemory(from: $0.baseAddress!, byteCount: frame.0.count) }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide == frame.1 && decoded.pixelsHigh == frame.2)
        #expect(decoded.colorAt(x: frame.1 / 2, y: frame.2 / 2)?.blueComponent == 1)
    }
}

@Test(arguments: [false, true]) @MainActor
func terminalScaleApplyRetainsLivePIDAndCompletedStaticSource(animated: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraScaleApply-\(UUID())")
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/test.plist"))
    try store.ensureDirectories()
    try JSONSerialization.data(withJSONObject: ["show_on_lock_screen": true])
        .write(to: root.appendingPathComponent("config.json"))
    let output = animated
        ? "while :; do printf '\\033[44m\\033[2J\\033[Hvisual frame'; sleep 0.05; done"
        : "printf '\\033[44m\\033[2Jstatic frame'"
    var config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh",
        arguments: ["-c", "printf x >> launches; " + output], workingDirectory: root.path),
        render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 20, rows: 4, scaleMode: .fill),
        behavior: .init(allDisplays: false, pauseOnFullscreen: false))
    try store.saveConfig(config)
    let delegate = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false)
    defer {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try? FileManager.default.removeItem(at: root)
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    func pumpUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
    }
    await pumpUntil { store.loadSharedFrameDescriptor() != nil && store.loadHealth()?.childRunning == animated && store.loadLockScreenHeartbeat() != nil }
    let initial = try #require(store.loadSharedFrameDescriptor())
    let health = try #require(store.loadHealth())
    let png = try Data(contentsOf: store.lockScreenFrameURL)
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: selection, runtimeStore: store, windowIsVisible: { true })
    let controller = try NativeTerminalWallpaperController(store: store,
        helperURL: URL(fileURLWithPath: "/usr/bin/true"), videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false }, lockScreenCoordinator: ScaleLockScreenCoordinator(),
        lockScreenFrameReadinessWaiter: { _, _ in true })
    let settings = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection)
    defer { selection.selectVideo() }
    for mode in TerminalScaleMode.allCases + [.fill, .stretch, .fit] {
        config.render.scaleMode = mode
        // The settings control updates preview and active wallpaper without Apply.
        selection.selectTerminal(config)
        settings.setScaleMode(mode)
        preview.updateViewportSize(mode == .fill ? CGSize(width: 900, height: 300) : CGSize(width: 300, height: 900))
        await pumpUntil { preview.sharedFrame == initial && preview.configuration?.render.scaleMode == mode }
        #expect(preview.sharedFrame == initial)
        #expect(preview.snapshot == nil)
        #expect(preview.configuration?.render.scaleMode == mode)
        let requestedAt = Date().timeIntervalSince1970
        await pumpUntil { store.loadConfig().render.scaleMode == mode && (store.loadHealth()?.updatedAt ?? 0) > requestedAt }
        #expect((store.loadHealth()?.updatedAt ?? 0) > requestedAt)
        #expect(store.loadConfig().render.scaleMode == mode)
        #expect(store.loadSharedFrameDescriptor() == initial)
        #expect(store.loadHealth()?.childPID == health.childPID)
        #expect(store.loadHealth()?.columns == 20 && store.loadHealth()?.rows == 4)
        #expect(store.loadHealth()?.childRunning == animated)
        #expect(store.loadHealth()?.lastError == nil)
        if !animated { #expect(try Data(contentsOf: store.lockScreenFrameURL) == png) }
    }
    let restored = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(restored.terminalConfiguration?.render.scaleMode == .fit)
    #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
}
