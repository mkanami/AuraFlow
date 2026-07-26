/// The surface on which the wallpaper should currently be presented.
public enum WallpaperPresentationMode: String, Equatable, Sendable {
    case desktop
    case lockScreen
}

/// The lock state reported by the macOS user session.
public enum LockScreenSessionState: Equatable, Sendable {
    case unlocked
    case locked
}

/// A temporary lock-screen presentation requested by the app's preview UI.
public enum LockScreenPreviewState: Equatable, Sendable {
    case inactive
    case active
}

/// Inputs accepted by ``LockScreenStateMachine``.
public enum LockScreenStateEvent: Equatable, Sendable {
    case setEnabled(Bool)
    case sessionLocked
    case sessionUnlocked
    case beginPreview
    case endPreview
}

/// Pure state used to decide whether wallpaper windows belong on the desktop or
/// on the lock-screen presentation surface.
///
/// Session lock and preview are intentionally independent. Ending a preview
/// cannot accidentally hide a real locked session, and an unlock notification
/// cannot end a preview that is still active.
public struct LockScreenStateMachine: Equatable, Sendable {
    public private(set) var isEnabled: Bool
    public private(set) var sessionState: LockScreenSessionState
    public private(set) var previewState: LockScreenPreviewState

    public init(
        isEnabled: Bool = false,
        sessionState: LockScreenSessionState = .unlocked,
        previewState: LockScreenPreviewState = .inactive
    ) {
        self.isEnabled = isEnabled
        self.sessionState = sessionState
        self.previewState = previewState
    }

    public var presentationMode: WallpaperPresentationMode {
        guard isEnabled else { return .desktop }

        if sessionState == .locked || previewState == .active {
            return .lockScreen
        }

        return .desktop
    }

    /// Applies an input and returns whether the stored state changed.
    ///
    /// Repeating any event is safe: duplicate notifications are idempotent and
    /// return `false`.
    @discardableResult
    public mutating func apply(_ event: LockScreenStateEvent) -> Bool {
        let previousState = self

        switch event {
        case .setEnabled(let isEnabled):
            self.isEnabled = isEnabled
        case .sessionLocked:
            sessionState = .locked
        case .sessionUnlocked:
            sessionState = .unlocked
        case .beginPreview:
            previewState = .active
        case .endPreview:
            previewState = .inactive
        }

        return self != previousState
    }
}
