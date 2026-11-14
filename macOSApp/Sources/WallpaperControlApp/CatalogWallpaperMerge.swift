import Foundation

enum CatalogWallpaperMerge {
    /// Preserve card order and the original route while accepting a later
    /// decoded-audio result for the same wallpaper ID.
    static func combining(_ existing: [CatalogWallpaper], _ additions: [CatalogWallpaper]) -> [CatalogWallpaper] {
        var indices: [String: Int] = [:]
        var result: [CatalogWallpaper] = []
        for wallpaper in existing + additions {
            guard CatalogContentPolicy.allows(wallpaper) else { continue }
            if let index = indices[wallpaper.id] {
                if wallpaper.hasMusic == true { result[index].hasMusic = true }
            } else {
                indices[wallpaper.id] = result.count
                result.append(wallpaper)
            }
        }
        return result
    }
}

extension CatalogWallpaper {
    var explicitlyExcludesMusic: Bool {
        title.range(of: #"\b(no|without)\s+(music|audio|sound)\b|без\s+(музыки|звука)"#,
            options: .caseInsensitive.union(.regularExpression)) != nil
    }
}
