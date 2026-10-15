import Foundation
import AuraTerminalWallpaperCore

enum TerminalAnimationAvailability: Equatable, Sendable {
    case checking
    case installed(String)
    case available(String)
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .checking: return "Checking availability…"
        case .installed: return "Installed on this Mac"
        case .available(let version): return "Available via Homebrew · \(version)"
        case .unavailable(let reason), .failed(let reason): return reason
        }
    }

    var canInstall: Bool {
        if case .available = self { return true }
        return false
    }
}

struct TerminalAnimationPackageMetadata: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let disabled: Bool
    var executables: [String]? = nil
}

protocol TerminalAnimationPackageProviding: Sendable {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata
}

actor SystemTerminalAnimationPackageProvider: TerminalAnimationPackageProviding {
    /// Availability and installation share the same verified in-memory cache.
    static let shared = SystemTerminalAnimationPackageProvider()
    private struct CacheEntry: Codable {
        let date: Date
        let metadata: TerminalAnimationPackageMetadata
    }
    private struct Formula: Decodable {
        let name: String
        let disabled: Bool
        let versions: Versions
        let executables: [String]?
        let tap: String?
        struct Versions: Decodable { let stable: String? }
    }
    private var cache: [String: CacheEntry] = [:]
    private var loadedCache = false
    private var activeRequests = 0
    private var inFlight: [String: Task<TerminalAnimationPackageMetadata, Error>] = [:]
    private let cacheURL: URL?
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        cacheURL: URL? = TerminalWallpaperRuntimeStore.defaultAppSupportURL().appendingPathComponent("package-metadata-cache.json"),
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    ) {
        self.cacheURL = cacheURL; self.now = now; self.fetch = fetch
    }

    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        guard preset.isValid, !preset.formula.isEmpty else {
            throw TerminalWallpaperInstallError.invalidPreset
        }
        if !loadedCache {
            loadedCache = true
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
                cache = stored
            }
        }
        if let entry = cache[preset.formula], entry.metadata.name == preset.formula,
           entry.metadata.executables?.contains(preset.executableName) == true,
           (0..<86_400).contains(now().timeIntervalSince(entry.date)) { return entry.metadata }
        if let pending = inFlight[preset.formula] { return try await pending.value }
        let operation = Task { try await self.fetchMetadata(for: preset) }
        inFlight[preset.formula] = operation
        defer { inFlight[preset.formula] = nil }
        return try await operation.value
    }

    private func fetchMetadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        while activeRequests >= 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        activeRequests += 1
        defer { activeRequests -= 1 }
        var request = URLRequest(url: URL(string: "https://formulae.brew.sh/api/formula/\(preset.formula).json")!)
        request.timeoutInterval = 10
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw TerminalAnimationPackageError.notFound }
            throw URLError(.badServerResponse)
        }
        let formula = try JSONDecoder().decode(Formula.self, from: data)
        guard formula.name == preset.formula, let version = formula.versions.stable, !version.isEmpty,
              formula.tap == "homebrew/core",
              formula.executables?.contains(preset.executableName) == true else {
            throw TerminalAnimationPackageError.invalidResponse
        }
        let metadata = TerminalAnimationPackageMetadata(name: formula.name, version: version, disabled: formula.disabled,
                                                       executables: formula.executables)
        cache[preset.formula] = CacheEntry(date: now(), metadata: metadata)
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        }
        return metadata
    }
}

enum TerminalAnimationPackageError: LocalizedError {
    case notFound, invalidResponse
    var errorDescription: String? {
        switch self {
        case .notFound: return "This package is no longer available in Homebrew."
        case .invalidResponse: return "Homebrew returned invalid package information."
        }
    }
}
