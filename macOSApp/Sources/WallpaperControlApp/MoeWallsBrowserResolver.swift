import Foundation
import WebKit

enum MoeWallsBrowserResolverError: LocalizedError {
    case tokenNotFound
    case downloadDidNotStart
    case downloadDestinationMissing
    case invalidResponse
    case playableSourceNotFound

    var errorDescription: String? {
        switch self {
        case .tokenNotFound:
            return "MoeWalls browser flow could not resolve a download token."
        case .downloadDidNotStart:
            return "MoeWalls browser flow could not start the wallpaper download."
        case .downloadDestinationMissing:
            return "MoeWalls browser flow has no destination for the downloaded file."
        case .invalidResponse:
            return "MoeWalls browser flow returned an invalid download response."
        case .playableSourceNotFound:
            return "MoeWalls browser flow could not resolve a playable video source."
        }
    }
}

@MainActor
final class MoeWallsBrowserResolver: NSObject {
    private let webView: WKWebView
    private var popupWebViews: [WKWebView] = []
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var pendingDownloadDestinationURL: URL?
    private var downloadTimeoutWorkItem: DispatchWorkItem?
    private var activeDownload: WKDownload?
    private var downloadProgressObservation: NSKeyValueObservation?
    private var downloadProgressHandler: CatalogDownloadProgress.Handler?
    private var cancellationInProgress = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func downloadWallpaper(from pageURL: URL, to destinationURL: URL,
                           progress: CatalogDownloadProgress.Handler? = nil) async throws -> URL {
        downloadProgressHandler = progress
        defer { downloadProgressHandler = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await performDownloadWallpaper(from: pageURL, to: destinationURL)
        } onCancel: {
            Task { @MainActor [self] in cancelCurrentOperation() }
        }
    }

