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
        WallpaperDesktopSupport.restoreFromBackupFiles(
            appSupportPath: appSupportPath
        )
    }
}
