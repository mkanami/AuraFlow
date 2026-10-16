import AppKit

/// One timer per drag, rather than a cancelled work item and an actor task for
/// every didMove notification. Resize tracking cannot expire between events.
@MainActor
final class WindowInteractionActivity {
    private(set) var isActive = false
    private var isResizing = false
    private var lastMovement: TimeInterval = 0
    private var timer: WindowInteractionTimerLifetime?
    var onStart: () -> Void = {}
    var onEnd: () -> Void = {}

    func begin(resizing: Bool = false) {
        isResizing = isResizing || resizing
        lastMovement = ProcessInfo.processInfo.systemUptime
        guard !isActive else { return }
        isActive = true
        onStart()
    }

    func moved() {
        guard isActive, !isResizing else { return }
        lastMovement = ProcessInfo.processInfo.systemUptime
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isResizing,
                      ProcessInfo.processInfo.systemUptime - self.lastMovement >= 0.12 else { return }
                self.end()
            }
        }
        self.timer = WindowInteractionTimerLifetime(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    func end() {
        timer = nil
        isResizing = false
        guard isActive else { return }
        isActive = false
        onEnd()
    }

}

/// Timer invalidation is thread-safe; the reference never exposes it outside
/// the main-actor activity, except to cancel during destruction.
private final class WindowInteractionTimerLifetime: @unchecked Sendable {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    deinit { timer.invalidate() }
}
