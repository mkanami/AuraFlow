import Foundation
import Testing
@testable import WallpaperControlApp

/// Opt-in CPU benchmark of the values read by the header/grid while scrolling.
/// This measures presentation work, not display FPS or network throughput.
@Test @MainActor func catalogScrollingPresentationBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_CATALOG_SCROLL_BENCHMARK"] == "1" else { return }
    let model = CatalogViewModel()
    model.wallpapers = (0..<600).map { index in
        var item = CatalogWallpaper(id: "scroll-\(index)", title: "Anime scenery \(index)",
            category: index % 2 == 0 ? "Anime" : "Scenic", attribution: "Test",
            previewImageURL: URL(string: "https://wallpaper.test/images/\(index).jpg"),
            sourcePageURL: URL(string: "https://wallpaper.test/wallpapers/\(index)"), sources: [])
        item.hasMusic = index % 10 == 0 ? true : nil
        return item
    }
    var timings: [Double] = [], checksum = 0
    for _ in 0..<30 {
        let start = ProcessInfo.processInfo.systemUptime
        checksum += model.filteredWallpapers.count
        checksum += model.musicCount
        checksum += model.count(in: .anime)
        checksum += model.count(in: .scenic)
        checksum += model.musicCount
        timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    #expect(checksum == 39_600)
    timings.sort()
    print("[catalog-scroll] 600 cards; presentation reads median=\(timings[15]) ms p95=\(timings[28]) ms max=\(timings[29]) ms")
}
