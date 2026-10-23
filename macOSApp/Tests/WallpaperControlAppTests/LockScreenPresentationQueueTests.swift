import AuraWallpaperCore
import Foundation
import Testing

@MainActor
private final class PresentationQueueFixture {
    final class Surface {
        let id: UInt64
        init(_ id: UInt64) { self.id = id }
    }
    var requests: [LockScreenPresentationQueue<Surface>.Request] = []
    var waiters: [CheckedContinuation<Surface, Error>] = []
    var applied: [UInt64] = []
    var errors = 0
    lazy var queue: LockScreenPresentationQueue<Surface> = {
        let queue = LockScreenPresentationQueue<Surface> { [unowned self] request, _ in
            requests.append(request)
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        queue.onApplied = { [unowned self] in applied.append($0.id) }
        queue.onFailure = { [unowned self] _, _ in errors += 1 }
        return queue
    }()
    func settle() async { for _ in 0..<20 { await Task.yield() } }
    func succeed(_ id: UInt64) { waiters.removeFirst().resume(returning: Surface(id)) }
    func fail() { waiters.removeFirst().resume(throwing: CocoaError(.fileReadUnknown)) }
}

@Suite(.serialized)
struct LockScreenPresentationQueueTests {
    @Test @MainActor func retainsCommittedSurfaceAcrossSlowAndFailedLidWakeRebind() async throws {
        let fixture = PresentationQueueFixture()
        let queue = fixture.queue
        defer { queue.stop() }
        let first = queue.request(locked: true)
        await fixture.settle()
        fixture.succeed(first)
        await fixture.settle()
        weak var retained = queue.surface
        #expect(retained != nil)

        queue.request(locked: true, reloadRoute: true)
        await fixture.settle()
        #expect(queue.surface === retained)
        fixture.fail()
        await fixture.settle()
        #expect(queue.surface === retained)
        #expect(fixture.errors == 1)

        let replacement = queue.request(locked: true, reloadRoute: true)
        await fixture.settle()
        #expect(queue.surface === retained)
        fixture.succeed(replacement)
        await fixture.settle()
        #expect(queue.surface?.id == replacement)
        #expect(retained == nil)
    }

    @Test @MainActor func serializesUncancellableIdleCallBeforeLatestLockAndCoalescesWakeEvents() async throws {
        let fixture = PresentationQueueFixture()
        let queue = fixture.queue
        defer { queue.stop() }
        let idle = queue.request(locked: false)
        await fixture.settle()
        queue.request(locked: true, reloadRoute: true)
        queue.request(locked: false)
        let lock = queue.request(locked: true)
        await fixture.settle()
        #expect(fixture.requests.count == 1)
        fixture.succeed(idle)
        await fixture.settle()
        #expect(queue.surface == nil)
        #expect(fixture.applied.isEmpty)
        #expect(fixture.requests.count == 2)
        let latest = try #require(fixture.requests.last)
        #expect(latest.id == lock)
        #expect(latest.locked)
        // A lock received while a route reload is pending must not reuse an
        // assertion bound to the previous saver, even when coalesced.
        #expect(latest.reloadRoute)
        fixture.succeed(lock)
        await fixture.settle()
        #expect(fixture.applied == [lock])
        #expect(queue.surface?.id == lock)
    }

    @Test @MainActor func lateCompletionAfterStopCannotReviveSurfaceOrClearRestartedWorker() async {
        let fixture = PresentationQueueFixture()
        let queue = fixture.queue
        let stale = queue.request(locked: true)
        await fixture.settle()
        queue.stop()
        let current = queue.request(locked: false)
        await fixture.settle()
        fixture.succeed(stale)
        await fixture.settle()
        #expect(queue.surface == nil)
        #expect(fixture.applied.isEmpty)
        fixture.succeed(current)
        await fixture.settle()
        #expect(queue.surface?.id == current)
        #expect(fixture.applied == [current])
        queue.stop()
    }

    @Test @MainActor func lockUnlockWakeStressKeepsLastSurfaceUntilFinalRequestCompletes() async {
        let fixture = PresentationQueueFixture()
        let queue = fixture.queue
        defer { queue.stop() }
        var committed = queue.request(locked: false)
        await fixture.settle()
        fixture.succeed(committed)
        await fixture.settle()
        for _ in 0..<1_000 {
            let stale = queue.request(locked: false, reloadRoute: true)
            await fixture.settle()
            queue.request(locked: true)
            queue.request(locked: false)
            let latest = queue.request(locked: true, reloadRoute: true)
            #expect(queue.surface?.id == committed)
            fixture.succeed(stale)
            await fixture.settle()
            #expect(queue.surface?.id == committed)
            fixture.succeed(latest)
            await fixture.settle()
            #expect(queue.surface?.id == latest)
            committed = latest
        }
        #expect(fixture.errors == 0)
    }
}

@Test func lockSessionNeverInfersUnlockFromUnavailableOrPartialWindowServerState() {
    #expect(LockScreenSession.isLocked(in: nil) == nil)
    #expect(LockScreenSession.isLocked(in: [:]) == nil)
    #expect(LockScreenSession.isLocked(in: ["kCGSSessionOnConsoleKey": true]) == nil)
    #expect(LockScreenSession.isLocked(in: ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]) == false)
    #expect(LockScreenSession.isLocked(in: ["CGSSessionScreenIsLocked": true, "kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]) == true)
    #expect(LockScreenSession.isLocked(in: ["CGSSessionScreenIsLocked": false]) == false)
}
