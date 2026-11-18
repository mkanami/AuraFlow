import Combine
import Foundation

/// Window movement must not publish changes through the application model.
/// Video and effects share this gate; audio keeps its independent clock.
@MainActor
final class PreviewRenderingActivity {
    enum Reason: Hashable { case windowDrag }
    private var reasons: Set<Reason> = []
    let changes = PassthroughSubject<Bool, Never>()
    var isSuspended: Bool { !reasons.isEmpty }

    func set(_ reason: Reason, active: Bool) {
        let wasSuspended = isSuspended
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        if wasSuspended != isSuspended { changes.send(isSuspended) }
    }
}
