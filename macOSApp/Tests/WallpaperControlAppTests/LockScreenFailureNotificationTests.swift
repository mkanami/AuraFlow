import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Test(arguments: ["active", "foreign-root", "retired-pid", "unscoped"], [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func nativeFailureNotificationsOnlyAffectTheirActiveRuntime(origin: String, preferences: (Bool, Bool)) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFailureOrigin-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperRuntimeStore(appSupportURL: root)
    try store.ensureDirectories()
    try "42".write(to: store.pidURL, atomically: true, encoding: .utf8)
    let controller = MockNativeWallpaperController()
    controller.statusRunning = true
    controller.statusConfigAutostart = preferences.0
    controller.statusAutostart = preferences.0
    controller.statusShowOnLockScreen = preferences.1
    let app = AppViewModel(controller: controller, appSupportDirectoryURL: root)
    await app.loadStatus()
    let source = origin == "foreign-root" ? root.appendingPathComponent("other-runtime") : root
    await app.handleLockScreenProviderUnavailableNotification(reason: "Native Lock Screen bridge executable is unavailable.",
        sourceRoot: origin == "unscoped" ? nil : source.path,
        sourcePID: origin == "unscoped" ? nil : (origin == "retired-pid" ? 41 : 42))
    #expect(controller.nativeBridgeFailureReasons.count == (origin == "active" ? 1 : 0))
    #expect(controller.startCallCount == 0 && controller.stopCallCount == 0 && controller.lockCallCount == 0)
    #expect(controller.statusConfigAutostart == preferences.0 && controller.statusShowOnLockScreen == preferences.1)
}

@Test func nativeFailureEnvelopeIncludesTheRuntimeAndRejectsMissingOrInvalidOwners() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraOrigin")
    let info = WallpaperRuntimeNotifications.lockScreenFailureInfo(reason: "fixture", appSupportURL: root, pid: 42)
    #expect(info[WallpaperRuntimeNotifications.lockScreenFallbackReasonKey] as? String == "fixture")
    let sourceRoot = info[WallpaperRuntimeNotifications.lockScreenFallbackRootKey] as? String
    let sourcePID = info[WallpaperRuntimeNotifications.lockScreenFallbackPIDKey] as? Int
    #expect(WallpaperRuntimeNotifications.lockScreenFailureBelongsToRuntime(sourceRoot: sourceRoot, sourcePID: sourcePID,
        appSupportURL: root, currentPID: 42))
    #expect(!WallpaperRuntimeNotifications.lockScreenFailureBelongsToRuntime(sourceRoot: sourceRoot, sourcePID: 0,
        appSupportURL: root, currentPID: 42))
    #expect(!WallpaperRuntimeNotifications.lockScreenFailureBelongsToRuntime(sourceRoot: nil, sourcePID: 42,
        appSupportURL: root, currentPID: 42))
}
