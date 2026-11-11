import Foundation
import Testing
@testable import WallpaperControlApp

/// Opt-in, bounded public-network check. Never starts wallpaper playback or
/// touches Desktop / Lock Screen / preferences. Reads at most 4 KiB per video.
@Test func learnedCatalogLiveHTTPAndMedia() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_LEARNED_CATALOG"] == "1" else { return }
    for site in LearnedAnimeSite.allCases {
        let source = LearnedAnimeSource(site: site, cacheDirectory: nil)
        let items = try await source.fetchCatalog()
        #expect(!items.isEmpty)
        let next = try await source.fetchNextCatalogPage()
        #expect(!next.wallpapers.isEmpty)
        #expect(Set(items.map(\.id)).isDisjoint(with: Set(next.wallpapers.map(\.id))))
        let matches = try await source.searchCatalog(query: "gojo")
        #expect(!matches.isEmpty)
        #expect(try await source.searchCatalog(query: "auraflownoresults9x7z").isEmpty)
        for wallpaper in items.prefix(2) {
            let media = try await source.resolveMedia(for: wallpaper)
            let preview = try #require(media.previewSources.first?.url)
            let original = try #require(media.originalSources.first?.url)
            #expect(preview != original)
            try await learnedProbeVideo(preview, page: wallpaper.sourcePageURL!)
            try await learnedProbeVideo(original, page: wallpaper.sourcePageURL!)
            print("[learned-catalog-live] \(site.title) | \(wallpaper.title) | preview + original MP4 verified")
        }
        print("[learned-catalog-live] \(site.title) | initial=\(items.count) next=\(next.wallpapers.count) gojo=\(matches.count) empty=0")
    }
}

private func learnedProbeVideo(_ url: URL, page: URL) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: 25)
    request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
    request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
    let (bytes, response) = try await session.bytes(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200 || http.statusCode == 206)
    #expect(http.mimeType != "text/html")
    var prefix = Data()
    for try await byte in bytes {
        prefix.append(byte)
        if prefix.count >= 4096 { break }
    }
    #expect(prefix.count >= 12)
    #expect(String(data: prefix.dropFirst(4).prefix(4), encoding: .ascii) == "ftyp")
}