    private func performDownloadWallpaper(from pageURL: URL, to destinationURL: URL) async throws -> URL {
        try await load(pageURL: pageURL)
        try await prepareDownloadState()
        var lastError: Error?

        let cookies = await currentCookies()

        if let token = try? await waitForDownloadToken(maxAttempts: 8) {
            do {
                let downloadURL = try Self.resolvedDownloadURL(from: token, pageURL: pageURL)
                return try await downloadWithBrowserContext(
                    from: downloadURL,
                    pageURL: pageURL,
                    cookies: cookies,
                    destinationURL: destinationURL
                )
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        try Task.checkCancellation()
        do {
            let playableSourceURL = try await waitForPlayableSourceURL(pageURL: pageURL)
            do {
                return try await downloadWithBrowserContext(
                    from: playableSourceURL,
                    pageURL: pageURL,
                    cookies: cookies,
                    destinationURL: destinationURL
                )
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        } catch {
            try Task.checkCancellation()
        }

        // A JavaScript click can be intercepted by WebKit without producing
        // a WKDownload (for example when the site opens the response in a
        // popup). Keep that path only as the final compatibility fallback;
        // direct playable sources above are deterministic and do not leave
        // the catalog button waiting for the 20-second timeout.
        do {
            return try await startBrowserManagedDownload(to: destinationURL)
        } catch {
            try Task.checkCancellation()
            lastError = error
        }

        throw lastError ?? MoeWallsBrowserResolverError.downloadDidNotStart
    }

    func resolvePlayableSourceURL(from pageURL: URL) async throws -> URL {
        try await load(pageURL: pageURL)
        try await prepareDownloadState()
        return try await waitForPlayableSourceURL(pageURL: pageURL)
    }

    private func load(pageURL: URL) async throws {
        try Task.checkCancellation()
        cancellationInProgress = false
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 60
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                navigationContinuation = continuation
                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor [self] in cancelCurrentOperation() }
        }
    }

    private func waitForDownloadToken(maxAttempts: Int = 80) async throws -> String {
        let script = """
        (() => {
            const button = document.getElementById('moe-download');
            if (!button) { return null; }
            return button.getAttribute('data-url');
        })();
        """

        for _ in 0..<maxAttempts {
            try Task.checkCancellation()
            if let value = try await webView.evaluateJavaScript(script) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !value.contains("facebook.com/sharer"),
               !value.contains("twitter.com/intent") {
                return value
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw MoeWallsBrowserResolverError.tokenNotFound
    }

    private func waitForPlayableSourceURL(pageURL: URL) async throws -> URL {
        let script = """
        (() => {
            const source = document.querySelector('video source[src]');
            if (source) {
                return source.currentSrc || source.src || source.getAttribute('src');
            }
            const video = document.querySelector('video');
            if (!video) { return null; }
            return video.currentSrc || video.src || video.getAttribute('src');
        })();
        """

        for _ in 0..<80 {
            try Task.checkCancellation()
            if let rawValue = try await webView.evaluateJavaScript(script) as? String,
               let url = try? Self.resolvedDownloadURL(from: rawValue, pageURL: pageURL) {
                return url
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw MoeWallsBrowserResolverError.playableSourceNotFound
    }

    private func prepareDownloadState() async throws {
        let script = """
        (() => {
            const expiry = Date.now() + 24 * 60 * 60 * 1000;
            localStorage.setItem('cf_country', JSON.stringify({ value: 'VN', expiry }));
            document.cookie = 'LastPUExpire=' + Date.now() + '; path=/; SameSite=Lax';
            return document.cookie;
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
    }

    private func currentCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func startBrowserManagedDownload(to destinationURL: URL) async throws -> URL {
        try Task.checkCancellation()
        pendingDownloadDestinationURL = destinationURL
        downloadTimeoutWorkItem?.cancel()

        return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            downloadContinuation = continuation

            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finishDownload(with: .failure(MoeWallsBrowserResolverError.downloadDidNotStart))
            }
            downloadTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

            let clickScript = """
            (() => {
                const button = document.getElementById('moe-download');
                if (!button) { return false; }
                button.click();
                return true;
            })();
            """

            Task { @MainActor [weak self] in
                do {
                    let clicked = try await self?.webView.evaluateJavaScript(clickScript) as? Bool
                    if clicked != true {
                        self?.finishDownload(with: .failure(MoeWallsBrowserResolverError.downloadDidNotStart))
                    }
                } catch {
                    self?.finishDownload(with: .failure(error))
                }
            }
        }
    }

    private func finishDownload(with result: Result<URL, Error>) {
        downloadProgressObservation = nil
        activeDownload = nil
        downloadTimeoutWorkItem?.cancel()
        downloadTimeoutWorkItem = nil

        let continuation = downloadContinuation
        downloadContinuation = nil
        pendingDownloadDestinationURL = nil

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func cancelCurrentOperation() {
        guard !cancellationInProgress else { return }
        cancellationInProgress = true
        webView.stopLoading()
        popupWebViews.forEach { $0.stopLoading() }
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
        let destination = pendingDownloadDestinationURL
        if let activeDownload {
            downloadProgressObservation = nil
            activeDownload.cancel { [self] _ in
                if let destination { try? FileManager.default.removeItem(at: destination) }
                finishDownload(with: .failure(CancellationError()))
            }
        } else {
            finishDownload(with: .failure(CancellationError()))
        }
    }

    private func observe(_ download: WKDownload) {
        guard downloadContinuation != nil else { download.cancel(nil); return }
        activeDownload = download
        download.delegate = self
        let relay = CatalogDownloadProgressRelay(handler: downloadProgressHandler)
        downloadProgressObservation = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { progress, _ in
            relay.report(received: progress.completedUnitCount, total: progress.totalUnitCount)
        }
    }

    nonisolated static func resolvedDownloadURL(from token: String, pageURL: URL) throws -> URL {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MoeWallsBrowserResolverError.tokenNotFound
        }
        if isDownloadToken(trimmed) {
            guard let downloadURL = URL(string: "https://go.moewalls.com/download.php?video=\(trimmed)") else {
                throw MoeWallsBrowserResolverError.tokenNotFound
            }
            return downloadURL
        }
        if trimmed.hasPrefix("//"),
           let schemeRelative = URL(string: "https:\(trimmed)") {
            return schemeRelative
        }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let relative = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL {
            return relative
        }
        throw MoeWallsBrowserResolverError.tokenNotFound
    }

    private nonisolated static func isDownloadToken(_ value: String) -> Bool {
        guard !value.contains("://"), !value.contains("/") else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%=_-+")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func downloadWithBrowserContext(
        from downloadURL: URL,
        pageURL: URL,
        cookies: [HTTPCookie],
        destinationURL: URL
    ) async throws -> URL {
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 45
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("\(pageURL.scheme ?? "https")://\(pageURL.host ?? "moewalls.com")", forHTTPHeaderField: "Origin")
        if !cookies.isEmpty {
            request.setValue(
                HTTPCookie.requestHeaderFields(with: cookies)["Cookie"],
                forHTTPHeaderField: "Cookie"
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage()
        cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // The browser resolver already has a page-scoped token and cookies.
        // Use one regular download for this compatibility path: the range
        // assembler is optimized for stable CDN assets, while token-backed
        // responses can reject parallel range requests even though a normal
        // full response is valid.
        downloadProgressHandler?(.init(phase: .downloading))
        let relay = CatalogDownloadProgressRelay(handler: downloadProgressHandler)
        let observer = CatalogDownloadObserver(update: { received, expected, _ in
            relay.report(received: received, total: expected)
        })
        let (temporaryURL, response) = try await observer.download(request: request, session: session)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CatalogDownloadError.badStatus(url: downloadURL, statusCode: httpResponse.statusCode)
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/") || mimeType.contains("html") {
            throw CatalogDownloadError.htmlResponse(url: downloadURL)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

}

extension MoeWallsBrowserResolver: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        observe(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        observe(download)
    }
}

extension MoeWallsBrowserResolver: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popupWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.setValue(false, forKey: "drawsBackground")
        popupWebViews.append(popupWebView)
        return popupWebView
    }
}

extension MoeWallsBrowserResolver: WKDownloadDelegate {
    private func downloadDestinationURL() -> URL? {
        guard let destinationURL = pendingDownloadDestinationURL else {
            finishDownload(with: .failure(MoeWallsBrowserResolverError.downloadDestinationMissing))
            return nil
        }

        try? FileManager.default.removeItem(at: destinationURL)
        return destinationURL
    }

    @available(macOS 11.3, *)
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        downloadDestinationURL()
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !cancellationInProgress else { return }
        guard let destinationURL = pendingDownloadDestinationURL else {
            finishDownload(with: .failure(MoeWallsBrowserResolverError.downloadDestinationMissing))
            return
        }
        finishDownload(with: .success(destinationURL))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard !cancellationInProgress else { return }
        _ = resumeData
        finishDownload(with: .failure(error))
    }
}
