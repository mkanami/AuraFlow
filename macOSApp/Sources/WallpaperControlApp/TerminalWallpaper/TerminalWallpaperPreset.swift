import AuraTerminalWallpaperCore

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
        .init(id: "asciiquarium", description: "Fish and waves", formula: "asciiquarium"),
        .init(id: "lavat", description: "Flowing lava lamp", formula: "lavat"),
        .init(id: "cmatrix", description: "Digital rain", formula: "cmatrix"),
        .init(id: "pipes", description: "Colorful moving lines", formula: "pipes-sh"),
    ]

    static func preset(id: String) -> TerminalWallpaperPreset? {
        featured.first { $0.id == id }
    }
}
