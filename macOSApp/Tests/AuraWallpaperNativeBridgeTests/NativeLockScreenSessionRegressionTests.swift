import AppKit
import AuraWallpaperCore
import QuartzCore
import Testing
@testable import AuraWallpaperNativeBridge

@MainActor
private final class SecurePresentationFixture {
    let root: URL
    let store: WallpaperRuntimeStore
    let window: NSWindow
    let layer = CALayer()
    var locked: Bool? = false
    var requests: [(locked: Bool, reload: Bool)] = []
    var saverStarts: [Bool?] = []
    var holdNextLockedAssertion = false
    var pendingAssertion: CheckedContinuation<Void, Never>?
    lazy var bridge = NativeLockScreenWallpaperBridge(sessionIsLocked: { [weak self] in self?.locked },
        startScreenSaver: { [weak self] in
            guard let self else { return nil }
            self.saverStarts.append(self.locked)
            return 0
        }, store: store, hasDisplays: { true }, surfacePreparer: { [weak self] request, _ in
            guard let self else { throw CancellationError() }
            self.requests.append((request.locked, request.reloadRoute))
            if request.locked, self.holdNextLockedAssertion {
                self.holdNextLockedAssertion = false
                await withCheckedContinuation { self.pendingAssertion = $0 }
            }
            return NativeLockScreenWallpaperBridge.PresentationSurface(display: nil, presentation: nil,
                window: self.window, layer: self.layer)
        })

    init() throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            styleMask: .borderless, backing: .buffered, defer: false)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSecureSession-\(UUID())")
        store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
        try store.saveConfig(.init(video_path: "fixture.mp4", playback_speed: 1, show_on_lock_screen: true))
        window.isReleasedWhenClosed = false
    }

    func prepare() async throws {
        var completed = false
        bridge.prepare { success, _ in completed = success }
        try await eventually { completed && self.bridge.isReady }
    }

    func releaseAssertion() {
        pendingAssertion?.resume()
        pendingAssertion = nil
    }

    func cleanup() {
        bridge.shutdown()
        releaseAssertion()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized)
struct NativeLockScreenSessionRegressionTests {
    @Test @MainActor
    func issue1PreparedHelperNeverRelocksAfterStaleShowsOrLateRecovery() async throws {
        let fixture = try SecurePresentationFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        fixture.locked = true
        fixture.bridge.showForLockTransition()
        try await eventually { fixture.bridge.hasLockedPresentation }
        let previousStarts = fixture.saverStarts.count
        fixture.holdNextLockedAssertion = true
        fixture.bridge.recoverAfterSystemChange()
        try await eventually { fixture.pendingAssertion != nil }
        // WindowServer already says unlocked, but the IPC unlock notification
        // is lost. The pending native operation must not revive the lock.
        fixture.locked = false
        fixture.releaseAssertion()
        try await eventually { !fixture.bridge.hasLockedPresentation }
        for _ in 0..<1_000 {
            fixture.bridge.showForLockTransition { success, reason in
                #expect(!success)
                #expect(NativeLockScreenBridgeResponse.isExpectedPresentationCancellation(reason))
            }
        }
        let previousRequests = fixture.requests.count
        fixture.bridge.recoverAfterSystemChange()
        try await eventually {
            fixture.requests.count > previousRequests
                && fixture.requests.last?.reload == true && fixture.requests.last?.locked == false
        }
        #expect(fixture.saverStarts.count == previousStarts)
        #expect(fixture.saverStarts.allSatisfy { $0 == true })
        #expect(fixture.bridge.isReady)
    }

    @Test(arguments: [false, true]) @MainActor
    func issue4LockScreenWaitsForPreparedSecureSurfaceAfterLogin(automaticRecovery: Bool) async throws {
        let fixture = try SecurePresentationFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        #expect(fixture.requests.map(\.locked) == [false])
        #expect(fixture.saverStarts.isEmpty)
        fixture.locked = true
        fixture.holdNextLockedAssertion = true
        var showCompleted = false
        if automaticRecovery {
            fixture.bridge.recoverAfterSystemChange()
        } else {
            fixture.bridge.showForLockTransition { success, _ in showCompleted = success }
        }
        try await eventually { fixture.pendingAssertion != nil }
        #expect(!showCompleted)
        #expect(!fixture.bridge.hasLockedPresentation)
        #expect(fixture.saverStarts.isEmpty, "Starting the saver against an idle assertion can show the system image or black instead of Aura")
        fixture.releaseAssertion()
        try await eventually { fixture.bridge.hasLockedPresentation && fixture.saverStarts.count == 1 }
        #expect(fixture.requests.last?.locked == true)
        if !automaticRecovery { #expect(showCompleted) }
        #expect(fixture.saverStarts == [true])
        // Duplicate lock events must reuse this committed surface.
        fixture.bridge.showForLockTransition()
        fixture.bridge.showForLockTransition()
        #expect(fixture.saverStarts.count == 1)
    }
}

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() {
        try #require(Date() < deadline, "Timed out waiting for the native presentation contract")
        try await Task.sleep(for: .milliseconds(5))
    }
}
