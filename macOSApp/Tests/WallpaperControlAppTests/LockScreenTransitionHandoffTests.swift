import Testing
@testable import AuraWallpaperAgent

@Test func sharedLockKeepsTheExistingDesktopSurfaceUnderTheSecureSession() {
    #expect(
        LockScreenTransitionHandoff.retainsDesktopSurface(
            sessionIsLocked: true,
            lockScreenOnlyMode: false
        )
    )
    #expect(
        !LockScreenTransitionHandoff.retainsDesktopSurface(
            sessionIsLocked: false,
            lockScreenOnlyMode: false
        )
    )
    #expect(
        !LockScreenTransitionHandoff.retainsDesktopSurface(
            sessionIsLocked: true,
            lockScreenOnlyMode: true
        )
    )
}

@Test func sharedUnlockPresentsAuraBeforeReleasingTheNativeLockSurface() {
    var events: [String] = []

    LockScreenTransitionHandoff.completeSharedUnlock {
        events.append("present-desktop")
    } releaseNativeLockSurface: {
        events.append("release-lock")
    }

    #expect(events == ["present-desktop", "release-lock"])
}
