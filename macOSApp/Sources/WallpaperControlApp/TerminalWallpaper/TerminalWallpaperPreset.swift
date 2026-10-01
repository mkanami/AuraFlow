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
        .init(id: "asciiquarium", description: "An ASCII aquarium with swimming fish, bubbles and waves.", formula: "asciiquarium"),
        .init(id: "lavat", description: "A flowing lava lamp with softly moving, merging blobs.", formula: "lavat"),
        .init(id: "cmatrix", description: "Matrix-style digital rain falling down your screen.", formula: "cmatrix"),
        .init(id: "pipes", description: "Colorful pipes that turn and weave across your screen.", formula: "pipes-sh"),
    ]

    static func preset(id: String) -> TerminalWallpaperPreset? {
        featured.first { $0.id == id }
    }
}
