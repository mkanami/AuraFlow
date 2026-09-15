import AVFoundation
import AppKit
import Foundation

/// Downloads catalog media, including provider-specific fallbacks, without
/// coupling the catalog UI to URLSession, cache naming, or MoeWalls' browser
/// flow.
final class CatalogDownloadService: @unchecked Sendable {
    typealias FileDownload = @Sendable (
        URLRequest,
        URLSession
    ) async throws -> (temporaryURL: URL, response: URLResponse)

    private let provider: WallpaperCatalogProviding
    private let catalogDirectoryURL: URL
    private let fileDownloader: FileDownload
    private let standardSession: URLSession
    private let browserSession: URLSession

    private var downloadedWallpapersDirectoryURL: URL {
        CatalogStorageLayout.downloadedWallpapersDirectory(in: catalogDirectoryURL)
    }

    init(
        provider: WallpaperCatalogProviding,
        catalogDirectoryURL: URL,
        standardSession: URLSession? = nil,
        browserSession: URLSession? = nil,
        fileDownloader: @escaping FileDownload = { request, session in
            try await CatalogFileDownloader.download(request: request, session: session)
        }
    ) {
        self.provider = provider
        self.catalogDirectoryURL = catalogDirectoryURL
        self.fileDownloader = fileDownloader
        self.standardSession = standardSession ?? Self.makeSession(browserStyle: false)
        self.browserSession = browserSession ?? Self.makeSession(browserStyle: true)
    }

