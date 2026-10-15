import AppKit
import AuraLockScreenRendering
import AuraTerminalWallpaperCore
import Foundation
import IOSurface
import Metal
import Testing
@testable import AuraTerminalRendering
@testable import AuraTerminalWallpaperAgent

private func speedSurface(width: Int, height: Int) throws -> IOSurfaceRef {
    let stride = ((width * 4 + 63) / 64) * 64
    return try #require(IOSurfaceCreate([
        kIOSurfaceWidth: width, kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: stride,
        kIOSurfaceAllocSize: stride * height,
        kIOSurfacePixelFormat: UInt32(0x42475241), kIOSurfaceIsGlobal: true,
    ] as CFDictionary))
}

private func speedDescriptor(_ surface: IOSurfaceRef) -> [String: Any] {
    ["surfaceID": IOSurfaceGetID(surface), "width": IOSurfaceGetWidth(surface),
     "height": IOSurfaceGetHeight(surface), "agentPID": Int(getpid()), "generation": UUID().uuidString]
}

@Test @MainActor func terminalLockScreenSurfaceUpdatesAcrossProcessBoundary() async throws {
    let surface = try speedSurface(width: 2, height: 2)
    func color(_ bytes: [UInt8]) {
        IOSurfaceLock(surface, [], nil)
        for row in 0..<2 {
            for column in 0..<2 {
                bytes.withUnsafeBytes {
                    IOSurfaceGetBaseAddress(surface).advanced(by: row * IOSurfaceGetBytesPerRow(surface) + column * 4)
                        .copyMemory(from: $0.baseAddress!, byteCount: 4)
                }
            }
        }
        IOSurfaceUnlock(surface, [], nil)
    }
    color([0,0,255,255])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSurfaceIPC-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = package.appendingPathComponent("Sources/AuraLockScreenRendering")
    let fixture = try #require(Bundle.module.url(forResource: "TerminalSurfaceProbe", withExtension: "m"))
    let executable = root.appendingPathComponent("probe")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["clang", "-fobjc-arc", "-fmodules", "-I" + source.appendingPathComponent("include").path,
        "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "IOSurface",
        fixture.path, source.appendingPathComponent("AuraFlowTerminalSurface.m").path, "-o", executable.path]
    try compile.run(); compile.waitUntilExit()
    #expect(compile.terminationStatus == 0)
    let process = Process(), output = Pipe(), input = Pipe()
    process.executableURL = executable
    process.arguments = [String(decoding: try JSONSerialization.data(withJSONObject: speedDescriptor(surface)), as: UTF8.self),
                         String(getpid())]
    process.standardOutput = output; process.standardInput = input
    defer { if process.isRunning { process.terminate() } }
    try process.run()
    let timeout = Task.detached {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel() }
    let read = Task.detached { output.fileHandleForReading.availableData }
    let first = await read.value
    #expect(String(decoding: first, as: UTF8.self) == "0,0,255,255\n")
    guard String(decoding: first, as: UTF8.self) == "0,0,255,255\n" else { return }
    color([255,0,0,255])
    try input.fileHandleForWriting.write(contentsOf: Data([10]))
    try input.fileHandleForWriting.close()
    let remaining = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
    let second = await remaining.value
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: second, as: UTF8.self) == "255,0,0,255\n")
}

@Test @MainActor func terminalLockScreenSurfaceDisplaysLatestFramesWithoutPNG() throws {
    let renderer = AuraFlowTerminalSurfaceRenderer()
    let device = try #require(renderer.device)
    let queue = try #require(device.makeCommandQueue())
    // Match the user's Retina frame size, rather than benchmarking tiny PNGs.
    let surface = try speedSurface(width: 3420, height: 2224)
    #expect(renderer.updateDescriptor(speedDescriptor(surface), expectedAgentPID: getpid()))
    let input = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: 3420, height: 2224, mipmapped: false)
    input.storageMode = .shared; input.usage = [.renderTarget, .shaderRead]
    let source = try #require(device.makeTexture(descriptor: input, iosurface: surface, plane: 0))
    let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: 3420, height: 2224, mipmapped: false)
    output.storageMode = .shared; output.usage = .renderTarget
    let target = try #require(device.makeTexture(descriptor: output))
    let started = Date()
    for frame in 0..<30 {
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = source
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(frame) / 255, green: 0.5, blue: 0, alpha: 1)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding()
        #expect(renderer.encode(to: target, commandBuffer: command, scaleMode: "fill"))
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(100, 100, 1, 1), mipmapLevel: 0)
        #expect(abs(Int(pixel[2]) - frame) <= 1)
        #expect(pixel[1] >= 127 && pixel[1] <= 128)
        #expect(pixel[3] == 255)
    }
    print("Lock Screen Metal 3420x2224: 30 current frames in \(Date().timeIntervalSince(started)) s; no PNG writes")
}

