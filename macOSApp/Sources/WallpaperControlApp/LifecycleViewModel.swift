import Combine
import Foundation
import OSLog

enum WallpaperLifecycleState: String, Equatable {
    case idle
    case preparing
    case ready
    case paused
    case removing
    case failed
}

enum WallpaperLifecycleIntent: Equatable {
    case start(URL, resume: Bool)
    case lock(URL)
    case stop(lockScreenOnly: Bool, staticImage: Bool)
    case remove(lockScreenOnly: Bool)

    var name: String {
        switch self {
        case .start: return "start"
        case .lock: return "lock"
        case .stop: return "stop"
        case .remove: return "remove"
        }
    }
}

struct PreparedLifecycleVideo: Sendable {
    let url: URL
    let summary: String?
}

struct LifecycleRequest: Equatable, Sendable {
    let id: UInt64
    let intent: WallpaperLifecycleIntent
}

struct LifecycleResult: Sendable {
    let status: ControlStatus
    let state: WallpaperLifecycleState
    let statusMessage: String
    let successMessage: String?
    let previewURL: URL?
    let clearPendingPreview: Bool
    let refreshPreview: Bool
}

struct LifecycleViewModelDependencies {
    let controller: @MainActor @Sendable () -> WallpaperControlling?
    let prepareVideo: @MainActor @Sendable (URL) async throws -> PreparedLifecycleVideo
    let prepareCatalogVideo: @MainActor @Sendable (URL) async throws -> PreparedLifecycleVideo
    let prepareLockScreenVideo: @MainActor @Sendable (URL) async throws -> PreparedLifecycleVideo
    let isManagedCacheURL: @MainActor @Sendable (URL) -> Bool
}

struct LifecycleViewModelCallbacks {
    var applyResult: (LifecycleResult) -> Void = { _ in }
    var setStatusMessage: (String?) -> Void = { _ in }
    var setAlertMessage: (String?) -> Void = { _ in }
    var recordBridgeSuccess: () -> Void = {}
    var recordBridgeFailure: (Error, String) -> Void = { _, _ in }
    var showSuccessBanner: (String) -> Void = { _ in }
    var scheduleFallbackRetry: () -> Void = {}
}

private let lifecycleViewModelLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LifecycleViewModel"
)

