import Foundation
import Testing
@testable import WallpaperControlApp

/// Developer-only metadata refresh. The explicit input/output opt-in keeps this
/// network audit out of normal tests and never changes playback or preferences.
@Test func musicCatalogAuditCandidateAudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["AURAFLOW_MUSIC_AUDIT_INPUT"], let output = env["AURAFLOW_MUSIC_AUDIT_OUTPUT"] else { return }
    let candidates = try JSONDecoder().decode([CatalogWallpaper].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    try #require(!candidates.isEmpty, "The audit input must contain wallpaper candidates.")
    let sources = Dictionary(uniqueKeysWithValues: LearnedAnimeSite.allCases.map { ($0, LearnedAnimeSource(site: $0, cacheDirectory: nil)) })
    let excludedURLs: Set<URL>
    if env["AURAFLOW_MUSIC_AUDIT_EXCLUDE_CURRENT"] == "1" {
        excludedURLs = await musicAuditOriginalURLs(MusicWallpaperCatalogProvider.bundledSelections(), sources: sources)
        print("[music-audit] excluding \(excludedURLs.count) existing original videos")
    } else { excludedURLs = [] }
    try Data("[]".utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
    if candidates.contains(where: { $0.attribution == "Lively Wallpaper" }), let source = sources[.livelywallpaper] { _ = try await source.searchCatalog(query: "anime") }
    var verified: [CatalogWallpaper] = []
    var originals = excludedURLs
    var proofs: [MusicAuditProof] = []
    var iterator = candidates.enumerated().makeIterator()
    try await withThrowingTaskGroup(of: (Int, CatalogWallpaper?, URL?).self) { group in
        func schedule(_ index: Int, _ item: CatalogWallpaper) {
            group.addTask {
                do {
                    guard !item.explicitlyExcludesMusic, let page = item.sourcePageURL,
                          let site = LearnedAnimeSite.allCases.first(where: { $0.accepts(page) }), let source = sources[site],
                          let url = try await source.resolveMedia(for: item).originalSources.first?.url else { return (index, nil, nil) }
                    guard !excludedURLs.contains(url) else {
                        print("[music-audit] \(index) existing-original \(item.id)")
                        return (index, nil, nil)
                    }
                    let audio = try await MusicWallpaperCatalogProvider.verifyOriginalAudio(url, page)
                    print("[music-audit] \(index) \(audio.rawValue) \(item.id)")
                    guard audio == .audible else { return (index, nil, nil) }
                    var card = item; card.hasMusic = nil
                    return (index, card, url)
                } catch { print("[music-audit] \(index) unavailable \(item.id): \(error.localizedDescription)"); return (index, nil, nil) }
            }
        }
        for _ in 0..<4 { if let (index, item) = iterator.next() { schedule(index, item) } }
        for try await (_, item, original) in group {
            if let item, let original, originals.insert(original).inserted {
                verified.append(item)
                proofs.append(MusicAuditProof(id: item.id, originalURL: original, checkedAt: Date()))
                let data = try JSONEncoder().encode(verified.sorted { $0.id < $1.id })
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(proofs).write(to: URL(fileURLWithPath: output + ".proof.json"), options: .atomic)
            }
            if let (index, item) = iterator.next() { schedule(index, item) }
        }
    }
    print("[music-audit] confirmed \(verified.count)/\(candidates.count)")
}

private struct MusicAuditProof: Codable {
    let id: String
    let originalURL: URL
    let checkedAt: Date
}

/// Resolve the existing selection with the same four-request limit. Different
/// source pages that expose an already-shipped original do not count as additions.
private func musicAuditOriginalURLs(_ items: [CatalogWallpaper], sources: [LearnedAnimeSite: LearnedAnimeSource]) async -> Set<URL> {
    var iterator = items.makeIterator()
    return await withTaskGroup(of: URL?.self) { group in
        func schedule() {
            guard let item = iterator.next() else { return }
            group.addTask {
                guard let page = item.sourcePageURL,
                      let site = LearnedAnimeSite.allCases.first(where: { $0.accepts(page) }), let source = sources[site] else { return nil }
                return try? await source.resolveMedia(for: item).originalSources.first?.url
            }
        }
        for _ in 0..<4 { schedule() }
        var urls = Set<URL>()
        for await url in group {
            if let url { urls.insert(url) }
            schedule()
        }
        return urls
    }
}
