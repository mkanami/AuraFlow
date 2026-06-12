import Foundation

struct MoeWallsResolution: Codable, Hashable {
    let width: Int
    let height: Int

    var label: String {
        "\(width)x\(height)"
    }

    var isSupportedForAuraFlow: Bool {
        width >= 1920 && height >= 1080 && width <= 3840 && height <= 2400
    }

    static func parse(_ value: String) -> MoeWallsResolution? {
        let pattern = #"(\d{3,5})\s*[xX]\s*(\d{3,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: nsRange),
              match.numberOfRanges == 3,
              let widthRange = Range(match.range(at: 1), in: value),
              let heightRange = Range(match.range(at: 2), in: value),
              let width = Int(value[widthRange]),
              let height = Int(value[heightRange]) else {
            return nil
        }
        return MoeWallsResolution(width: width, height: height)
    }
}

struct MoeWallsWallpaper: Codable, Hashable {
    let id: String
    let slug: String
    let title: String
    let pageURL: URL
    let previewImageURL: URL?
    let previewVideoURL: URL?
    let category: String
    let tags: [String]
    let resolution: MoeWallsResolution?
    let fileSizeMB: Double?
    let sourceName: String?
    let publishedAt: Date?
    let downloadURL: URL?
    let hasExplicitPlayableSource: Bool?

    var asCatalogWallpaper: CatalogWallpaper {
        let dimensions = (resolution?.width ?? 0, resolution?.height ?? 0)
        let sources = previewCandidateURLs.map { url in
            CatalogVideoSource(url: url, width: dimensions.0, height: dimensions.1)
        }

        return CatalogWallpaper(
            id: id,
            title: title,
            category: category,
            attribution: sourceName ?? "MoeWalls",
            previewImageURL: previewImageURL,
            sourcePageURL: pageURL,
            sources: sources
        )
    }

    var previewCandidateURLs: [URL] {
        var candidates: [URL] = []
        if let downloadURL {
            candidates.append(downloadURL)
        }
        if let previewVideoURL {
            candidates.append(previewVideoURL)
            if previewVideoURL.pathExtension.lowercased() == "webm" {
                candidates.append(
                    previewVideoURL.deletingPathExtension().appendingPathExtension("mp4")
                )
            }
        } else if let derivedPreviewURL = MoeWallsParser.derivedPreviewVideoURL(from: previewImageURL, slug: slug) {
            candidates.append(derivedPreviewURL)
            if derivedPreviewURL.pathExtension.lowercased() == "webm" {
                let mp4Candidate = derivedPreviewURL.deletingPathExtension().appendingPathExtension("mp4")
                candidates.append(mp4Candidate)
            }
        }
        var seen = Set<String>()
        let uniqueCandidates = candidates.filter { seen.insert($0.absoluteString).inserted }
        return uniqueCandidates.enumerated().sorted { lhs, rhs in
            let lhsRank = sourceCompatibilityRank(for: lhs.element)
            let rhsRank = sourceCompatibilityRank(for: rhs.element)
            if lhsRank == rhsRank {
                return lhs.offset < rhs.offset
            }
            return lhsRank < rhsRank
        }.map(\.element)
    }

    private func sourceCompatibilityRank(for url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v":
            return 0
        case "webm", "mkv":
            return 2
        default:
            return 1
        }
    }
}

struct MoeWallsArchivePage {
    let wallpapers: [MoeWallsWallpaper]
    let hasNextPage: Bool
}

enum MoeWallsParser {
    static func isChallengePage(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("just a moment") ||
            lowercased.contains("enable javascript and cookies to continue") ||
            lowercased.contains("/cdn-cgi/challenge-platform/") ||
            lowercased.contains("cf_chl_opt")
    }

    static func parseRESTRootRoutes(from data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = object["routes"] as? [String: Any] else {
            return []
        }
        return Set(routes.keys)
    }

