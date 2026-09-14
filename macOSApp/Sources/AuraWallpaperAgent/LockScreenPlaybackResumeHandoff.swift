import Foundation

/// Keeps the last valid Lock Screen frame visible while the dedicated Aerial
/// route changes from its paused still asset back to the animated generation.
/// The native presentation is released only after the provider transaction
/// completes, so its empty transition frame never reaches the user.
@MainActor
struct LockScreenPlaybackResumeHandoff {
    static func complete(
        restoreAnimatedGeneration: () async throws -> Bool,
        isCurrent: () -> Bool,
        revealAnimatedSurface: () -> Void
    ) async throws -> Bool {
        let restored = try await restoreAnimatedGeneration()
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        revealAnimatedSurface()
        return restored
    }
}
