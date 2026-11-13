import CoreGraphics
import Foundation

/// Read-only presentation policy. Saver activity only suspends effects; it never establishes a secure lock.
public struct WallpaperEffectsActivity: Equatable {
    /// The installed saver's start/stop lifecycle, including idle before lock.
    /// Rendering that surface never establishes a secure lock.
    public var screenSaverPresentation = false
    public var windowVisible = true
    public var sessionActive = true
    public var sleeping = false
    public var screenSaverActive = false
    public var sessionLocked: Bool? = false
    public var playbackPaused = false
    public var reduceMotion = false
    public var lowPower = false

    public init() {}

    public var canAnimate: Bool {
        pauseReason == nil
    }

    public var framesPerSecond: Double { lowPower ? 30 : 60 }

    public var pauseReason: String? {
        if !windowVisible { return "hidden" }
        if !sessionActive && !screenSaverPresentation { return "inactiveSession" }
        if sleeping { return "sleeping" }
        if !screenSaverPresentation {
            if screenSaverActive { return "screenSaver" }
            if sessionLocked == nil { return "unknownSession" }
            if sessionLocked == true { return "locked" }
        }
        if playbackPaused { return "playbackPaused" }
        if reduceMotion { return "reduceMotion" }
        return nil
    }
}

/// Notifications can lead the compositor or be lost. Hints expire; system samples remain authoritative.
struct WallpaperEffectsSuspensionHints {
    private var systemUntil = -Double.infinity
    private var saverUntil = -Double.infinity

    mutating func systemWillSuspend(at time: Double) { systemUntil = time + 1.5 }
    mutating func systemDidResume() { systemUntil = -Double.infinity }
    mutating func saverDidStart(at time: Double) { saverUntil = time + 1.5 }
    mutating func saverDidStop() { saverUntil = -Double.infinity }
    func systemSuspended(at time: Double) -> Bool { time < systemUntil }
    func saverSuspended(at time: Double) -> Bool { time < saverUntil }
}

struct WallpaperEffectsMotion {
    private(set) var pointer = CGPoint.zero
    private(set) var presence = 0.0
    private(set) var time = 0.0
    private(set) var elapsedTime = 0.0

    /// Coordinates use AppKit's bottom-left origin and the actual window, including secondary displays.
    static func normalizedCursor(_ cursor: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0, frame.contains(cursor) else { return nil }
        return CGPoint(x: (cursor.x - frame.minX) / frame.width * 2 - 1,
                       y: (cursor.y - frame.minY) / frame.height * 2 - 1)
    }

    mutating func advance(settings: WallpaperEffectsSettings, cursor: CGPoint?, deltaTime: Double) {
        let dt = deltaTime.isFinite ? min(0.1, max(0, deltaTime)) : 0
        elapsedTime += dt
        time += dt * (0.15 + settings.ambientSpeed * 0.85)
        let target = settings.reactsToCursor ? (cursor ?? .zero)
            : CGPoint(x: sin(time * 0.7) * 0.65, y: cos(time * 0.53) * 0.55)
        let response = 1 - exp(-dt / (0.015 + settings.smoothing * 0.1))
        pointer.x += (min(1, max(-1, target.x)) - pointer.x) * response
        pointer.y += (min(1, max(-1, target.y)) - pointer.y) * response
        let targetPresence = !settings.reactsToCursor || cursor != nil ? 1.0 : 0
        presence += (targetPresence - presence) * response
    }

    func contentFrame(in size: CGSize, settings: WallpaperEffectsSettings) -> CGRect {
        guard settings.hasVisibleEffects else {
            return CGRect(origin: .zero, size: size)
        }
        let travel = settings.parallaxEnabled ? settings.parallaxAmount * 0.035 : 0
        // Gaussian blur samples outside the frame. Keep those transparent edges outside the viewport too.
        let blurMargin = settings.blurEnabled ? settings.blurAmount * 54 / max(1, min(size.width, size.height)) : 0
        let cover = travel + blurMargin
        return CGRect(x: -size.width * (cover + travel * pointer.x),
                      y: -size.height * (cover + travel * pointer.y),
                      width: size.width * (1 + 2 * cover), height: size.height * (1 + 2 * cover))
    }
}
