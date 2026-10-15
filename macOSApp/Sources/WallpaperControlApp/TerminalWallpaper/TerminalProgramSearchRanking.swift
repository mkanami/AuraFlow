import AuraTerminalWallpaperCore
import Foundation

/// Rank by the user's query, never by source, availability or selection state.
/// Apply after merging and before limiting so an exact match cannot be hidden
/// behind alphabetically earlier fuzzy matches or a later network response.
enum TerminalProgramSearchRanking {
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func items(_ values: [TerminalWallpaperCatalogItem], query: String) -> [TerminalWallpaperCatalogItem] {
        ranked(values, query: query) { item, query in
            score(item, query: query, aliases: TerminalWallpaperPreset.preset(id: item.id)?.aliases ?? [])
        }
    }

    static func presets(_ values: [TerminalWallpaperPreset], query: String) -> [TerminalWallpaperPreset] {
        ranked(values, query: query) { preset, query in
            score(preset.item, query: query, aliases: preset.aliases, formula: preset.formula)
        }
    }

    private static func ranked<Value>(_ values: [Value], query: String,
        score: (Value, String) -> Int) -> [Value] {
        let query = normalize(query)
        guard !query.isEmpty else { return values }
        return values.enumerated().map { (offset: $0.offset, value: $0.element, score: score($0.element, query)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.value)
    }

    private static func score(_ item: TerminalWallpaperCatalogItem, query: String,
        aliases: [String], formula: String = "") -> Int {
        let names = ([item.title] + item.executableCandidates.map { URL(fileURLWithPath: $0).lastPathComponent }).map(normalize)
        let aliases = aliases.map(normalize)
        let formula = normalize(formula)
        if names.contains(query) { return 60_000 }
        if aliases.contains(query) { return 59_000 }
        if !formula.isEmpty && formula == query { return 58_000 }
        let fields = names + aliases + (formula.isEmpty ? [] : [formula])
        let prefix = min(999, fields.map { zip($0, query).prefix(while: { $0.0 == $0.1 }).count }.max() ?? 0)
        if fields.contains(where: { $0.hasPrefix(query) }) { return 40_000 + prefix }
        if fields.contains(where: { $0.contains(query) }) { return 30_000 + prefix }
        // Providers already filter fuzzy/description matches. Preserve their
        // relative order for ties, while preferring the matching word prefix.
        return prefix
    }
}
