import AppKit
import AVFoundation
import OSLog
import QuartzCore

/// Objective-C boundary used by the signed ScreenSaver bundle. The view and
/// all GPU simulation code are shared with the Desktop, not approximated here.
@objc(AuraFlowSaverEffects)
@MainActor public final class ScreenSaverEffectsBridge: NSObject {
    @objc public let view: NSView
    private let effects: WallpaperEffectsView
    private let preview: Bool
    private var paused = false
    private var lastImageSequence: NSNumber?
    private let healthURL: URL?
    private var healthDirectory: URL?
    private var nextLog = -Double.infinity
    private var loggedCursorX: Double?
    private static let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "ScreenSaverEffects")
    private var presenting = false
    private var nextHealth = -Double.infinity
    private var lastPublishedActive: Bool?
    private var samplingActive = false
    private var cursorMinX: Double?
    private var cursorMaxX: Double?
    private var parallaxMinX: Double?
    private var parallaxMaxX: Double?
    private struct Health: Encodable {
        let processID: Int32
        let updatedAt: Date
        let preview: Bool
        let status: WallpaperEffectsStatus
        let cursorMinX: Double?
        let cursorMaxX: Double?
        let parallaxMinX: Double?
        let parallaxMaxX: Double?
    }

    @objc(initWithContent:appSupportURL:isPreview:)
    public init(content: NSView, appSupportURL: URL, isPreview: Bool = false) {
        effects = WallpaperEffectsView(content: content,
            store: WallpaperEffectsStore(appSupportURL: appSupportURL), isScreenSaver: true)
        preview = isPreview
        view = effects
        healthURL = appSupportURL.appendingPathComponent("ScreenSaverEffects")
            .appendingPathComponent("saver-\(ProcessInfo.processInfo.processIdentifier)-\(UUID()).json")
        super.init()
        effects.useScreenSaverFrameClock()
        if isPreview { effects.screenSaverPresentationIsVisible = { true } }
        effects.playbackIsPaused = { [weak self] in self?.paused ?? true }
    }

    @objc(setPresenting:paused:surfaceID:sequence:imageURL:gravity:)
    public func setPresenting(_ presenting: Bool, paused: Bool, surfaceID: NSNumber?, sequence: NSNumber?, imageURL: URL?, gravity: String) {
        sampleCursor()
        let changed = self.presenting != presenting || self.paused != paused
        self.presenting = presenting
        self.paused = paused
        effects.rainLightingSurfaceID = surfaceID?.uint32Value
        effects.rainFrameSequence = sequence?.uint64Value
        if imageURL != nil && sequence != lastImageSequence {
            // Terminal/web PNG fallback files are atomically replaced in place.
            effects.rainLightingImageURL = nil
        }
        lastImageSequence = sequence
        effects.rainLightingImageURL = imageURL
        effects.rainFrameGravity = AVLayerVideoGravity(rawValue: gravity)
        effects.setScreenSaverPresenting(presenting, paused: paused)
        publishHealth(force: changed)
    }

    private func sampleCursor() {
        let status = effects.status
        guard status.active else { samplingActive = false; return }
        if !samplingActive {
            cursorMinX = nil; cursorMaxX = nil; parallaxMinX = nil; parallaxMaxX = nil
            samplingActive = true
        }
        guard status.renderedFrames > 0 else { return }
        cursorMinX = min(cursorMinX ?? status.cursorX, status.cursorX)
        cursorMaxX = max(cursorMaxX ?? status.cursorX, status.cursorX)
        parallaxMinX = min(parallaxMinX ?? status.parallaxX, status.parallaxX)
        parallaxMaxX = max(parallaxMaxX ?? status.parallaxX, status.parallaxX)
    }

    @objc public var presentationVisible: Bool {
        effects.screenSaverVisible
    }

    @objc public var frameInterval: Double {
        effects.animationFramesPerSecond > 0 ? 1 / effects.animationFramesPerSecond : 1.0 / 30
    }

    @objc public func advanceFrame() {
        effects.advanceScreenSaverFrame(at: CACurrentMediaTime())
    }

    /// At most one small record per second, per real saver instance. This
    /// measures the protected renderer, independently of the app preview.
    private func publishHealth(force: Bool) {
        guard let healthURL else { return }
        let status = effects.status
        let activityChanged = lastPublishedActive != status.active
        guard force || status.active || activityChanged else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now >= nextHealth else { return }
        nextHealth = now + 1
        lastPublishedActive = status.active
        if force || activityChanged || (status.active && (now >= nextLog || abs(status.cursorX - (loggedCursorX ?? 10)) > 0.05)) {
            Self.logger.notice("Saver FX preview=\(self.preview, privacy: .public) active=\(status.active, privacy: .public) frames=\(status.renderedFrames, privacy: .public) cursorX=\(status.cursorX, privacy: .public) parallaxX=\(status.parallaxX, privacy: .public) glassFrames=\(status.glassRenderedFrames ?? 0, privacy: .public)")
            loggedCursorX = status.cursorX; nextLog = now + 10
        }
        let health = Health(processID: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(), preview: preview, status: status,
            cursorMinX: cursorMinX, cursorMaxX: cursorMaxX, parallaxMinX: parallaxMinX, parallaxMaxX: parallaxMaxX)
        guard let data = try? JSONEncoder().encode(health) else { return }
        // Apple's saver host can read the account's media but write only in
        // its own container. Keep the diagnostic there if the shared root is
        // read-only; the renderer requires no extra sandbox permissions.
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraFlowEffectsHealth")
        let candidates = healthDirectory.map { [$0] }
            ?? [healthURL.deletingLastPathComponent(), fallback].compactMap { $0 }
        for directory in candidates {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent(healthURL.lastPathComponent)
                try data.write(to: output, options: .atomic)
                if healthDirectory == nil { Self.logger.notice("Saver FX health file: \(output.path, privacy: .public)") }
                healthDirectory = directory
                if force {
                    let files = (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
                        .filter { $0.lastPathComponent.hasPrefix("saver-") && $0.pathExtension == "json" }
                        .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                            > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                    for file in files.dropFirst(16) where file != output { try? FileManager.default.removeItem(at: file) }
                }
                return
            } catch { /* Diagnostics must not interrupt the protected renderer. */ }
        }
    }

    @objc public var diagnostics: [String: Any] {
        guard let data = try? JSONEncoder().encode(effects.status),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}
