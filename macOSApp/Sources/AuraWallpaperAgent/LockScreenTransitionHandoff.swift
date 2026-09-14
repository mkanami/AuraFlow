import Foundation

/// Keeps the shared Desktop player underneath macOS's secure Lock Screen so
/// WindowServer always has an Aura frame to reveal during lock transitions.
/// The dedicated Lock-only runtime does not own Desktop windows and therefore
/// keeps its existing presentation lifecycle.
struct LockScreenTransitionHandoff {
    static func retainsDesktopSurface(
        sessionIsLocked: Bool,
        lockScreenOnlyMode: Bool
    ) -> Bool {
        sessionIsLocked && !lockScreenOnlyMode
    }

    static func completeSharedUnlock(
        presentDesktopSurface: () -> Void,
        releaseNativeLockSurface: () -> Void
    ) {
        presentDesktopSurface()
        releaseNativeLockSurface()
    }
}
