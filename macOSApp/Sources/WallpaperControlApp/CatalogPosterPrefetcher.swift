import Combine
import Foundation

/// A small poster-only working set. It never resolves or downloads wallpaper
/// videos, and shares in-flight requests with visible image loaders.
@MainActor
final class CatalogPosterPrefetcher: ObservableObject {
    private let session: URLSession
    private var wallpapers: [CatalogWallpaper] = []
    private var visibleIDs: Set<String> = []
    private var previousCenter: Int?
    private var loaders: [URL: CatalogPreviewImageLoader] = [:]
    private var updateTask: Task<Void, Never>?

    init(session: URLSession = .shared) { self.session = session }
    deinit { updateTask?.cancel() }

    func update(wallpapers: [CatalogWallpaper]) {
        self.wallpapers = wallpapers
        visibleIDs.formIntersection(wallpapers.map(\.id))
        schedule()
    }

    func setVisible(_ id: String, _ visible: Bool) {
        if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
        schedule()
    }

    func cancel() {
        updateTask?.cancel()
        updateTask = nil
        for loader in loaders.values { loader.cancel() }
        loaders.removeAll()
        visibleIDs.removeAll()
        wallpapers.removeAll()
        previousCenter = nil
    }

    private func schedule() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            // Coalesce a row's appearance callbacks and let visible posters
            // acquire their permits before speculative work starts.
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
            self?.prepareLookahead()
        }
    }

    private func prepareLookahead() {
        let plan = CatalogPreviewViewportPlan.make(wallpaperIDs: wallpapers.map(\.id),
            visibleIDs: visibleIDs, previousCenterIndex: previousCenter)
        previousCenter = plan?.centerIndex
        let byID = Dictionary(wallpapers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ahead = (plan?.lookaheadIDs ?? []).prefix(12).compactMap { byID[$0] }
        let urls = Set(ahead.compactMap(\.previewImageURL))
        for url in Array(loaders.keys) where !urls.contains(url) {
            loaders.removeValue(forKey: url)?.cancel()
        }
        for wallpaper in ahead {
            guard let url = wallpaper.previewImageURL, loaders[url] == nil else { continue }
            let loader = CatalogPreviewImageLoader(session: session)
            loaders[url] = loader
            loader.load(url: url, referer: wallpaper.sourcePageURL, priority: .lookahead)
        }
    }
}
