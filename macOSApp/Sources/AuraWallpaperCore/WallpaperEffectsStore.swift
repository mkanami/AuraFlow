import AppKit
import Foundation

public struct WallpaperEffectsStore {
    public static let didChange = Notification.Name("com.andrijvergeles.auraflow.wallpaper-effects-changed")
    public let url: URL

    public init(appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL()) {
        url = appSupportURL.appendingPathComponent("wallpaper-effects.json")
    }

    public func load() -> WallpaperEffectsSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(WallpaperEffectsSettings.self, from: data)
        else { return WallpaperEffectsSettings() }
        return settings
    }

    public func save(_ settings: WallpaperEffectsSettings) throws {
        let data = try JSONEncoder().encode(settings.normalized())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(Self.didChange, object: nil,
                                                                    userInfo: nil, deliverImmediately: true)
    }
}
