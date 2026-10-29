import Foundation
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct DockRefreshRegressionTests {
    @Test func wallpaperRefreshNeverTerminatesDock() throws {
        var calls: [(String, [String])] = []
        try AerialProviderController.refreshWallpaperProcesses(shouldProceed: { true }) {
            calls.append(($0, $1))
        }
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { !$0.1.contains("Dock") })
        #expect(calls.contains { $0.1.contains(WallpaperPlatformConstants.wallpaperAgentProcessName) })
    }

    @Test func isolatedRuntimeNeverChangesTheUsersDesktopOrSystemProcesses() {
        var effects = 0
        let recovery = DesktopWallpaperRecovery(
            appSupportURL: FileManager.default.temporaryDirectory.appendingPathComponent("IsolatedRuntime-\(UUID())"),
            applyDesktop: { _ in effects += 1; return true },
            restoreDesktop: { _ in effects += 1; return .restored },
            repairDesktop: { effects += 1; return true })
        #expect(recovery.applyStillWallpaper(from: "/unused/source.mp4") == nil)
        #expect(recovery.restoreWallpaperBackup() == .notNeeded)
        #expect(!recovery.repairCurrentDesktopWallpaperIfNeeded())
        #expect(effects == 0)
    }

    @Test func ownedRuntimeStillUsesInjectedDesktopRecovery() {
        var effects = 0
        let recovery = DesktopWallpaperRecovery(appSupportURL: WallpaperRuntimeStore.defaultAppSupportURL(),
            restoreDesktop: { _ in effects += 1; return .restored },
            repairDesktop: { effects += 1; return true })
        #expect(recovery.restoreWallpaperBackup() == .restored)
        #expect(recovery.repairCurrentDesktopWallpaperIfNeeded())
        #expect(effects == 2)
    }
}
