import AppKit
import AuraWallpaperCore
import CoreGraphics
import QuartzCore
import OSLog

/// Preview music uses an audio-only player, including companion soundtracks.
/// Its clock pauses when the preview is hidden or AuraFlow loses focus.
@MainActor
final class WallpaperPreviewAudioPlayback {
    let playback = WallpaperAudioPlayback()
    private let systemAllowsPlayback: @MainActor () -> Bool
    private let desktopOwnsAudio: @MainActor () -> Bool
    private let applicationIsActive: @MainActor () -> Bool
    private let automaticallyMonitor: Bool
    private var timer: ScheduledTimerLifetime?
    private var observers: [NotificationObserverLifetime] = []
    private var source: URL?
    private var volume = 0.0
    private var visible = false
    private var suspendedUntil = -Double.infinity
    private var lastPlaybackState: String?
    private let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "preview-audio")
    var isMonitoringSystem: Bool { timer != nil }

    init(systemAllowsPlayback: @escaping @MainActor () -> Bool = { WallpaperPreviewAudioPlayback.currentSystemAllowsPlayback() },
         desktopOwnsAudio: @escaping @MainActor () -> Bool = { false },
         applicationIsActive: @escaping @MainActor () -> Bool = { NSApp?.isActive == true },
         applicationNotifications: NotificationCenter = .default, automaticallyMonitor: Bool = true) {
        self.systemAllowsPlayback = systemAllowsPlayback
        self.desktopOwnsAudio = desktopOwnsAudio
        self.applicationIsActive = applicationIsActive
        self.automaticallyMonitor = automaticallyMonitor
        guard automaticallyMonitor else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationObserverLifetime(applicationNotifications.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }, center: applicationNotifications))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let suspending = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                          NSWorkspace.sessionDidResignActiveNotification]
        for name in suspending + [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                                  NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name, center: workspace, suspending: suspending.contains(name))
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                     "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            observe(Notification.Name(name), center: distributed,
                    suspending: name == "com.apple.screenIsLocked" || name == "com.apple.screensaver.didstart")
        }
    }

    func setSource(_ url: URL?) {
        source = url
        playback.setSource(url)
        refresh()
    }

    func update(volume: Double, visible: Bool) {
        self.volume = WallpaperAudioPolicy.normalized(volume)
        self.visible = visible
        refresh()
    }

    func refresh() {
        guard source != nil, visible, applicationIsActive(), volume > 0, playback.errorDescription == nil else {
            playback.update(volume: 0)
            timer?.invalidate(); timer = nil
            logPlaybackState()
            return
        }
        let allowed = CACurrentMediaTime() >= suspendedUntil && systemAllowsPlayback()
        playback.update(volume: WallpaperAudioPolicy.previewVolume(volume,
            desktopOwnsAudio: desktopOwnsAudio(), visible: visible, systemLocked: !allowed))
        logPlaybackState()
        // Poll only while a visible preview requests music. This also handles
        // delayed/missing lock notifications and waits for Desktop audio to pause.
        if automaticallyMonitor, timer == nil {
            let scheduled = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            scheduled.tolerance = 0.05
            timer = ScheduledTimerLifetime(scheduled)
            RunLoop.main.add(scheduled, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        source = nil
        playback.stop()
        logPlaybackState()
    }

    private func logPlaybackState() {
        let state = source == nil ? "stopped" : (playback.errorDescription != nil ? "unavailable"
            : (playback.rate > 0 ? "playing" : (playback.isPrepared ? "paused" : "waiting")))
        guard state != lastPlaybackState else { return }
        lastPlaybackState = state
        logger.info("Preview music state=\(state, privacy: .public) rate=\(self.playback.rate, privacy: .public) time=\(self.playback.time ?? 0, privacy: .public) volume=\(self.volume, privacy: .public) visible=\(self.visible, privacy: .public) active=\(self.applicationIsActive(), privacy: .public)")
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, suspending: Bool) {
        observers.append(NotificationObserverLifetime(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspendedUntil = suspending ? CACurrentMediaTime() + 1.5 : -Double.infinity
                self.refresh()
            }
        }, center: center))
    }

    static func currentSystemAllowsPlayback() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let awake = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsAsleep(number.uint32Value) == 0
        }
        return sessionAllowsPlayback(locked: LockScreenSession.isLocked(in: session),
            active: (session?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true,
            saver: WallpaperScreenSaverActivity.currentIsVisible(), displayAwake: awake)
    }

    static func sessionAllowsPlayback(locked: Bool?, active: Bool, saver: Bool, displayAwake: Bool) -> Bool {
        locked == false && active && !saver && displayAwake
    }
}
