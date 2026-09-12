import Foundation

/// The small set of system identifiers shared by platform adapters. Keeping
/// them here makes an OS update a single-place review instead of a search
/// through app, agent, and recovery code.
public enum WallpaperPlatformConstants {
    public static let wallpaperApplicationID = "com.apple.wallpaper"
    public static let screenSaverApplicationID = "com.apple.screensaver"
    public static let systemWallpaperURLKey = "SystemWallpaperURL"

    public static let aerialProviderID = "com.apple.wallpaper.choice.aerials"
    public static let imageProviderID = "com.apple.wallpaper.choice.image"
    public static let screenSaverProviderID = "com.apple.wallpaper.choice.screen-saver"
    public static let aerialExtensionBundleID =
        "com.apple.wallpaper.extension.aerials"
    public static let wallpaperExtensionPointID = "com.apple.wallpaper"

    public static let wallpaperSupportRelativePath =
        "Library/Application Support/com.apple.wallpaper"
    public static let wallpaperStoreRelativePath = "Store/Index.plist"
    public static let aerialVideosRelativePath = "aerials/videos"
    public static let aerialThumbnailsRelativePath = "aerials/thumbnails"
    public static let aerialProviderPath =
        "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
    public static let wallpaperAgentApplicationPath =
        "/System/Library/CoreServices/WallpaperAgent.app"
    public static let fallbackScreenSaverPath =
        "/System/Library/ExtensionKit/Extensions/Ventura.appex"
    public static let fallbackDesktopImagePath =
        "/System/Library/Desktop Pictures/Solid Colors/Stone.png"

    public static let wallpaperAgentProcessName = "WallpaperAgent"
    public static let aerialExtensionProcessName = "WallpaperAerialsExtension"
    public static let dockProcessName = "Dock"
    public static let loginFrameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/login"
    public static let startScreenSaverSymbol = "SACScreenSaverStartNow"

    public static func wallpaperSupportURL(homeURL: URL) -> URL {
        homeURL.appendingPathComponent(
            wallpaperSupportRelativePath,
            isDirectory: true
        )
    }

    public static func wallpaperStoreURL(homeURL: URL) -> URL {
        wallpaperSupportURL(homeURL: homeURL)
            .appendingPathComponent(wallpaperStoreRelativePath)
    }
}
