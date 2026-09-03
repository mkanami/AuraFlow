import Combine
import Foundation

/// UI-facing lifecycle state. Runtime commands remain serialized by
/// `AppViewModel`, but the state they publish is isolated here.
@MainActor
final class LifecycleViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isPlaybackActive = false
    @Published var isPlaybackPaused = false
    @Published var isLockScreenOnlyActive = false
    @Published var isLockScreenPreviewActive = false
    @Published var state: WallpaperLifecycleState = .idle
    @Published var isBusy = false
}
