import Foundation

/// Owns the system Desktop side of the legacy wallpaper fallback.
///
/// Runtime persistence and LaunchAgent orchestration stay in their respective
/// components. This object is the only runtime-layer entry point that applies
/// a generated still frame or restores the user's Desktop backup.
public final class DesktopWallpaperRecovery {
    private let appSupportURL: URL
    private let stillFrameService: StillFrameService
    private let applyDesktop: (String) -> Bool
    private let restoreDesktop: (String) -> WallpaperRestoreStatus
    private let repairDesktop: () -> Bool
    private var ownsSystemDesktop: Bool {
        appSupportURL == WallpaperRuntimeStore.defaultAppSupportURL().standardizedFileURL
    }

    public init(
        appSupportURL: URL,
        stillFrameService: StillFrameService? = nil,
        applyDesktop: @escaping (String) -> Bool = { WallpaperDesktopPlatform.applyToAllDesktops(imagePath: $0) },
        restoreDesktop: @escaping (String) -> WallpaperRestoreStatus = { WallpaperDesktopPlatform.restoreFromBackupFilesResult(appSupportPath: $0) },
        repairDesktop: @escaping () -> Bool = { WallpaperDesktopPlatform.repairCurrentDesktopWallpaperIfNeeded() }
    ) {
        self.appSupportURL = appSupportURL.standardizedFileURL
        self.stillFrameService = stillFrameService
            ?? StillFrameService(appSupportURL: appSupportURL)
        self.applyDesktop = applyDesktop
        self.restoreDesktop = restoreDesktop
        self.repairDesktop = repairDesktop
    }

    @discardableResult
    public func applyStillWallpaper(from videoPath: String) -> String? {
        guard ownsSystemDesktop, !videoPath.isEmpty else { return nil }
        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path),
              let frameURL = try? stillFrameService.captureStillFrame(from: videoURL)
        else {
            return nil
        }
        guard applyDesktop(frameURL.path) else {
            return nil
        }
        return frameURL.path
    }

    public func restoreWallpaperBackup() -> WallpaperRestoreStatus {
        guard ownsSystemDesktop else { return .notNeeded }
        return restoreDesktop(appSupportURL.path)
    }

    @discardableResult
    public func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        guard ownsSystemDesktop else { return false }
        return repairDesktop()
    }
}
