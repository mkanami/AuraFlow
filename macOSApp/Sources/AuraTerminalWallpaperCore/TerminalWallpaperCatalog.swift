import Foundation

public enum TerminalWallpaperCatalogCategory: String, CaseIterable, Identifiable, Sendable {
    case applications
    case utilities

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .applications: return "Terminal Apps"
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
            id: "lavat",
            title: "lavat",
            subtitle: "Animated lava lamp in the terminal",
            category: .applications,
            systemImage: "sparkles.tv",
            executableCandidates: [
                "/opt/homebrew/bin/lavat",
                "/usr/local/bin/lavat",
                "lavat",
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
        if let item = items.first(where: { $0.id == id }) {
            return item
        }
        guard id.hasPrefix("discovered:") else { return nil }
        let path = String(id.dropFirst("discovered:".count))
        return discoveredItem(at: path)
    }

    /// Matches names, descriptions, and executable paths while tolerating a
    /// single-character typo in a query of at least three characters.
    public static func matchesSearch(
        query rawQuery: String,
        item: TerminalWallpaperCatalogItem
    ) -> Bool {
        let query = normalizedSearchValue(rawQuery)
        guard !query.isEmpty else { return true }
        let fields = [item.title, item.subtitle] + item.executableCandidates
        return fields.contains { field in
            fuzzyContains(query: query, value: normalizedSearchValue(field))
        }
    }

    public static func recommendedItems(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [TerminalWallpaperCatalogItem] {
        items.filter { $0.resolvedExecutable(environment: environment) != nil }
    }

    public static func availableItems(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [TerminalWallpaperCatalogItem] {
        let recommended = recommendedItems(environment: environment)
        var result = recommended
        var seenPaths = Set(
            recommended.compactMap { $0.resolvedExecutable(environment: environment) }
                .map(normalizedPath)
        )

        for item in discoveredItems(environment: environment, fileManager: fileManager) {
            guard let executable = item.resolvedExecutable(environment: environment) else { continue }
            guard seenPaths.insert(normalizedPath(executable)).inserted else { continue }
            result.append(item)
        }

        return sorted(result)
    }

    /// Searches the installed executable catalog for a user-entered query.
    ///
    /// The normal discovery pass only scans the executable directories that
    /// are cheap and predictable. Search additionally asks Spotlight for
    /// matching executable files, which covers tools installed in custom
    /// Homebrew, Python, Cargo, npm, or project-specific directories without
    /// recursively scanning the user's home directory on every keystroke.
    public static func searchItems(
        for query: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [TerminalWallpaperCatalogItem] {
        searchItems(
            for: query,
            candidates: availableItems(environment: environment, fileManager: fileManager),
            environment: environment,
            fileManager: fileManager
        )
    }

    /// Searches a previously discovered executable snapshot. Reusing the
    /// snapshot keeps keystrokes from rescanning every executable directory.
    public static func searchItems(
        for query: String,
        candidates: [TerminalWallpaperCatalogItem],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [TerminalWallpaperCatalogItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return sorted(candidates) }

        let localMatches = searchSorted(candidates, query: normalizedQuery)
        // Most terminal programs live in PATH or a standard package-manager
        // bin directory. Avoid launching Spotlight for every partial query
        // when those directories already supplied matches.
        guard localMatches.isEmpty, normalizedQuery.count >= 3 else {
            return localMatches
        }

        var result = candidates
        var seenPaths = Set(
            result.flatMap { $0.executableCandidates }
                .compactMap { $0.contains("/") ? $0 : nil }
                .map(normalizedPath)
        )

        for path in spotlightExecutablePaths(
            matching: normalizedQuery,
            fileManager: fileManager
        ) {
            guard seenPaths.insert(normalizedPath(path)).inserted,
                  let item = discoveredItem(at: path, environment: environment) else {
                continue
            }
            result.append(item)
        }

        return searchSorted(result, query: normalizedQuery)
    }

    public static func discoveredItems(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [TerminalWallpaperCatalogItem] {
        let roots = discoveryRoots(environment: environment)
        var seenPaths = Set(
            items.compactMap { $0.resolvedExecutable(environment: environment) }
                .map(normalizedPath)
        )
        var result: [TerminalWallpaperCatalogItem] = []

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                guard let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey]
                ), values.isDirectory != true,
                    fileManager.isExecutableFile(atPath: entry.path) else {
                    continue
                }
                // Homebrew exposes most commands through symlinks in its bin
                // directory. Keep the link as the user-facing command path,
                // while normalizedPath() still deduplicates its target.
                let path = entry.standardizedFileURL.path
                guard seenPaths.insert(normalizedPath(path)).inserted else { continue }
                result.append(
                    TerminalWallpaperCatalogItem(
                        id: "discovered:\(path)",
                        title: entry.lastPathComponent,
                        subtitle: "Command-line executable · \(path)",
                        category: isSystemRoot(root) ? .utilities : .applications,
                        systemImage: isSystemRoot(root) ? "wrench.and.screwdriver" : "terminal",
                        executableCandidates: [path]
                    )
                )
            }
        }
        return result
    }

