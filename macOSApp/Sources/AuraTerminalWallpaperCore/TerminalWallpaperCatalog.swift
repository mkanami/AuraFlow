import Foundation

public enum TerminalWallpaperCatalogCategory: String, CaseIterable, Identifiable, Sendable {
    case applications
    case utilities

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .applications: return "TUI Apps"
        case .utilities: return "System Utilities"
        }
    }

    public var systemImage: String {
        switch self {
        case .applications: return "square.grid.2x2"
        case .utilities: return "wrench.and.screwdriver"
        }
    }
}

public struct TerminalWallpaperCatalogItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: TerminalWallpaperCatalogCategory
    public let systemImage: String
    public let executableCandidates: [String]
    public let arguments: [String]

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: TerminalWallpaperCatalogCategory,
        systemImage: String,
        executableCandidates: [String],
        arguments: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.systemImage = systemImage
        self.executableCandidates = executableCandidates
        self.arguments = arguments
    }

    public func resolvedExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        TerminalExecutableLocator.resolve(
            candidates: executableCandidates,
            environment: environment
        )
    }

    public func commandConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalCommandConfiguration {
        TerminalCommandConfiguration(
            catalogItemID: id,
            executable: resolvedExecutable(environment: environment) ?? executableCandidates.first ?? "",
            arguments: arguments
        )
    }
}

public enum TerminalWallpaperCatalog {
    public static let items: [TerminalWallpaperCatalogItem] = [
        TerminalWallpaperCatalogItem(
            id: "btop",
            title: "btop",
            subtitle: "Interactive system monitor",
            category: .applications,
            systemImage: "chart.xyaxis.line",
            executableCandidates: [
                "/opt/homebrew/bin/btop",
                "/usr/local/bin/btop",
                "btop",
            ]
        ),
        TerminalWallpaperCatalogItem(
            id: "htop",
            title: "htop",
            subtitle: "Process monitor",
            category: .applications,
            systemImage: "list.bullet.rectangle",
            executableCandidates: [
                "/opt/homebrew/bin/htop",
                "/usr/local/bin/htop",
                "htop",
            ]
        ),
        TerminalWallpaperCatalogItem(
            id: "fastfetch",
            title: "fastfetch",
            subtitle: "System information dashboard",
            category: .applications,
            systemImage: "desktopcomputer",
            executableCandidates: [
                "/opt/homebrew/bin/fastfetch",
                "/usr/local/bin/fastfetch",
                "fastfetch",
            ]
        ),
        TerminalWallpaperCatalogItem(
            id: "top",
            title: "top",
            subtitle: "Live process and CPU monitor",
            category: .utilities,
            systemImage: "waveform.path.ecg",
            executableCandidates: ["/usr/bin/top", "top"]
        ),
        TerminalWallpaperCatalogItem(
            id: "vm-stat",
            title: "vm_stat",
            subtitle: "Live memory statistics",
            category: .utilities,
            systemImage: "memorychip",
            executableCandidates: ["/usr/bin/vm_stat", "vm_stat"],
            arguments: ["2"]
        ),
        TerminalWallpaperCatalogItem(
            id: "iostat",
            title: "iostat",
            subtitle: "Live disk and CPU statistics",
            category: .utilities,
            systemImage: "internaldrive",
            executableCandidates: ["/usr/bin/iostat", "iostat"],
            arguments: ["-w", "2"]
        ),
        TerminalWallpaperCatalogItem(
            id: "log-stream",
            title: "System Log",
            subtitle: "Live compact system log",
            category: .utilities,
            systemImage: "doc.text.magnifyingglass",
            executableCandidates: ["/usr/bin/log", "log"],
            arguments: ["stream", "--style", "compact"]
        ),
    ]

    public static func item(id: String) -> TerminalWallpaperCatalogItem? {
        items.first { $0.id == id }
    }

    public static func availableItems(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [TerminalWallpaperCatalogItem] {
        items.filter { $0.resolvedExecutable(environment: environment) != nil }
    }
}

public enum TerminalExecutableLocator {
    public static func resolve(
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        candidates.lazy.compactMap { resolve($0, environment: environment) }.first
    }

    public static func resolve(
        _ value: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return resolvePath(expanded)
        }

        let paths = (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path)
                .appendingPathComponent(expanded)
                .path
            if let resolved = resolvePath(candidate) {
                return resolved
            }
        }
        return nil
    }

    private static func resolvePath(_ path: String) -> String? {
        let fileManager = FileManager.default
        if path.hasSuffix(".app") {
            guard let bundle = Bundle(path: path), let executableURL = bundle.executableURL else {
                return nil
            }
            guard fileManager.isExecutableFile(atPath: executableURL.path) else { return nil }
            return executableURL.path
        }
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }
}
