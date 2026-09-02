import AuraWallpaperCore
import Testing

@Test func lockLifecycleCoalescesDuplicateNotifications() {
    var coordinator = LockScreenLifecycleCoordinator()

    let preparation = coordinator.enqueue(.healthCheck)
    #expect(preparation?.operationID == 1)
    #expect(preparation?.expectedLocked == false)

    let lock = coordinator.enqueue(.sessionLocked)
    #expect(lock == nil)
    #expect(coordinator.desiredLocked)

    // A second shield callback represents the same target state and must not
    // create another operation after the first one finishes.
    #expect(coordinator.enqueue(.shieldRaised) == nil)
    let locked = coordinator.finish(operationID: preparation!.operationID)
    #expect(locked?.expectedLocked == true)
    #expect(locked?.operationID == 2)
    #expect(coordinator.finish(operationID: preparation!.operationID) == nil)
    #expect(coordinator.enqueue(.sessionLocked) == nil)
    #expect(coordinator.finish(operationID: locked!.operationID) == nil)
}

@Test func lockLifecycleUsesLatestExplicitState() throws {
    var coordinator = LockScreenLifecycleCoordinator()
    let initialValue = coordinator.enqueue(.sessionLocked)
    let initial = try #require(initialValue)
    #expect(initial.expectedLocked)

    #expect(coordinator.enqueue(.sessionUnlocked) == nil)
    #expect(coordinator.enqueue(.sessionLocked) == nil)
    #expect(coordinator.desiredLocked)

    // The final explicit request returns to the state already being applied,
    // so the older pending unlock is discarded.
    #expect(coordinator.finish(operationID: initial.operationID) == nil)

    let unlockValue = coordinator.enqueue(.sessionUnlocked)
    let unlock = try #require(unlockValue)
    #expect(unlock.expectedLocked == false)
    #expect(unlock.event == .sessionUnlocked)
    #expect(coordinator.finish(operationID: unlock.operationID) == nil)
}

@Test func lockLifecycleKeepsLatestUnlockWhenItDiffers() throws {
    var coordinator = LockScreenLifecycleCoordinator()
    let initialValue = coordinator.enqueue(.sessionLocked)
    let initial = try #require(initialValue)
    #expect(coordinator.enqueue(.sessionUnlocked) == nil)
    #expect(coordinator.desiredLocked == false)

    let latestValue = coordinator.finish(operationID: initial.operationID)
    let latest = try #require(latestValue)
    #expect(latest.expectedLocked == false)
    #expect(latest.event == .sessionUnlocked)

    #expect(coordinator.finish(operationID: latest.operationID) == nil)
}

@Test func staleLifecycleCompletionCannotClearCurrentOperation() throws {
    var coordinator = LockScreenLifecycleCoordinator()
    let firstValue = coordinator.enqueue(.sessionLocked)
    let first = try #require(firstValue)
    let second = coordinator.enqueue(.sessionUnlocked)

    #expect(second == nil)
    #expect(coordinator.finish(operationID: first.operationID + 1) == nil)
    let unlockValue = coordinator.finish(operationID: first.operationID)
    let unlock = try #require(unlockValue)
    #expect(unlock.operationID > first.operationID)
    #expect(unlock.expectedLocked == false)
}

@Test func lockUnlockLifecycleRemainsMonotonicForManyCycles() throws {
    var coordinator = LockScreenLifecycleCoordinator()
    var lastOperationID: UInt64 = 0

    for _ in 0..<1_000 {
        let lockValue = coordinator.enqueue(.sessionLocked)
        let lock = try #require(lockValue)
        #expect(lock.operationID > lastOperationID)
        #expect(lock.expectedLocked)
        lastOperationID = lock.operationID

        let unlockRequest = coordinator.enqueue(.sessionUnlocked)
        #expect(unlockRequest == nil)
        let unlockValue = coordinator.finish(operationID: lock.operationID)
        let unlock = try #require(unlockValue)
        #expect(unlock.operationID > lastOperationID)
        #expect(unlock.expectedLocked == false)
        lastOperationID = unlock.operationID
        #expect(coordinator.finish(operationID: unlock.operationID) == nil)
    }
}