    private static func searchSorted(
        _ itemsToSort: [TerminalWallpaperCatalogItem],
        query rawQuery: String
    ) -> [TerminalWallpaperCatalogItem] {
        let query = normalizedSearchValue(rawQuery)
        return itemsToSort
            .filter { matchesSearch(query: query, item: $0) }
            .sorted { lhs, rhs in
                let lhsScore = searchScore(query: query, item: lhs)
                let rhsScore = searchScore(query: query, item: rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return sorted([lhs, rhs]).first?.id == lhs.id
            }
    }

    private static func searchScore(
        query: String,
        item: TerminalWallpaperCatalogItem
    ) -> Int {
        let fields = [item.title] + item.executableCandidates.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let normalizedFields = fields.map(normalizedSearchValue)
        var score = 0

        if normalizedFields.contains(query) {
            score += 1_000
        }
        if normalizedFields.contains(where: { $0.hasPrefix(query) }) {
            score += 800
        }
        if normalizedFields.contains(where: { $0.contains(query) }) {
            score += 600
        }

        // A fuzzy match should prefer the candidate that preserves the
        // longest prefix. This makes `lavac` prefer `lavat` over `javac`.
        let longestPrefix = normalizedFields.map { field in
            zip(field, query).prefix(while: { $0.0 == $0.1 }).count
        }.max() ?? 0
        score += longestPrefix * 10
        return score
    }

    private static func discoveredItem(
        at path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalWallpaperCatalogItem? {
        guard let resolved = TerminalExecutableLocator.resolve(path) else { return nil }
        let root = discoveryRoots(environment: environment)
            .first { path.hasPrefix($0 + "/") }
        return TerminalWallpaperCatalogItem(
            id: "discovered:\(path)",
            title: URL(fileURLWithPath: path).lastPathComponent,
            subtitle: "Command-line executable · \(path)",
            category: root.map(isSystemRoot) == true ? .utilities : .applications,
            systemImage: root.map(isSystemRoot) == true ? "wrench.and.screwdriver" : "terminal",
            executableCandidates: [resolved]
        )
    }

    private static func discoveryRoots(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let standardRoots = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/opt/local/sbin",
            "\(home)/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let pathRoots = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var result: [String] = []
        for root in standardRoots + pathRoots where !root.isEmpty && !result.contains(root) {
            result.append((root as NSString).expandingTildeInPath)
        }
        return result
    }

    private static func spotlightExecutablePaths(
        matching query: String,
        fileManager: FileManager
    ) -> [String] {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/mdfind") else { return [] }
        guard !Task.isCancelled else { return [] }

        let safeQuery = query.filter { character in
            character.isLetter || character.isNumber || character == " " ||
                character == "." || character == "_" || character == "-"
        }
        guard !safeQuery.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemFSName == '*\(safeQuery)*'cd"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let outputBuffer = TerminalWallpaperSearchOutputBuffer()
        let didReachEOF = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                didReachEOF.signal()
                return
            }
            outputBuffer.append(data)
        }
        let didExit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in didExit.signal() }

        do {
            guard !Task.isCancelled else {
                output.fileHandleForReading.readabilityHandler = nil
                return []
            }
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return []
        }

        let deadline = Date().addingTimeInterval(2)
        var sentTermination = false
        while didExit.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if (Task.isCancelled || Date() >= deadline), !sentTermination {
                process.terminate()
                sentTermination = true
            }
        }
        process.waitUntilExit()
        _ = didReachEOF.wait(timeout: .now() + .milliseconds(250))
        output.fileHandleForReading.readabilityHandler = nil

        guard !Task.isCancelled else { return [] }
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: outputBuffer.data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { path in
                !path.contains(".app/") && fileManager.isExecutableFile(atPath: path)
            }
    }

    private static func sorted(
        _ itemsToSort: [TerminalWallpaperCatalogItem]
    ) -> [TerminalWallpaperCatalogItem] {
        itemsToSort.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            let lhsIsRecommended = items.contains { $0.id == lhs.id }
            let rhsIsRecommended = items.contains { $0.id == rhs.id }
            if lhsIsRecommended != rhsIsRecommended {
                return lhsIsRecommended
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func normalizedSearchValue(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func fuzzyContains(query: String, value: String) -> Bool {
        if value.contains(query) {
            return true
        }
        guard query.count >= 3 else { return false }
        let queryCharacters = Array(query)
        let valueCharacters = Array(value)
        let maximumDistance = queryCharacters.count >= 8 ? 2 : 1
        guard !valueCharacters.isEmpty else { return false }

        if valueCharacters.count < queryCharacters.count {
            return levenshteinDistance(valueCharacters, queryCharacters) <= maximumDistance
        }

        let lastStart = valueCharacters.count - queryCharacters.count
        for start in 0...lastStart {
            let window = Array(valueCharacters[start..<(start + queryCharacters.count)])
            if levenshteinDistance(window, queryCharacters) <= maximumDistance {
                return true
            }
        }
        return false
    }

    private static func levenshteinDistance(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Int {
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func isSystemRoot(_ root: String) -> Bool {
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains(root)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class TerminalWallpaperSearchOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
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
