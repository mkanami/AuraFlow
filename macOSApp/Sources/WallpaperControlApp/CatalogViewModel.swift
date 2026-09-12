import Combine
import Foundation

/// UI state for the catalog and downloaded-wallpaper browser.
///
/// Networking and cache I/O live in `CatalogDownloadService`; this object only
/// owns presentation state so catalog changes do not inflate the application
/// orchestration model.
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var isCatalogOpen = false
    @Published var isDownloadedWallpapersOpen = false
    @Published var selectedWallpaper: CatalogWallpaper?
    @Published var scrollTargetID: String?
    @Published var searchText = ""
    @Published var selectedGroup: CatalogWallpaperGroup?
    @Published var downloadID: String?
    @Published var wallpapers: [CatalogWallpaper] = []
    @Published var isRefreshing = false
    @Published var downloadedWallpapers: [DownloadedCatalogWallpaper] = []

    var filteredWallpapers: [CatalogWallpaper] {
        let groupFiltered = wallpapers.filter { wallpaper in
            guard let selectedGroup else { return true }
            return wallpaper.catalogGroup == selectedGroup
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupFiltered }
        return groupFiltered.filter { wallpaper in
            wallpaper.title.localizedCaseInsensitiveContains(query)
                || wallpaper.category.localizedCaseInsensitiveContains(query)
        }
    }

    func resetCatalogNavigation() {
        selectedWallpaper = nil
        scrollTargetID = nil
        selectedGroup = nil
    }

    func toggleGroup(_ group: CatalogWallpaperGroup) {
        selectedGroup = selectedGroup == group ? nil : group
        scrollTargetID = filteredWallpapers.first?.id
    }

    func count(in group: CatalogWallpaperGroup) -> Int {
        wallpapers.filter { $0.catalogGroup == group }.count
    }

    func isDownloading(_ wallpaper: CatalogWallpaper) -> Bool {
        downloadID == wallpaper.id
    }
}
