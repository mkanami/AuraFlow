import AuraTerminalWallpaperCore
import Foundation

protocol TerminalProgramSearchProviding: Sendable {
    func search(_ query: String) async throws -> [TerminalWallpaperPreset]
}

/// Official core formula metadata only: no casks, arbitrary web results, taps
/// or downloaded launch commands. Libraries without executables are excluded.
actor SystemTerminalProgramSearchProvider: TerminalProgramSearchProviding {
    struct Formula: Codable, Sendable {
        let name: String
        let desc: String?
        let tap: String
        let disabled: Bool
        let executables: [String]?
        var versions: Versions? = nil
        struct Versions: Codable, Sendable { let stable: String? }
    }
    private struct Cache: Codable {
        let date: Date
        let formulae: [Formula]
    }
    private var cache: Cache?
    private var inFlight: Task<Cache, Error>?
    private let cacheURL: URL?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(cacheURL: URL? = TerminalWallpaperRuntimeStore.defaultAppSupportURL().appendingPathComponent("full-program-search-cache-v2.json"),
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
             return (data, response)
         }) {
        self.cacheURL = cacheURL; self.fetch = fetch
    }

    func search(_ query: String) async throws -> [TerminalWallpaperPreset] {
        let query = TerminalProgramSearchRanking.normalize(query)
        guard !query.isEmpty else { return [] }
        if cache == nil, let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            cache = try? JSONDecoder().decode(Cache.self, from: data)
        }
        if cache == nil || Date().timeIntervalSince(cache!.date) >= 86_400 {
            if inFlight == nil {
                let fetch = fetch
                inFlight = Task {
                    var request = URLRequest(url: URL(string: "https://formulae.brew.sh/api/formula.json")!)
                    request.timeoutInterval = 10
                    let (data, response) = try await fetch(request)
                    guard response.statusCode == 200, data.count <= 64 * 1024 * 1024 else { throw URLError(.badServerResponse) }
                    let entries = try JSONDecoder().decode([Formula].self, from: data)
                    return Cache(date: Date(), formulae: entries.filter { formula in
                        formula.tap == "homebrew/core" && !formula.disabled && TerminalProgramDefinition.validName(formula.name)
                            && formula.executables?.contains(where: TerminalProgramDefinition.validName) == true
                    })
                }
            }
            if let cache {
                let refresh = inFlight!
                Task { [weak self] in
                    guard let refreshed = try? await refresh.value else {
                        await self?.refreshFailed()
                        return
                    }
                    await self?.store(refreshed)
                }
                return Self.results(query: query, formulae: cache.formulae)
            }
            do {
                cache = try await inFlight!.value
                inFlight = nil
                if let cacheURL, let cache {
                    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
                }
            } catch {
                inFlight = nil
                if let cache { return Self.results(query: query, formulae: cache.formulae) }
                throw error
            }
        }
        try Task.checkCancellation()
        return Self.results(query: query, formulae: cache?.formulae ?? [])
    }

    private func refreshFailed() { inFlight = nil }

    private func store(_ refreshed: Cache) {
        cache = refreshed
        inFlight = nil
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(refreshed).write(to: cacheURL, options: .atomic)
        }
    }

    static func results(query: String, formulae: [Formula]) -> [TerminalWallpaperPreset] {
        let query = TerminalProgramSearchRanking.normalize(query)
        guard !query.isEmpty else { return [] }
        var scored: [(TerminalWallpaperPreset, Int)] = []
        for formula in formulae where formula.tap == "homebrew/core" && !formula.disabled
            && TerminalProgramDefinition.validName(formula.name) {
            for name in formula.executables ?? [] where TerminalProgramDefinition.validName(name) {
                let score = name == query ? 5 : formula.name == query ? 4
                    : name.hasPrefix(query) || formula.name.hasPrefix(query) ? 3
                    : name.contains(query) || formula.name.contains(query) ? 2
                    : (query.count >= 3 && formula.desc?.localizedCaseInsensitiveContains(query) == true ? 1 : 0)
                guard score > 0 else { continue }
                let definition = TerminalProgramDefinition(id: "brew:\(formula.name):\(name)", name: name,
                                                           formula: formula.name, executable: nil)
                scored.append((.init(id: definition.id, description: formula.desc ?? definition.preset.description,
                                     formula: formula.name, program: definition), score))
            }
        }
        let matches = scored.sorted {
            $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
        }.map(\.0)
        return Array(TerminalProgramSearchRanking.presets(matches, query: query).prefix(24))
    }
}
