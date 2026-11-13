import AppKit
import QuartzCore

/// Display-paced rendering on modern macOS, with an App Nap-safe fallback for macOS 13.
@MainActor
final class WallpaperEffectsFrameClock {
    let framesPerSecond: Double
    let screen: NSScreen?
    private var timer: Timer?
    private var saverTimer: DispatchSourceTimer?
    private var invalidateDisplayLink: (() -> Void)?
    private var activity: NSObjectProtocol?

    init(view: NSView, framesPerSecond: Double, isScreenSaver: Bool = false, onFrame: @escaping (CFTimeInterval) -> Void) {
        self.framesPerSecond = framesPerSecond
        screen = view.window?.screen ?? NSScreen.main
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Render interactive wallpaper effects while visible")
        if isScreenSaver {
            // Both the protected host's native timer and screen-bound display
            // links can be throttled to 2–5 Hz while its window is visible.
            // A strict dispatch timer is independent of that host cadence.
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now(), repeating: 1 / framesPerSecond, leeway: .milliseconds(1))
            timer.setEventHandler { MainActor.assumeIsolated { onFrame(CACurrentMediaTime()) } }
            saverTimer = timer
            timer.resume()
        } else if #available(macOS 14, *), let screen {
            let target = WallpaperEffectsDisplayTarget(onFrame: onFrame)
            // A view-bound display link can retain the view. Track its current
            // screen instead; WallpaperEffectsView replaces the clock on screen changes.
            let link = screen.displayLink(target: target, selector: #selector(WallpaperEffectsDisplayTarget.tick(_:)))
            let fps = Float(framesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            invalidateDisplayLink = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { _ in
                MainActor.assumeIsolated { onFrame(CACurrentMediaTime()) }
            }
            timer.tolerance = 0.001
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        saverTimer?.setEventHandler(handler: nil)
        saverTimer?.cancel()
        saverTimer = nil
        timer?.invalidate()
        timer = nil
        invalidateDisplayLink?()
        invalidateDisplayLink = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    deinit {
        saverTimer?.cancel()
        timer?.invalidate()
        invalidateDisplayLink?()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

@available(macOS 14, *)
@MainActor
private final class WallpaperEffectsDisplayTarget: NSObject {
    private let onFrame: (CFTimeInterval) -> Void
    init(onFrame: @escaping (CFTimeInterval) -> Void) { self.onFrame = onFrame }
    @objc func tick(_ link: CADisplayLink) { onFrame(link.targetTimestamp) }
}
