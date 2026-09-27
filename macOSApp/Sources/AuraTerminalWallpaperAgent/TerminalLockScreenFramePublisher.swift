import AuraTerminalWallpaperCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes the same rasterized frame used by the desktop Metal view for the
/// ScreenSaver process. At most one encode is in flight; intermediate animation
/// frames are dropped rather than queued behind PNG compression.
final class TerminalLockScreenFramePublisher {
    private let store: TerminalWallpaperRuntimeStore
    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-lock-frame", qos: .utility)
    private var writing = false // Main thread only.
    private var generation: UInt64 = 0 // Main thread only.
    private var lastPublishedAt: TimeInterval = 0 // Main thread only.

    init(store: TerminalWallpaperRuntimeStore) {
        self.store = store
    }

    func publish(_ bytes: Data, width: Int, height: Int) {
        let now = Date().timeIntervalSince1970
        guard !writing, width > 0, height > 0, now - lastPublishedAt >= 1.0 / 30.0 else { return }
        writing = true
        let currentGeneration = generation
        let store = store
        queue.async { [weak self] in
            let success = Self.encodePNG(bytes, width: width, height: height).map { png in
                do {
                    try store.ensureDirectories()
                    try png.write(to: store.lockScreenFrameURL, options: .atomic)
                    return true
                } catch {
                    return false
                }
            } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writing = false
                guard success, self.generation == currentGeneration else { return }
                self.lastPublishedAt = Date().timeIntervalSince1970
                try? store.saveLockScreenHeartbeat(TerminalLockScreenHeartbeat(pid: Int(getpid())))
            }
        }
    }

    func refreshHeartbeat() {
        guard FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path),
              store.loadLockScreenHeartbeat()?.pid == Int(getpid()) else { return }
        try? store.saveLockScreenHeartbeat(TerminalLockScreenHeartbeat(pid: Int(getpid())))
    }

    func revoke() {
        generation &+= 1
        lastPublishedAt = 0
        store.removeLockScreenPublication()
    }

    static func encodePNG(_ bytes: Data, width: Int, height: Int) -> Data? {
        guard bytes.count == width * height * 4,
              let provider = CGDataProvider(data: bytes as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
