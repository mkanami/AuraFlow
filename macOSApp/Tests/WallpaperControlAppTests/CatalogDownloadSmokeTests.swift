import Foundation
import Testing
@testable import WallpaperControlApp

@Test func liveCatalogDownloadSmoke() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_CATALOG_SMOKE"] == "1" else {
        return
    }

    let offset = max(
        0,
        Int(ProcessInfo.processInfo.environment["AURAFLOW_LIVE_CATALOG_OFFSET"] ?? "0") ?? 0
    )
    let sampleCount = max(
        1,
        min(
            Int(ProcessInfo.processInfo.environment["AURAFLOW_LIVE_CATALOG_SAMPLE"] ?? "12") ?? 12,
            100
        )
    )

    let provider = MoeWallsSource()
    let catalog = try await provider.fetchCatalog()
    let wallpapers = Array(catalog.dropFirst(offset).prefix(sampleCount))

    if wallpapers.count < sampleCount {
        throw CatalogSmokeError(
            "Catalog returned only \(wallpapers.count) wallpapers after offset \(offset), expected at least \(sampleCount)."
        )
    }

    var failures: [String] = []
    for wallpaper in wallpapers {
        do {
            let result = try await smokeDownload(for: wallpaper, provider: provider)
            print("[catalog-smoke] ok | \(wallpaper.title) | \(result.url.absoluteString) | status \(result.statusCode) | bytes \(result.byteCount)")
        } catch {
            let message = "[catalog-smoke] fail | \(wallpaper.title) | \(error.localizedDescription)"
            print(message)
            failures.append(message)
        }
    }

    if !failures.isEmpty {
        throw CatalogSmokeError(failures.joined(separator: "\n"))
    }
}

@Test @MainActor func liveMoeWallsBrowserDownloadSmoke() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_BROWSER_DOWNLOAD_SMOKE"] == "1" else {
        return
    }

    let resolver = MoeWallsBrowserResolver()
    let pageURL = URL(string: "https://moewalls.com/anime/makima-chainsaw-man-6-live-wallpaper/")!
    let destinationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-browser-smoke-\(UUID().uuidString).webm")

    let downloadedURL = try await resolver.downloadWallpaper(from: pageURL, to: destinationURL)
    defer { try? FileManager.default.removeItem(at: downloadedURL) }

    let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
    let byteCount = attributes[.size] as? Int64 ?? 0
    if byteCount <= 0 {
        throw CatalogSmokeError("Browser resolver downloaded an empty file.")
    }
}

private struct SmokeDownloadResult {
    let url: URL
    let statusCode: Int
    let byteCount: Int64
}

private struct CatalogSmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func smokeDownload(
    for wallpaper: CatalogWallpaper,
    provider: MoeWallsSource
) async throws -> SmokeDownloadResult {
    let sources = try await smokeCandidateSources(for: wallpaper, provider: provider)
    var failures: [String] = []

    for source in sources {
        do {
            return try await smokeDownloadSource(source, wallpaper: wallpaper)
        } catch {
            failures.append("\(source.url.absoluteString) -> \(error.localizedDescription)")
        }
    }

    throw CatalogSmokeError(
        """
        No downloadable source worked for "\(wallpaper.title)".
        \(failures.joined(separator: "\n"))
        """
    )
}

