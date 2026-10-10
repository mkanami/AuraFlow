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
