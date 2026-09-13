import Foundation
import Testing
@testable import WallpaperControlApp

@Test func liveAllCatalogCardsResolveToReachableMedia() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_ALL_CATALOG_CARDS"] == "1" else {
        return
    }

    let providers: [(name: String, provider: any WallpaperCatalogProviding)] = [
        ("MoeWalls", MoeWallsSource()),
        ("MotionBGS", MotionBGSAnimeNatureSource()),
        ("Dareful", DarefulSource()),
    ]

    var failures: [String] = []
    for entry in providers {
        do {
            let catalog = try await withTimeout(seconds: 90) {
                try await entry.provider.fetchCatalog()
            }
            guard !catalog.isEmpty else {
                failures.append(entry.name + ": catalog is empty")
                continue
            }

            print("[catalog-all-cards] " + entry.name + ": checking " + String(catalog.count) + " cards")
            let providerFailures = await checkAllCatalogCards(
                catalog,
                provider: entry.provider,
                providerName: entry.name
            )
            failures.append(contentsOf: providerFailures)
        } catch {
            failures.append(entry.name + ": catalog fetch failed: " + error.localizedDescription)
        }
    }

    if !failures.isEmpty {
        throw CatalogAllCardsSmokeError(failures.joined(separator: "\n"))
    }
}

@Test func liveCatalogPreviewMediaRangesEveryProvider() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_PREVIEW_SMOKE"] == "1" else {
        return
    }

    let moeWalls = CatalogWallpaper(
        id: "moewalls-nephis-shadow-slave-live-wallpaper",
        title: "Nephis Shadow Slave",
        category: "Anime",
        attribution: "MoeWalls",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://moewalls.com/anime/nephis-shadow-slave-live-wallpaper/")!,
        sources: [CatalogVideoSource(
            url: URL(string: "https://moewalls.com/wp-content/uploads/preview/2026/nephis-shadow-slave-preview.webm")!,
            width: 1920,
            height: 1080
        )]
    )
    try await probeMediaSource(moeWalls.sources[0].url, wallpaper: moeWalls)
    print("[catalog-preview] MoeWalls: real streaming media range ready")

    let nativeSamples: [(String, CatalogWallpaper, any WallpaperCatalogPreviewResolving)] = [
        (
            "MotionBGS",
            CatalogWallpaper(
                id: "motionbgs-anime-nature-summer-mountain-paradise",
                title: "Summer Mountain Paradise",
                category: "Anime Nature",
                attribution: "MotionBGS",
                previewImageURL: nil,
                sourcePageURL: URL(string: "https://motionbgs.com/summer-mountain-paradise")!,
                sources: []
            ),
            MotionBGSAnimeNatureSource()
        ),
        (
            "Dareful",
            CatalogWallpaper(
                id: "dareful-52",
                title: "Las Vegas Strip Sunset 4k",
                category: "Scenic",
                attribution: "Dareful",
                previewImageURL: nil,
                sourcePageURL: URL(string: "https://dareful.com/free-4k-time-lapse-stock-video-las-vegas-strip-sunset/")!,
                sources: []
            ),
            DarefulSource()
        ),
    ]
    for (name, wallpaper, provider) in nativeSamples {
        let sources = try await withTimeout(seconds: 45) {
            try await provider.resolvePreviewSources(for: wallpaper)
        }
        let source = try #require(sources.first)
        try await probeMediaSource(source.url, wallpaper: wallpaper)
        print("[catalog-preview] \(name): real preview media range ready")
    }
}

private func withTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw CatalogAllCardsSmokeError("Timed out after \(seconds) seconds")
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CatalogAllCardsSmokeError("Timed out without a result")
        }
        return result
    }
}

private func checkAllCatalogCards(
    _ catalog: [CatalogWallpaper],
    provider: any WallpaperCatalogProviding,
    providerName: String
) async -> [String] {
    var failures: [String] = []

    for wallpaper in catalog {
        do {
            let candidates = try await candidateSources(for: wallpaper, provider: provider)
            guard !candidates.isEmpty else {
                failures.append(providerName + " / " + wallpaper.id + ": no download candidates")
                continue
            }

            var candidateErrors: [String] = []
            var reachable = await probeCandidates(
                candidates,
                wallpaper: wallpaper,
                errors: &candidateErrors
            )

            // Listing previews can become stale while the detail page still
            // exposes the current playable asset. Mirror the app's fallback
            // route for those cards instead of declaring them broken early.
            if !reachable,
               let moeWallsProvider = provider as? MoeWallsSource,
               let pageURL = wallpaper.sourcePageURL,
               let details = await fetchMoeWallsDetailsWithRetry(
                   from: moeWallsProvider,
                   pageURL: pageURL,
                   errors: &candidateErrors
               ) {
                var detailCandidates: [URL] = []
                if let downloadURL = details.downloadURL {
                    detailCandidates.append(downloadURL)
                }
                if let previewVideoURL = details.previewVideoURL {
                    detailCandidates.append(previewVideoURL)
                    if previewVideoURL.pathExtension.lowercased() == "webm" {
                        detailCandidates.append(
                            previewVideoURL.deletingPathExtension().appendingPathExtension("mp4")
                        )
                    }
                }
                reachable = await probeCandidates(
                    detailCandidates,
                    wallpaper: wallpaper,
                    errors: &candidateErrors
                )
            }

            if !reachable {
                failures.append(
                    providerName + " / " + wallpaper.id + " / " + wallpaper.title + ": " +
                    candidateErrors.joined(separator: " | ")
                )
            }
        } catch {
            failures.append(providerName + " / " + wallpaper.id + " / " + wallpaper.title + ": " + error.localizedDescription)
        }
    }

    return failures
}