private func smokeCandidateSources(
    for wallpaper: CatalogWallpaper,
    provider: MoeWallsSource
) async throws -> [CatalogVideoSource] {
    var candidates: [CatalogVideoSource] = []
    if let pageURL = wallpaper.sourcePageURL,
       let details = try? await provider.fetchDetails(pageURL: pageURL) {
        let width = details.resolution?.width ?? 0
        let height = details.resolution?.height ?? 0
        if details.hasExplicitPlayableSource == true,
           let downloadURL = details.downloadURL {
            candidates.append(CatalogVideoSource(url: downloadURL, width: width, height: height))
        }
        if details.hasExplicitPlayableSource == true,
           let previewVideoURL = details.previewVideoURL {
            candidates.append(CatalogVideoSource(url: previewVideoURL, width: width, height: height))
            if previewVideoURL.pathExtension.lowercased() == "webm" {
                candidates.append(
                    CatalogVideoSource(
                        url: previewVideoURL.deletingPathExtension().appendingPathExtension("mp4"),
                        width: width,
                        height: height
                    )
                )
            }
        }
    }

    if candidates.isEmpty,
       let pageURL = wallpaper.sourcePageURL {
        let resolver = await MainActor.run { MoeWallsBrowserResolver() }
        if let browserSourceURL = try? await resolver.resolvePlayableSourceURL(from: pageURL) {
            candidates.append(CatalogVideoSource(url: browserSourceURL, width: 0, height: 0))
            if browserSourceURL.pathExtension.lowercased() == "webm" {
                candidates.append(
                    CatalogVideoSource(
                        url: browserSourceURL.deletingPathExtension().appendingPathExtension("mp4"),
                        width: 0,
                        height: 0
                    )
                )
            }
        }
    }

    if candidates.isEmpty {
        candidates.append(contentsOf: wallpaper.sources)
    }

    if candidates.isEmpty {
        let resolvedURL = try await provider.resolveDownloadURL(for: wallpaper)
        candidates.append(CatalogVideoSource(url: resolvedURL, width: 0, height: 0))
    }

    return preferredSmokeSources(from: candidates)
}

private func preferredSmokeSources(from sources: [CatalogVideoSource]) -> [CatalogVideoSource] {
    var seen = Set<String>()
    let unique = sources.filter { seen.insert($0.url.absoluteString).inserted }
    return unique.sorted { lhs, rhs in
        let lhsRank = smokeContainerRank(for: lhs.url)
        let rhsRank = smokeContainerRank(for: rhs.url)
        if lhsRank == rhsRank {
            return (lhs.width * lhs.height) > (rhs.width * rhs.height)
        }
        return lhsRank < rhsRank
    }
}

private func smokeContainerRank(for url: URL) -> Int {
    switch url.pathExtension.lowercased() {
    case "mp4", "mov", "m4v":
        return 0
    case "webm", "mkv":
        return 2
    default:
        return 1
    }
}

private func smokeDownloadSource(
    _ source: CatalogVideoSource,
    wallpaper: CatalogWallpaper
) async throws -> SmokeDownloadResult {
    var request = URLRequest(url: source.url)
    request.timeoutInterval = 45
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")

    if shouldUseBrowserStyleHeaders(for: source.url, wallpaper: wallpaper) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    } else {
        request.setValue("AuraFlow/1.1", forHTTPHeaderField: "User-Agent")
    }

    if let sourcePageURL = wallpaper.sourcePageURL {
        request.setValue(sourcePageURL.absoluteString, forHTTPHeaderField: "Referer")
        if source.url.host?.contains("moewalls.com") == true,
           let origin = catalogOriginHeaderValue(for: sourcePageURL) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = true
    configuration.httpCookieAcceptPolicy = .always
    let session = URLSession(configuration: configuration)
    let (temporaryURL, response) = try await session.download(for: request)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    guard let httpResponse = response as? HTTPURLResponse else {
        throw CatalogSmokeError("Non-HTTP response.")
    }
    guard [200, 206].contains(httpResponse.statusCode) else {
        throw CatalogSmokeError("HTTP \(httpResponse.statusCode)")
    }

    if let mimeType = response.mimeType?.lowercased(),
       mimeType.hasPrefix("text/") || mimeType.contains("html") {
        throw CatalogSmokeError("HTML/text response: \(mimeType)")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    let byteCount = attributes[.size] as? Int64 ?? 0
    if byteCount <= 0 {
        throw CatalogSmokeError("Downloaded file is empty.")
    }

    return SmokeDownloadResult(
        url: source.url,
        statusCode: httpResponse.statusCode,
        byteCount: byteCount
    )
}

private func shouldUseBrowserStyleHeaders(for sourceURL: URL, wallpaper: CatalogWallpaper) -> Bool {
    guard wallpaper.attribution == "MoeWalls" || wallpaper.sourcePageURL?.host?.contains("moewalls.com") == true else {
        return false
    }

    guard let host = sourceURL.host?.lowercased() else {
        return false
    }

    return host.contains("moewalls.com")
        || host.contains("media.moewalls.com")
        || host.contains("cdn.moewalls.com")
}
