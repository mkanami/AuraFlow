import Foundation

enum WallpaperSearchMatcher {
    static func matches(query rawQuery: String, fields: [String]) -> Bool {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return true }
        return fields.contains { normalizedQuery($0).contains(query) }
    }

    static func normalizedQuery(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
