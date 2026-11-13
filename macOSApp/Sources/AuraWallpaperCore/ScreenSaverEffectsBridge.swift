import AppKit
import AVFoundation

/// Objective-C boundary used by the signed ScreenSaver bundle. The view and
/// all GPU simulation code are shared with the Desktop, not approximated here.
@objc(AuraFlowSaverEffects)
@MainActor public final class ScreenSaverEffectsBridge: NSObject {
    @objc public let view: NSView
    private let effects: WallpaperEffectsView
    private var paused = false
    private var lastImageSequence: NSNumber?

    @objc(initWithContent:appSupportURL:isPreview:)
    public init(content: NSView, appSupportURL: URL, isPreview: Bool = false) {
        effects = WallpaperEffectsView(content: content,
            store: WallpaperEffectsStore(appSupportURL: appSupportURL), isScreenSaver: true)
        view = effects
        super.init()
        if isPreview { effects.screenSaverPresentationIsVisible = { true } }
        effects.playbackIsPaused = { [weak self] in self?.paused ?? true }
    }

    @objc(setPresenting:paused:surfaceID:sequence:imageURL:gravity:)
    public func setPresenting(_ presenting: Bool, paused: Bool, surfaceID: NSNumber?, sequence: NSNumber?, imageURL: URL?, gravity: String) {
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
    }

    @objc public var diagnostics: [String: Any] {
        guard let data = try? JSONEncoder().encode(effects.status),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}