/// Owns the serialized wallpaper lifecycle state machine.
///
/// The app view model supplies platform/preparation dependencies and handles
/// app-wide presentation. Queueing, coalescing, cancellation and the actual
/// start/lock/stop/remove decisions live here so lifecycle behavior has one
/// owner and can be tested without constructing the whole app composition.
@MainActor
final class LifecycleViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isPlaybackActive = false
    @Published var isPlaybackPaused = false
    @Published var isLockScreenOnlyActive = false
    @Published var isLockScreenPreviewActive = false
    @Published var state: WallpaperLifecycleState = .idle
    @Published var isBusy = false

    private var dependencies: LifecycleViewModelDependencies?
    private var callbacks = LifecycleViewModelCallbacks()
    private var lifecycleTask: Task<Void, Never>?
    private var activeLifecycleIntent: WallpaperLifecycleIntent?
    private var pendingLifecycleRequest: LifecycleRequest?
    private var latestLifecycleOperationID: UInt64 = 0

    var activeIntentName: String? {
        activeLifecycleIntent?.name
    }

    var pendingIntentName: String? {
        pendingLifecycleRequest?.intent.name
    }

    var hasActiveOrPendingLifecycleOperation: Bool {
        activeLifecycleIntent != nil || pendingLifecycleRequest != nil
    }

    func configure(
        dependencies: LifecycleViewModelDependencies,
        callbacks: LifecycleViewModelCallbacks = LifecycleViewModelCallbacks()
    ) {
        self.dependencies = dependencies
        self.callbacks = callbacks
    }

    func start(selectedVideoURL: URL?, hasPendingPreview: Bool) {
        guard !isPlaybackRunningForControls || hasPendingPreview else { return }
        guard let selectedVideoURL else {
            callbacks.setAlertMessage("Choose a video before starting.")
            return
        }

        submitLifecycle(
            .start(
                selectedVideoURL,
                resume: isPlaybackPaused && !hasPendingPreview
            )
        )
    }

    func applyLockScreenOnly(selectedVideoURL: URL?) {
        guard !isLockScreenOnlyActive,
              activeLifecycleIntent?.name != "lock",
              pendingLifecycleRequest?.intent.name != "lock"
        else {
            return
        }
        guard let selectedVideoURL else {
            callbacks.setAlertMessage(
                "Choose a video before applying it to the Lock Screen."
            )
            return
        }
        guard dependencies?.controller() != nil else {
            callbacks.setAlertMessage("Native wallpaper runtime unavailable.")
            return
        }
        submitLifecycle(.lock(selectedVideoURL))
    }

    func stop(selectedVideoURL: URL?) {
        guard dependencies?.controller() != nil else { return }
        guard isPlaybackRunningForControls
                || isLockScreenOnlyActive
                || activeLifecycleIntent?.name == "lock"
                || pendingLifecycleRequest?.intent.name == "lock"
        else {
            return
        }

        let stoppingLockScreenOnly = isLockScreenOnlyActive
            || activeLifecycleIntent?.name == "lock"
            || pendingLifecycleRequest?.intent.name == "lock"
        let staticImage = stoppingLockScreenOnly
            && selectedVideoURL.map {
                WallpaperMediaKind.forURL($0).isStaticImage
            } == true
        submitLifecycle(
            .stop(
                lockScreenOnly: stoppingLockScreenOnly,
                staticImage: staticImage
            )
        )
    }

    func clearWallpaper() {
        guard dependencies?.controller() != nil else { return }
        submitLifecycle(.remove(lockScreenOnly: isLockScreenOnlyActive))
    }

    func cancel() {
        latestLifecycleOperationID &+= 1
        pendingLifecycleRequest = nil
        activeLifecycleIntent = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        isBusy = false
    }

    deinit {
        lifecycleTask?.cancel()
    }

    private var isPlaybackRunningForControls: Bool {
        isRunning && !isPlaybackPaused
    }

    private func submitLifecycle(_ intent: WallpaperLifecycleIntent) {
        if activeLifecycleIntent == intent,
           pendingLifecycleRequest == nil {
            return
        }
        if pendingLifecycleRequest?.intent == intent {
            return
        }

        latestLifecycleOperationID &+= 1
        let request = LifecycleRequest(
            id: latestLifecycleOperationID,
            intent: intent
        )
        pendingLifecycleRequest = request
        lifecycleViewModelLogger.notice(
            "Queued operation=\(request.id, privacy: .public) intent=\(intent.name, privacy: .public)"
        )
        switch intent {
        case .remove:
            state = .removing
            callbacks.setStatusMessage("Removing wallpaper…")
        case .stop:
            callbacks.setStatusMessage("Pausing wallpaper…")
        case .start:
            state = .preparing
            callbacks.setStatusMessage("Starting wallpaper…")
        case .lock:
            state = .preparing
            callbacks.setStatusMessage("Preparing Lock Screen wallpaper…")
        }
        callbacks.setAlertMessage(nil)

        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            await self?.drainLifecycleQueue()
        }
    }

    private func drainLifecycleQueue() async {
        isBusy = true
        defer {
            activeLifecycleIntent = nil
            lifecycleTask = nil
            isBusy = false
            callbacks.scheduleFallbackRetry()
        }

        while !Task.isCancelled,
              let request = pendingLifecycleRequest {
            pendingLifecycleRequest = nil
            activeLifecycleIntent = request.intent
            let startedAt = ContinuousClock.now
            lifecycleViewModelLogger.notice(
                "Started operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
            )
            do {
                let result = try await executeLifecycle(request)
                guard request.id == latestLifecycleOperationID,
                      pendingLifecycleRequest == nil
                else {
                    lifecycleViewModelLogger.notice(
                        "Superseded operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
                    )
                    activeLifecycleIntent = nil
                    continue
                }
                callbacks.applyResult(result)
                callbacks.recordBridgeSuccess()
                state = result.state
                callbacks.setAlertMessage(nil)
                if let successMessage = result.successMessage {
                    callbacks.showSuccessBanner(successMessage)
                }
                let elapsed = startedAt.duration(to: .now)
                lifecycleViewModelLogger.notice(
                    "Completed operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
                )
            } catch is CancellationError {
                lifecycleViewModelLogger.notice(
                    "Cancelled operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public)"
                )
            } catch {
                guard request.id == latestLifecycleOperationID,
                      pendingLifecycleRequest == nil
                else {
                    activeLifecycleIntent = nil
                    continue
                }
                state = .failed
                let context: String
                switch request.intent {
                case .start: context = "start"
                case .lock: context = "lock-screen-only"
                case .stop: context = "pause"
                case .remove: context = "clear-wallpaper"
                }
                callbacks.recordBridgeFailure(error, context)
                callbacks.setAlertMessage(
                    "Failed to \(request.intent.name): \(error.localizedDescription)"
                )
                lifecycleViewModelLogger.error(
                    "Failed operation=\(request.id, privacy: .public) intent=\(request.intent.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            activeLifecycleIntent = nil
        }
    }

    private func executeLifecycle(
        _ request: LifecycleRequest
    ) async throws -> LifecycleResult {
        guard let dependencies,
              let controller = dependencies.controller()
        else {
            throw NativeWallpaperControllerError.unavailable(
                "Native wallpaper runtime unavailable."
            )
        }

        switch request.intent {
        case .start(let sourceURL, let resume):
            if resume {
                // Start always owns both surfaces, including the paused
                // resume path. Re-enable and synchronize Lock Screen before
                // asking the Desktop agent to resume.
                _ = try await runAsync {
                    try await controller.setShowOnLockScreen(true)
                }
                let status = try await runAsync { try controller.resume() }
                return LifecycleResult(
                    status: status,
                    state: .ready,
                    statusMessage: "Wallpaper resumed.",
                    successMessage: "Wallpaper started.",
                    previewURL: nil,
                    clearPendingPreview: false,
                    refreshPreview: true
                )
            }
            let prepared = dependencies.isManagedCacheURL(sourceURL)
                ? try await dependencies.prepareCatalogVideo(sourceURL)
                : try await dependencies.prepareVideo(sourceURL)
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync {
                try await controller.start(videoURL: prepared.url, speed: nil)
            }
            return LifecycleResult(
                status: status,
                state: .ready,
                statusMessage: prepared.summary ?? "Wallpaper started.",
                successMessage: "Wallpaper started.",
                previewURL: prepared.url,
                clearPendingPreview: true,
                refreshPreview: false
            )

        case .lock(let sourceURL):
            let prepared = try await dependencies.prepareLockScreenVideo(sourceURL)
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync {
                try await controller.installLockScreenOnly(videoURL: prepared.url)
            }
            return LifecycleResult(
                status: status,
                state: .ready,
                statusMessage: prepared.summary.map {
                    "Lock Screen wallpaper confirmed. \($0)"
                } ?? "Lock Screen wallpaper confirmed by macOS.",
                successMessage: "Wallpaper started on Lock Screen.",
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: false
            )

        case .stop(let lockScreenOnly, let staticImage):
            try ensureLifecycleMayCommit(request)
            let status = try await runAsync { try controller.stop() }
            return LifecycleResult(
                status: status,
                state: staticImage ? .ready : .paused,
                statusMessage: staticImage
                    ? "Static Lock Screen wallpaper is already still."
                    : lockScreenOnly
                        ? "Lock Screen wallpaper paused."
                        : "Paused on current frame.",
                successMessage: "Wallpaper stopped.",
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: true
            )

        case .remove:
            try ensureLifecycleMayCommit(request)
            let status = try await controller.clearWallpaper()
            let removalStatusMessage: String
            let removalSuccessMessage: String?
            switch status.wallpaper_restore_status {
            case .restored:
                removalStatusMessage = "Original wallpaper restored."
                removalSuccessMessage = "Wallpaper removed."
            case .failed:
                removalStatusMessage = "Wallpaper removed, but the original wallpaper could not be restored. AuraFlow will retry on the next launch."
                removalSuccessMessage = nil
            case .notNeeded, .none:
                removalStatusMessage = "Wallpaper removed."
                removalSuccessMessage = "Wallpaper removed."
            }
            return LifecycleResult(
                status: status,
                state: .idle,
                statusMessage: removalStatusMessage,
                successMessage: removalSuccessMessage,
                previewURL: nil,
                clearPendingPreview: false,
                refreshPreview: true
            )
        }
    }

    private func ensureLifecycleMayCommit(
        _ request: LifecycleRequest
    ) throws {
        guard request.id == latestLifecycleOperationID,
              pendingLifecycleRequest == nil,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
    }

    private func runAsync<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await work()
    }
}
