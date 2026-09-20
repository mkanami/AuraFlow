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
    @Published private(set) var scrollRequestGeneration: UInt = 0
    @Published var searchText = ""
    @Published var selectedGroup: CatalogWallpaperGroup?
    @Published var downloadID: String?
    @Published var wallpapers: [CatalogWallpaper] = []
    @Published var searchResults: [CatalogWallpaper] = []
    @Published var isRefreshing = false
    @Published var isLoadingMore = false
    @Published var isSearching = false
    @Published var hasMoreWallpapers = true
    @Published var downloadedWallpapers: [DownloadedCatalogWallpaper] = []

    private let catalogDisplayPageSize = 12
    private let searchDisplayPageSize = 24
    private var deferredWallpapers: [CatalogWallpaper] = []
    private var deferredSearchResults: [CatalogWallpaper] = []
    private var hasMoreRemoteWallpapers = false

    var filteredWallpapers: [CatalogWallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableWallpapers: [CatalogWallpaper]
        if query.isEmpty {
            availableWallpapers = wallpapers
        } else {
            var seen = Set<String>()
            availableWallpapers = (wallpapers + searchResults).filter {
                seen.insert($0.id).inserted
            }
        }

        let groupFiltered = availableWallpapers.filter { wallpaper in
            guard let selectedGroup else { return true }
            return wallpaper.catalogGroup == selectedGroup
        }
        guard !query.isEmpty else { return groupFiltered }
        return groupFiltered.filter { wallpaper in
            WallpaperSearchMatcher.matches(
                query: query,
                fields: [
                    wallpaper.title,
                    wallpaper.category,
                    wallpaper.attribution,
                    wallpaper.id,
                    wallpaper.sourcePageURL?.absoluteString ?? "",
                    wallpaper.previewImageURL?.absoluteString ?? "",
                ]
            )
        }
    }

    func resetCatalogNavigation() {
        selectedWallpaper = nil
        scrollTargetID = nil
        selectedGroup = nil
    }

    func toggleGroup(_ group: CatalogWallpaperGroup) {
        selectedGroup = selectedGroup == group ? nil : group
        requestScroll(to: filteredWallpapers.first?.id)
    }

    func requestScroll(to wallpaperID: String?) {
        scrollTargetID = wallpaperID
        guard wallpaperID != nil else { return }
        scrollRequestGeneration &+= 1
    }

    func count(in group: CatalogWallpaperGroup) -> Int {
        wallpapers.filter { $0.catalogGroup == group }.count
    }

    var hasDeferredWallpapers: Bool {
        !deferredWallpapers.isEmpty
    }

    var hasDeferredSearchResults: Bool {
        !deferredSearchResults.isEmpty
    }

    func setWallpapersDirectly(_ wallpapers: [CatalogWallpaper]) {
        self.wallpapers = wallpapers
        deferredWallpapers = []
        hasMoreRemoteWallpapers = false
    }

    func setSearchResultsDirectly(_ results: [CatalogWallpaper]) {
        searchResults = results
        deferredSearchResults = []
    }

    func appendSearchResults(_ additions: [CatalogWallpaper]) {
        var seen = Set(searchResults.map(\.id))
        seen.formUnion(deferredSearchResults.map(\.id))
        let uniqueAdditions = additions.filter { seen.insert($0.id).inserted }
        guard !uniqueAdditions.isEmpty else { return }

        let availableSlots = max(0, searchDisplayPageSize - searchResults.count)
        searchResults.append(contentsOf: uniqueAdditions.prefix(availableSlots))
        deferredSearchResults.append(contentsOf: uniqueAdditions.dropFirst(availableSlots))
    }

    @discardableResult
    func loadNextSearchPage() -> Bool {
        guard !deferredSearchResults.isEmpty else { return false }
        let page = Array(deferredSearchResults.prefix(searchDisplayPageSize))
        deferredSearchResults.removeFirst(page.count)
        searchResults.append(contentsOf: page)
        return true
    }

    func replaceCatalogForDisplay(
        with allWallpapers: [CatalogWallpaper],
        hasMoreRemotePages: Bool
    ) {
        let uniqueWallpapers = Self.deduplicated(allWallpapers)
        wallpapers = Array(uniqueWallpapers.prefix(catalogDisplayPageSize))
        deferredWallpapers = Array(uniqueWallpapers.dropFirst(catalogDisplayPageSize))
        hasMoreRemoteWallpapers = hasMoreRemotePages
        hasMoreWallpapers = !deferredWallpapers.isEmpty || hasMoreRemotePages
    }

    @discardableResult
    func loadNextDeferredPage() -> Bool {
        guard !deferredWallpapers.isEmpty else { return false }
        let page = Array(deferredWallpapers.prefix(catalogDisplayPageSize))
        deferredWallpapers.removeFirst(page.count)
        wallpapers.append(contentsOf: page)
        hasMoreWallpapers = !deferredWallpapers.isEmpty || hasMoreRemoteWallpapers
        return true
    }

    func appendCatalogPage(
        mergedWallpapers: [CatalogWallpaper],
        hasMoreRemotePages: Bool
    ) {
        var seen = Set(wallpapers.map(\.id))
        let additions = mergedWallpapers.filter { seen.insert($0.id).inserted }
        wallpapers.append(contentsOf: additions)
        deferredWallpapers = []
        hasMoreRemoteWallpapers = hasMoreRemotePages
        hasMoreWallpapers = hasMoreRemotePages
    }

    func isDownloading(_ wallpaper: CatalogWallpaper) -> Bool {
        downloadID == wallpaper.id
    }

    private static func deduplicated(_ wallpapers: [CatalogWallpaper]) -> [CatalogWallpaper] {
        var seen = Set<String>()
        return wallpapers.filter { seen.insert($0.id).inserted }
    }
}
