import AuraTerminalWallpaperCore
import Foundation
import Combine

protocol TerminalWallpaperCatalogProviding: Sendable {
    func discover(query: String) -> [TerminalWallpaperCatalogItem]
    func refresh()
}

extension TerminalWallpaperCatalogProviding {
    func refresh() {}
}

final class SystemTerminalWallpaperCatalogProvider: TerminalWallpaperCatalogProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let searchItems: @Sendable (String) -> [TerminalWallpaperCatalogItem]
    private var cachedItems: [String: [TerminalWallpaperCatalogItem]] = [:]
    private var generation = 0

    init(
        searchItems: @escaping @Sendable (String) -> [TerminalWallpaperCatalogItem] = {
            TerminalWallpaperCatalog.exactExecutableItems(named: $0)
        }
    ) {
        self.searchItems = searchItems
    }

    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        lock.lock()
        if let cached = cachedItems[query] {
            lock.unlock()
            return cached
        }
        let currentGeneration = generation
        lock.unlock()
        let results = searchItems(query)
        lock.lock()
        if generation == currentGeneration { cachedItems[query] = results }
        lock.unlock()
        return results
    }

    func refresh() {
        lock.lock()
        cachedItems = [:]
        generation &+= 1
        lock.unlock()
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
    @Published private(set) var installStage: String?
    @Published private(set) var status: TerminalWallpaperStatus
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var installHelpURL: URL?

    private let controller: TerminalWallpaperControlling
    private let catalogProvider: any TerminalWallpaperCatalogProviding
    private let installer: any TerminalWallpaperInstalling
    private let resolveExecutable: @Sendable (TerminalWallpaperCatalogItem) -> String?
    private var catalogPrepared = false
    private var catalogSearchGeneration = 0
    private var catalogSearchTask: Task<Void, Never>?
    private var catalogDiscoveryTask: Task<Void, Never>?
    private var catalogDiscoveryWorkerTask: Task<[TerminalWallpaperCatalogItem], Never>?
    private var discoveredCatalogItemsByQuery: [String: [TerminalWallpaperCatalogItem]] = [:]
    private var resolvedExecutableCache: [String: String] = [:]
    private let featuredItems: [TerminalWallpaperCatalogItem]
    private var activeInstallationID: UUID?
    private var statusRefreshInFlight = false
    private var statusRefreshGeneration = 0

    init(
        controller: TerminalWallpaperControlling? = nil,
        catalogProvider: any TerminalWallpaperCatalogProviding = SystemTerminalWallpaperCatalogProvider(),
        installer: any TerminalWallpaperInstalling = SystemTerminalWallpaperInstaller(),
        resolveExecutable: @escaping @Sendable (TerminalWallpaperCatalogItem) -> String? = { $0.resolvedExecutable() }
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
        self.installer = installer
        self.resolveExecutable = resolveExecutable

        let config = (try? resolvedController.status().config) ?? .defaultConfig
        executable = config.command.executable
        argumentsText = config.command.arguments.joined(separator: "\n")
        selectedCatalogItemID = config.command.catalogItemID

        let presets = TerminalWallpaperPreset.featured.map(\.item)
        var executableCache: [String: String] = [:]
        for item in presets {
            if let executable = resolveExecutable(item) {
                executableCache[item.id] = executable
            }
        }

        featuredItems = presets
        catalogItems = presets
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

    var featuredPresets: [TerminalWallpaperPreset] {
        TerminalWallpaperPreset.featured.sorted { lhs, rhs in
            let lhsInstalled = cachedExecutablePath(for: lhs.item) != nil
            let rhsInstalled = cachedExecutablePath(for: rhs.item) != nil
            if lhsInstalled != rhsInstalled { return lhsInstalled }
            return TerminalWallpaperPreset.featured.firstIndex(of: lhs)! < TerminalWallpaperPreset.featured.firstIndex(of: rhs)!
        }
    }

    var activeUnfeaturedTitle: String? {
        guard status.running else { return nil }
        if let id = status.config.command.catalogItemID {
            guard TerminalWallpaperPreset.preset(id: id) == nil else { return nil }
            if let title = TerminalWallpaperCatalog.item(id: id)?.title { return title }
        }
        let name = URL(fileURLWithPath: status.config.command.executable).lastPathComponent
        return name.isEmpty ? nil : name
    }

    func isActive(_ item: TerminalWallpaperCatalogItem) -> Bool {
        guard status.running else { return false }
        if let activeID = status.config.command.catalogItemID { return activeID == item.id }
        return cachedExecutablePath(for: item) == status.config.command.executable
    }

    func executablePath(for item: TerminalWallpaperCatalogItem) -> String? {
        if let cached = resolvedExecutableCache[item.id] {
            return cached
        }
        guard let executable = resolveExecutable(item) else { return nil }
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
    }

    func refreshCatalog() {
        errorMessage = nil
        statusMessage = nil
        installHelpURL = nil
        catalogSearchTask?.cancel()
        catalogDiscoveryTask?.cancel()
        catalogDiscoveryWorkerTask?.cancel()
        catalogSearchTask = nil
        catalogDiscoveryTask = nil
        catalogDiscoveryWorkerTask = nil
        catalogProvider.refresh()
        catalogSearchGeneration &+= 1
        catalogSearch = ""
        discoveredCatalogItemsByQuery = [:]
        resolvedExecutableCache = [:]
        for item in featuredItems {
            if let executable = resolveExecutable(item) {
                resolvedExecutableCache[item.id] = executable
            }
        }
        catalogIsLoading = false
        catalogPrepared = true
        catalogItems = initialCatalogItems
    }

    func setCatalogSearch(_ value: String) {
        guard value != catalogSearch else { return }
        catalogSearch = value
        catalogSearchGeneration &+= 1
        let generation = catalogSearchGeneration
        catalogSearchTask?.cancel()
        catalogDiscoveryTask?.cancel()
        catalogDiscoveryWorkerTask?.cancel()
        catalogSearchTask = nil
        catalogDiscoveryTask = nil
        catalogDiscoveryWorkerTask = nil
        let query = normalizedCatalogSearch

        guard !query.isEmpty else {
            catalogIsLoading = false
            catalogItems = initialCatalogItems
            return
        }

        applyVisibleSearchResults(for: query)
        if discoveredCatalogItemsByQuery[query] != nil || !catalogItems.isEmpty {
            catalogIsLoading = false
            return
        }

        catalogIsLoading = true

        catalogSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self,
                  generation == self.catalogSearchGeneration,
                  !Task.isCancelled else { return }
            self.startCatalogDiscovery()
        }
    }

    var statusTitle: String {
        if status.running && status.health?.childRunning == true { return "Running" }
        if status.running { return "Agent running" }
        return "Stopped"
    }

    func refresh() {
        guard !isBusy, !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        let generation = statusRefreshGeneration
        let controller = controller
        Task { @MainActor in
            defer { statusRefreshInFlight = false }
            guard let latest: TerminalWallpaperStatus = try? await withCheckedThrowingContinuation({ continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try controller.status()) }
                    catch { continuation.resume(throwing: error) }
                }
            }), generation == statusRefreshGeneration, !isBusy else { return }
            apply(latest)
        }
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

    func use(_ item: TerminalWallpaperCatalogItem) {
        guard !isBusy, !isActive(item) else { return }
        isBusy = true
        statusRefreshGeneration &+= 1
        errorMessage = nil
        statusMessage = nil
        installHelpURL = nil
        let installationID = UUID()
        activeInstallationID = installationID
        let controller = controller
        let installer = installer
        let preset = TerminalWallpaperPreset.preset(id: item.id)
        Task { @MainActor in
            defer {
                isBusy = false
                installStage = nil
                activeInstallationID = nil
            }
            do {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { try controller.ensureCanStart(); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                if let preset, cachedExecutablePath(for: item) == nil {
                    try await installer.install(preset: preset) { [weak self] stage in
                        Task { @MainActor in
                            guard self?.activeInstallationID == installationID else { return }
                            self?.installStage = stage
                        }
                    }
                    guard let path = resolveExecutable(item) else {
                        throw TerminalWallpaperInstallError.executableStillMissing
                    }
                    resolvedExecutableCache[item.id] = path
                    applyVisibleSearchResults(for: normalizedCatalogSearch)
                }
                guard cachedExecutablePath(for: item) != nil else {
                    throw TerminalWallpaperInstallError.executableStillMissing
                }
                select(item)
                let config = makeConfig()
                let newStatus: TerminalWallpaperStatus = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { continuation.resume(returning: try controller.start(config: config)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                apply(newStatus)
                statusMessage = "\(item.title) is now your terminal wallpaper."
            } catch {
                errorMessage = error.localizedDescription
                if case TerminalWallpaperInstallError.unsupportedHomebrewPlatform = error {
                    installHelpURL = URL(string: "https://docs.brew.sh/Installation")
                }
            }
        }
    }

    @discardableResult
    func selectCustomExecutable(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" {
            errorMessage = "GUI .app applications cannot be rendered as Terminal Wallpaper. Choose a command-line executable or TUI app."
            return false
        }
        selectedCatalogItemID = nil
        executable = url.path
        errorMessage = nil
        installHelpURL = nil
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
        let worker = Task.detached(priority: .userInitiated) {
            provider.discover(query: query)
        }
        catalogDiscoveryWorkerTask = worker
        catalogDiscoveryTask = Task { [weak self] in
            let discovered = await worker.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.catalogSearchGeneration,
                  self.normalizedCatalogSearch == query else { return }
            self.catalogDiscoveryWorkerTask = nil
            self.discoveredCatalogItemsByQuery[query] = discovered
            for item in discovered {
                if let executable = self.resolveExecutable(item) {
                    self.resolvedExecutableCache[item.id] = executable
                }
            }
            self.catalogDiscoveryTask = nil
            self.catalogIsLoading = false
            self.applyVisibleSearchResults(for: self.normalizedCatalogSearch)
        }
    }

    private func applyVisibleSearchResults(for query: String) {
        guard !query.isEmpty else {
            catalogItems = initialCatalogItems
            return
        }

        var seenIDs = Set<String>()
        let allItems = (initialCatalogItems + (discoveredCatalogItemsByQuery[query] ?? [])).filter {
            seenIDs.insert($0.id).inserted
        }
        let matches = allItems.filter { item in
            TerminalWallpaperPreset.preset(id: item.id) != nil
                ? TerminalWallpaperCatalog.matchesSearch(query: query, item: item, includeExecutablePaths: false)
                : item.title.localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        catalogItems = Array(matches.prefix(5))
    }

    private var initialCatalogItems: [TerminalWallpaperCatalogItem] {
        featuredItems
    }

    private func perform(
        successMessage: String? = nil,
        _ work: @escaping () throws -> TerminalWallpaperStatus
    ) {
        guard !isBusy else { return }
        isBusy = true
        statusRefreshGeneration &+= 1
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
