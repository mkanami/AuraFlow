import Foundation
import Testing
@testable import WallpaperControlApp

@MainActor
private func makeLifecycleViewModel(
    controller: MockNativeWallpaperController,
    preparationDelay: UInt64 = 0
) -> LifecycleViewModel {
    let viewModel = LifecycleViewModel()
    let prepare: @MainActor @Sendable (URL) async throws -> PreparedLifecycleVideo = { url in
        if preparationDelay > 0 {
            try await Task.sleep(nanoseconds: preparationDelay)
        }
        return PreparedLifecycleVideo(url: url, summary: nil)
    }

    viewModel.configure(
        dependencies: LifecycleViewModelDependencies(
            controller: { controller },
            prepareVideo: prepare,
            prepareCatalogVideo: prepare,
            prepareLockScreenVideo: prepare,
            isManagedCacheURL: { _ in false }
        ),
        callbacks: LifecycleViewModelCallbacks(
            applyResult: { [weak viewModel] result in
                viewModel?.isRunning = result.status.running
                viewModel?.isPlaybackPaused = result.status.paused ?? false
                viewModel?.isLockScreenOnlyActive =
                    result.status.lock_screen_only ?? false
            }
        )
    )
    return viewModel
}

@MainActor
private func waitForLifecycleToBecomeIdle(_ viewModel: LifecycleViewModel) async {
    for _ in 0..<100 {
        if !viewModel.isBusy,
           !viewModel.hasActiveOrPendingLifecycleOperation {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Test @MainActor
func lifecycleViewModelOwnsStartLockStopAndRemoveOperations() async {
    let controller = MockNativeWallpaperController()
    let viewModel = makeLifecycleViewModel(controller: controller)
    let videoURL = URL(fileURLWithPath: "/tmp/lifecycle-view-model.mp4")

    viewModel.start(selectedVideoURL: videoURL, hasPendingPreview: false)
    await waitForLifecycleToBecomeIdle(viewModel)
    #expect(controller.startCallCount == 1)
    #expect(viewModel.state == .ready)

    viewModel.stop(selectedVideoURL: videoURL)
    await waitForLifecycleToBecomeIdle(viewModel)
    #expect(controller.stopCallCount == 1)
    #expect(viewModel.state == .paused)

    viewModel.applyLockScreenOnly(selectedVideoURL: videoURL)
    await waitForLifecycleToBecomeIdle(viewModel)
    #expect(controller.lockCallCount == 1)
    #expect(viewModel.isLockScreenOnlyActive)

    viewModel.clearWallpaper()
    await waitForLifecycleToBecomeIdle(viewModel)
    #expect(controller.clearCallCount == 1)
    #expect(viewModel.state == .idle)
    #expect(!viewModel.isBusy)
}

@Test @MainActor
func lifecycleViewModelCoalescesDuplicatesAndSupersedesStalePreparation() async {
    let controller = MockNativeWallpaperController()
    let viewModel = makeLifecycleViewModel(
        controller: controller,
        preparationDelay: 80_000_000
    )
    let videoURL = URL(fileURLWithPath: "/tmp/lifecycle-coalescing.mp4")

    viewModel.start(selectedVideoURL: videoURL, hasPendingPreview: false)
    viewModel.start(selectedVideoURL: videoURL, hasPendingPreview: false)
    try? await Task.sleep(nanoseconds: 10_000_000)
    viewModel.clearWallpaper()
    await waitForLifecycleToBecomeIdle(viewModel)

    #expect(controller.startCallCount == 0)
    #expect(controller.clearCallCount == 1)
    #expect(viewModel.state == .idle)
    #expect(!viewModel.hasActiveOrPendingLifecycleOperation)
}

@Test @MainActor
func lifecycleViewModelCancellationClearsQueuedWork() async {
    let controller = MockNativeWallpaperController()
    let viewModel = makeLifecycleViewModel(
        controller: controller,
        preparationDelay: 150_000_000
    )
    let videoURL = URL(fileURLWithPath: "/tmp/lifecycle-cancellation.mp4")

    viewModel.start(selectedVideoURL: videoURL, hasPendingPreview: false)
    viewModel.cancel()
    await waitForLifecycleToBecomeIdle(viewModel)

    #expect(controller.startCallCount == 0)
    #expect(!viewModel.isBusy)
    #expect(!viewModel.hasActiveOrPendingLifecycleOperation)
}

@Test @MainActor
func lifecycleViewModelIgnoresLockWhenLockScreenOnlyIsAlreadyActive() async {
    let controller = MockNativeWallpaperController()
    let viewModel = makeLifecycleViewModel(controller: controller)
    viewModel.isLockScreenOnlyActive = true

    viewModel.applyLockScreenOnly(
        selectedVideoURL: URL(fileURLWithPath: "/tmp/already-locked.mp4")
    )
    await waitForLifecycleToBecomeIdle(viewModel)

    #expect(controller.lockCallCount == 0)
    #expect(!viewModel.hasActiveOrPendingLifecycleOperation)
}
