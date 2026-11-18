import AppKit
import QuartzCore

/// Display-paced rendering on modern macOS, with an App Nap-safe fallback for macOS 13.
@MainActor
final class WallpaperEffectsFrameClock {
    let framesPerSecond: Double
    let screen: NSScreen?
    private var timer: WallpaperEffectsCleanup?
    private var saverTimer: DispatchSourceTimer?
    private var invalidateDisplayLink: WallpaperEffectsCleanup?
    private var activity: WallpaperEffectsCleanup?

    init(view: NSView, framesPerSecond: Double, isScreenSaver: Bool = false, onFrame: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.framesPerSecond = framesPerSecond
        screen = view.window?.screen ?? NSScreen.main
        let activityToken = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Render interactive wallpaper effects while visible")
        activity = WallpaperEffectsCleanup { ProcessInfo.processInfo.endActivity(activityToken) }
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
            invalidateDisplayLink = WallpaperEffectsCleanup { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { _ in
                MainActor.assumeIsolated { onFrame(CACurrentMediaTime()) }
            }
            timer.tolerance = 0.001
            self.timer = WallpaperEffectsCleanup { timer.invalidate() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        saverTimer?.setEventHandler(handler: nil)
        saverTimer?.cancel()
        saverTimer = nil
        timer?.run()
        timer = nil
        invalidateDisplayLink?.run()
        invalidateDisplayLink = nil
        activity?.run()
        activity = nil
    }

    deinit {
        saverTimer?.cancel()
        timer?.run()
        invalidateDisplayLink?.run()
        activity?.run()
    }
}

/// An immutable actor-bound cleanup keeps SDK resources off a nonisolated
/// deinit. Teardown on another executor schedules their release on main.
struct WallpaperEffectsCleanup: Sendable {
    let action: @MainActor @Sendable () -> Void

    func run() {
        if Thread.isMainThread { MainActor.assumeIsolated { action() } }
        else { DispatchQueue.main.async { action() } }
    }
}

@available(macOS 14, *)
@MainActor
private final class WallpaperEffectsDisplayTarget: NSObject {
    private let onFrame: @MainActor (CFTimeInterval) -> Void
    init(onFrame: @escaping @MainActor (CFTimeInterval) -> Void) { self.onFrame = onFrame }
    @objc func tick(_ link: CADisplayLink) { onFrame(link.targetTimestamp) }
}
