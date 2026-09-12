import Foundation
import Testing
@testable import AuraWallpaperCore

private final class MutationTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.lock()
        signaled = true
        lock.unlock()
    }

    func isSignaled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

private func waitForSignal(
    _ latch: MutationTestLatch,
    timeout: TimeInterval
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !latch.isSignaled() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

private func waitSynchronously(for latch: MutationTestLatch) {
    while !latch.isSignaled() {
        Thread.sleep(forTimeInterval: 0.001)
    }
}

@Test func synchronousMutationWaitsForAsyncMutation() async throws {
    let coordinator = AerialMutationCoordinator()
    let entered = MutationTestLatch()
    let release = MutationTestLatch()
    let completed = MutationTestLatch()

    let asyncMutation = Task {
        try await coordinator.withExclusiveAsync {
            entered.signal()
            while !release.isSignaled() {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    #expect(await waitForSignal(entered, timeout: 1))

    let synchronousMutation = Task.detached {
        coordinator.withExclusive {
            completed.signal()
        }
    }

    #expect(!(await waitForSignal(completed, timeout: 0.05)))
    release.signal()
    _ = try await asyncMutation.value
    _ = await synchronousMutation.value
    #expect(await waitForSignal(completed, timeout: 1))
}

@Test func asyncMutationWaitsForSynchronousMutation() async throws {
    let coordinator = AerialMutationCoordinator()
    let entered = MutationTestLatch()
    let release = MutationTestLatch()
    let completed = MutationTestLatch()

    let synchronousMutation = Task.detached {
        coordinator.withExclusive {
            entered.signal()
            waitSynchronously(for: release)
        }
    }

    #expect(await waitForSignal(entered, timeout: 1))
    let asyncMutation = Task {
        try await coordinator.withExclusiveAsync {
            completed.signal()
        }
    }

    #expect(!(await waitForSignal(completed, timeout: 0.05)))
    release.signal()
    _ = try await asyncMutation.value
    _ = await synchronousMutation.value
    #expect(await waitForSignal(completed, timeout: 1))
}

@Test func cancelledAsyncMutationDoesNotBlockFollowingMutation() async throws {
    let coordinator = AerialMutationCoordinator()
    let entered = MutationTestLatch()
    let release = MutationTestLatch()
    let completed = MutationTestLatch()

    let holder = Task {
        try await coordinator.withExclusiveAsync {
            entered.signal()
            while !release.isSignaled() {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }
    #expect(await waitForSignal(entered, timeout: 1))

    let cancelled = Task {
        try await coordinator.withExclusiveAsync { true }
    }
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        Issue.record("Cancelled mutation unexpectedly acquired the coordinator")
    } catch is CancellationError {
        // Expected.
    }

    release.signal()
    _ = try await holder.value
    _ = try await coordinator.withExclusiveAsync {
        completed.signal()
    }
    #expect(await waitForSignal(completed, timeout: 1))
}
