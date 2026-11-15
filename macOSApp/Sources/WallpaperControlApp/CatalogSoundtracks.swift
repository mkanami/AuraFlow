import CryptoKit
import Foundation

struct CatalogSoundtrack: Sendable {
    let id: String
    let title: String
    let author: String
    let page: URL
    let url: URL
    let bytes: Int
    let sha256: String
}

/// Public-domain recordings, explicitly paired with reviewed artwork. IDs,
/// download addresses and fingerprints are bundled rather than supplied by a site.
enum CatalogSoundtracks {
    static let all: [CatalogSoundtrack] = [
        .init(id: "cozy-piano", title: "Cozy Puzzle", author: "MintoDog",
            page: URL(string: "https://opengameart.org/content/cozy-puzzle-in-game-2")!,
            url: URL(string: "https://opengameart.org/sites/default/files/cozy_puzzle_in-game_2_bpm90.mp3")!,
            bytes: 5_122_216, sha256: "bae99bca0d05474323c94a142942af41bc9227aed83ec197a14083a8684cc6dd"),
        .init(id: "our-expanse", title: "Our Expanse", author: "Bobjt",
            page: URL(string: "https://opengameart.org/content/our-expanse")!,
            url: URL(string: "https://opengameart.org/sites/default/files/our_expanse_-_loop-version-.mp3")!,
            bytes: 2_026_336, sha256: "a7345b52b309c8b77cc5f245559a60e5ff6a2ae3ff028b775cd2035a77d05dec"),
        .init(id: "blackout", title: "Blackout", author: "SkyleTheFrench",
            page: URL(string: "https://opengameart.org/content/blackout")!,
            url: URL(string: "https://opengameart.org/sites/default/files/blackout_3mzut0qtwao.mp3")!,
            bytes: 2_879_009, sha256: "8fe1e07fa6edf38fa75ef9fd4a8e7ecee36dbdc6dbbc40638bdcdcca222a8180"),
    ]
    static func track(_ id: String?) -> CatalogSoundtrack? { all.first { $0.id == id } }
}

actor CatalogSoundtrackCache {
    static let shared = CatalogSoundtrackCache()
    typealias Download = @Sendable (URL) async throws -> Data
    typealias Inspect = @Sendable (URL) async throws -> WallpaperAudioContent
    private let tracks: [CatalogSoundtrack]
    private let directory: URL
    private let download: Download
    private let inspect: Inspect
    private var jobs: [String: Task<URL, Error>] = [:]

    init(tracks: [CatalogSoundtrack] = CatalogSoundtracks.all, directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AuraFlow/Soundtracks", isDirectory: true),
         download: @escaping Download = { url in
             var request = URLRequest(url: url)
             request.timeoutInterval = 45
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                   response.url?.scheme == "https", response.url?.host == "opengameart.org",
                   data.count <= 8_000_000 else { throw URLError(.badServerResponse) }
             return data
         }, inspect: @escaping Inspect = { try await WallpaperAudioInspector.inspect(url: $0) }) {
        self.tracks = tracks; self.directory = directory; self.download = download; self.inspect = inspect
    }

    func file(for id: String) async throws -> URL {
        guard let track = tracks.first(where: { $0.id == id }) else { throw URLError(.unsupportedURL) }
        if let job = jobs[id] { return try await job.value }
        let directory = directory, download = download, inspect = inspect
        let task = Task<URL, Error> {
            let url = directory.appendingPathComponent(track.id + ".mp3")
            func valid(_ data: Data) -> Bool {
                data.count == track.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == track.sha256
            }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), valid(data),
               try await inspect(url) == .audible { return url }
            let data = try await download(track.url)
            guard valid(data) else { throw URLError(.cannotDecodeContentData) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            guard try await inspect(url) == .audible else {
                try? FileManager.default.removeItem(at: url)
                throw URLError(.cannotDecodeContentData)
            }
            return url
        }
        jobs[id] = task
        do { return try await task.value }
        catch { jobs[id] = nil; throw error }
    }
}
