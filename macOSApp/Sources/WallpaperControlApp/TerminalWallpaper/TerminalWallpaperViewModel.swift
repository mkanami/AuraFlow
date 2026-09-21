import AuraTerminalWallpaperCore
import Foundation
import Combine

protocol TerminalWallpaperCatalogProviding: Sendable {
    func discover() -> [TerminalWallpaperCatalogItem]
    func discover(query: String) -> [TerminalWallpaperCatalogItem]
}

extension TerminalWallpaperCatalogProviding {
    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        discover()
    }
}

struct SystemTerminalWallpaperCatalogProvider: TerminalWallpaperCatalogProviding {
    func discover() -> [TerminalWallpaperCatalogItem] {
        TerminalWallpaperCatalog.availableItems()
    }

    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        TerminalWallpaperCatalog.searchItems(for: query)
    }
}

@MainActor
final class TerminalWallpaperViewModel: ObservableObject {
    @Published var executable: String
    @Published var argumentsText: String
    @Published var workingDirectory: String
    @Published var environmentText: String
    @Published var pixelMode: TerminalPixelMode
    @Published var fixedWidth: Int
    @Published var fixedHeight: Int
    @Published var columns: Int
    @Published var rows: Int
    @Published var useAutomaticGrid: Bool
    @Published var fontFamily: String
    @Published var fontSize: Double
    @Published var cellSpacing: Double
    @Published var maxFPS: Int
    @Published var textScale: Double
    @Published var scaleMode: TerminalScaleMode
    @Published var backgroundHex: String
    @Published var backgroundOpacity: Double
    @Published var allDisplays: Bool
    @Published var launchAtLogin: Bool
    @Published private(set) var selectedCatalogItemID: String?
    @Published private(set) var catalogItems: [TerminalWallpaperCatalogItem]
    @Published private(set) var catalogSearch = ""
    @Published private(set) var catalogIsLoading = false
    @Published private(set) var catalogHasMore = false
    @Published private(set) var status: TerminalWallpaperStatus
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let controller: TerminalWallpaperControlling
    private let catalogProvider: any TerminalWallpaperCatalogProviding
    private let catalogPageSize = 24
    private var discoveredCatalogItems: [TerminalWallpaperCatalogItem]?
    private var catalogPrepared = false
    private var catalogSearchGeneration = 0
    private var catalogSearchTask: Task<Void, Never>?
    private var catalogDiscoveryTask: Task<Void, Never>?
    private var deferredSearchItems: [TerminalWallpaperCatalogItem] = []
    private var discoveredCatalogItemsByQuery: [String: [TerminalWallpaperCatalogItem]] = [:]
    private var resolvedExecutableCache: [String: String] = [:]
    private let demoCatalogItems: [TerminalWallpaperCatalogItem]

    init(
        controller: TerminalWallpaperControlling? = nil,
        catalogProvider: any TerminalWallpaperCatalogProviding = SystemTerminalWallpaperCatalogProvider()
    ) {
        let resolvedController: TerminalWallpaperControlling
        if let controller {
            resolvedController = controller
        } else if let native = try? NativeTerminalWallpaperController() {
            resolvedController = native
        } else {
            resolvedController = UnavailableTerminalWallpaperController()
        }
        self.controller = resolvedController
        self.catalogProvider = catalogProvider

        let config = (try? resolvedController.status().config) ?? .defaultConfig
        executable = config.command.executable
        argumentsText = config.command.arguments.joined(separator: "\n")
        selectedCatalogItemID = config.command.catalogItemID

        let demoItems = Self.demoCatalogItems()
        var executableCache: [String: String] = [:]
        for item in demoItems {
            if let executable = item.resolvedExecutable() {
                executableCache[item.id] = executable
            }
        }

        demoCatalogItems = demoItems
        catalogItems = demoItems
        resolvedExecutableCache = executableCache

        workingDirectory = config.command.workingDirectory ?? ""
        environmentText = config.command.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        pixelMode = config.render.pixelMode
        fixedWidth = config.render.fixedWidth ?? 1920
        fixedHeight = config.render.fixedHeight ?? 1080
        columns = config.render.columns ?? 120
        rows = config.render.rows ?? 40
        useAutomaticGrid = config.render.columns == nil || config.render.rows == nil
        fontFamily = config.render.fontFamily
        fontSize = config.render.fontSize
        cellSpacing = config.render.cellSpacing
        maxFPS = config.render.maxFPS
        textScale = config.render.textScale
        scaleMode = config.render.scaleMode
        backgroundHex = Self.hexString(for: config.render.background)
        backgroundOpacity = config.render.backgroundOpacity
        allDisplays = config.behavior.allDisplays
        launchAtLogin = config.behavior.launchAtLogin
        status = (try? resolvedController.status()) ?? TerminalWallpaperStatus(
            running: false,
            config: config
        )
    }

