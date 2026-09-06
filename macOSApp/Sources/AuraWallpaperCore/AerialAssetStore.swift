import Darwin
import Foundation

internal struct AerialAssetReplacementMetadata {
    let modificationDate: Date?
    let posixPermissions: NSNumber?
    let sourceURL: Data?
    let lastETag: Data?
}

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

    /// Returns downloaded provider slots in deterministic order. Selecting a
    /// catalog ID whose movie is absent asks WallpaperAerialsExtension to
    /// download Apple's original asset over AuraFlow's file. Reusing an
    /// already-downloaded, otherwise-unreferenced slot avoids that race.
    internal func orderedDownloadedProviderAssetIDs(
        lastAssetID: String? = nil
    ) -> [String] {
        let downloadedAssetIDs = supportedProviderAssetIDs()
            .filter { fileManager.fileExists(atPath: assetURL(for: $0).path) }
            .sorted()

        guard downloadedAssetIDs.count > 1,
              let lastAssetID,
              let index = downloadedAssetIDs.firstIndex(of: lastAssetID)
        else {
            return downloadedAssetIDs
        }

        let next = downloadedAssetIDs.index(after: index)
        return Array(downloadedAssetIDs[next...])
            + Array(downloadedAssetIDs[..<next])
    }

    internal func replacementMetadata(
        at url: URL
    ) -> AerialAssetReplacementMetadata? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return AerialAssetReplacementMetadata(
            modificationDate: attributes?[.modificationDate] as? Date,
            posixPermissions: attributes?[.posixPermissions] as? NSNumber,
            sourceURL: extendedAttribute(named: "SourceURL", at: url),
            lastETag: extendedAttribute(named: "LastETag", at: url)
        )
    }

    /// Keeps the Apple downloader metadata attached to a reserved slot. The
    /// prepared Aura file must not inherit its own quarantine metadata, while
    /// SourceURL/LastETag tell WallpaperAerialsExtension that this downloaded
    /// slot is already materialized.
    internal func restoreReplacementMetadata(
        _ metadata: AerialAssetReplacementMetadata?,
        to url: URL
    ) throws {
        guard let metadata else { return }
        var attributes: [FileAttributeKey: Any] = [:]
        if let modificationDate = metadata.modificationDate {
            attributes[.modificationDate] = modificationDate
        }
        if let posixPermissions = metadata.posixPermissions {
            attributes[.posixPermissions] = posixPermissions
        }
        if !attributes.isEmpty {
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        try restoreExtendedAttribute(
            named: "SourceURL",
            value: metadata.sourceURL,
            at: url
        )
        try restoreExtendedAttribute(
            named: "LastETag",
            value: metadata.lastETag,
            at: url
        )
    }

    private func extendedAttribute(named name: String, at url: URL) -> Data? {
        let size = url.path.withCString { path in
            name.withCString { attribute in
                getxattr(path, attribute, nil, 0, 0, 0)
            }
        }
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { attribute in
                    getxattr(
                        path,
                        attribute,
                        bytes.baseAddress,
                        size,
                        0,
                        0
                    )
                }
            }
        }
        return result == size ? data : nil
    }

    private func restoreExtendedAttribute(
        named name: String,
        value: Data?,
        at url: URL
    ) throws {
        let result: Int32
        if let value {
            result = value.withUnsafeBytes { bytes in
                url.path.withCString { path in
                    name.withCString { attribute in
                        setxattr(
                            path,
                            attribute,
                            bytes.baseAddress,
                            value.count,
                            0,
                            0
                        )
                    }
                }
            }
        } else {
            result = url.path.withCString { path in
                name.withCString { attribute in
                    removexattr(path, attribute, 0)
                }
            }
            if result != 0, errno == ENOATTR {
                return
            }
        }
        guard result == 0 else {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }
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
