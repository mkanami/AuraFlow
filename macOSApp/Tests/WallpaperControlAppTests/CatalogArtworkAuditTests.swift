import Foundation
import Testing
@testable import WallpaperControlApp

/// Explicit developer audit only; resolves public previews without playing or
/// changing wallpapers. Visual decisions are stored separately from media.
@Test func catalogArtworkAuditResolvesPreviewVideos() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["AURAFLOW_ARTWORK_AUDIT_INPUT"], let output = env["AURAFLOW_ARTWORK_AUDIT_OUTPUT"] else { return }
    let items = try JSONDecoder().decode([CatalogWallpaper].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let source = AnimeWallpaperCatalogProvider()
    var iterator = items.makeIterator()
    var records: [ArtworkAuditMedia] = []
    await withTaskGroup(of: ArtworkAuditMedia?.self) { group in
        func schedule() {
            guard let item = iterator.next() else { return }
            group.addTask {
                do {
                    let media = try await source.resolveMedia(for: item)
                    guard let preview = media.previewSources.first?.url, let original = media.originalSources.first?.url else { return nil }
                    return ArtworkAuditMedia(id: item.id, title: item.title, sourcePageURL: item.sourcePageURL,
                        previewURL: preview, originalURL: original)
                } catch { print("[artwork-audit] unavailable \(item.id)"); return nil }
            }
        }
        for _ in 0..<4 { schedule() }
        for await record in group {
            if let record { records.append(record) }
            schedule()
        }
    }
    try JSONEncoder().encode(records).write(to: URL(fileURLWithPath: output), options: .atomic)
    print("[artwork-audit] resolved \(records.count)/\(items.count) preview videos")
}

private struct ArtworkAuditMedia: Codable, Sendable {
    let id: String
    let title: String
    let sourcePageURL: URL?
    let previewURL: URL
    let originalURL: URL
}
