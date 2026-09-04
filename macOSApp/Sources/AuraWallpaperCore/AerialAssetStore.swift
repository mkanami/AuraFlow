import Foundation

/// Resolves the downloaded Aerial cache files and the signed Apple provider's
/// catalog. The video cache is the ownership boundary for slot selection:
/// catalog thumbnails can exist before a movie has ever been downloaded.
internal final class AerialAssetStore {
    internal let aerialVideosURL: URL
    internal let aerialThumbnailsURL: URL
    internal let aerialProviderURL: URL
    internal let fileManager: FileManager

    internal init(
        fileManager: FileManager = .default,
        aerialVideosURL: URL? = nil,
        aerialThumbnailsURL: URL? = nil,
        aerialProviderURL: URL? = nil
    ) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        let wallpaperSupport = WallpaperPlatformConstants.wallpaperSupportURL(
            homeURL: home
        )
        self.aerialVideosURL = aerialVideosURL
            ?? wallpaperSupport.appendingPathComponent(
                WallpaperPlatformConstants.aerialVideosRelativePath,
                isDirectory: true
            )
        self.aerialThumbnailsURL = aerialThumbnailsURL
            ?? wallpaperSupport.appendingPathComponent(
                WallpaperPlatformConstants.aerialThumbnailsRelativePath,
                isDirectory: true
            )
        self.aerialProviderURL = aerialProviderURL
            ?? URL(
                fileURLWithPath: WallpaperPlatformConstants.aerialProviderPath,
                isDirectory: true
            )
    }

    internal convenience init(
        aerialVideosURL: URL,
        aerialThumbnailsURL: URL,
        aerialProviderURL: URL,
        fileManager: FileManager
    ) {
        self.init(
            fileManager: fileManager,
            aerialVideosURL: aerialVideosURL,
            aerialThumbnailsURL: aerialThumbnailsURL,
            aerialProviderURL: aerialProviderURL
        )
    }

    internal func assetURL(for assetID: String) -> URL {
        aerialVideosURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
    }

    internal func thumbnailURL(for assetID: String) -> URL {
        aerialThumbnailsURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("png")
    }

    /// Returns true only when the installed provider is the expected Apple
    /// Aerial extension and its catalogs advertise the requested asset.
    internal func providerSupportsAsset(_ assetID: String) -> Bool {
        supportedProviderAssetIDs().contains(assetID)
    }

    /// Reads both provider catalogs. A missing, invalid, or mismatched
    /// provider is represented by an empty set so a stale cache cannot be
    /// selected after a system update.
    internal func supportedProviderAssetIDs() -> Set<String> {
        guard providerInfoIsCompatible() else {
            return []
        }

        let resourcesURL = aerialProviderURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        var assetIDs = Set<String>()

        for catalogName in ["entries.json", "entries_variants.json"] {
            let catalogURL = resourcesURL
                .appendingPathComponent(catalogName)
            guard let data = try? Data(contentsOf: catalogURL),
                  let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let assets = root["assets"] as? [[String: Any]]
            else {
                continue
            }

            for asset in assets {
                if let assetID = asset["id"] as? String {
                    assetIDs.insert(assetID)
                }
            }
        }

        return assetIDs
    }

    /// Returns free provider slots in deterministic order, rotating the
    /// result after `lastAssetID` when that ID is itself a free slot.
    internal func orderedFreeProviderAssetIDs(
        lastAssetID: String? = nil
    ) -> [String] {
        let freeAssetIDs = supportedProviderAssetIDs()
            .filter { !fileManager.fileExists(atPath: assetURL(for: $0).path) }
            .sorted()

        guard freeAssetIDs.count > 1,
              let lastAssetID,
              let index = freeAssetIDs.firstIndex(of: lastAssetID)
        else {
            return freeAssetIDs
        }

        let next = freeAssetIDs.index(after: index)
        return Array(freeAssetIDs[next...])
            + Array(freeAssetIDs[..<next])
    }

    private func providerInfoIsCompatible() -> Bool {
        let infoURL = aerialProviderURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(
                  from: infoData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                  == WallpaperPlatformConstants.aerialExtensionBundleID,
              let attributes = info["EXAppExtensionAttributes"]
                  as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String
                  == WallpaperPlatformConstants.wallpaperExtensionPointID
        else {
            return false
        }
        return true
    }
}
