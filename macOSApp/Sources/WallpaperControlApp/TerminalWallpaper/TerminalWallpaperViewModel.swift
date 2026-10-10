import AuraTerminalWallpaperCore
import Foundation
import Combine
import OSLog

private let terminalWallpaperViewModelLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow", category: "TerminalWallpaperViewModel"
)

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
    @Published var pauseOnFullscreen: Bool
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
    @Published private(set) var availability: [String: TerminalAnimationAvailability] = [:]
    @Published private(set) var libraryIDs: [String] = []
    @Published private(set) var installingAnimationID: String?
    @Published private(set) var needsHomebrew = false

    private let controller: TerminalWallpaperControlling
    private let catalogProvider: any TerminalWallpaperCatalogProviding
    private let installer: any TerminalWallpaperInstalling
    private let resolveExecutable: @Sendable (TerminalWallpaperCatalogItem) -> String?
    private let previewSelectionStore: WallpaperPreviewSelectionStore?
    private let libraryStore: TerminalAnimationLibraryStore
    private let packageProvider: any TerminalAnimationPackageProviding
    private let previewReady: @MainActor (TerminalWallpaperConfig, UUID) async throws -> Void
    private var installationTask: Task<Void, Never>?
    private var availabilityTasks: [String: Task<Void, Never>] = [:]
    private var catalogPrepared = false
    private var catalogSearchGeneration = 0
    private var catalogSearchTask: Task<Void, Never>?
    private var resolvedExecutableCache: [String: String] = [:]
    private let featuredItems: [TerminalWallpaperCatalogItem]
    private var activeInstallationID: UUID?
    private(set) var statusRefreshInFlight = false
    private var statusRefreshGeneration = 0
    private var agentStartObserver: NSObjectProtocol?
    private var previewConfigPersistence: AnyCancellable?
    private var scaleUpdateTask: Task<Void, Never>?
    private var pendingScaleMode: TerminalScaleMode?
    private var scaleUpdateGeneration: UInt = 0
    private var confirmedScaleMode: TerminalScaleMode

    init(
        controller: TerminalWallpaperControlling? = nil,
        catalogProvider: any TerminalWallpaperCatalogProviding = SystemTerminalWallpaperCatalogProvider(),
        installer: any TerminalWallpaperInstalling = SystemTerminalWallpaperInstaller(),
        previewSelectionStore: WallpaperPreviewSelectionStore? = nil,
        resolveExecutable: @escaping @Sendable (TerminalWallpaperCatalogItem) -> String? = { $0.resolvedExecutable() },
        libraryStore: TerminalAnimationLibraryStore = TerminalAnimationLibraryStore(),
        packageProvider: any TerminalAnimationPackageProviding = SystemTerminalAnimationPackageProvider(),
        previewReady: @escaping @MainActor (TerminalWallpaperConfig, UUID) async throws -> Void = { _, _ in
            throw TerminalWallpaperControllerError.unavailable("Preview readiness is unavailable.")
        }
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
        self.previewSelectionStore = previewSelectionStore
        self.libraryStore = libraryStore
        self.packageProvider = packageProvider
        self.previewReady = previewReady

        let runtimeConfig = (try? resolvedController.status().config) ?? .defaultConfig
        let config = previewSelectionStore?.terminalConfiguration ?? runtimeConfig
        executable = config.command.executable
        argumentsText = config.command.arguments.joined(separator: "\n")
        selectedCatalogItemID = config.command.catalogItemID

        let presets = TerminalWallpaperPreset.featured.map(\.item)
        featuredItems = presets
        catalogItems = presets

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
        confirmedScaleMode = config.render.scaleMode
        backgroundHex = Self.hexString(for: config.render.background)
        backgroundOpacity = config.render.backgroundOpacity
        allDisplays = config.behavior.allDisplays
        pauseOnFullscreen = config.behavior.pauseOnFullscreen
        launchAtLogin = config.behavior.launchAtLogin
        status = (try? resolvedController.status()) ?? TerminalWallpaperStatus(
            running: false,
            config: config
        )
        if status.running { reconcileLockScreen() }
        agentStartObserver = DistributedNotificationCenter.default().addObserver(
            forName: TerminalWallpaperRuntimeNotifications.agentDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Status polling, search and progress are not configuration edits.
        // Coalesce actual edits before scheduling persistence on the main actor.
        previewConfigPersistence = configurationEdits
            .filter { [weak self] _ in self?.isBusy == false }
            .debounce(for: .milliseconds(90), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isBusy, self.previewSelectionStore?.pendingOperationID == nil,
                          self.previewSelectionStore?.kind == .terminal else { return }
                    self.previewSelectionStore?.selectTerminal(self.makeConfig())
                }
            }
    }

    private var configurationEdits: AnyPublisher<Void, Never> {
        func edits<T>(_ publisher: Published<T>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return Publishers.MergeMany([
            edits($executable), edits($argumentsText), edits($workingDirectory), edits($environmentText),
            edits($selectedCatalogItemID), edits($pixelMode), edits($fixedWidth), edits($fixedHeight),
            edits($columns), edits($rows), edits($useAutomaticGrid), edits($fontFamily), edits($fontSize),
            edits($cellSpacing), edits($maxFPS), edits($textScale), edits($scaleMode),
            edits($backgroundHex), edits($backgroundOpacity), edits($allDisplays),
            edits($pauseOnFullscreen), edits($launchAtLogin)
        ]).eraseToAnyPublisher()
    }

    deinit {
        if let agentStartObserver {
            DistributedNotificationCenter.default().removeObserver(agentStartObserver)
        }
    }

    var canStart: Bool {
        !isBusy && !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Read the actual selection and runtime separately: editing a command is
    // not selecting a preview, and selecting a preview is not applying it.
    var previewTitle: String? {
        guard previewSelectionStore?.kind == .terminal,
              let command = previewSelectionStore?.terminalConfiguration?.command else { return nil }
        return Self.title(for: command)
    }

    var activeWallpaperTitle: String? {
        guard status.running else { return nil }
        return Self.title(for: status.config.command)
    }

    private static func title(for command: TerminalCommandConfiguration) -> String? {
        if let id = command.catalogItemID, let item = TerminalWallpaperCatalog.item(id: id) {
            return item.title
        }
        let name = URL(fileURLWithPath: command.executable).lastPathComponent
        return name.isEmpty ? nil : name
    }

    var featuredPresets: [TerminalWallpaperPreset] {
        TerminalWallpaperPreset.featured
    }

    var libraryPresets: [TerminalWallpaperPreset] {
        featuredPresets + libraryIDs.compactMap { id in
            guard !featuredPresets.contains(where: { $0.id == id }) else { return nil }
            return TerminalWallpaperPreset.preset(id: id)
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

    func isPreviewSelected(_ item: TerminalWallpaperCatalogItem) -> Bool {
        guard previewSelectionStore?.kind == .terminal,
              let selected = previewSelectionStore?.terminalConfiguration?.command else { return false }
        return selected.catalogItemID == item.id
            || (selected.catalogItemID == nil && selected.executable == cachedExecutablePath(for: item))
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
        guard !catalogPrepared else {
            // Installed programs can be removed or moved while AuraFlow is
            // running. Reopening rechecks presence without resetting the list.
            catalogProvider.refresh()
            for preset in libraryPresets { checkAvailability(preset) }
            return
        }
        catalogPrepared = true
        catalogItems = initialCatalogItems
        Task { [weak self] in
            guard let self else { return }
            do { self.libraryIDs = try await self.libraryStore.load() }
            catch { self.errorMessage = "Could not read the animation library: \(error.localizedDescription)" }
        }
        for preset in TerminalWallpaperPreset.all { checkAvailability(preset) }
    }

    func refreshCatalog() {
        errorMessage = nil
        statusMessage = nil
        installHelpURL = nil
        catalogSearchTask?.cancel()
        catalogSearchTask = nil
        catalogProvider.refresh()
        catalogSearchGeneration &+= 1
        catalogSearch = ""
        resolvedExecutableCache = [:]
        for task in availabilityTasks.values { task.cancel() }
        availabilityTasks = [:]
        availability = [:]
        for preset in TerminalWallpaperPreset.all { checkAvailability(preset) }
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
        catalogSearchTask = nil
        let query = normalizedCatalogSearch
        let retained = Set(libraryPresets.map(\.id) + TerminalWallpaperPreset.search(query).map(\.id))
        for id in Array(availabilityTasks.keys) where !retained.contains(id) {
            availabilityTasks.removeValue(forKey: id)?.cancel()
        }

        guard !query.isEmpty else {
            catalogIsLoading = false
            catalogItems = initialCatalogItems
            return
        }

        catalogItems = TerminalWallpaperPreset.search(query).map(\.item)
        catalogIsLoading = !catalogItems.isEmpty

        catalogSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self,
                  generation == self.catalogSearchGeneration,
                  !Task.isCancelled else { return }
            for preset in TerminalWallpaperPreset.search(query) { self.checkAvailability(preset) }
            self.catalogIsLoading = false
        }
    }

    var statusTitle: String {
        if status.running && status.health?.childRunning == true { return "Running" }
        if status.running { return "Agent running" }
        return "Stopped"
    }

    func refresh() {
        guard !isBusy, scaleUpdateTask == nil, !statusRefreshInFlight else { return }
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
            let wasRunning = status.running
            apply(latest)
            if latest.running && !wasRunning { reconcileLockScreen() }
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
        guard !isBusy else { return }
        guard let preset = TerminalWallpaperPreset.preset(id: item.id), preset.item == item else {
            errorMessage = TerminalWallpaperInstallError.invalidPreset.localizedDescription
            return
        }
        isBusy = true
        statusRefreshGeneration &+= 1
        errorMessage = nil
        statusMessage = nil
        installHelpURL = nil
        let installationID = UUID()
        activeInstallationID = installationID
        installingAnimationID = item.id
        needsHomebrew = false
        let installer = installer
        let selectionRevision = previewSelectionStore?.selectionRevision
        installationTask = Task { @MainActor in
            var addedLibraryID: String?
            defer {
                isBusy = false
                installStage = nil
                activeInstallationID = nil
                installingAnimationID = nil
                installationTask = nil
            }
            do {
                var path = await locate(item)
                try Task.checkCancellation()
                if path == nil {
                    guard installer.homebrewAvailable else {
                        needsHomebrew = true
                        throw TerminalWallpaperInstallError.homebrewRequired
                    }
                    installStage = "Checking package…"
                    let metadata = try await packageProvider.metadata(for: preset)
                    guard metadata.name == preset.formula else { throw TerminalAnimationPackageError.invalidResponse }
                    guard !metadata.disabled else { throw TerminalAnimationPackageError.notFound }
                    try await installer.install(preset: preset) { [weak self] stage in
                        Task { @MainActor in
                            guard self?.activeInstallationID == installationID else { return }
                            self?.installStage = stage
                        }
                    }
                    catalogProvider.refresh()
                    path = await locate(item)
                }
                try Task.checkCancellation()
                guard let path else {
                    throw TerminalWallpaperInstallError.executableStillMissing
                }
                resolvedExecutableCache[item.id] = path
                availability[item.id] = .installed(path)
                guard let store = previewSelectionStore, store.selectionRevision == selectionRevision else { throw CancellationError() }
                var config = makeConfig()
                let command = TerminalCommandConfiguration(catalogItemID: item.id, executable: path, arguments: item.arguments)
                if config.command != command {
                    config.nativeSpeed = nil
                    config.playbackSpeed = 1
                }
                config.command = command
                config = config.normalized()
                installStage = "Starting preview…"
                store.beginTemporaryTerminal(config, operationID: installationID)
                try await previewReady(config, installationID)
                try Task.checkCancellation()
                guard store.pendingOperationID == installationID else { throw CancellationError() }
                // Persist only a confirmed, living preview. The actor serializes
                // atomic library writes and preserves first-add order.
                let previousIDs = try await libraryStore.load()
                guard store.pendingOperationID == installationID else { throw CancellationError() }
                libraryIDs = try await libraryStore.add(preset.id)
                if !previousIDs.contains(preset.id) { addedLibraryID = preset.id }
                try Task.checkCancellation()
                guard store.pendingOperationID == installationID else { throw CancellationError() }
                try store.commitTemporaryTerminal(operationID: installationID)
                select(item)
            } catch is CancellationError {
                if let addedLibraryID { libraryIDs = (try? await libraryStore.remove(addedLibraryID)) ?? libraryIDs }
                previewSelectionStore?.rollbackTemporaryTerminal(operationID: installationID)
            } catch {
                if let addedLibraryID { libraryIDs = (try? await libraryStore.remove(addedLibraryID)) ?? libraryIDs }
                previewSelectionStore?.rollbackTemporaryTerminal(operationID: installationID)
                errorMessage = error.localizedDescription
                if case TerminalWallpaperInstallError.unsupportedHomebrewPlatform = error {
                    installHelpURL = URL(string: "https://docs.brew.sh/Installation")
                }
            }
        }
    }

    func cancelInstallation() { installationTask?.cancel() }

    func prepareHomebrew() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let operationID = UUID()
        activeInstallationID = operationID
        installationTask = Task {
            defer { isBusy = false; installationTask = nil; installStage = nil; activeInstallationID = nil }
            do {
                try await installer.prepareHomebrew { [weak self] stage in
                    Task { @MainActor in
                        guard self?.activeInstallationID == operationID else { return }
                        self?.installStage = stage
                    }
                }
                needsHomebrew = !installer.homebrewAvailable
                statusMessage = "Homebrew is ready. Choose Install & show in preview to continue."
            } catch is CancellationError { }
            catch {
                errorMessage = error.localizedDescription
                installHelpURL = URL(string: "https://docs.brew.sh/Installation")
            }
        }
    }

    private func locate(_ item: TerminalWallpaperCatalogItem) async -> String? {
        let resolve = resolveExecutable
        let provider = catalogProvider
        return await Task.detached(priority: .userInitiated) {
            if let path = resolve(item) { return path }
            // Spotlight gets only reviewed executable names, never search text.
            for name in Set(item.executableCandidates.map { URL(fileURLWithPath: $0).lastPathComponent }) {
                for candidate in provider.discover(query: name) {
                    if let path = resolve(candidate), URL(fileURLWithPath: path).lastPathComponent == name { return path }
                }
            }
            return nil
        }.value
    }

    func checkAvailability(_ preset: TerminalWallpaperPreset) {
        guard availabilityTasks[preset.id] == nil else { return }
        availability[preset.id] = .checking
        availabilityTasks[preset.id] = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.availabilityTasks[preset.id] = nil } }
            let path = await self.locate(preset.item)
            guard !Task.isCancelled else { return }
            if let path {
                self.resolvedExecutableCache[preset.id] = path
                self.availability[preset.id] = .installed(path)
                return
            }
            self.resolvedExecutableCache[preset.id] = nil
            do {
                let metadata = try await self.packageProvider.metadata(for: preset)
                guard !Task.isCancelled else { return }
                guard metadata.name == preset.formula else { throw TerminalAnimationPackageError.invalidResponse }
                self.availability[preset.id] = metadata.disabled ? .unavailable("Package unavailable") : .available(metadata.version)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.availability[preset.id] = error is TerminalAnimationPackageError ? .unavailable(error.localizedDescription) : .failed("Could not check package. Check your connection and retry.")
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
        previewSelectionStore?.selectTerminal(makeConfig())
        statusMessage = nil
        return true
    }

    func setExecutable(_ value: String) {
        selectedCatalogItemID = nil
        executable = value
    }

    func showCurrentCommandInPreview() {
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Choose a terminal executable first."
            return
        }
        errorMessage = nil
        previewSelectionStore?.selectTerminal(makeConfig())
        statusMessage = nil
    }

    var controlsScaleMode: TerminalScaleMode {
        if scaleUpdateTask != nil { return scaleMode }
        return status.running ? status.config.render.scaleMode : scaleMode
    }

    func setScaleMode(_ mode: TerminalScaleMode) {
        guard !isBusy, mode != scaleMode || (status.running && mode != status.config.render.scaleMode) else { return }
        if scaleUpdateTask == nil {
            confirmedScaleMode = controlsScaleMode
        }
        scaleMode = mode
        updatePreviewScale(mode)
        errorMessage = nil
        scaleUpdateGeneration &+= 1
        statusRefreshGeneration &+= 1
        pendingScaleMode = mode
        guard scaleUpdateTask == nil else { return }
        // Keep one worker: cancellation alone cannot stop a synchronous write.
        // Coalesce waiting choices and serialize writes so the last choice wins.
        scaleUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { scaleUpdateTask = nil }
            while let requested = pendingScaleMode {
                pendingScaleMode = nil
                let generation = scaleUpdateGeneration
                let controller = controller
                do {
                    let latest: TerminalWallpaperStatus = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do { continuation.resume(returning: try controller.updateScaleMode(requested)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    if generation == scaleUpdateGeneration || pendingScaleMode != nil {
                        confirmedScaleMode = requested
                    }
                    guard generation == scaleUpdateGeneration else { continue }
                    apply(latest)
                } catch {
                    guard generation == scaleUpdateGeneration else { continue }
                    scaleMode = confirmedScaleMode
                    updatePreviewScale(confirmedScaleMode)
                    errorMessage = "Failed to update scale mode: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updatePreviewScale(_ mode: TerminalScaleMode) {
        guard let store = previewSelectionStore, store.kind == .terminal,
              store.pendingOperationID == nil, var config = store.terminalConfiguration else { return }
        config.render.scaleMode = mode
        store.selectTerminal(config)
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

    private var initialCatalogItems: [TerminalWallpaperCatalogItem] {
        featuredItems
    }

    private func perform(
        successMessage: String? = nil,
        _ work: @escaping () throws -> TerminalWallpaperStatus
    ) {
        guard !isBusy else { return }
        isBusy = true
        pendingScaleMode = nil
        scaleUpdateGeneration &+= 1
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
                confirmedScaleMode = status.config.render.scaleMode
                statusMessage = successMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ status: TerminalWallpaperStatus) {
        if self.status != status { self.status = status }
        if launchAtLogin != status.config.behavior.launchAtLogin {
            launchAtLogin = status.config.behavior.launchAtLogin
        }
        if pauseOnFullscreen != status.config.behavior.pauseOnFullscreen {
            pauseOnFullscreen = status.config.behavior.pauseOnFullscreen
        }
    }

    private func reconcileLockScreen() {
        let controller = controller
        Task { [weak self] in
            do {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            try controller.reconcileLockScreenIfRunning()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                terminalWallpaperViewModelLogger.error(
                    "Lock Screen selection failed: \(error.localizedDescription, privacy: .public)"
                )
                self?.errorMessage = "Lock Screen: \(error.localizedDescription)"
            }
        }
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
        let command = TerminalCommandConfiguration(
            catalogItemID: selectedCatalogItemID,
            executable: executable,
            arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            environment: environment
        )
        let speedConfiguration = previewSelectionStore?.terminalConfiguration ?? status.config
        let preservesSpeed = speedConfiguration.command == command
        return TerminalWallpaperConfig(
            command: command,
            render: render,
            behavior: TerminalWallpaperBehavior(
                launchAtLogin: launchAtLogin,
                allDisplays: allDisplays,
                pauseOnFullscreen: pauseOnFullscreen
            ),
            playbackSpeed: preservesSpeed ? speedConfiguration.playbackSpeed : 1,
            nativeSpeed: preservesSpeed ? speedConfiguration.nativeSpeed : nil
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
