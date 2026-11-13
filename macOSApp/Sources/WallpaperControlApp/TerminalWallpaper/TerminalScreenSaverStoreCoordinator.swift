import AuraWallpaperCore
import AuraTerminalWallpaperCore
import Darwin
import Foundation

/// macOS 26+ selects the Lock Screen's Idle route from WallpaperAgent's store.
/// The legacy com.apple.screensaver moduleDict is still written for older macOS,
/// but changing it alone does not select the saver in modern System Settings.
protocol TerminalScreenSaverStoreCoordinating {
    func activate() throws
    func restoreIfOwned() throws
    func restoreCurrentDesktopIfOwned() throws
}

extension TerminalScreenSaverStoreCoordinating {
    func restoreCurrentDesktopIfOwned() throws { try restoreIfOwned() }
}

typealias TerminalScreenSaverStoreCoordinator = LiveScreenSaverStoreCoordinator

extension LiveScreenSaverStoreCoordinator: TerminalScreenSaverStoreCoordinating {}
