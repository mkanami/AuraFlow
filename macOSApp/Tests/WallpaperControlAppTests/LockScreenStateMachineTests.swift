import AuraWallpaperCore
import Testing

@Test func lockScreenPresentationIsDisabledByDefault() {
    let stateMachine = LockScreenStateMachine()

    #expect(stateMachine.isEnabled == false)
    #expect(stateMachine.sessionState == .unlocked)
    #expect(stateMachine.previewState == .inactive)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func enabledLockAndUnlockFollowTheRealSession() {
    var stateMachine = LockScreenStateMachine(isEnabled: true)

    #expect(stateMachine.presentationMode == .desktop)

    let didLock = stateMachine.apply(.sessionLocked)
    #expect(didLock)
    #expect(stateMachine.sessionState == .locked)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didUnlock = stateMachine.apply(.sessionUnlocked)
    #expect(didUnlock)
    #expect(stateMachine.sessionState == .unlocked)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func disabledMachineTracksSessionWithoutPresentingIt() {
    var stateMachine = LockScreenStateMachine()

    let didLock = stateMachine.apply(.sessionLocked)
    #expect(didLock)
    #expect(stateMachine.sessionState == .locked)
    #expect(stateMachine.presentationMode == .desktop)

    let didEnableWhileLocked = stateMachine.apply(.setEnabled(true))
    #expect(didEnableWhileLocked)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didDisable = stateMachine.apply(.setEnabled(false))
    #expect(didDisable)
    #expect(stateMachine.sessionState == .locked)
    #expect(stateMachine.presentationMode == .desktop)

    let didUnlock = stateMachine.apply(.sessionUnlocked)
    let didEnableWhileUnlocked = stateMachine.apply(.setEnabled(true))
    #expect(didUnlock)
    #expect(didEnableWhileUnlocked)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func previewDoesNotPretendTheRealSessionIsLocked() {
    var stateMachine = LockScreenStateMachine(isEnabled: true)

    let didBeginPreview = stateMachine.apply(.beginPreview)
    #expect(didBeginPreview)
    #expect(stateMachine.sessionState == .unlocked)
    #expect(stateMachine.previewState == .active)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didEndPreview = stateMachine.apply(.endPreview)
    #expect(didEndPreview)
    #expect(stateMachine.sessionState == .unlocked)
    #expect(stateMachine.previewState == .inactive)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func disabledMachineTracksPreviewWithoutPresentingIt() {
    var stateMachine = LockScreenStateMachine()

    let didBeginPreview = stateMachine.apply(.beginPreview)
    #expect(didBeginPreview)
    #expect(stateMachine.previewState == .active)
    #expect(stateMachine.presentationMode == .desktop)

    let didEnableDuringPreview = stateMachine.apply(.setEnabled(true))
    #expect(didEnableDuringPreview)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didDisable = stateMachine.apply(.setEnabled(false))
    #expect(didDisable)
    #expect(stateMachine.previewState == .active)
    #expect(stateMachine.presentationMode == .desktop)

    let didEndPreview = stateMachine.apply(.endPreview)
    let didEnableAfterPreview = stateMachine.apply(.setEnabled(true))
    #expect(didEndPreview)
    #expect(didEnableAfterPreview)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func realLockKeepsPresentationActiveAfterPreviewEnds() {
    var stateMachine = LockScreenStateMachine(isEnabled: true)

    stateMachine.apply(.beginPreview)
    stateMachine.apply(.sessionLocked)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didEndPreview = stateMachine.apply(.endPreview)
    #expect(didEndPreview)
    #expect(stateMachine.previewState == .inactive)
    #expect(stateMachine.sessionState == .locked)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didUnlock = stateMachine.apply(.sessionUnlocked)
    #expect(didUnlock)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func previewKeepsPresentationActiveAfterRealSessionUnlocks() {
    var stateMachine = LockScreenStateMachine(isEnabled: true)

    stateMachine.apply(.sessionLocked)
    stateMachine.apply(.beginPreview)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didUnlock = stateMachine.apply(.sessionUnlocked)
    #expect(didUnlock)
    #expect(stateMachine.sessionState == .unlocked)
    #expect(stateMachine.previewState == .active)
    #expect(stateMachine.presentationMode == .lockScreen)

    let didEndPreview = stateMachine.apply(.endPreview)
    #expect(didEndPreview)
    #expect(stateMachine.presentationMode == .desktop)
}

@Test func duplicateEventsAreIdempotent() {
    var stateMachine = LockScreenStateMachine(isEnabled: true)

    let duplicateEnable = stateMachine.apply(.setEnabled(true))
    let duplicateUnlock = stateMachine.apply(.sessionUnlocked)
    let duplicateEndPreview = stateMachine.apply(.endPreview)
    #expect(duplicateEnable == false)
    #expect(duplicateUnlock == false)
    #expect(duplicateEndPreview == false)

    let didLock = stateMachine.apply(.sessionLocked)
    #expect(didLock)
    let lockedState = stateMachine
    let duplicateLock = stateMachine.apply(.sessionLocked)
    #expect(duplicateLock == false)
    #expect(stateMachine == lockedState)

    let didBeginPreview = stateMachine.apply(.beginPreview)
    #expect(didBeginPreview)
    let previewState = stateMachine
    let duplicateBeginPreview = stateMachine.apply(.beginPreview)
    #expect(duplicateBeginPreview == false)
    #expect(stateMachine == previewState)

    let didDisable = stateMachine.apply(.setEnabled(false))
    #expect(didDisable)
    let disabledState = stateMachine
    let duplicateDisable = stateMachine.apply(.setEnabled(false))
    #expect(duplicateDisable == false)
    #expect(stateMachine == disabledState)
}
