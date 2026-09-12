import Foundation

enum WallpaperSearchMatcher {
    static func matches(query rawQuery: String, fields: [String]) -> Bool {
        let query = normalized(rawQuery)
        guard !query.isEmpty else { return true }

        let normalizedFields = fields.map(normalized)
        let combined = normalizedFields.joined(separator: " ")
        if combined.contains(query) {
            return true
        }

        let queryTokens = tokens(in: query)
        let fieldTokens = normalizedFields.flatMap(tokens)
        guard !queryTokens.isEmpty, !fieldTokens.isEmpty else { return false }

        return queryTokens.allSatisfy { queryToken in
            fieldTokens.contains { fieldToken in
                token(queryToken, matches: fieldToken)
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in value: String) -> [String] {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func token(_ query: String, matches candidate: String) -> Bool {
        if candidate.contains(query) || (candidate.count >= 3 && query.contains(candidate)) {
            return true
        }

        guard query.count >= 3, candidate.count >= 3 else { return false }
        if isSingleAdjacentTransposition(query, candidate) {
            return true
        }
        return editDistance(query, candidate, limit: query.count >= 7 ? 2 : 1) != nil
    }

    private static func isSingleAdjacentTransposition(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count == right.count else { return false }

        let differences = left.indices.filter { left[$0] != right[$0] }
        guard differences.count == 2,
              differences[1] == differences[0] + 1 else {
            return false
        }
        let first = differences[0]
        let second = differences[1]
        return left[first] == right[second] && left[second] == right[first]
    }

    /// Returns a distance only while it remains within `limit`, avoiding work
    /// for unrelated catalog words.
    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return nil }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            guard rowMinimum <= limit else { return nil }
            previous = current
        }

        guard let distance = previous.last, distance <= limit else { return nil }
        return distance
    }
}
