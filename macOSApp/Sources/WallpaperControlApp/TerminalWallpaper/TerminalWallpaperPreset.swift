import AuraTerminalWallpaperCore
import Foundation

struct TerminalWallpaperPreset: Identifiable, Equatable, Sendable {
    let id: String
    let description: String
    let formula: String

    var item: TerminalWallpaperCatalogItem {
        // Every preset is backed by the core catalog so the helper can resolve
        // its stable ID again after AuraFlow quits and relaunches.
        TerminalWallpaperCatalog.item(id: id)!
    }

    static let featured: [TerminalWallpaperPreset] = [
        .init(id: "asciiquarium", description: "An ASCII aquarium with swimming fish, bubbles and waves.", formula: "asciiquarium"),
        .init(id: "lavat", description: "A flowing lava lamp with softly moving, merging blobs.", formula: "lavat"),
        .init(id: "cmatrix", description: "Matrix-style digital rain falling down your screen.", formula: "cmatrix"),
        .init(id: "pipes", description: "Colorful pipes that turn and weave across your screen.", formula: "pipes-sh"),
    ]

    static func preset(id: String) -> TerminalWallpaperPreset? {
        all.first { $0.id == id }
    }

    static let all = featured + [
        TerminalWallpaperPreset(id: "cbonsai", description: "Watch colorful bonsai trees grow, one branch at a time.", formula: "cbonsai"),
        TerminalWallpaperPreset(id: "nyancat", description: "A looping rainbow Nyan Cat animation.", formula: "nyancat"),
    ]

    var aliases: [String] {
        switch id {
        case "asciiquarium": return ["aquarium", "fish", "аквариум", "рыбы", "рыбки", "аски аквариум"]
        case "lavat": return ["lava", "lava lamp", "лава", "лават", "лавовая лампа"]
        case "cmatrix": return ["matrix", "матрица", "матрикс", "сматрикс"]
        case "pipes": return ["pipes.sh", "pipes-sh", "pipe", "трубы", "трубки"]
        case "cbonsai": return ["bonsai", "tree", "бонсай", "дерево"]
        case "nyancat": return ["nyan", "nyan cat", "cat", "rainbow cat", "нян", "нян кот", "кот"]
        default: return []
        }
    }

    static func search(_ rawQuery: String) -> [TerminalWallpaperPreset] {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        return all.compactMap { preset -> (TerminalWallpaperPreset, Int)? in
            let fields = ([preset.id, preset.item.title, preset.formula] + preset.aliases).map(normalize)
            let score = fields.map { field -> Int in
                if field == query { return 3 }
                if field.hasPrefix(query) { return 2 }
                if query.count >= 3 && editDistance(query, field) <= 1 { return 1 }
                return 0
            }.max() ?? 0
            return score > 0 ? (preset, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return all.firstIndex(of: $0.0)! < all.firstIndex(of: $1.0)!
        }.map(\.0)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a), rhs = Array(b)
        guard abs(lhs.count - rhs.count) <= 1 else { return 2 }
        var previous = Array(0...rhs.count)
        for (i, x) in lhs.enumerated() {
            var row = [i + 1]
            for (j, y) in rhs.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return previous.last!
    }
}
