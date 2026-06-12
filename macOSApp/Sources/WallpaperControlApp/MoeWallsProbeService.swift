import Foundation

enum MoeWallsSourceError: LocalizedError {
    case unavailable(String)
    case challengeBlocked
    case invalidResponse
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .challengeBlocked:
            return "MoeWalls is protected by a challenge page."
        case .invalidResponse:
            return "MoeWalls returned an invalid response."
        case .missingDownloadURL:
            return "MoeWalls detail page does not expose a playable download URL."
        }
    }
}

enum MoeWallsCatalogStrategy: String, Codable {
    case rest
    case sitemap
    case archive
    case unavailable
}

struct MoeWallsProbeResult {
    let strategy: MoeWallsCatalogStrategy
    let available: Bool
    let reason: String?
}

struct MoeWallsHTTPResponse {
    let data: Data
    let response: HTTPURLResponse

    var text: String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

final class MoeWallsHTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval
    private let userAgent: String
    private let maxRetries: Int
    private let proxyBaseURL = "https://r.jina.ai/http://"

    init(
        session: URLSession = .shared,
        timeout: TimeInterval = 20,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
        maxRetries: Int = 2
    ) {
        self.session = session
        self.timeout = timeout
        self.userAgent = userAgent
        self.maxRetries = maxRetries
    }

    func get(_ url: URL, accept: String = "text/html,application/xml,application/json") async throws -> MoeWallsHTTPResponse {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                do {
                    return try await performRequest(url: url, accept: accept)
                } catch MoeWallsSourceError.challengeBlocked {
                    return try await performProxyRequest(for: url, accept: accept)
                } catch {
                    if attempt == maxRetries {
                        return try await performProxyRequest(for: url, accept: accept)
                    }
                    throw error
                }
            } catch {
                lastError = error
                if error is MoeWallsSourceError || attempt == maxRetries {
                    throw error
                }
            }
        }

        throw lastError ?? MoeWallsSourceError.invalidResponse
    }

    private func performRequest(url: URL, accept: String) async throws -> MoeWallsHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoeWallsSourceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MoeWallsSourceError.challengeBlocked
            }
            throw URLError(.badServerResponse)
        }
        let payload = MoeWallsHTTPResponse(data: data, response: httpResponse)
        if MoeWallsParser.isChallengePage(payload.text) {
            throw MoeWallsSourceError.challengeBlocked
        }
        return payload
    }

    private func performProxyRequest(for url: URL, accept: String) async throws -> MoeWallsHTTPResponse {
        let proxyURL = makeProxyURL(for: url)
        let payload = try await performRequest(url: proxyURL, accept: accept)
        let unwrapped = unwrapProxyPayload(payload.text)
        let data = Data(unwrapped.utf8)
        return MoeWallsHTTPResponse(data: data, response: payload.response)
    }

    private func makeProxyURL(for url: URL) -> URL {
        URL(string: proxyBaseURL + url.absoluteString)!
    }

    private func unwrapProxyPayload(_ text: String) -> String {
        guard let contentRange = text.range(of: "Markdown Content:") else {
            return text
        }

        var content = String(text[contentRange.upperBound...])
        if let firstNewline = content.firstIndex(of: "\n") {
            content = String(content[content.index(after: firstNewline)...])
        }

        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content = content.replacingOccurrences(of: "<html><body><pre>", with: "")
        content = content.replacingOccurrences(of: "</pre></body></html>", with: "")

        if let footerRange = content.range(of: "\n===============", options: .backwards) {
            content = String(content[..<footerRange.lowerBound])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MoeWallsProbeService {
    private let client: MoeWallsHTTPClient
    private let baseURL: URL

    init(
        client: MoeWallsHTTPClient,
        baseURL: URL = URL(string: "https://moewalls.com/")!
    ) {
        self.client = client
        self.baseURL = baseURL
    }

    func probe() async -> MoeWallsProbeResult {
        do {
            let rootURL = baseURL.appending(path: "wp-json/")
            let rootResponse = try await client.get(rootURL, accept: "application/json,text/html")
            let routes = MoeWallsParser.parseRESTRootRoutes(from: rootResponse.data)
            let hasREST = routes.contains("/wp/v2/posts") || routes.contains("/wp/v2/categories") || routes.contains("/wp/v2/tags")
            if hasREST {
                let testURL = baseURL.appending(path: "wp-json/wp/v2/posts")
                var components = URLComponents(url: testURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "per_page", value: "1"),
                    URLQueryItem(name: "_fields", value: "slug,link,title,date")
                ]
                if let url = components?.url {
                    _ = try await client.get(url, accept: "application/json,text/html")
                    return MoeWallsProbeResult(strategy: .rest, available: true, reason: nil)
                }
            }
        } catch MoeWallsSourceError.challengeBlocked {
            return MoeWallsProbeResult(strategy: .unavailable, available: false, reason: "Cloudflare challenge")
        } catch {
        }

        do {
            let robotsURL = baseURL.appending(path: "robots.txt")
            let robots = try await client.get(robotsURL)
            if robots.text.localizedCaseInsensitiveContains("sitemap:") {
                return MoeWallsProbeResult(strategy: .sitemap, available: true, reason: nil)
            }
        } catch MoeWallsSourceError.challengeBlocked {
            return MoeWallsProbeResult(strategy: .unavailable, available: false, reason: "Cloudflare challenge")
        } catch {
        }

        do {
            let archiveURL = baseURL.appending(path: "category/anime/")
            _ = try await client.get(archiveURL)
            return MoeWallsProbeResult(strategy: .archive, available: true, reason: nil)
        } catch MoeWallsSourceError.challengeBlocked {
            return MoeWallsProbeResult(strategy: .unavailable, available: false, reason: "Cloudflare challenge")
        } catch {
            return MoeWallsProbeResult(strategy: .unavailable, available: false, reason: error.localizedDescription)
        }
    }
}
