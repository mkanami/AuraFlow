import AppKit
import OSLog

/// Observes this window only and always returns the original input event.
/// A single idle timer covers wheel scrolling, momentum and scroller dragging.
@MainActor
final class PreviewScrollMonitor {
    var onChange: (Bool) -> Void
    private weak var window: NSWindow?
    private let activity = WindowInteractionActivity()
    private var observers: [NotificationObserverLifetime] = []
    private var eventMonitor: PreviewScrollEventLifetime?
    private let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "preview-scroll")

    init(window: NSWindow, notifications: NotificationCenter = .default,
         monitorEvents: Bool = true, onChange: @escaping (Bool) -> Void) {
        self.window = window
        self.onChange = onChange
        activity.onStart = { [weak self] in
            self?.onChange(true)
            self?.logger.debug("Scroll preview suspension started")
        }
        activity.onEnd = { [weak self] in
            self?.onChange(false)
            self?.logger.debug("Scroll preview suspension ended")
        }
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            observers.append(NotificationObserverLifetime(notifications.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let scroll = note.object as? NSScrollView,
                          let window = self.window, scroll.window === window else { return }
                    self.scrolled()
                }
            }, center: notifications))
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationObserverLifetime(notifications.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification || (note.object as? NSWindow) === self.window {
                        self.activity.end()
                    }
                }
            }, center: notifications))
        }
        if monitorEvents, let token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let window = self.window, event.window === window { self.scrolled() }
            }
            return event
        }) { eventMonitor = PreviewScrollEventLifetime(token) }
    }

    private func scrolled() {
        activity.begin()
        activity.moved()
    }

    func cancel() {
        activity.end()
        observers.removeAll()
        eventMonitor = nil
    }
}

private final class PreviewScrollEventLifetime {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}