    var canStart: Bool {
        !isBusy && !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func availableCatalogItems(
        for category: TerminalWallpaperCatalogCategory
    ) -> [TerminalWallpaperCatalogItem] {
        catalogItems.filter { $0.category == category }
    }

    func executablePath(for item: TerminalWallpaperCatalogItem) -> String? {
        if let cached = resolvedExecutableCache[item.id] {
            return cached
        }
        guard let executable = item.resolvedExecutable() else { return nil }
        resolvedExecutableCache[item.id] = executable
        return executable
    }

    func cachedExecutablePath(for item: TerminalWallpaperCatalogItem) -> String? {
        resolvedExecutableCache[item.id]
    }

    func prepareCatalogIfNeeded() {
        guard !catalogPrepared else { return }
        catalogPrepared = true
        catalogItems = initialCatalogItems
        deferredSearchItems = []
        catalogHasMore = false
    }

    func refreshCatalog() {
        catalogSearchTask?.cancel()
        catalogDiscoveryTask?.cancel()
        catalogSearchTask = nil
        catalogDiscoveryTask = nil
        catalogSearchGeneration &+= 1
        catalogSearch = ""
        discoveredCatalogItems = nil
        discoveredCatalogItemsByQuery = [:]
        resolvedExecutableCache = [:]
        for item in demoCatalogItems {
            if let executable = item.resolvedExecutable() {
                resolvedExecutableCache[item.id] = executable
            }
        }
        deferredSearchItems = []
        catalogIsLoading = false
        catalogPrepared = true
        catalogHasMore = false
        catalogItems = initialCatalogItems
    }

    func setCatalogSearch(_ value: String) {
        catalogSearch = value
        catalogSearchGeneration &+= 1
        let generation = catalogSearchGeneration
        catalogSearchTask?.cancel()
        catalogSearchTask = nil
        let query = normalizedCatalogSearch

        guard !query.isEmpty else {
            catalogDiscoveryTask?.cancel()
            catalogDiscoveryTask = nil
            catalogIsLoading = false
            catalogItems = initialCatalogItems
            deferredSearchItems = []
            catalogHasMore = false
            return
        }

        applyVisibleSearchResults(for: query)
        if let cached = discoveredCatalogItemsByQuery[query] {
            discoveredCatalogItems = cached
            applyVisibleSearchResults(for: query)
            return
        }

        discoveredCatalogItems = nil
        catalogDiscoveryTask?.cancel()
        catalogDiscoveryTask = nil
        catalogIsLoading = false

        catalogSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard let self,
                  generation == self.catalogSearchGeneration,
                  !Task.isCancelled else { return }
            self.startCatalogDiscovery()
        }
    }

    func loadMoreCatalogItems() {
        guard !normalizedCatalogSearch.isEmpty,
              !catalogIsLoading,
              !deferredSearchItems.isEmpty else { return }

        let nextPage = Array(deferredSearchItems.prefix(catalogPageSize))
        deferredSearchItems.removeFirst(nextPage.count)
        catalogItems.append(contentsOf: nextPage)
        catalogHasMore = !deferredSearchItems.isEmpty
    }

    var statusTitle: String {
        if status.running && status.health?.childRunning == true { return "Running" }
        if status.running { return "Agent running" }
        return "Stopped"
    }

    func refresh() {
        let controller = controller
        perform { try controller.status() }
    }

    func start() { applyRuntime(.start) }
    func stop() { applyRuntime(.stop) }
    func restart() { applyRuntime(.restart) }

    func select(_ item: TerminalWallpaperCatalogItem) {
        let command = TerminalCommandConfiguration(
            catalogItemID: item.id,
            executable: executablePath(for: item) ?? item.executableCandidates.first ?? "",
            arguments: item.arguments
        )
        selectedCatalogItemID = item.id
        executable = command.executable
        argumentsText = command.arguments.joined(separator: "\n")
        workingDirectory = ""
        environmentText = ""
    }

    func start(_ item: TerminalWallpaperCatalogItem) {
        select(item)
        start()
    }