@Test @MainActor func terminalLockScreenSurfaceRejectsWrongOwnersMissingAndMalformedBuffers() throws {
    let renderer = AuraFlowTerminalSurfaceRenderer()
    let surface = try speedSurface(width: 2, height: 2)
    let valid = speedDescriptor(surface)
    #expect(renderer.updateDescriptor(valid, expectedAgentPID: getpid()))
    #expect(!renderer.updateDescriptor(valid, expectedAgentPID: getpid() + 1))
    #expect(!renderer.updateDescriptor([:], expectedAgentPID: getpid()))
    var wrong = valid
    wrong["width"] = 3
    #expect(!renderer.updateDescriptor(wrong, expectedAgentPID: getpid()))
    wrong = valid; wrong["surfaceID"] = UInt32.max
    #expect(!renderer.updateDescriptor(wrong, expectedAgentPID: getpid()))
    wrong = valid; wrong["generation"] = ""
    #expect(!renderer.updateDescriptor(wrong, expectedAgentPID: getpid()))
    let misaligned = try #require(IOSurfaceCreate([
        kIOSurfaceWidth: 2, kIOSurfaceHeight: 2, kIOSurfaceBytesPerElement: 4,
        kIOSurfaceBytesPerRow: 8, kIOSurfaceAllocSize: 16,
        kIOSurfacePixelFormat: UInt32(0x42475241), kIOSurfaceIsGlobal: true,
    ] as CFDictionary))
    #expect(!renderer.updateDescriptor(speedDescriptor(misaligned), expectedAgentPID: getpid()))
    #expect(renderer.updateDescriptor(valid, expectedAgentPID: getpid()))
}

@Test @MainActor func terminalLockScreenSurfacePreservesFitFillAndTextureOrientation() throws {
    let renderer = AuraFlowTerminalSurfaceRenderer()
    let device = try #require(renderer.device), queue = try #require(device.makeCommandQueue())
    let surface = try speedSurface(width: 2, height: 2)
    IOSurfaceLock(surface, [], nil)
    // Red at the top, blue at the bottom, BGRA; no vertical flip allowed.
    let bytes: [UInt8] = [0,0,255,255, 0,0,255,255, 255,0,0,255, 255,0,0,255]
    bytes.withUnsafeBytes {
        IOSurfaceGetBaseAddress(surface).copyMemory(from: $0.baseAddress!, byteCount: 8)
        IOSurfaceGetBaseAddress(surface).advanced(by: IOSurfaceGetBytesPerRow(surface))
            .copyMemory(from: $0.baseAddress!.advanced(by: 8), byteCount: 8)
    }
    IOSurfaceUnlock(surface, [], nil)
    #expect(renderer.updateDescriptor(speedDescriptor(surface), expectedAgentPID: getpid()))
    let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 4, mipmapped: false)
    output.storageMode = .shared; output.usage = .renderTarget
    let target = try #require(device.makeTexture(descriptor: output))
    for mode in ["fit", "fill", "stretch"] {
        let command = try #require(queue.makeCommandBuffer())
        #expect(renderer.encode(to: target, commandBuffer: command, scaleMode: mode))
        command.commit(); command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        target.getBytes(&pixels, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0)
        #expect(pixels[4 * 4 + 2] > pixels[4 * 4])
        #expect(pixels[(3 * 8 + 4) * 4] > pixels[(3 * 8 + 4) * 4 + 2])
        if mode == "fit" { #expect(pixels[0] == 0 && pixels[2] == 0) }
        else { #expect(pixels[0] > 0 || pixels[2] > 0) }
    }
}

@Test @MainActor func terminalLockedRenderingDoesNotDependOnVisibleDesktopDrawable() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let view = TerminalMetalView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                 logicalSize: CGSize(width: 320, height: 240), device: device)
    #expect(view.window == nil) // Simulate the occluded desktop; no drawable host.
    view.setLockScreenCaptureEnabled(true)
    var completed = 0
    view.onSharedFrame = { _, _ in completed += 1 }
    var parser = VTParser(columns: 20, rows: 4)
    let render = TerminalRenderConfiguration(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240,
                                               columns: 20, rows: 4, fontSize: 18)
    for frame in 0..<8 {
        let previous = completed
        parser.feed(Data("\u{1b}[Hcurrent frame \(frame)".utf8))
        view.update(snapshot: parser.grid.snapshot(), configuration: render)
        let deadline = Date().addingTimeInterval(2)
        while completed == previous && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(completed > previous)
    }
    view.setLockScreenCaptureEnabled(false)
    view.setRendererPaused(true)
}

@Test @MainActor func terminalFallbackFramePacingUsesCaptureStartNotEncodingCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockPacing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var now: TimeInterval = 1000
    let publisher = TerminalLockScreenFramePublisher(store: .init(appSupportURL: root), clock: { now })
    publisher.configure(maxFPS: 30); publisher.setLockScreenActive(true)
    publisher.publish(Data([0,0,255,255]), width: 1, height: 1)
    #expect(publisher.isWritingFrame)
    // Advance time while the encoder owns the operation, as on a large frame.
    now += 0.2
    let deadline = Date().addingTimeInterval(2)
    while publisher.isWritingFrame && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    #expect(!publisher.isWritingFrame)
    publisher.publish(Data([0,255,0,255]), width: 1, height: 1)
    #expect(publisher.isWritingFrame) // No extra post-encode frame interval.
    let finished = Date().addingTimeInterval(2)
    while publisher.isWritingFrame && Date() < finished { try await Task.sleep(nanoseconds: 5_000_000) }
    publisher.revoke()
}