private func candidateSources(
    for wallpaper: CatalogWallpaper,
    provider: any WallpaperCatalogProviding
) async throws -> [URL] {
    var candidates: [URL]
    if let previewProvider = provider as? any WallpaperCatalogPreviewResolving {
        candidates = try await previewProvider.resolvePreviewSources(for: wallpaper).map(\.url)
    } else {
        candidates = wallpaper.sources.map(\.url)
    }

    if candidates.isEmpty,
       let moeWallsProvider = provider as? MoeWallsSource,
       let pageURL = wallpaper.sourcePageURL,
       let details = try? await moeWallsProvider.fetchDetails(pageURL: pageURL) {
        if let downloadURL = details.downloadURL {
            candidates.append(downloadURL)
        }
        if let previewVideoURL = details.previewVideoURL {
            candidates.append(previewVideoURL)
            if previewVideoURL.pathExtension.lowercased() == "webm" {
                candidates.append(previewVideoURL.deletingPathExtension().appendingPathExtension("mp4"))
            }
        }
    }

    if candidates.isEmpty || wallpaper.catalogGroup != .anime {
        candidates.append(try await provider.resolveDownloadURL(for: wallpaper))
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0.absoluteString).inserted }
}

private func fetchMoeWallsDetailsWithRetry(
    from provider: MoeWallsSource,
    pageURL: URL,
    errors: inout [String]
) async -> MoeWallsWallpaper? {
    for attempt in 0..<3 {
        do {
            return try await provider.fetchDetails(pageURL: pageURL)
        } catch {
            if attempt == 2 {
                errors.append("detail page: " + error.localizedDescription)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    return nil
}

private func probeCandidates(
    _ candidates: [URL],
    wallpaper: CatalogWallpaper,
    errors: inout [String]
) async -> Bool {
    for candidate in candidates {
        do {
            try await probeMediaSource(candidate, wallpaper: wallpaper)
            return true
        } catch {
            errors.append(candidate.absoluteString + ": " + error.localizedDescription)
        }
    }
    return false
}

private func probeMediaSource(
    _ sourceURL: URL,
    wallpaper: CatalogWallpaper
) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    var rangeRequest = makeProbeRequest(sourceURL, wallpaper: wallpaper)
    rangeRequest.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
    let (data, response) = try await session.data(for: rangeRequest)
    try validateMediaResponse(response, sourceURL: sourceURL)
    guard data.count > 1_024 else {
        throw CatalogAllCardsSmokeError("Media range returned too little data")
    }
}

private func makeProbeRequest(
    _ sourceURL: URL,
    wallpaper: CatalogWallpaper
) -> URLRequest {
    var request = URLRequest(url: sourceURL)
    request.timeoutInterval = 25
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue(
        shouldUseBrowserStyleHeaders(for: sourceURL, wallpaper: wallpaper)
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
            : "AuraFlow/1.1",
        forHTTPHeaderField: "User-Agent"
    )
    if let pageURL = wallpaper.sourcePageURL {
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        if sourceURL.host?.contains("moewalls.com") == true,
           let origin = catalogOriginHeaderValue(for: pageURL) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
    }
    return request
}

private func validateMediaResponse(_ response: URLResponse, sourceURL: URL) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
        throw CatalogAllCardsSmokeError("Non-HTTP response")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
        throw CatalogAllCardsSmokeError("HTTP \(httpResponse.statusCode)")
    }
    if let mimeType = response.mimeType?.lowercased(),
       mimeType.hasPrefix("text/") || mimeType.contains("html") || mimeType.contains("json") {
        throw CatalogAllCardsSmokeError("Non-media response \(mimeType) for \(sourceURL.absoluteString)")
    }
}

private func shouldUseBrowserStyleHeaders(
    for sourceURL: URL,
    wallpaper: CatalogWallpaper
) -> Bool {
    guard wallpaper.attribution == "MoeWalls" || wallpaper.sourcePageURL?.host?.contains("moewalls.com") == true,
          let host = sourceURL.host?.lowercased() else {
        return false
    }
    return host.contains("moewalls.com")
        || host.contains("media.moewalls.com")
        || host.contains("cdn.moewalls.com")
}

private struct CatalogAllCardsSmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
