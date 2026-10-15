import Foundation

/// Apply only reviewed defaults, consistently for catalog, search and custom
/// launches. Unknown CLI options are prepared asynchronously by the app from
/// its restricted help/manual probe and persisted in command.arguments. Never
/// repeat a completed command: it may have irreversible side effects.
enum TerminalWallpaperLaunchDefaults {
    static func arguments(for command: TerminalCommandConfiguration, executable: String) -> [String] {
        guard command.arguments.isEmpty else { return command.arguments }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if let profile = TerminalWallpaperCompatibility.profile(executable: name) { return profile.arguments }
        return TerminalWallpaperCatalog.items.first { item in
            item.executableCandidates.contains { URL(fileURLWithPath: $0).lastPathComponent == name }
        }?.arguments ?? []
    }
}
