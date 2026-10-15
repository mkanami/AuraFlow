import Foundation

/// Foundation allows invalidation/removal during teardown on any thread.
/// Immutable ownership boxes keep SDK tokens out of actor-isolated deinits.
final class ScheduledTimerLifetime: @unchecked Sendable {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func invalidate() { timer.invalidate() }
    deinit { timer.invalidate() }
}

final class NotificationObserverLifetime: @unchecked Sendable {
    let token: NSObjectProtocol
    let center: NotificationCenter
    init(_ token: NSObjectProtocol, center: NotificationCenter = .default) {
        self.token = token
        self.center = center
    }
    deinit { center.removeObserver(token) }
}
