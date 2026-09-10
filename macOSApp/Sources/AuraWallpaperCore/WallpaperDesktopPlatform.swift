import Foundation

/// Application-facing facade for Desktop wallpaper recovery. The AppKit and
/// wallpaper-store implementation remains in `WallpaperDesktopSupport`; app
/// and runtime orchestration code depends on this boundary instead.
public enum WallpaperDesktopPlatform {
    @discardableResult
    public static func captureCurrentDesktopWallpaperBackup(
        appSupportPath: String
    ) -> Bool {
        WallpaperDesktopSupport.captureCurrentDesktopWallpaperBackup(
            appSupportPath: appSupportPath
        )
    }

    @discardableResult
    public static func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        WallpaperDesktopSupport.repairCurrentDesktopWallpaperIfNeeded()
    }

    public static func discardWallpaperBackupFiles(appSupportPath: String) {
        WallpaperDesktopSupport.discardWallpaperBackupFiles(
            appSupportPath: appSupportPath
        )
    }

    @discardableResult
    public static func applyToAllDesktops(imagePath: String) -> Bool {
        WallpaperDesktopSupport.applyToAllDesktops(imagePath: imagePath)
    }

    @discardableResult
    public static func restoreFromBackupFiles(appSupportPath: String) -> Bool {
        restoreFromBackupFilesResult(appSupportPath: appSupportPath) != .failed
    }

    public static func restoreFromBackupFilesResult(
        appSupportPath: String
    ) -> WallpaperRestoreStatus {
        WallpaperDesktopSupport.restoreFromBackupFilesResult(
            appSupportPath: appSupportPath
        )
    }

    public static func hasWallpaperBackupFiles(appSupportPath: String) -> Bool {
        WallpaperDesktopSupport.hasWallpaperBackupFiles(
            appSupportPath: appSupportPath
        )
    }
}
