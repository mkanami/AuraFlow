import AuraTerminalWallpaperCore
import Foundation

/// Describes a program, not a shell command. Discovered programs receive no
/// invented launch arguments. Package identity is reverified before installing.
struct TerminalProgramDefinition: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let formula: String
    let executable: String?

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.first?.isLetter == true
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-@".contains($0)) }
    }

    var isValid: Bool {
        Self.validName(name) && (formula.isEmpty || Self.validName(formula))
            && (id == "local:\(name)" || (!formula.isEmpty && id == "brew:\(formula):\(name)"))
            && (executable == nil || (executable!.hasPrefix("/")
                && !executable!.contains(".app/") && !executable!.hasSuffix(".app")
                && URL(fileURLWithPath: executable!).lastPathComponent == name))
    }

    var item: TerminalWallpaperCatalogItem {
        let profile = TerminalWallpaperCompatibility.profile(executable: name, formula: formula)
        return TerminalWallpaperCatalogItem(
            id: id, title: profile?.title ?? name,
            subtitle: name == "lolcat" ? "Animated rainbow text · No audio"
                : name == "cava" ? "Silent visualizer · No audio"
                : executable.map { "Local program · \($0)" } ?? "Homebrew · \(formula)",
            category: .applications, systemImage: "terminal",
            executableCandidates: (executable.map { [$0] } ?? []) + [name],
            arguments: profile?.arguments ?? []
        )
    }

    var preset: TerminalWallpaperPreset {
        let profile = TerminalWallpaperCompatibility.profile(executable: name, formula: formula)
        return .init(id: id, description: profile?.description ?? (name == "lolcat"
              ? "Continuously colors a moving text pattern. No audio; custom arguments keep your own input."
              : name == "cava"
              ? "Animated spectrum bars. No microphone, system-audio capture or sound playback."
              : "Terminal program. Static output is supported; wallpaper compatibility is not verified."),
              formula: formula, program: self)
    }

    static func local(_ item: TerminalWallpaperCatalogItem) -> TerminalWallpaperPreset? {
        guard let path = item.resolvedExecutable(), !path.contains(".app/"),
              !URL(fileURLWithPath: path).resolvingSymlinksInPath().path.contains(".app/") else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let profile = TerminalWallpaperCompatibility.profile(item: item),
           profile.executable == name, let reviewed = TerminalWallpaperPreset.preset(id: profile.id) { return reviewed }
        let value = Self(id: "local:\(name)", name: name, formula: "", executable: path)
        return value.isValid ? value.preset : nil
    }
}
