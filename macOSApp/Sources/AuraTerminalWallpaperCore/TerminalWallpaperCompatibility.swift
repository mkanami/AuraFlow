import Foundation

/// Tested default configurations for known wallpaper presets. These records
/// provide launch arguments and aliases; general CLI search is unrestricted.
/// Audit and visually review changes to these preset defaults.
public struct TerminalWallpaperCompatibilityProfile: Equatable, Sendable {
    public enum Mode: String, Sendable { case animated, `static`, dashboard }
    public enum Adapter: String, Sendable { case none, lolcatVisualInput, cavaVisualInput }

    public let id: String
    public let executable: String
    public let formula: String
    public let title: String
    public let description: String
    public let aliases: [String]
    public let mode: Mode
    public let arguments: [String]
    public let adapter: Adapter
    public let verifiedVersions: [String]
    public let verifiedMacOS: [String]

    public var item: TerminalWallpaperCatalogItem {
        let paths = formula.isEmpty ? ["/usr/bin/\(executable)"]
            : ["/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)", executable]
        let icon = TerminalWallpaperCatalog.items.first { $0.id == id }?.systemImage
            ?? (id == "cbonsai-static" ? "tree" : mode == .dashboard ? "chart.xyaxis.line" : "terminal")
        return .init(id: id, title: title, subtitle: description, category: .applications,
                     systemImage: icon,
                     executableCandidates: paths, arguments: arguments)
    }
}

public enum TerminalWallpaperCompatibility {
    public static let revision = 1

    private static func profile(_ id: String, _ executable: String, _ formula: String,
                                _ title: String, _ description: String,
                                _ mode: TerminalWallpaperCompatibilityProfile.Mode,
                                _ version: String, arguments: [String] = [], aliases: [String] = [],
                                adapter: TerminalWallpaperCompatibilityProfile.Adapter = .none, additionalVerifiedVersions: [String] = [])
        -> TerminalWallpaperCompatibilityProfile {
        .init(id: id, executable: executable, formula: formula, title: title, description: description,
              aliases: aliases, mode: mode, arguments: arguments, adapter: adapter,
              verifiedVersions: [version] + additionalVerifiedVersions, verifiedMacOS: ["27.0"])
    }

    public static let profiles: [TerminalWallpaperCompatibilityProfile] = [
        profile("asciiquarium", "asciiquarium", "asciiquarium", "Asciiquarium", "Animated ASCII aquarium", .animated, "1.1",
                aliases: ["aquarium", "fish", "аквариум", "рыбы", "рыбки", "аски аквариум"]),
        profile("lavat", "lavat", "lavat", "lavat", "Animated lava lamp", .animated, "3.0.0",
                aliases: ["lava", "lava lamp", "лава", "лават", "лавовая лампа"]),
        profile("cmatrix", "cmatrix", "cmatrix", "CMatrix", "Falling digital rain", .animated, "2.0",
                aliases: ["matrix", "матрица", "матрикс", "сматрикс"]),
        profile("pipes", "pipes.sh", "pipes-sh", "Pipes", "Moving colorful terminal lines", .animated, "1.3.0",
                aliases: ["pipes", "pipes-sh", "pipe", "трубы", "трубки"]),
        profile("cbonsai", "cbonsai", "cbonsai", "cbonsai", "Growing bonsai trees", .animated, "1.4.2",
                arguments: ["-l", "-i"], aliases: ["bonsai", "tree", "бонсай", "дерево"]),
        profile("nyancat", "nyancat", "nyancat", "Nyan Cat", "Animated rainbow cat", .animated, "1.5.2",
                arguments: ["-n", "-s"], aliases: ["nyan", "nyan cat", "cat", "rainbow cat", "нян", "нян кот", "кот"]),
        profile("cbonsai-static", "cbonsai", "cbonsai", "Bonsai · Static", "A finished ASCII bonsai tree", .static, "1.4.2",
                arguments: ["-p"], aliases: ["bonsai", "static", "tree", "бонсай", "дерево", "статичные", "статик"]),
        profile("btop", "btop", "btop", "btop", "Live resource dashboard", .dashboard, "1.4.7",
                arguments: ["--force-utf", "--update", "2000"], aliases: ["monitor", "dashboard", "монитор"]),
        profile("htop", "htop", "htop", "htop", "Live process dashboard", .dashboard, "3.5.3",
                arguments: ["-d", "20"], aliases: ["monitor", "process", "монитор", "процессы"]),
        profile("fastfetch", "fastfetch", "fastfetch", "fastfetch", "Static system information composition", .static, "2.69.0",
                arguments: ["--config", "none", "--logo-type", "builtin"],
                aliases: ["static", "system", "dashboard", "статичные", "статик", "система"]),
        profile("lolcat", "lolcat", "lolcat", "lolcat", "Animated rainbow text · No audio", .animated, "100.0.1",
                aliases: ["rainbow", "радуга"], adapter: .lolcatVisualInput),
        profile("cava", "cava", "cava", "cava", "Animated spectrum bars · No audio", .animated, "1.0.0",
                aliases: ["spectrum", "visualizer", "спектр", "визуализатор"], adapter: .cavaVisualInput, additionalVerifiedVersions: ["0.10.4"]),
    ]

    public static func profile(id: String) -> TerminalWallpaperCompatibilityProfile? {
        profiles.first { $0.id == id }
    }

    /// The default launch for a binary. Alternate reviewed modes have their own
    /// stable catalog ID (e.g. static bonsai); helper binaries never inherit it.
    public static func profile(executable: String, formula: String = "") -> TerminalWallpaperCompatibilityProfile? {
        profiles.first { $0.executable == executable && (formula.isEmpty || $0.formula == formula) }
    }

    public static func profile(item: TerminalWallpaperCatalogItem) -> TerminalWallpaperCompatibilityProfile? {
        if let profile = profile(id: item.id) { return profile }
        guard let executable = item.executableCandidates.last.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        return profile(executable: executable)
    }
}
