import Foundation

/// Serializes all mutations made by one Aerial installer instance.
///
/// Synchronous callers wait on a condition, while asynchronous callers wait
/// with continuations and therefore do not block a Swift concurrency worker.
/// Keeping both acquisition paths in one coordinator is important: an async
/// install must exclude a synchronous remove/restore, and vice versa.
internal final class AerialMutationCoordinator: @unchecked Sendable {
    private final class AsyncWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
        var completed = false
    }

    private let condition = NSCondition()
    private var isHeld = false
    private var waiters: [AsyncWaiter] = []

    func acquireSynchronously() {
        condition.lock()
        while isHeld || !waiters.isEmpty {
            condition.wait()
        }
        isHeld = true
        condition.unlock()
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let waiter = AsyncWaiter()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(waiter, continuation: continuation)
            }
        }, onCancel: {
            cancel(waiter)
        })
    }

    func release() {
        var nextContinuation: CheckedContinuation<Void, Error>?
        var cancelledContinuations: [CheckedContinuation<Void, Error>] = []

        condition.lock()
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            guard !waiter.cancelled else {
                waiter.completed = true
                if let continuation = waiter.continuation {
                    waiter.continuation = nil
                    cancelledContinuations.append(continuation)
                }
                continue
            }

            waiter.completed = true
            waiter.continuation.map { continuation in
                waiter.continuation = nil
                nextContinuation = continuation
            }
            isHeld = true
            break
        }

        if nextContinuation == nil {
            isHeld = false
            condition.broadcast()
        }
        condition.unlock()

        cancelledContinuations.forEach {
            $0.resume(throwing: CancellationError())
        }
        nextContinuation?.resume()
    }

    func withExclusive<T>(_ operation: () throws -> T) rethrows -> T {
        acquireSynchronously()
        defer { release() }
        return try operation()
    }

    func withExclusiveNonThrowing<T>(_ operation: () -> T) -> T {
        acquireSynchronously()
        defer { release() }
        return operation()
    }

    func withExclusiveAsync<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func enqueue(
        _ waiter: AsyncWaiter,
        continuation: CheckedContinuation<Void, Error>
    ) {
        var successContinuation: CheckedContinuation<Void, Error>?
        var cancellationContinuation: CheckedContinuation<Void, Error>?

        condition.lock()
        waiter.continuation = continuation
        if waiter.cancelled {
            waiter.completed = true
            waiter.continuation = nil
            cancellationContinuation = continuation
        } else if !isHeld && waiters.isEmpty {
            waiter.completed = true
            waiter.continuation = nil
            isHeld = true
            successContinuation = continuation
        } else {
            waiters.append(waiter)
        }
        condition.unlock()

        cancellationContinuation?.resume(throwing: CancellationError())
        successContinuation?.resume()
    }

    private func cancel(_ waiter: AsyncWaiter) {
        var cancellationContinuation: CheckedContinuation<Void, Error>?

        condition.lock()
        guard !waiter.completed else {
            condition.unlock()
            return
        }
        waiter.cancelled = true
        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
            waiter.completed = true
            waiter.continuation.map { continuation in
                waiter.continuation = nil
                cancellationContinuation = continuation
            }
        }
        condition.unlock()

        cancellationContinuation?.resume(throwing: CancellationError())
    }
}
