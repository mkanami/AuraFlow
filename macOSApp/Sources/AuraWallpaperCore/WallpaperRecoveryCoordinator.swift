import Foundation
import OSLog

public enum WallpaperRecoveryResult: Equatable, Sendable {
    case notNeeded
    case restoredPendingOperation
    case restoredAfterInterruptedRemoval
    case repairDeferred
}

/// Recovers Desktop wallpaper state left behind by an interrupted removal.
///
/// This coordinator deliberately does not install or remove Lock Screen
/// routes. Its only job is the durable Desktop backup/recovery transaction,
/// which makes it safe to run during controller bootstrap.
public final class WallpaperRecoveryCoordinator {
    private static let logger = Logger(
        subsystem: "com.andrijvergeles.auraflow",
        category: "WallpaperRecovery"
    )

    private let store: WallpaperRuntimeStore

    public init(store: WallpaperRuntimeStore) {
        self.store = store
    }

    @discardableResult
    public func recoverInterruptedWallpaperRemovalIfNeeded() -> WallpaperRecoveryResult {
        guard store.appSupportURL.standardizedFileURL
            == WallpaperRuntimeStore.defaultAppSupportURL()
                .standardizedFileURL
        else {
            return .notNeeded
        }

        if store.isWallpaperRestorePending() {
            let restoreStatus = store.restoreWallpaperBackup()
            switch restoreStatus {
            case .restored, .notNeeded:
                store.markWallpaperRestorePending(false)
                store.removeManagedFallback()
                return .restoredPendingOperation
            case .failed:
                Self.logger.error(
                    "Deferred Desktop wallpaper restore failed; keeping the backup for retry"
                )
                return .repairDeferred
            }
        }

        let config = store.loadConfig()
        guard config.video_path.isEmpty,
              config.show_on_lock_screen != true
        else {
            return .notNeeded
        }

        let restoreStatus = store.restoreWallpaperBackup()
        if restoreStatus != .failed {
            store.removeManagedFallback()
            return .restoredAfterInterruptedRemoval
        }

        _ = WallpaperDesktopPlatform.repairCurrentDesktopWallpaperIfNeeded()
        return .repairDeferred
    }
}
