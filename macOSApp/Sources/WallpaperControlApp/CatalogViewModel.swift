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
    @Published var showsMusicOnly = false
    @Published var audioStatus: [String: Bool] = [:]
    @Published var downloadID: String?
    @Published var downloadProgress: CatalogDownloadProgress?
    @Published var isDownloadCancelling = false
    @Published var wallpapers: [CatalogWallpaper] = []
    @Published var searchResults: [CatalogWallpaper] = []
    @Published var isRefreshing = false
    @Published var isLoadingMore = false
    @Published var isSearching = false
    @Published var hasMoreWallpapers = true
    @Published var hasMoreMusicWallpapers = true
    @Published var loadMoreFailed = false
    @Published var automaticPaginationPaused = false
    @Published var downloadedWallpapers: [DownloadedCatalogWallpaper] = []

    var visibleDownloadedWallpapers: [DownloadedCatalogWallpaper] {
        downloadedWallpapers.filter(CatalogContentPolicy.allows)
    }

    private let catalogDisplayPageSize = 12
    private let searchDisplayPageSize = 24
    private var deferredWallpapers: [CatalogWallpaper] = []
    private var deferredSearchResults: [CatalogWallpaper] = []
    private var hasMoreRemoteWallpapers = false

    var filteredWallpapers: [CatalogWallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableWallpapers: [CatalogWallpaper]
        if query.isEmpty {
            availableWallpapers = showsMusicOnly ? Self.deduplicated(wallpapers + deferredWallpapers) : wallpapers
        } else {
            availableWallpapers = Self.deduplicated(wallpapers + (showsMusicOnly ? deferredWallpapers : []) + searchResults)
        }

        let groupFiltered = availableWallpapers.filter { wallpaper in
            if showsMusicOnly { return containsMusic(wallpaper) }
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
        showsMusicOnly = false
    }

    func toggleGroup(_ group: CatalogWallpaperGroup) {
        showsMusicOnly = false
        selectedGroup = selectedGroup == group ? nil : group
        requestScroll(to: filteredWallpapers.first?.id)
    }

    func toggleMusic() {
        showsMusicOnly.toggle()
        if showsMusicOnly { revealDeferredMusic() }
        selectedGroup = nil
        requestScroll(to: filteredWallpapers.first?.id)
    }

    var musicCount: Int {
        Self.deduplicated(wallpapers + deferredWallpapers).filter { containsMusic($0) }.count
    }

    private func containsMusic(_ wallpaper: CatalogWallpaper) -> Bool {
        wallpaper.hasMusic == true && !wallpaper.explicitlyExcludesMusic && audioStatus[wallpaper.id] != false
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

    var canLoadMore: Bool {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hasDeferredSearchResults
        }
        if showsMusicOnly { return hasMoreMusicWallpapers || deferredWallpapers.contains(where: containsMusic) }
        return hasMoreWallpapers && (hasDeferredWallpapers || selectedGroup == nil || selectedGroup == .anime)
    }

    func setWallpapersDirectly(_ wallpapers: [CatalogWallpaper]) {
        self.wallpapers = wallpapers
        deferredWallpapers = []
        hasMoreRemoteWallpapers = false
        hasMoreMusicWallpapers = false
    }

    func setSearchResultsDirectly(_ results: [CatalogWallpaper]) {
        searchResults = results
        deferredSearchResults = []
    }

    func appendSearchResults(_ additions: [CatalogWallpaper]) {
        guard !additions.isEmpty else { return }
        let merged = CatalogWallpaperMerge.combining(searchResults + deferredSearchResults, additions)
        let displayedCount = max(searchDisplayPageSize, searchResults.count)
        searchResults = Array(merged.prefix(displayedCount))
        deferredSearchResults = Array(merged.dropFirst(displayedCount))
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
        // A refresh must not fold already expanded cached pages back to twelve
        // cards while the user is scrolling them.
        let displayedCount = max(catalogDisplayPageSize, wallpapers.count)
        wallpapers = Array(uniqueWallpapers.prefix(displayedCount))
        deferredWallpapers = Array(uniqueWallpapers.dropFirst(displayedCount))
        hasMoreRemoteWallpapers = hasMoreRemotePages
        if showsMusicOnly { revealDeferredMusic() }
        hasMoreWallpapers = !deferredWallpapers.isEmpty || hasMoreRemotePages
    }

    @discardableResult
    func loadNextDeferredPage() -> Bool {
        guard !deferredWallpapers.isEmpty else { return false }
        if showsMusicOnly {
            revealDeferredMusic()
            wallpapers = Self.deduplicated(wallpapers + deferredWallpapers)
            deferredWallpapers = []
            hasMoreWallpapers = hasMoreRemoteWallpapers
            return false
        }
        let page = Array(deferredWallpapers.prefix(catalogDisplayPageSize))
        deferredWallpapers.removeFirst(page.count)
        wallpapers.append(contentsOf: page)
        hasMoreWallpapers = !deferredWallpapers.isEmpty || hasMoreRemoteWallpapers
        return true
    }

    func appendCatalogPage(
        mergedWallpapers: [CatalogWallpaper],
        hasMoreRemotePages: Bool,
        musicOnly: Bool = false
    ) {
        wallpapers = CatalogWallpaperMerge.combining(wallpapers, mergedWallpapers)
        deferredWallpapers = []
        if musicOnly {
            hasMoreMusicWallpapers = hasMoreRemotePages
        } else {
            hasMoreRemoteWallpapers = hasMoreRemotePages
            hasMoreWallpapers = hasMoreRemotePages
        }
    }

    private func revealDeferredMusic() {
        let music = deferredWallpapers.filter { containsMusic($0) }
        wallpapers = Self.deduplicated(wallpapers + music)
        let ids = Set(music.map(\.id))
        deferredWallpapers.removeAll { ids.contains($0.id) }
    }

    func isDownloading(_ wallpaper: CatalogWallpaper) -> Bool {
        downloadID == wallpaper.id
    }

    private static func deduplicated(_ wallpapers: [CatalogWallpaper]) -> [CatalogWallpaper] {
        CatalogWallpaperMerge.combining([], wallpapers)
    }
}