    @discardableResult
    func selectCustomExecutable(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" {
            errorMessage = "GUI .app applications cannot be rendered as Terminal Wallpaper. Choose a command-line executable or TUI app."
            return false
        }
        selectedCatalogItemID = nil
        executable = url.path
        argumentsText = ""
        workingDirectory = ""
        environmentText = ""
        return true
    }

    func setExecutable(_ value: String) {
        selectedCatalogItemID = nil
        executable = value
    }

    func apply() {
        let controller = controller
        let config = makeConfig()
        perform(successMessage: "Terminal Wallpaper settings applied.") {
            try controller.update(config: config)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        let controller = controller
        let config = makeConfig()
        perform { try controller.setLaunchAtLogin(enabled, config: config) }
    }

    private enum RuntimeAction { case start, stop, restart }

    private func applyRuntime(_ action: RuntimeAction) {
        let controller = controller
        let config = makeConfig()
        perform(successMessage: action == .stop ? "Terminal Wallpaper stopped." : "Terminal Wallpaper updated.") {
            switch action {
            case .start: return try controller.start(config: config)
            case .stop: return try controller.stop()
            case .restart: return try controller.restart(config: config)
            }
        }
    }

    private func startCatalogDiscovery() {
        let query = normalizedCatalogSearch
        guard !query.isEmpty,
              discoveredCatalogItemsByQuery[query] == nil,
              catalogDiscoveryTask == nil else { return }
        catalogIsLoading = true
        let provider = catalogProvider
        let generation = catalogSearchGeneration
        catalogDiscoveryTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                provider.discover(query: query)
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.catalogSearchGeneration,
                  self.normalizedCatalogSearch == query else { return }
            self.discoveredCatalogItemsByQuery[query] = discovered
            self.discoveredCatalogItems = discovered
            for item in discovered {
                if let executable = item.resolvedExecutable() {
                    self.resolvedExecutableCache[item.id] = executable
                }
            }
            self.catalogDiscoveryTask = nil
            self.catalogIsLoading = false
            if self.normalizedCatalogSearch.isEmpty {
                self.catalogItems = self.initialCatalogItems
                self.deferredSearchItems = []
                self.catalogHasMore = false
            } else {
                self.applyVisibleSearchResults(for: self.normalizedCatalogSearch)
            }
        }
    }

    private func applyVisibleSearchResults(for query: String) {
        guard !query.isEmpty else {
            catalogItems = initialCatalogItems
            deferredSearchItems = []
            catalogHasMore = false
            return
        }

        var seenIDs = Set<String>()
        let allItems = (initialCatalogItems + (discoveredCatalogItems ?? [])).filter {
            seenIDs.insert($0.id).inserted
        }
        let matches = allItems.filter { item in
            TerminalWallpaperCatalog.matchesSearch(query: query, item: item)
                || (executablePath(for: item)?.localizedCaseInsensitiveContains(query) ?? false)
        }
        catalogItems = Array(matches.prefix(catalogPageSize))
        deferredSearchItems = Array(matches.dropFirst(catalogPageSize))
        catalogHasMore = !deferredSearchItems.isEmpty
    }

    private var initialCatalogItems: [TerminalWallpaperCatalogItem] {
        demoCatalogItems
    }

    private static func demoCatalogItems() -> [TerminalWallpaperCatalogItem] {
        let demoIDs = Set(["btop", "htop"])
        return TerminalWallpaperCatalog.items.filter { item in
            demoIDs.contains(item.id) && item.resolvedExecutable() != nil
        }
    }

    private func perform(
        successMessage: String? = nil,
        _ work: @escaping () throws -> TerminalWallpaperStatus
    ) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                let status = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            continuation.resume(returning: try work())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                apply(status)
                statusMessage = successMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ status: TerminalWallpaperStatus) {
        self.status = status
        launchAtLogin = status.config.behavior.launchAtLogin
    }

    private var normalizedCatalogSearch: String {
        catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeConfig() -> TerminalWallpaperConfig {
        var environment: [String: String] = [:]
        for line in environmentText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            environment[parts[0]] = parts[1]
        }
        var render = TerminalRenderConfiguration(
            pixelMode: pixelMode,
            fixedWidth: pixelMode == .fixed ? fixedWidth : nil,
            fixedHeight: pixelMode == .fixed ? fixedHeight : nil,
            columns: useAutomaticGrid ? nil : columns,
            rows: useAutomaticGrid ? nil : rows,
            fontFamily: fontFamily,
            fontSize: fontSize,
            cellSpacing: cellSpacing,
            maxFPS: maxFPS,
            scaleMode: scaleMode,
            background: parseHexColor(backgroundHex),
            backgroundOpacity: backgroundOpacity,
            textScale: textScale
        )
        render = render.normalized()
        return TerminalWallpaperConfig(
            command: TerminalCommandConfiguration(
                catalogItemID: selectedCatalogItemID,
                executable: executable,
                arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
                workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
                environment: environment
            ),
            render: render,
            behavior: TerminalWallpaperBehavior(
                launchAtLogin: launchAtLogin,
                allDisplays: allDisplays
            )
        ).normalized()
    }

    private func parseHexColor(_ value: String) -> TerminalRGBA {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6, let number = UInt64(normalized, radix: 16) else {
            return .black
        }
        return TerminalRGBA(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    private static func hexString(for color: TerminalRGBA) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private final class UnavailableTerminalWallpaperController: TerminalWallpaperControlling {
    func status() throws -> TerminalWallpaperStatus { throw TerminalWallpaperControllerError.unavailable("Terminal Wallpaper runtime unavailable.") }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try fail() }
    func stop() throws -> TerminalWallpaperStatus { try fail() }
    func terminate() throws -> TerminalWallpaperStatus { try fail() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try fail() }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try fail() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try fail() }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try fail() }

    private func fail<T>() throws -> T {
        throw TerminalWallpaperControllerError.unavailable("Terminal Wallpaper runtime unavailable.")
    }
}