    static func parseArchivePage(html: String, pageURL: URL) -> MoeWallsArchivePage {
        let normalized = decodeHTMLEntities(html)
        let cardPattern = #"<a[^>]+href=["'](https?://moewalls\.com/[^"']+)["'][^>]*>(?:(?!</a>).)*?<img[^>]+(?:data-src|data-lazy-src|src)=["']([^"']+)["'][^>]*?(?:alt=["']([^"']+)["'])?[^>]*>"#
        let markdownCardPattern = #"\[\!\[[^\]]*\]\((https?://moewalls\.com/wp-content/uploads/[^)\s]+)\)\]\((https?://moewalls\.com/[^)\s]+)\s+\"([^\"]+)\"\)"#
        let matches = regexMatches(pattern: cardPattern, in: normalized, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let markdownMatches = regexMatches(pattern: markdownCardPattern, in: normalized, options: [.caseInsensitive])

        var wallpapers: [MoeWallsWallpaper] = []
        var seen = Set<String>()

        for match in matches {
            appendArchiveWallpaper(
                fromPageURL: match.count > 1 ? match[1] : nil,
                previewImageURLString: match.count > 2 ? match[2] : nil,
                titleString: match.count > 3 ? match[3] : nil,
                seen: &seen,
                wallpapers: &wallpapers
            )
        }

        for match in markdownMatches {
            appendArchiveWallpaper(
                fromPageURL: match.count > 2 ? match[2] : nil,
                previewImageURLString: match.count > 1 ? match[1] : nil,
                titleString: match.count > 3 ? match[3] : nil,
                seen: &seen,
                wallpapers: &wallpapers
            )
        }

        let hasNextPage = normalized.range(
            of: #"(?:(?:href=["'])|https?://moewalls\.com/)[^"'\s]+/page/\d+/["']?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        return MoeWallsArchivePage(wallpapers: wallpapers, hasNextPage: hasNextPage)
    }

    static func parseWallpaperDetail(html: String, pageURL: URL) -> MoeWallsWallpaper {
        let normalized = decodeHTMLEntities(html)
        let slug = slug(from: pageURL)
        let canonicalURL = URL(string: firstMatch(in: normalized, pattern: #"<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']"#) ?? "") ?? pageURL

        let title = firstMatch(in: normalized, pattern: #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#)
            ?? firstMatch(in: normalized, pattern: #"<title>([^<]+)</title>"#)
            ?? firstMatch(in: normalized, pattern: #"(?m)^(.+?)\s*-\s*MoeWalls$"#)
            ?? titleFromSlug(slug)

        let previewImageURL = url(from: firstMatch(
            in: normalized,
            pattern: #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#
        )) ?? url(from: firstMatch(
            in: normalized,
            pattern: #"\!\[[^\]]*\]\((https?://[^)\s]*wp-content/uploads/[^)\s]*?(?:thumb|thumb-\d+x\d+)\.(?:jpg|jpeg|png|webp))\)"#
        ))
        let explicitPlayableURL = firstPlayableURL(in: normalized, relativeTo: canonicalURL)
        let explicitDownloadURL = bestDownloadURL(in: normalized, relativeTo: canonicalURL)
        let previewVideoURL = explicitPlayableURL
            ?? derivedPreviewVideoURL(from: previewImageURL, slug: slug)
        let categorySlug = firstMatch(in: normalized, pattern: #"https?://moewalls\.com/category/([^/"']+)/"#)
        let tagMatches = regexMatches(
            pattern: #"https?://moewalls\.com/tag/([^/"']+)/"#,
            in: normalized
        )
        let tags = Array(Set<String>(tagMatches.compactMap { match in
            guard match.count > 1 else { return nil }
            return slugToTagName(match[1])
        })).sorted()

        let resolutionString = firstMatch(in: normalized, pattern: #"Resolution(?:</[^>]+>|:|\s)+(\d{3,5}\s*[xX]\s*\d{3,5})"#)
            ?? firstMatch(in: normalized, pattern: #"https?://moewalls\.com/resolution/(\d{3,5}x\d{3,5})/"#)
        let resolution = resolutionString.flatMap(MoeWallsResolution.parse)

        let fileSizeText = firstMatch(in: normalized, pattern: #"File Size(?:</[^>]+>|:|\s)+([0-9]+(?:\.[0-9]+)?)\s*MB"#)
        let fileSizeMB = fileSizeText.flatMap(Double.init)

        let sourceName = firstMatch(in: normalized, pattern: #"Source(?:</[^>]+>|:|\s)+([^<\n\r]+)"#)
        let publishedAt = parseDate(
            firstMatch(in: normalized, pattern: #"<meta[^>]+property=["']article:published_time["'][^>]+content=["']([^"']+)["']"#)
                ?? firstMatch(in: normalized, pattern: #"<time[^>]+datetime=["']([^"']+)["']"#)
        )

        let downloadURL = explicitDownloadURL

        return MoeWallsWallpaper(
            id: "moewalls-\(slug)",
            slug: slug,
            title: cleanupText(title),
            pageURL: canonicalURL,
            previewImageURL: previewImageURL,
            previewVideoURL: previewVideoURL,
            category: categorySlug.map(titleFromSlug) ?? "Anime",
            tags: tags,
            resolution: resolution,
            fileSizeMB: fileSizeMB,
            sourceName: sourceName?.nonEmpty,
            publishedAt: publishedAt,
            downloadURL: downloadURL,
            hasExplicitPlayableSource: explicitPlayableURL != nil || explicitDownloadURL != nil
        )
    }

    static func parseSitemapIndex(xml: Data) -> [URL] {
        parseSitemapURLs(xml: xml)
    }

    static func parseURLSet(xml: Data) -> [URL] {
        parseSitemapURLs(xml: xml)
    }

    static func derivedPreviewVideoURL(from previewImageURL: URL?, slug: String) -> URL? {
        guard let previewImageURL else { return nil }
        return derivePreviewVideoURLUsingRegex(from: previewImageURL, slug: previewSlug(from: slug))
    }

    private static func parseSitemapURLs(xml: Data) -> [URL] {
        let parser = MoeWallsSitemapXMLParser(data: xml)
        return parser.parse()
    }

    private static func derivePreviewVideoURLUsingRegex(from previewImageURL: URL, slug: String) -> URL? {
        let pattern = #"/wp-content/uploads/(\d{4})/\d{2}/"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: previewImageURL.path,
                range: NSRange(previewImageURL.path.startIndex..<previewImageURL.path.endIndex, in: previewImageURL.path)
              ),
              let yearRange = Range(match.range(at: 1), in: previewImageURL.path) else {
            return nil
        }
        let year = String(previewImageURL.path[yearRange])
        return URL(string: "https://moewalls.com/wp-content/uploads/preview/\(year)/\(slug)-preview.webm")
    }

    private static func previewSlug(from slug: String) -> String {
        if slug.hasSuffix("-live-wallpaper") {
            return String(slug.dropLast("-live-wallpaper".count))
        }
        return slug
    }

    private static func appendArchiveWallpaper(
        fromPageURL pageURLString: String?,
        previewImageURLString: String?,
        titleString: String?,
        seen: inout Set<String>,
        wallpapers: inout [MoeWallsWallpaper]
    ) {
        guard let pageURLString,
              let pageURL = URL(string: pageURLString),
              isWallpaperDetailURL(pageURL) else {
            return
        }

        let canonicalKey = pageURL.absoluteString
        guard seen.insert(canonicalKey).inserted else {
            return
        }

        let slug = slug(from: pageURL)
        let fallbackTitle = titleFromSlug(slug)
        let title = titleString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? fallbackTitle
        let previewImageURL = previewImageURLString.flatMap(URL.init(string:))
        let category = pageURL.pathComponents.dropFirst().first.map(titleFromSlug) ?? "Anime"

        wallpapers.append(
            MoeWallsWallpaper(
                id: "moewalls-\(slug)",
                slug: slug,
                title: cleanupText(title),
                pageURL: pageURL,
                previewImageURL: previewImageURL,
                previewVideoURL: derivedPreviewVideoURL(from: previewImageURL, slug: slug),
                category: category,
                tags: [],
                resolution: nil,
                fileSizeMB: nil,
                sourceName: "MoeWalls",
                publishedAt: nil,
                downloadURL: nil,
                hasExplicitPlayableSource: nil
            )
        )
    }

    private static func firstPlayableURL(in html: String, relativeTo baseURL: URL) -> URL? {
        playableURLs(in: html, relativeTo: baseURL).first
    }

    private static func bestDownloadURL(in html: String, relativeTo baseURL: URL) -> URL? {
        let urls = playableURLs(in: html, relativeTo: baseURL)
        if let mp4 = urls.first(where: { $0.pathExtension.lowercased() == "mp4" }) {
            return mp4
        }
        return urls.first
    }

    private static func playableURLs(in html: String, relativeTo baseURL: URL) -> [URL] {
        let matches = regexMatches(
            pattern: #"((?:https?:)?//[^"'<>\s]+?\.(?:mp4|webm|mov|m4v)(?:\?[^"'<>\s]*)?|/[^"'<>\s]+?\.(?:mp4|webm|mov|m4v)(?:\?[^"'<>\s]*)?)"#,
            in: html
        ).compactMap(\.first)

        var seen = Set<String>()
        return matches.compactMap { rawURL in
            url(from: rawURL, relativeTo: baseURL)
        }.filter { url in
            seen.insert(url.absoluteString).inserted
        }
    }

    private static func firstMatch(in input: String, pattern: String) -> String? {
        regexMatches(pattern: pattern, in: input, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .first?
            .dropFirst()
            .first
            .map(cleanupText)
    }

    private static func regexMatches(
        pattern: String,
        in input: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).map { result in
            (0..<result.numberOfRanges).compactMap { index in
                let range = result.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: input) else {
                    return nil
                }
                return String(input[swiftRange])
            }
        }
    }

    private static func cleanupText(_ value: String) -> String {
        decodeHTMLEntities(value)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func url(from raw: String?) -> URL? {
        url(from: raw, relativeTo: nil)
    }

    private static func url(from raw: String?, relativeTo baseURL: URL?) -> URL? {
        guard let raw = raw?.nonEmpty else { return nil }
        if raw.hasPrefix("//") {
            return URL(string: "https:\(raw)")
        }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: baseURL)?.absoluteURL
        }
        return URL(string: raw)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.nonEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }

    private static func slug(from url: URL) -> String {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last?.lowercased() ?? UUID().uuidString
    }

    private static func titleFromSlug(_ slug: String) -> String {
        cleanupText(slug.replacingOccurrences(of: "-", with: " "))
            .split(separator: " ")
            .map { part in
                let value = String(part)
                guard let first = value.first else { return value }
                return first.uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func slugToTagName(_ slug: String) -> String {
        titleFromSlug(slug)
    }

    private static func isWallpaperDetailURL(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count == 2 else {
            return false
        }
        let first = parts[0].lowercased()
        return !["category", "tag", "resolution", "page", "wp-json"].contains(first)
    }
}

private final class MoeWallsSitemapXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var urls: [URL] = []
    private var currentElement = ""
    private var currentLoc = ""

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> [URL] {
        parser.parse()
        return urls
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "loc" {
            currentLoc = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement == "loc" else { return }
        currentLoc.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "loc" else {
            currentElement = ""
            return
        }
        let trimmed = currentLoc.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            urls.append(url)
        }
        currentElement = ""
        currentLoc = ""
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
