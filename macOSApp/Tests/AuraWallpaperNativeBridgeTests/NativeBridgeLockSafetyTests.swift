import AuraWallpaperCore
import Testing
@testable import AuraWallpaperNativeBridge

@Suite(.serialized)
struct NativeBridgeLockSafetyTests {
    @Test(arguments: [false, nil] as [Bool?]) @MainActor
    func repeatedStaleShowsNeverStartSaverOrLockDesktop(locked: Bool?) {
        var starts = 0
        var cancellations = 0
        let bridge = NativeLockScreenWallpaperBridge(sessionIsLocked: { locked },
            startScreenSaver: { starts += 1; return 0 })
        defer { bridge.shutdown() }
        for _ in 0..<1_000 {
            bridge.showForLockTransition { succeeded, reason in
                #expect(!succeeded)
                #expect(NativeLockScreenBridgeResponse.isExpectedPresentationCancellation(reason))
                cancellations += 1
            }
            bridge.recoverAfterSystemChange()
        }
        #expect(starts == 0)
        #expect(cancellations == 1_000)
        #expect(!bridge.isReady)
    }

    @Test @MainActor func unpreparedBridgeNeverStartsSaverEvenDuringConfirmedLock() {
        var starts = 0
        let bridge = NativeLockScreenWallpaperBridge(sessionIsLocked: { true },
            startScreenSaver: { starts += 1; return 0 })
        defer { bridge.shutdown() }
        bridge.showForLockTransition { succeeded, _ in #expect(!succeeded) }
        #expect(starts == 0)
    }
}
