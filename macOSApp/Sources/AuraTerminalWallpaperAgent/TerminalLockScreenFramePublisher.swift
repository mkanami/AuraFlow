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
    private var lockScreenActive = false // Main thread only.
    private var didPublishDesktopSeed = false // Main thread only.
    private var desktopSeedCount = 0
    private var lastDesktopSeedAt: TimeInterval = 0
    private let clock: () -> TimeInterval
    private var maxFPS = 30 // Main thread only.

    init(store: TerminalWallpaperRuntimeStore, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.clock = clock
    }

    var needsDesktopSeed: Bool {
        guard !lockScreenActive, !writing else { return false }
        guard didPublishDesktopSeed else { return true }
        // A CLI often paints its first screen in multiple PTY chunks. Briefly
        // settle that seed with at most four captures, then stop desktop
        // readbacks entirely. Slow PNG/GPU completion must not exhaust a
        // wall-clock settling window before a complete frame arrives. Full-rate
        // publication remains restricted to the actual Lock Screen session.
        let now = clock()
        return desktopSeedCount < 4 && now - lastDesktopSeedAt >= 0.5
    }

    var isWritingFrame: Bool { writing }

    func publish(_ bytes: Data, width: Int, height: Int) {
        let now = clock()
        guard lockScreenActive,
              !writing,
              width > 0,
              height > 0,
              now - lastPublishedAt >= 1.0 / Double(max(maxFPS, 1)) else { return }
        writing = true
        // Pace capture starts, not completion + another frame interval. PNG
        // encoding is only a fallback and must not add an artificial cooldown.
        lastPublishedAt = now
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
                try? store.saveLockScreenHeartbeat(TerminalLockScreenHeartbeat(pid: Int(getpid())))
            }
        }
    }

    /// Seed and bounded startup settling, not continuous desktop PNG encoding.
    func publishDesktopSeed(_ bytes: Data, width: Int, height: Int) {
        guard needsDesktopSeed,
              width > 0,
              height > 0 else { return }
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
                guard success, self.generation == currentGeneration,
                      !self.lockScreenActive else { return }
                self.didPublishDesktopSeed = true
                self.desktopSeedCount += 1
                self.lastDesktopSeedAt = self.clock()
                self.lastPublishedAt = self.clock()
                try? store.saveLockScreenHeartbeat(TerminalLockScreenHeartbeat(pid: Int(getpid())))
            }
        }
    }

    /// Allows a restart to replace the previous desktop seed with a frame from
    /// the new PTY session without removing the currently available Lock Screen image.
    func beginDesktopGeneration() {
        generation &+= 1
        lastPublishedAt = 0
        didPublishDesktopSeed = false
        desktopSeedCount = 0
        lastDesktopSeedAt = 0
    }

    func configure(maxFPS: Int) {
        self.maxFPS = min(max(maxFPS, 1), 60)
    }

    func setLockScreenActive(_ active: Bool) {
        guard lockScreenActive != active else { return }
        lockScreenActive = active
        generation &+= 1
        lastPublishedAt = 0
    }

    func refreshHeartbeat() {
        guard store.lockScreenPlaybackEnabled else { return }
        let pid = Int(getpid())
        let hasRaster = FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path)
            && store.loadLockScreenHeartbeat()?.pid == pid
        // A shared descriptor is published only after its GPU frame completes.
        // Keep that live source usable while its optional PNG is being encoded.
        guard hasRaster || store.loadSharedFrameDescriptor()?.agentPID == pid else { return }
        try? store.saveLockScreenHeartbeat(TerminalLockScreenHeartbeat(pid: Int(getpid())))
    }

    func revoke() {
        lockScreenActive = false
        generation &+= 1
        lastPublishedAt = 0
        didPublishDesktopSeed = false
        desktopSeedCount = 0
        lastDesktopSeedAt = 0
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
