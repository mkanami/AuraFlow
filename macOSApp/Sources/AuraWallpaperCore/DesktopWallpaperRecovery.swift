import Foundation

/// Restores the user's Desktop backup. Generated frames are retained inside
/// Aura's rendering surfaces and are never installed as system wallpaper.
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
        // Cached frames belong to Aura's own windows and the screen saver.
        // Persisting one as the user's system Desktop survives a stopped or
        // failed runtime and disguises a failed login as a frozen wallpaper.
        return nil
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
