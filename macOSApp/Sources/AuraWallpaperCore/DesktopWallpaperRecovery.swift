import Foundation

/// Owns the system Desktop side of the legacy wallpaper fallback.
///
/// Runtime persistence and LaunchAgent orchestration stay in their respective
/// components. This object is the only runtime-layer entry point that applies
/// a generated still frame or restores the user's Desktop backup.
public final class DesktopWallpaperRecovery {
    private let appSupportURL: URL
    private let stillFrameService: StillFrameService

    public init(
        appSupportURL: URL,
        stillFrameService: StillFrameService? = nil
    ) {
        self.appSupportURL = appSupportURL.standardizedFileURL
        self.stillFrameService = stillFrameService
            ?? StillFrameService(appSupportURL: appSupportURL)
    }

    @discardableResult
    public func applyStillWallpaper(from videoPath: String) -> String? {
        guard !videoPath.isEmpty else { return nil }
        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path),
              let frameURL = try? stillFrameService.captureStillFrame(from: videoURL)
        else {
            return nil
        }
        guard WallpaperDesktopPlatform.applyToAllDesktops(imagePath: frameURL.path) else {
            return nil
        }
        return frameURL.path
    }

    public func restoreWallpaperBackup() -> WallpaperRestoreStatus {
        WallpaperDesktopPlatform.restoreFromBackupFilesResult(
            appSupportPath: appSupportURL.path
        )
    }

    @discardableResult
    public func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        WallpaperDesktopPlatform.repairCurrentDesktopWallpaperIfNeeded()
    }
}