    /// Uses already-resolved original routes and never tries preview or
    /// synthetic URLs before the full-quality file.
    func download(
        _ wallpaper: CatalogWallpaper,
        preferredSources: [CatalogVideoSource],
        allowProviderFallbackAfterStaleRoute: Bool = true
    ) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: downloadedWallpapersDirectoryURL,
            withIntermediateDirectories: true
        )

        var seen = Set<String>()
        var lastError: Error?
        var staleRouteError: Error?
        for source in preferredSources where seen.insert(source.url.absoluteString).inserted {
            do {
                return try await downloadSource(source, for: wallpaper)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.isStaleRouteError(error) {
                    staleRouteError = staleRouteError ?? error
                }
            }
        }

        if !allowProviderFallbackAfterStaleRoute,
           let staleRouteError {
            throw staleRouteError
        }

        if isMoeWallsWallpaper(wallpaper), let pageURL = wallpaper.sourcePageURL {
            do {
                return try await downloadMoeWallsVideo(for: wallpaper, pageURL: pageURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.badURL)
    }

    private static func isStaleRouteError(_ error: Error) -> Bool {
        guard let downloadError = error as? CatalogDownloadError else { return false }
        if case let .badStatus(_, statusCode) = downloadError {
            return statusCode == 403 || statusCode == 404
        }
        return false
    }

    func download(_ wallpaper: CatalogWallpaper) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: downloadedWallpapersDirectoryURL,
            withIntermediateDirectories: true
        )

        var lastError: Error?

        do {
            try Task.checkCancellation()
            let sources = try await sources(for: wallpaper)
            for source in sources {
                do {
                    try Task.checkCancellation()
                    // Direct CDN requests are faster than the browser flow and
                    // still receive browser-style headers when required.
                    return try await downloadSource(source, for: wallpaper)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            lastError = error
        }

        // If cached catalog metadata did not contain a usable direct source,
        // refresh the provider-specific detail only after trying the sources
        // already available locally. This keeps a catalog download fast and
        // avoids making a Cloudflare/browser round trip the first step.
        if isMoeWallsWallpaper(wallpaper) {
            do {
                try Task.checkCancellation()
                if let detailSource = try await moeWallsDetailDownloadSource(for: wallpaper) {
                    try Task.checkCancellation()
                    return try await downloadSource(detailSource, for: wallpaper)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        // Managed catalogs can contain an older entry with no sources at all.
        // If the derived preview URLs above are unavailable, ask the provider
        // for its current full download URL before entering the WebKit path.
        if isMoeWallsWallpaper(wallpaper), wallpaper.sources.isEmpty {
            do {
                try Task.checkCancellation()
                let resolvedURL = try await provider.resolveDownloadURL(for: wallpaper)
                try Task.checkCancellation()
                return try await downloadSource(
                    CatalogVideoSource(url: resolvedURL, width: 0, height: 0),
                    for: wallpaper
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        // MoeWalls pages can require a JavaScript-generated token. Keep the
        // browser resolver as the final compatibility path.
        if isMoeWallsWallpaper(wallpaper),
           let pageURL = wallpaper.sourcePageURL {
            do {
                try Task.checkCancellation()
                return try await downloadMoeWallsVideo(
                    for: wallpaper,
                    pageURL: pageURL
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        throw lastError ?? URLError(.badURL)
    }

    private func moeWallsDetailDownloadSource(
        for wallpaper: CatalogWallpaper
    ) async throws -> CatalogVideoSource? {
        guard let pageURL = wallpaper.sourcePageURL,
              let moeWallsSource = provider as? MoeWallsSource
        else {
            return nil
        }

        try Task.checkCancellation()
        let details = try await moeWallsSource.fetchDetails(pageURL: pageURL)
        try Task.checkCancellation()
        guard details.hasExplicitPlayableSource == true,
              let downloadURL = details.downloadURL
        else {
            return nil
        }

        return CatalogVideoSource(
            url: downloadURL,
            width: details.resolution?.width ?? 0,
            height: details.resolution?.height ?? 0
        )
    }

    private func downloadSource(
        _ source: CatalogVideoSource,
        for wallpaper: CatalogWallpaper
    ) async throws -> URL {
        try Task.checkCancellation()
        let widthLabel = source.width > 0 ? String(source.width) : "auto"
        let heightLabel = source.height > 0 ? String(source.height) : "auto"
        let fileStem = "\(wallpaper.id)-\(widthLabel)x\(heightLabel)"
        let cachedDestination = downloadedWallpapersDirectoryURL.appendingPathComponent(
            "\(fileStem).\(downloadFileExtension(for: source.url))"
        )

        if hasUsableCatalogFile(at: cachedDestination) {
            return cachedDestination.standardizedFileURL
        }
        if FileManager.default.fileExists(atPath: cachedDestination.path) {
            try? FileManager.default.removeItem(at: cachedDestination)
        }

        let useBrowserStyleHeaders = shouldUseBrowserStyleHeaders(
            for: source.url,
            wallpaper: wallpaper
        )
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 45
        request.setValue(
            useBrowserStyleHeaders
                ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
                : "AuraFlow/1.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if useBrowserStyleHeaders {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if let sourcePageURL = wallpaper.sourcePageURL {
            request.setValue(sourcePageURL.absoluteString, forHTTPHeaderField: "Referer")
            if source.url.host?.contains("moewalls.com") == true,
               let origin = catalogOriginHeaderValue(for: sourcePageURL) {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
        }

        try Task.checkCancellation()
        let (temporaryURL, response) = try await fileDownloader(
            request,
            useBrowserStyleHeaders ? browserSession : standardSession
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CatalogDownloadError.badStatus(
                url: source.url,
                statusCode: httpResponse.statusCode
            )
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/") || mimeType.contains("html") {
            throw CatalogDownloadError.htmlResponse(url: source.url)
        }
        guard isLikelyCatalogMediaResponse(response: response, sourceURL: source.url) else {
            throw CatalogDownloadError.unsupportedResponse(url: source.url)
        }

        let destination = downloadedWallpapersDirectoryURL.appendingPathComponent(
            "\(fileStem).\(downloadFileExtension(for: source.url, response: response))"
        )
        if destination != cachedDestination {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination.standardizedFileURL
    }

    private func downloadMoeWallsVideo(
        for wallpaper: CatalogWallpaper,
        pageURL: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let resolver = await MainActor.run { MoeWallsBrowserResolver() }
        let destination = downloadedWallpapersDirectoryURL.appendingPathComponent(
            "\(wallpaper.id).mp4"
        )
        try? FileManager.default.removeItem(at: destination)
        try Task.checkCancellation()
        let downloadedURL = try await resolver.downloadWallpaper(
            from: pageURL,
            to: destination
        )
        try Task.checkCancellation()
        guard await isPreviewPlayableVideo(at: downloadedURL) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw URLError(.cannotDecodeContentData)
        }
        return downloadedURL
    }

    private func sources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        if !wallpaper.sources.isEmpty {
            var ordered = wallpaper.sources
            if isMoeWallsWallpaper(wallpaper) {
                ordered.append(contentsOf: moeWallsPreviewSources(for: wallpaper))
                var seen = Set<String>()
                ordered = ordered.filter { seen.insert($0.url.absoluteString).inserted }
            }
            if let preferred = preferredSource(for: wallpaper),
               let preferredIndex = ordered.firstIndex(of: preferred),
               preferredIndex != 0 {
                ordered.remove(at: preferredIndex)
                ordered.insert(preferred, at: 0)
            }
            return ordered
        }

        let previewSources = moeWallsPreviewSources(for: wallpaper)
        if !previewSources.isEmpty {
            return previewSources
        }

        try Task.checkCancellation()
        let resolvedURL = try await provider.resolveDownloadURL(for: wallpaper)
        try Task.checkCancellation()
        return [CatalogVideoSource(url: resolvedURL, width: 0, height: 0)]
    }

    private func moeWallsPreviewSources(
        for wallpaper: CatalogWallpaper
    ) -> [CatalogVideoSource] {
        guard isMoeWallsWallpaper(wallpaper),
              let previewImageURL = wallpaper.previewImageURL,
              let sourcePageURL = wallpaper.sourcePageURL,
              let slug = sourcePageURL.pathComponents.last,
              let webmURL = MoeWallsParser.derivedPreviewVideoURL(
                  from: previewImageURL,
                  slug: slug
              ) else {
            return []
        }

        let mp4URL = webmURL.deletingPathExtension().appendingPathExtension("mp4")
        return [
            CatalogVideoSource(url: webmURL, width: 0, height: 0),
            CatalogVideoSource(url: mp4URL, width: 0, height: 0),
        ]
    }

    private func downloadFileExtension(for url: URL) -> String {
        let ext = url.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ext.isEmpty ? "mp4" : ext
    }

    private func downloadFileExtension(for url: URL, response: URLResponse) -> String {
        let ext = url.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let knownExtensions: Set<String> = [
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ]
        if knownExtensions.contains(ext) {
            return ext
        }

        switch response.mimeType?.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/webp": return "webp"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }

    private func isLikelyCatalogMediaResponse(
        response: URLResponse,
        sourceURL: URL
    ) -> Bool {
        if let mime = response.mimeType?.lowercased() {
            if mime.hasPrefix("video/") || mime.hasPrefix("image/")
                || mime == "application/octet-stream" || mime == "binary/octet-stream" {
                return true
            }
            if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") {
                return false
            }
        }

        return [
            "mp4", "webm", "mov", "m4v", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ].contains(sourceURL.pathExtension.lowercased())
    }

    private func hasUsableCatalogFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    private func isMoeWallsWallpaper(_ wallpaper: CatalogWallpaper) -> Bool {
        wallpaper.attribution == "MoeWalls"
            || wallpaper.sourcePageURL?.host?.contains("moewalls.com") == true
    }

    private func preferredSource(for wallpaper: CatalogWallpaper) -> CatalogVideoSource? {
        guard !wallpaper.sources.isEmpty else { return nil }
        guard wallpaper.sources.count > 1 else { return wallpaper.sources.first }

        let nativeSources = wallpaper.sources.filter {
            isNativePlaybackContainer($0.url)
        }
        let candidateSources = nativeSources.isEmpty ? wallpaper.sources : nativeSources
        let screenFrame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let targetWidth = Int(screenFrame.width)
        let targetHeight = Int(screenFrame.height)
        let largerOrEqual = candidateSources.filter {
            $0.width >= targetWidth && $0.height >= targetHeight
        }

        if let best = largerOrEqual.min(by: {
            ($0.width * $0.height) < ($1.width * $1.height)
        }) {
            return best
        }
        return candidateSources.max(by: {
            ($0.width * $0.height) < ($1.width * $1.height)
        })
    }

    private func isNativePlaybackContainer(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    private static func makeSession(browserStyle: Bool) -> URLSession {
        let configuration = browserStyle
            ? URLSessionConfiguration.ephemeral
            : URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if browserStyle {
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
        }
        return URLSession(configuration: configuration)
    }

    private func shouldUseBrowserStyleHeaders(
        for sourceURL: URL,
        wallpaper: CatalogWallpaper
    ) -> Bool {
        guard isMoeWallsWallpaper(wallpaper),
              let host = sourceURL.host?.lowercased()
        else {
            return false
        }
        return host.contains("moewalls.com")
            || host.contains("media.moewalls.com")
            || host.contains("cdn.moewalls.com")
    }

    private func isPreviewPlayableVideo(at url: URL) async -> Bool {
        if url.pathExtension.lowercased() == "gif" {
            return true
        }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return playable && !tracks.isEmpty
        } catch {
            return false
        }
    }
}
