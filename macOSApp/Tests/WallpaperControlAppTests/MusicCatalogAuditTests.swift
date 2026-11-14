import Foundation
import Testing
@testable import WallpaperControlApp

/// Developer-only metadata refresh. The explicit input/output opt-in keeps this
/// network audit out of normal tests and never changes playback or preferences.
@Test func musicCatalogAuditCandidateAudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["AURAFLOW_MUSIC_AUDIT_INPUT"], let output = env["AURAFLOW_MUSIC_AUDIT_OUTPUT"] else { return }
    let candidates = try JSONDecoder().decode([CatalogWallpaper].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let sources = Dictionary(uniqueKeysWithValues: LearnedAnimeSite.allCases.map { ($0, LearnedAnimeSource(site: $0, cacheDirectory: nil)) })
    try Data("[]".utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
    if candidates.contains(where: { $0.attribution == "Lively Wallpaper" }), let source = sources[.livelywallpaper] { _ = try await source.searchCatalog(query: "anime") }
    var verified: [CatalogWallpaper] = []
    var iterator = candidates.enumerated().makeIterator()
    try await withThrowingTaskGroup(of: (Int, CatalogWallpaper?).self) { group in
        func schedule(_ index: Int, _ item: CatalogWallpaper) {
            group.addTask {
                do {
                    guard !item.explicitlyExcludesMusic, let page = item.sourcePageURL,
                          let site = LearnedAnimeSite.allCases.first(where: { $0.accepts(page) }), let source = sources[site],
                          let url = try await source.resolveMedia(for: item).originalSources.first?.url else { return (index, nil) }
                    let audio = try await MusicWallpaperCatalogProvider.verifyOriginalAudio(url, page)
                    print("[music-audit] \(index) \(audio.rawValue) \(item.id)")
                    guard audio == .audible else { return (index, nil) }
                    var card = item; card.hasMusic = nil
                    return (index, card)
                } catch { print("[music-audit] \(index) unavailable \(item.id): \(error.localizedDescription)"); return (index, nil) }
            }
        }
        for _ in 0..<4 { if let (index, item) = iterator.next() { schedule(index, item) } }
        for try await (_, item) in group {
            if let item {
                verified.append(item)
                let data = try JSONEncoder().encode(verified.sorted { $0.id < $1.id })
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            if let (index, item) = iterator.next() { schedule(index, item) }
        }
    }
    print("[music-audit] confirmed \(verified.count)/\(candidates.count)")
}
