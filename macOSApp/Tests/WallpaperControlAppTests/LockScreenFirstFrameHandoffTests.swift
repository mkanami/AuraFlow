import AppKit
import AuraWallpaperCore
import Testing
@testable import AuraWallpaperAgent

private final class FirstFrameTrace {
    var locked: Bool? = false
    var promoted = false
    var events: [String] = []
}

private final class FirstFramePlatform: LockScreenSaverInstalling {
    let trace: FirstFrameTrace
    let requiresLockScreenSessionPromotion: Bool
    let isInstalled = true
    var capabilities: PlatformCapabilities { .modernMacOS26(isAvailable: true) }
    init(_ trace: FirstFrameTrace, promotionRequired: Bool) {
        self.trace = trace
        requiresLockScreenSessionPromotion = promotionRequired
        trace.promoted = !promotionRequired
    }
    func install(videoURL: URL) async throws {}
    func uninstall() throws {}
    func activateLockScreenForCurrentSession() throws -> Bool {
        trace.promoted = true
        trace.events.append("promote")
        return true
    }
}

private final class FirstFrameBridge: NativeLockScreenBridging {
    let trace: FirstFrameTrace
    var isReady = true
    var onFailure: (@Sendable (String) -> Void)?
    init(_ trace: FirstFrameTrace) { self.trace = trace }
    func prepare(completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    func showForLockTransition(completion: (@Sendable (Bool) -> Void)?) {
        trace.events.append(trace.promoted ? "show-aura" : "show-before-promotion")
        completion?(true)
    }
    func hideAfterUnlock() {}
    func pause() {}
    func resumeAfterPause() {}
    func invalidatePreparation() {}
    func shutdown() {}
}

@Suite(.serialized)
struct LockScreenFirstFrameHandoffTests {
    @Test @MainActor
    func disabledLockScreenDoesNotStartEarlyNativePresentation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraDisabledFirstFrame-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperRuntimeStore(appSupportURL: root)
        try store.saveConfig(.init(video_path: "fixture.mp4", playback_speed: 1, show_on_lock_screen: false))
        let trace = FirstFrameTrace()
        trace.locked = true
        let agent = WallpaperAgentDelegate(store: store,
            lockScreenPlatform: FirstFramePlatform(trace, promotionRequired: true),
            nativeLockScreenBridge: FirstFrameBridge(trace), observesSystemEvents: false,
            sessionIsLocked: { trace.locked })
        agent.lockShieldDidRaise(Notification(name: .init("com.apple.shieldWindowRaised")))
        #expect(trace.events.isEmpty)
    }

    @Test @MainActor
    func confirmedShieldPromotesAuraBeforeBindingTheFirstSecureFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFirstFrame-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperRuntimeStore(appSupportURL: root)
        try store.saveConfig(.init(video_path: "fixture.mp4", playback_speed: 1, show_on_lock_screen: true))
        let trace = FirstFrameTrace()
        trace.locked = true
        let agent = WallpaperAgentDelegate(store: store,
            lockScreenPlatform: FirstFramePlatform(trace, promotionRequired: true),
            nativeLockScreenBridge: FirstFrameBridge(trace), observesSystemEvents: false,
            sessionIsLocked: { trace.locked })
        // No application launch, real windows, processes, or system store.
        for _ in 0..<10 {
            agent.lockShieldDidRaise(Notification(name: .init("com.apple.shieldWindowRaised")))
            agent.handleSessionNotification(expectedLocked: true)
        }
        #expect(trace.events == ["promote", "show-aura"])
    }

    @Test @MainActor
    func shieldConfirmationDoesNotWaitForTwoSecondHealthPollWhenPromotionIsNotNeeded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFirstFramePoll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperRuntimeStore(appSupportURL: root)
        try store.saveConfig(.init(video_path: "fixture.mp4", playback_speed: 1, show_on_lock_screen: true))
        let trace = FirstFrameTrace()
        let agent = WallpaperAgentDelegate(store: store,
            lockScreenPlatform: FirstFramePlatform(trace, promotionRequired: false),
            nativeLockScreenBridge: FirstFrameBridge(trace), observesSystemEvents: false,
            sessionIsLocked: { trace.locked })
        agent.lockShieldDidRaise(Notification(name: .init("com.apple.shieldWindowRaised")))
        #expect(trace.events.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        #expect(trace.events.isEmpty)
        trace.locked = true
        try await Task.sleep(for: .milliseconds(250))
        #expect(trace.events == ["show-aura"])
        _ = agent // Retain the agent through the confirmation poll.
    }

    @Test(arguments: [false, nil] as [Bool?]) @MainActor
    func unconfirmedShieldNeverPromotesOrShowsASecureSurface(locked: Bool?) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraUnconfirmedFrame-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperRuntimeStore(appSupportURL: root)
        try store.saveConfig(.init(video_path: "fixture.mp4", playback_speed: 1, show_on_lock_screen: true))
        let trace = FirstFrameTrace()
        trace.locked = locked
        let agent = WallpaperAgentDelegate(store: store,
            lockScreenPlatform: FirstFramePlatform(trace, promotionRequired: true),
            nativeLockScreenBridge: FirstFrameBridge(trace), observesSystemEvents: false,
            sessionIsLocked: { trace.locked })
        agent.lockShieldDidRaise(Notification(name: .init("com.apple.shieldWindowRaised")))
        #expect(trace.events.isEmpty)
    }
}
