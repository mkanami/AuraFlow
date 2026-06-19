import AppKit
@_exported import AuraWallpaperCore
import AVKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct AdaptiveGlassAppearance: Equatable {
    var topGlassAlpha: CGFloat
    var bottomGlassAlpha: CGFloat
    var topProtectionOverlayOpacity: CGFloat
    var bottomProtectionOverlayOpacity: CGFloat
    var bottomButtonProtectionOpacity: CGFloat
    var bottomButtonHighlightOpacity: CGFloat

    static let `default` = AdaptiveGlassAppearance(
        topGlassAlpha: 1.0,
        bottomGlassAlpha: 1.0,
        topProtectionOverlayOpacity: 0.0,
        bottomProtectionOverlayOpacity: 0.0,
        bottomButtonProtectionOpacity: 0.0,
        bottomButtonHighlightOpacity: 0.055
    )
}

struct CatalogVideoSource: Hashable, Codable {
    let url: URL
    let width: Int
    let height: Int
}

struct CatalogWallpaper: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let category: String
    let attribution: String
    let previewImageURL: URL?
    let sourcePageURL: URL?
    let sources: [CatalogVideoSource]

    static let defaultCatalog: [CatalogWallpaper] = []
}

enum CatalogWallpaperGroup: String, CaseIterable, Identifiable {
    case anime
    case scenic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime:
            return "Anime"
        case .scenic:
            return "Scenic"
        }
    }

    var systemImage: String {
        switch self {
        case .anime:
            return "sparkles"
        case .scenic:
            return "leaf"
        }
    }
}

extension CatalogWallpaper {
    var catalogGroup: CatalogWallpaperGroup {
        if category.localizedCaseInsensitiveCompare("Anime") == .orderedSame ||
            attribution.localizedCaseInsensitiveCompare("MoeWalls") == .orderedSame ||
            sourcePageURL?.host?.localizedCaseInsensitiveContains("moewalls.com") == true {
            return .anime
        }
        return .scenic
    }
}

struct DownloadedCatalogWallpaper: Identifiable, Hashable, Codable {
    let id: String
    let wallpaperID: String
    let title: String
    let category: String
    let attribution: String
    let previewImageURL: URL?
    let localPreviewPath: String?
    let sourcePageURL: URL?
    let localPath: String
    let downloadedAt: Date

    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    var localPreviewURL: URL? {
        guard let localPreviewPath, !localPreviewPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPreviewPath)
    }

    var effectivePreviewURL: URL? {
        localPreviewURL ?? previewImageURL
    }
}

enum CatalogDownloadError: LocalizedError {
    case badStatus(url: URL, statusCode: Int)
    case htmlResponse(url: URL)

    var errorDescription: String? {
        switch self {
        case .badStatus(let url, let statusCode):
            let host = url.host ?? "server"
            switch statusCode {
            case 401, 403:
                return "\(host) blocked the download request (\(statusCode))."
            case 404:
                return "The wallpaper file is no longer available on \(host)."
            case 429:
                return "\(host) is rate-limiting download requests (\(statusCode))."
            case 500...599:
                return "\(host) returned a server error (\(statusCode))."
            default:
                return "\(host) returned HTTP \(statusCode)."
            }
        case .htmlResponse(let url):
            let host = url.host ?? "server"
            return "\(host) returned an HTML page instead of a video file."
        }
    }
}

func catalogOriginHeaderValue(for url: URL) -> String? {
    guard let scheme = url.scheme,
          let host = url.host else {
        return nil
    }

    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.string
}

protocol WallpaperControlling {
    func status() throws -> ControlStatus
    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus
    func stop() throws -> ControlStatus
    func clearWallpaper() throws -> ControlStatus
    func setVideo(_ url: URL) throws -> ControlStatus
    func setSpeed(_ speed: Double) throws -> ControlStatus
    func setInterpolation(_ enabled: Bool) throws -> ControlStatus
    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus
    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus
    func setAutostart(_ enabled: Bool) throws -> ControlStatus
    func metrics() throws -> DaemonMetrics
}

enum NativeWallpaperControllerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

final class NativeWallpaperController: WallpaperControlling {
    private let store: WallpaperRuntimeStore
    private let helperURL: URL

    init(store: WallpaperRuntimeStore = WallpaperRuntimeStore(), helperURL: URL? = nil) throws {
        self.store = store
        self.helperURL = try helperURL ?? Self.resolveHelperURL()
    }

    private static func resolveHelperURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["AURAFLOW_AGENT_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AuraWallpaperAgent"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AuraWallpaperAgent")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw NativeWallpaperControllerError.unavailable("Native wallpaper agent is not bundled with AuraFlow.")
    }

    private func updateConfig(_ block: (inout ControlConfig) -> Void) throws -> ControlConfig {
        var config = store.loadConfig()
        block(&config)
        let normalized = store.normalized(config)
        try store.saveConfig(normalized)
        return normalized
    }

    private func send(_ action: WallpaperRuntimeCommandAction, config: ControlConfig? = nil) throws {
        try store.saveCommand(WallpaperRuntimeCommand(action: action, config: config))
    }

    private func launchAgentIfNeeded() throws {
        if store.processIsAlive(pid: store.loadPID()) {
            return
        }

        store.removeCommand()
        store.removeHealth()
        let task = Process()
        task.executableURL = helperURL
        task.arguments = ["--config", store.configURL.path]
        try task.run()
        try store.savePID(task.processIdentifier)
    }

    func status() throws -> ControlStatus {
        store.status()
    }

    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus {
        let config = try updateConfig { config in
            if let videoURL {
                config.video_path = videoURL.path
            }
            if let speed {
                config.playback_speed = speed
            }
        }
        guard !config.video_path.isEmpty else {
            throw NativeWallpaperControllerError.unavailable("No video configured. Choose a wallpaper first.")
        }
        guard FileManager.default.fileExists(atPath: config.video_path) else {
            throw NativeWallpaperControllerError.unavailable("Video file not found: \(config.video_path)")
        }
        _ = WallpaperDesktopSupport.captureCurrentDesktopWallpaperBackup(appSupportPath: store.appSupportURL.path)
        store.markPaused(false)
        try launchAgentIfNeeded()
        try send(.reload, config: config)
        return store.status()
    }

    func stop() throws -> ControlStatus {
        let config = store.loadConfig()
        store.markPaused(true)
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.pause, config: config)
        }
        return store.status()
    }

    func clearWallpaper() throws -> ControlStatus {
        if store.processIsAlive(pid: store.loadPID()) {
            try? send(.terminate, config: store.loadConfig())
        }
        _ = store.terminateDaemon(timeout: 1.0)
        store.removeCommand()
        store.removeHealth()
        let restored = store.restoreWallpaperBackup()
        return store.status(wallpaperRestored: restored)
    }

    func setVideo(_ url: URL) throws -> ControlStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeWallpaperControllerError.unavailable("Video file not found: \(url.path)")
        }
        let config = try updateConfig { config in
            config.video_path = url.path
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.reload, config: config)
        }
        return store.status()
    }

    func setSpeed(_ speed: Double) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.playback_speed = speed
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setInterpolation(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.blend_interpolation = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.pause_on_fullscreen = enabled
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.scale_mode = mode.commandValue
        }
        if store.processIsAlive(pid: store.loadPID()) {
            try send(.update, config: config)
        }
        return store.status()
    }

    func setAutostart(_ enabled: Bool) throws -> ControlStatus {
        let config = try updateConfig { config in
            config.autostart = enabled
        }
        if enabled {
            guard !config.video_path.isEmpty else {
                throw NativeWallpaperControllerError.unavailable("Choose a video before enabling launch at login.")
            }
            try store.enableLaunchAgent(helperPath: helperURL.path)
        } else {
            store.disableLaunchAgent()
        }
        return store.status()
    }

    func metrics() throws -> DaemonMetrics {
        store.metrics()
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var appliedVideoURL: URL?
    @Published private(set) var pendingPreviewVideoURL: URL?
    @Published var playbackSpeed: Double = 1.0
    @Published var isRunning: Bool = false
    @Published private(set) var isPlaybackActive: Bool = false
    @Published private(set) var isPlaybackPaused: Bool = false
    @Published var autostartEnabled: Bool = false
    @Published var blendInterpolationEnabled: Bool = false
    @Published var pauseOnFullscreenEnabled: Bool = true
    @Published var scaleMode: WallpaperScaleMode = .fill
    @Published var isSettingsOpen: Bool = false
    @Published var isMonitoringOpen: Bool = false
    @Published var monitoringSnapshot: DaemonMetrics?
    @Published var monitoringErrorMessage: String?
    @Published var isMonitoringRefreshing: Bool = false
    @Published var optimizationEnabled: Bool = true
    @Published var optimizationAllowAV1Passthrough: Bool = true
    @Published var optimizationTranscodeH264ToHEVC: Bool = true
    @Published var optimizationForceSoftwareAV1Encode: Bool = false
    @Published private(set) var optimizationHardwareAV1DecodeAvailable: Bool = false
    @Published var optimizationProfile: OptimizationProfile = .balanced
    @Published var optimizationInProgress: Bool = false
    @Published var optimizationProgress: Double = 0.0
    @Published var optimizationLabel: String?
    @Published var isBusy: Bool = false
    @Published var statusMessage: String?
    @Published var alertMessage: String?
    @Published var successBannerMessage: String?
    @Published var previewPlayer: AVPlayer?
    @Published var isCatalogOpen: Bool = false
    @Published var isDownloadedWallpapersOpen: Bool = false
    @Published var selectedCatalogWallpaper: CatalogWallpaper?
    @Published var catalogScrollTargetID: String?
    @Published var catalogSearchText: String = ""
    @Published var selectedCatalogGroup: CatalogWallpaperGroup?
    @Published var catalogDownloadID: String?
    @Published private(set) var catalogWallpapers: [CatalogWallpaper] = []
    @Published private(set) var catalogIsRefreshing: Bool = false
    @Published private(set) var downloadedCatalogWallpapers: [DownloadedCatalogWallpaper] = []
    @Published private(set) var controllerAvailable: Bool = false
    @Published private(set) var adaptiveGlassAppearance: AdaptiveGlassAppearance = .default

    private var controller: WallpaperControlling?
    private let catalogProvider: WallpaperCatalogProviding
    private let optimizer = VideoOptimizer()
    private let optimizationStore: VideoOptimizationStore
    private var previewEndObserver: NSObjectProtocol?
    private var didAttemptAutostartOnLaunch = false
    private var healthMonitorTask: Task<Void, Never>?
    private var isHealthCheckInProgress = false
    private var bridgeFailureCount = 0
    private var daemonSuspiciousPolls = 0
    private var lowPowerAutoPauseActive = false
    private var fullscreenAutoPauseActive = false
    private var monitoringTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var isShuttingDown = false
    private var catalogNavigationLockedUntil: Date = .distantPast
    private var catalogRefreshTask: Task<Void, Never>?
    private var lastCatalogRefreshAt: Date?
    private var successBannerTask: Task<Void, Never>?
    private var controllerBootstrapTask: Task<Void, Never>?
    private var cacheClearTask: Task<Void, Never>?
    private var isControllerBootstrapInProgress = false
    private var previewRenderingSuspended = false
    private var suspendedPreviewRate: Float?
    private var glassAnalysisTask: Task<Void, Never>?

    private let expectedStatusContractVersion = 2
    private let bridgeFailureThreshold = 3
    private let daemonSuspiciousThreshold = 2
    private static let appSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)
    private static let startupConfigURL = appSupportDirectoryURL.appendingPathComponent("config.json")

    var isControllerAvailable: Bool {
        controllerAvailable
    }

    var selectedVideoName: String {
        selectedVideoURL?.lastPathComponent ?? "Not selected"
    }

    var currentVideoURL: URL? {
        selectedVideoURL
    }

    var isStartButtonHighlighted: Bool {
        selectedVideoURL != nil && !isRunning && !isPlaybackPaused
    }

    var isStopButtonHighlighted: Bool {
        appliedVideoURL != nil && isPlaybackPaused
    }

    var canStart: Bool {
        isControllerAvailable && !isBusy && !isRunning && selectedVideoURL != nil
    }

    var canStop: Bool {
        isControllerAvailable && !isBusy && isRunning
    }

    var canClearWallpaper: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleAutostart: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleBlendInterpolation: Bool {
        isControllerAvailable && !isBusy
    }

    var canTogglePauseOnFullscreen: Bool {
        isControllerAvailable && !isBusy
    }

    var canToggleScaleMode: Bool {
        isControllerAvailable && !isBusy
    }

    var canOpenMonitoring: Bool {
        isControllerAvailable
    }

    var canChangeOptimizationSettings: Bool {
        !isBusy && !optimizationInProgress
    }

    var canApplyCatalogWallpaper: Bool {
        isControllerAvailable && !isBusy && catalogDownloadID == nil
    }

    var canClearCache: Bool {
        true
    }

    private var selectedVideoURL: URL? {
        pendingPreviewVideoURL ?? appliedVideoURL
    }

    var filteredCatalogWallpapers: [CatalogWallpaper] {
        let groupFiltered = catalogWallpapers.filter { wallpaper in
            guard let selectedCatalogGroup else { return true }
            return wallpaper.catalogGroup == selectedCatalogGroup
        }
        let query = catalogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupFiltered }
        return groupFiltered.filter { wallpaper in
            wallpaper.title.localizedCaseInsensitiveContains(query)
                || wallpaper.category.localizedCaseInsensitiveContains(query)
        }
    }

    init(
        controller: WallpaperControlling? = nil,
        optimizationStore: VideoOptimizationStore = VideoOptimizationStore(),
        catalogProvider: WallpaperCatalogProviding = ManagedWallpaperCatalogProvider()
    ) {
        self.optimizationStore = optimizationStore
        self.catalogProvider = catalogProvider
        if let controller {
            self.controller = controller
            self.controllerAvailable = true
        } else {
            self.controller = nil
            self.controllerAvailable = false
            self.isControllerBootstrapInProgress = true
        }
        optimizationHardwareAV1DecodeAvailable = optimizer.supportsHardwareAV1Decode()
        applyOptimizationSettings(optimizationStore.load())
        restoreInitialPreviewFromSavedConfig()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginShutdown()
            }
        }
        Task { [weak self] in
            await self?.loadCatalogFromCache()
            await MainActor.run {
                self?.loadDownloadedCatalogWallpapers()
            }
        }
        bootstrapControllerIfNeeded()
        startHealthMonitor()
    }

    deinit {
        healthMonitorTask?.cancel()
        monitoringTask?.cancel()
        catalogRefreshTask?.cancel()
        controllerBootstrapTask?.cancel()
        glassAnalysisTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
        }
        successBannerTask?.cancel()
    }

    func loadStatus() async {
        guard let controller else {
            if !isControllerBootstrapInProgress {
                alertMessage = "Native wallpaper runtime unavailable."
            }
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await runAsync { try controller.status() }
            apply(status: status)
            let needsNormalizationURL = configuredVideoNeedingCompatibilityNormalization(from: status)
            recordBridgeSuccess()
            await startFromAutostartIfNeeded(using: status)
            if let needsNormalizationURL {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    await self?.applyVideoSelection(
                        needsNormalizationURL,
                        surfaceErrors: false
                    )
                }
            }
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "status")
        }
    }

    private func restoreInitialPreviewFromSavedConfig() {
        guard pendingPreviewVideoURL == nil else { return }
        guard let seed = Self.loadStartupPreviewSeed() else { return }
        let videoURL = URL(fileURLWithPath: seed.video_path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return }

        appliedVideoURL = videoURL
        playbackSpeed = seed.playback_speed
        if let rawScaleMode = seed.scale_mode,
           let restoredScaleMode = WallpaperScaleMode(rawValue: rawScaleMode) {
            scaleMode = restoredScaleMode
        }
        configurePreview(for: videoURL)
    }

    private static func loadStartupPreviewSeed() -> ControlConfig? {
        guard let data = try? Data(contentsOf: startupConfigURL) else { return nil }
        return try? JSONDecoder().decode(ControlConfig.self, from: data)
    }

    private func bootstrapControllerIfNeeded() {
        guard controller == nil else { return }
        guard controllerBootstrapTask == nil else { return }

        controllerBootstrapTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let controller = try NativeWallpaperController()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.controller = controller
                    self.controllerAvailable = true
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    Task { @MainActor [weak self] in
                        await self?.loadStatus()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.controller = nil
                    self.controllerAvailable = false
                    self.isControllerBootstrapInProgress = false
                    self.controllerBootstrapTask = nil
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func chooseVideo(force: Bool = false) {
        guard force || !isBusy else { return }
        let panel = NSOpenPanel()
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .gif]
        if let m4v = UTType(filenameExtension: "m4v") {
            types.append(m4v)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectLocalVideoForPreview(url)
        }
    }

    func chooseVideoFromMenuBar() {
        Task { @MainActor in
            var retries = 0
            while isBusy && retries < 20 {
                retries += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            chooseVideo(force: true)
        }
    }

    func openCatalog() {
        isSettingsOpen = false
        closeMonitoring()
        closeDownloadedWallpapers()
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        selectedCatalogGroup = nil
        isCatalogOpen = true
        refreshCatalogIfNeeded()
    }

    func openCatalogFromMenuBar() {
        isSettingsOpen = false
        closeMonitoring()
        closeDownloadedWallpapers()
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        selectedCatalogGroup = nil
        isCatalogOpen = true
        refreshCatalogIfNeeded()
    }

    func openDownloadedWallpapers() {
        isCatalogOpen = false
        selectedCatalogWallpaper = nil
        closeSettings()
        closeMonitoring()
        loadDownloadedCatalogWallpapers()
        isDownloadedWallpapersOpen = true
    }

    func closeDownloadedWallpapers() {
        isDownloadedWallpapersOpen = false
    }

    func applyDownloadedCatalogWallpaper(_ wallpaper: DownloadedCatalogWallpaper) {
        Task {
            let initialURL = wallpaper.localURL
            guard FileManager.default.fileExists(atPath: initialURL.path) else {
                loadDownloadedCatalogWallpapers()
                alertMessage = "Downloaded wallpaper file is missing. Re-download from catalog."
                return
            }

            do {
                let resolvedURL = try await resolveDownloadedCatalogWallpaperURL(wallpaper)
                closeDownloadedWallpapers()
                selectVideoForPreview(resolvedURL, summary: nil)
                applySelectionImmediately(resolvedURL, failureContext: "start")
            } catch {
                alertMessage = "Failed to prepare downloaded wallpaper: \(error.localizedDescription)"
            }
        }
    }

    func openCatalogWallpaper(_ wallpaper: CatalogWallpaper) {
        guard Date() >= catalogNavigationLockedUntil else { return }
        catalogScrollTargetID = wallpaper.id
        selectedCatalogWallpaper = wallpaper
    }

    func navigateBackFromCatalog() {
        if selectedCatalogWallpaper != nil {
            selectedCatalogWallpaper = nil
            catalogNavigationLockedUntil = Date().addingTimeInterval(0.35)
            return
        }
        selectedCatalogWallpaper = nil
        catalogScrollTargetID = nil
        isCatalogOpen = false
        catalogNavigationLockedUntil = Date().addingTimeInterval(0.2)
    }

    func isDownloading(_ wallpaper: CatalogWallpaper) -> Bool {
        catalogDownloadID == wallpaper.id
    }

    func toggleCatalogGroup(_ group: CatalogWallpaperGroup) {
        selectedCatalogGroup = selectedCatalogGroup == group ? nil : group
        catalogScrollTargetID = filteredCatalogWallpapers.first?.id
    }

    func catalogWallpaperCount(in group: CatalogWallpaperGroup) -> Int {
        catalogWallpapers.filter { $0.catalogGroup == group }.count
    }

    func applyCatalogWallpaper(_ wallpaper: CatalogWallpaper) {
        guard canApplyCatalogWallpaper else { return }
        if isCatalogWallpaperAlreadyApplied(wallpaper) {
            showSuccessBanner("Wallpaper is already applied.")
            return
        }
        catalogDownloadID = wallpaper.id

        Task {
            defer { catalogDownloadID = nil }
            do {
                let localURL = try await downloadCatalogVideo(for: wallpaper)
                stageCatalogWallpaperForPreview(wallpaper, localURL: localURL)
                alertMessage = nil
            } catch {
                alertMessage = "Failed to download wallpaper: \(error.localizedDescription)"
            }
        }
    }

    func applyVideoSelection(_ url: URL, surfaceErrors: Bool = true) async {
        guard let controller else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let prepared = try await prepareVideoURLForPlayback(url)
            let status = try await runAsync { try controller.setVideo(prepared.url) }
            apply(status: status)
            recordBridgeSuccess()
            statusMessage = prepared.summary ?? "Wallpaper source updated."
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "set-video", surface: surfaceErrors)
            if surfaceErrors && bridgeFailureCount < bridgeFailureThreshold {
                alertMessage = "Failed to set video: \(error.localizedDescription)"
            }
        }
    }

    func start() {
        guard !isBusy else { return }
        guard !isRunning else { return }
        guard let selectedVideoURL else {
            alertMessage = "Choose a video before starting."
            return
        }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await startWallpaper(using: selectedVideoURL, statusSummary: "Wallpaper started.")
            } catch {
                recordBridgeFailure(error, context: "start")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to start: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard let controller else { return }
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.stop() }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = "Paused on current frame."
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "pause")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to pause: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearWallpaper() {
        guard let controller else { return }
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.clearWallpaper() }
                apply(status: status)
                recordBridgeSuccess()
                if let restored = status.wallpaper_restored {
                    statusMessage = restored ? "Original wallpaper restored." : "Wallpaper backup not found."
                } else {
                    statusMessage = "Removing live wallpaper."
                }
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "clear-wallpaper")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to restore wallpaper: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateSpeed(_ speed: Double) {
        setPreviewPlaybackSpeed(speed)
        guard let controller else { return }
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setSpeed(speed) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = "Speed updated."
                alertMessage = nil
            } catch {
                recordBridgeFailure(error, context: "set-speed")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update speed: \(error.localizedDescription)"
                }
            }
        }
    }

    func setPreviewPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        syncPreviewPlaybackRate()
    }

    func toggleAutostart(_ enabled: Bool) {
        guard !isBusy else {
            autostartEnabled = !enabled
            return
        }
        if enabled && selectedVideoURL == nil {
            autostartEnabled = false
            alertMessage = "Choose a video before enabling launch at login."
            return
        }

        let previous = autostartEnabled
        autostartEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setAutostart(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled ? "Launch at login enabled." : "Launch at login disabled."
                alertMessage = nil
            } catch {
                autostartEnabled = previous
                recordBridgeFailure(error, context: "set-autostart")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update launch at login: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleBlendInterpolation(_ enabled: Bool) {
        guard !isBusy else {
            blendInterpolationEnabled = !enabled
            return
        }

        let previous = blendInterpolationEnabled
        blendInterpolationEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setInterpolation(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled
                    ? "Blend interpolation enabled."
                    : "Blend interpolation disabled."
                alertMessage = nil
            } catch {
                blendInterpolationEnabled = previous
                recordBridgeFailure(error, context: "set-interpolation")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update interpolation: \(error.localizedDescription)"
                }
            }
        }
    }

    func togglePauseOnFullscreen(_ enabled: Bool) {
        guard !isBusy else {
            pauseOnFullscreenEnabled = !enabled
            return
        }

        let previous = pauseOnFullscreenEnabled
        pauseOnFullscreenEnabled = enabled
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setPauseOnFullscreen(enabled) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = enabled
                    ? "Auto-pause on fullscreen enabled."
                    : "Auto-pause on fullscreen disabled."
                alertMessage = nil
            } catch {
                pauseOnFullscreenEnabled = previous
                recordBridgeFailure(error, context: "set-fullscreen-pause")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update fullscreen policy: \(error.localizedDescription)"
                }
            }
        }
    }

    func setScaleMode(_ mode: WallpaperScaleMode) {
        guard !isBusy else { return }
        let previous = scaleMode
        scaleMode = mode
        guard let controller else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let status = try await runAsync { try controller.setScaleMode(mode) }
                apply(status: status)
                recordBridgeSuccess()
                statusMessage = "Scale mode: \(mode.title)."
                alertMessage = nil
            } catch {
                scaleMode = previous
                recordBridgeFailure(error, context: "set-scale")
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to update scale mode: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshMonitoring() {
        Task {
            await refreshMonitoringSnapshot(surfaceErrors: true)
        }
    }

    func openSettings() {
        closeDownloadedWallpapers()
        closeMonitoring()
        isSettingsOpen = true
    }

    func closeSettings() {
        isSettingsOpen = false
    }

    func openMonitoring() {
        closeDownloadedWallpapers()
        closeSettings()
        isMonitoringOpen = true
        monitoringErrorMessage = nil
        startMonitoringLoop()
    }

    func closeMonitoring() {
        isMonitoringOpen = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func setOptimizationEnabled(_ enabled: Bool) {
        optimizationEnabled = enabled
        persistOptimizationSettings()
    }

    func setOptimizationAllowAV1Passthrough(_ enabled: Bool) {
        optimizationAllowAV1Passthrough = enabled
        persistOptimizationSettings()
    }

    func setOptimizationTranscodeH264ToHEVC(_ enabled: Bool) {
        optimizationTranscodeH264ToHEVC = enabled
        persistOptimizationSettings()
    }

    func setOptimizationForceSoftwareAV1Encode(_ enabled: Bool) {
        if enabled && !optimizationHardwareAV1DecodeAvailable {
            optimizationForceSoftwareAV1Encode = false
            statusMessage = "AV1 force encode unavailable: no hardware AV1 decode."
            return
        }
        optimizationForceSoftwareAV1Encode = enabled
        persistOptimizationSettings()
    }

    func setOptimizationProfile(_ profile: OptimizationProfile) {
        optimizationProfile = profile
        persistOptimizationSettings()
    }

    func clearCache() {
        if let cacheClearTask, !cacheClearTask.isCancelled {
            return
        }

        cacheClearTask = Task {
            isBusy = true
            defer {
                isBusy = false
                cacheClearTask = nil
            }

            do {
                let preservedPaths = preservedCachePaths()
                try clearCatalogCache(preserving: preservedPaths)
                try clearOptimizedVideoCache(preserving: preservedPaths)
                CatalogPreviewImageLoader.clearCache()

                if let cacheClearingProvider = catalogProvider as? CatalogCacheClearing {
                    await cacheClearingProvider.clearCache()
                }

                downloadedCatalogWallpapers = []

                if let pendingPreviewURL = pendingPreviewVideoURL,
                   !preservedPaths.contains(pendingPreviewURL.standardizedFileURL.path) {
                    pendingPreviewVideoURL = nil
                }

                catalogWallpapers = []
                selectedCatalogWallpaper = nil
                lastCatalogRefreshAt = nil
                statusMessage = "Cache cleared."
                alertMessage = nil
            } catch {
                alertMessage = "Failed to clear cache: \(error.localizedDescription)"
            }
        }
    }

    func preview() {
        configurePreview(for: selectedVideoURL)
    }

    private func currentOptimizationSettings() -> VideoOptimizationSettings {
        VideoOptimizationSettings(
            enabled: optimizationEnabled,
            allowAV1PassthroughOnHardwareDecode: optimizationAllowAV1Passthrough,
            transcodeH264ToHEVC: optimizationTranscodeH264ToHEVC,
            forceSoftwareAV1Encode: (
                optimizationForceSoftwareAV1Encode
                && optimizationHardwareAV1DecodeAvailable
            ),
            profile: optimizationProfile
        )
    }

    private func applyOptimizationSettings(_ settings: VideoOptimizationSettings) {
        optimizationEnabled = settings.enabled
        optimizationAllowAV1Passthrough = settings.allowAV1PassthroughOnHardwareDecode
        optimizationTranscodeH264ToHEVC = settings.transcodeH264ToHEVC
        optimizationForceSoftwareAV1Encode = (
            settings.forceSoftwareAV1Encode && optimizationHardwareAV1DecodeAvailable
        )
        optimizationProfile = settings.profile
    }

    private func persistOptimizationSettings() {
        optimizationStore.save(currentOptimizationSettings())
    }

    private func prepareVideoURLForPlayback(_ sourceURL: URL) async throws -> (url: URL, summary: String?) {
        let settings = currentOptimizationSettings()
        guard settings.enabled else {
            return (sourceURL, nil)
        }

        if shouldUseFastApplyPath(for: sourceURL, settings: settings) {
            return (sourceURL, "Using source video directly for faster apply.")
        }

        optimizationInProgress = true
        optimizationProgress = 0
        optimizationLabel = "Preparing optimization..."
        defer {
            optimizationInProgress = false
            optimizationProgress = 0
            optimizationLabel = nil
        }

        let result = try await optimizer.optimizeIfNeeded(
            inputURL: sourceURL,
            settings: settings,
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    let value = min(max(progress, 0), 1)
                    self?.optimizationProgress = value
                    let percent = Int((value * 100).rounded())
                    self?.optimizationLabel = "Optimizing video: \(percent)%"
                }
            }
        )

        switch result.decision {
        case .passthrough(let reason):
            return (result.outputURL, reason)
        case .transcode(let reason):
            let summary: String
            if result.fromCache {
                summary = "Using cached optimized video. \(reason)"
            } else {
                summary = "Video optimized for macOS playback. \(reason)"
            }
            return (result.outputURL, summary)
        }
    }

    private func prepareDownloadedCatalogSourceForPlayback(_ sourceURL: URL) async throws -> URL {
        if await isPreviewPlayableVideo(at: sourceURL) {
            return sourceURL
        }

        var settings = currentOptimizationSettings()
        settings.enabled = true

        let result = try await optimizer.optimizeIfNeeded(
            inputURL: sourceURL,
            settings: settings,
            progress: { _ in }
        )

        guard await isPreviewPlayableVideo(at: result.outputURL) else {
            throw URLError(.cannotDecodeContentData)
        }

        return result.outputURL
    }

    private func shouldUseFastApplyPath(for sourceURL: URL, settings: VideoOptimizationSettings) -> Bool {
        guard settings.enabled else { return true }
        guard sourceURL.isFileURL else { return false }

        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            return false
        }

        guard isCatalogManagedVideo(sourceURL) else {
            return false
        }

        return !settings.forceSoftwareAV1Encode
    }

    private func isCatalogManagedVideo(_ sourceURL: URL) -> Bool {
        guard let catalogDirectory = try? catalogDirectoryURL().standardizedFileURL.path else {
            return false
        }
        let standardizedPath = sourceURL.standardizedFileURL.path
        return standardizedPath.hasPrefix(catalogDirectory + "/")
    }

    private func apply(
        status: ControlStatus,
        refreshPreview: Bool = true,
        backgroundUpdate: Bool = false
    ) {
        let hasConfiguredVideo = !status.config.video_path.isEmpty
        let paused = status.paused ?? false
        let effectiveRunning = statusIndicatesActivePlayback(status)
        isRunning = status.running
        isPlaybackActive = effectiveRunning
        isPlaybackPaused = paused && hasConfiguredVideo && !effectiveRunning
        playbackSpeed = status.config.playback_speed
        autostartEnabled = status.autostart ?? status.config.autostart ?? false
        blendInterpolationEnabled = status.config.blend_interpolation ?? false
        pauseOnFullscreenEnabled = status.config.pause_on_fullscreen ?? true
        let previousScaleMode = scaleMode
        scaleMode = WallpaperScaleMode(rawValue: status.config.scale_mode ?? "fill") ?? .fill
        if hasConfiguredVideo {
            let currentURL = URL(fileURLWithPath: status.config.video_path)
            let hasVideoChanged = appliedVideoURL?.path != currentURL.path
            appliedVideoURL = currentURL
            if pendingPreviewVideoURL == nil,
               refreshPreview && (hasVideoChanged || previewPlayer == nil || previousScaleMode != scaleMode) {
                configurePreview(for: currentURL)
            }
        } else {
            appliedVideoURL = nil
            if pendingPreviewVideoURL == nil {
                previewPlayer = nil
            }
        }
        syncPreviewPlaybackRate()
        evaluateStatusContract(status, backgroundUpdate: backgroundUpdate)
        evaluateDaemonHealth(status.health, backgroundUpdate: backgroundUpdate)
    }

    private func startHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self?.recoverPlaybackIfUnexpectedlyStopped()
            }
        }
    }

    private func recoverPlaybackIfUnexpectedlyStopped() async {
        guard !isShuttingDown else { return }
        guard let controller else { return }
        guard !isBusy else { return }
        guard !isHealthCheckInProgress else { return }

        isHealthCheckInProgress = true
        defer { isHealthCheckInProgress = false }

        do {
            let status = try await runAsync { try controller.status() }
            let hasVideo = !status.config.video_path.isEmpty
            let paused = status.paused ?? false
            let shouldRecover = isRunning && !status.running && !paused && hasVideo
            apply(status: status, refreshPreview: false, backgroundUpdate: true)

            let healthSuspicious = status.health?.suspicious ?? false
            let shouldRecoverSuspiciousDaemon = (
                isRunning
                && status.running
                && !paused
                && hasVideo
                && healthSuspicious
                && daemonSuspiciousPolls >= daemonSuspiciousThreshold
            )

            if shouldRecover || shouldRecoverSuspiciousDaemon {
                let recoveredStatus = try await runAsync {
                    try controller.start(videoURL: nil, speed: nil)
                }
                apply(status: recoveredStatus, refreshPreview: false, backgroundUpdate: true)
                recordBridgeSuccess()
                if shouldRecoverSuspiciousDaemon {
                    statusMessage = "Daemon recovered from suspicious state."
                } else {
                    statusMessage = "Playback recovered after interruption."
                }
                alertMessage = nil
            }
        } catch {
            recordBridgeFailure(error, context: "background-health", surface: false)
        }
    }

    private func startMonitoringLoop() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMonitoringSnapshot(surfaceErrors: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isMonitoringOpen else { return }
                await self.refreshMonitoringSnapshot(surfaceErrors: false)
            }
        }
    }

    private func refreshMonitoringSnapshot(surfaceErrors: Bool) async {
        guard !isShuttingDown else { return }
        guard isMonitoringOpen else { return }
        guard let controller else {
            monitoringErrorMessage = "Native wallpaper runtime unavailable."
            return
        }
        if isMonitoringRefreshing {
            return
        }

        isMonitoringRefreshing = true
        defer { isMonitoringRefreshing = false }

        do {
            let metrics = try await runAsync { try controller.metrics() }
            monitoringSnapshot = metrics
            monitoringErrorMessage = nil
        } catch {
            monitoringErrorMessage = error.localizedDescription
            if surfaceErrors {
                alertMessage = "Failed to refresh monitoring: \(error.localizedDescription)"
            }
        }
    }

    private func loadCatalogFromCache() async {
        if let cached = await catalogProvider.loadCachedCatalog(), !cached.isEmpty {
            catalogWallpapers = cached
        }
    }

    private func loadDownloadedCatalogWallpapers() {
        let loaded: [DownloadedCatalogWallpaper]
        do {
            let manifestURL = try downloadedCatalogManifestURL()
            guard let data = try? Data(contentsOf: manifestURL) else {
                let inferred = inferredDownloadedCatalogWallpapersFromDisk()
                downloadedCatalogWallpapers = inferred
                if !inferred.isEmpty {
                    try? persistDownloadedCatalogWallpapers(inferred)
                }
                return
            }
            loaded = try JSONDecoder().decode([DownloadedCatalogWallpaper].self, from: data)
        } catch {
            downloadedCatalogWallpapers = inferredDownloadedCatalogWallpapersFromDisk()
            return
        }

        let existing = loaded.compactMap { item -> DownloadedCatalogWallpaper? in
            guard FileManager.default.fileExists(atPath: item.localURL.path) else {
                return nil
            }

            let repairedPreviewPath: String?
            if let localPreviewPath = item.localPreviewPath,
               FileManager.default.fileExists(atPath: localPreviewPath) {
                repairedPreviewPath = localPreviewPath
            } else {
                repairedPreviewPath = ensureLocalPreviewImage(
                    for: item.localURL,
                    legacyWallpaperID: item.wallpaperID
                )?.path
            }

            return DownloadedCatalogWallpaper(
                id: item.id,
                wallpaperID: item.wallpaperID,
                title: item.title,
                category: item.category,
                attribution: item.attribution,
                previewImageURL: item.previewImageURL,
                localPreviewPath: repairedPreviewPath,
                sourcePageURL: item.sourcePageURL,
                localPath: item.localPath,
                downloadedAt: item.downloadedAt
            )
        }
        var sorted = existing.sorted(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
        if sorted.isEmpty {
            sorted = inferredDownloadedCatalogWallpapersFromDisk()
        }
        downloadedCatalogWallpapers = sorted

        if existing.count != loaded.count {
            try? persistDownloadedCatalogWallpapers(sorted)
        }
    }

    private func refreshCatalogIfNeeded(force: Bool = false) {
        if catalogRefreshTask != nil {
            return
        }
        if !force,
           let lastCatalogRefreshAt,
           Date().timeIntervalSince(lastCatalogRefreshAt) < 60 * 60 * 6 {
            return
        }

        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            catalogIsRefreshing = true
            defer {
                catalogIsRefreshing = false
                catalogRefreshTask = nil
            }

            do {
                let fetched = try await catalogProvider.fetchCatalog { [weak self] partial in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.catalogWallpapers = partial
                        if let selectedCatalogWallpaper = self.selectedCatalogWallpaper {
                            self.selectedCatalogWallpaper = partial.first(where: { $0.id == selectedCatalogWallpaper.id })
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                guard !fetched.isEmpty else {
                    catalogWallpapers = []
                    selectedCatalogWallpaper = nil
                    statusMessage = "Wallpaper catalog returned no wallpapers."
                    lastCatalogRefreshAt = Date()
                    return
                }
                catalogWallpapers = fetched
                if let selectedCatalogWallpaper {
                    self.selectedCatalogWallpaper = fetched.first(where: { $0.id == selectedCatalogWallpaper.id })
                }
                statusMessage = nil
                lastCatalogRefreshAt = Date()
            } catch {
                if catalogWallpapers.isEmpty {
                    selectedCatalogWallpaper = nil
                }
                statusMessage = "Wallpaper catalog unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func downloadCatalogVideo(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let existing = downloadedCatalogWallpapers.first(where: { $0.wallpaperID == wallpaper.id }),
           FileManager.default.fileExists(atPath: existing.localURL.path) {
            if await isPreviewPlayableVideo(at: existing.localURL) {
                return existing.localURL
            }
            try? FileManager.default.removeItem(at: existing.localURL)
        }

        var lastError: Error?

        if isMoeWallsWallpaper(wallpaper) {
            do {
                if let detailSource = try await moeWallsDetailDownloadSource(for: wallpaper) {
                    return try await downloadCatalogSource(detailSource, for: wallpaper)
                }
            } catch {
                lastError = error
            }
        }

        if isMoeWallsWallpaper(wallpaper),
           let pageURL = wallpaper.sourcePageURL {
            do {
                return try await downloadMoeWallsVideo(for: wallpaper, pageURL: pageURL)
            } catch {
                lastError = error
            }
        }

        let sources = try await catalogSources(for: wallpaper)

        for source in sources {
            do {
                return try await downloadCatalogSource(source, for: wallpaper)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.badURL)
    }

    private func moeWallsDetailDownloadSource(for wallpaper: CatalogWallpaper) async throws -> CatalogVideoSource? {
        guard let pageURL = wallpaper.sourcePageURL else { return nil }
        guard let moeWallsSource = catalogProvider as? MoeWallsSource else { return nil }

        let details = try await moeWallsSource.fetchDetails(pageURL: pageURL)
        guard details.hasExplicitPlayableSource == true,
              let downloadURL = details.downloadURL else {
            return nil
        }
        let width = details.resolution?.width ?? 0
        let height = details.resolution?.height ?? 0
        return CatalogVideoSource(url: downloadURL, width: width, height: height)
    }

    private func downloadCatalogSource(_ source: CatalogVideoSource, for wallpaper: CatalogWallpaper) async throws -> URL {
        if isMoeWallsWallpaper(wallpaper),
           source.url.host?.lowercased() == "go.moewalls.com",
           let sourcePageURL = wallpaper.sourcePageURL {
            return try await downloadMoeWallsVideo(for: wallpaper, pageURL: sourcePageURL)
        }

        let widthLabel = source.width > 0 ? String(source.width) : "auto"
        let heightLabel = source.height > 0 ? String(source.height) : "auto"
        let destination = try catalogDirectoryURL().appendingPathComponent(
            "\(wallpaper.id)-\(widthLabel)x\(heightLabel).\(downloadFileExtension(for: source.url))"
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            if await isPreviewPlayableVideo(at: destination) {
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }

        let useBrowserStyleHeaders = shouldUseBrowserStyleHeaders(for: source.url, wallpaper: wallpaper)
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 45
        request.setValue(
            useBrowserStyleHeaders
                ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
                : "AuraFlow/1.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if useBrowserStyleHeaders {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if let sourcePageURL = wallpaper.sourcePageURL {
            request.setValue(sourcePageURL.absoluteString, forHTTPHeaderField: "Referer")
            if source.url.host?.contains("moewalls.com") == true,
               let origin = catalogOriginHeaderValue(for: sourcePageURL) {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
        }

        let session: URLSession
        if useBrowserStyleHeaders {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            session = URLSession(configuration: configuration)
        } else {
            session = .shared
        }

        let (temporaryURL, response) = try await session.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CatalogDownloadError.badStatus(url: source.url, statusCode: httpResponse.statusCode)
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/") || mimeType.contains("html") {
            throw CatalogDownloadError.htmlResponse(url: source.url)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        return try await prepareDownloadedCatalogSourceForPlayback(destination)
    }

    private func downloadMoeWallsVideo(for wallpaper: CatalogWallpaper, pageURL: URL) async throws -> URL {
        let resolver = await MainActor.run {
            let resolver = MoeWallsBrowserResolver()
            return resolver
        }
        let destination = try catalogDirectoryURL().appendingPathComponent("\(wallpaper.id).mp4")
        try? FileManager.default.removeItem(at: destination)
        let downloadedURL = try await resolver.downloadWallpaper(from: pageURL, to: destination)
        guard await isPreviewPlayableVideo(at: downloadedURL) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw URLError(.cannotDecodeContentData)
        }
        return downloadedURL
    }

    private func catalogSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        if !wallpaper.sources.isEmpty {
            var ordered = wallpaper.sources
            if let preferred = preferredSource(for: wallpaper),
               let preferredIndex = ordered.firstIndex(of: preferred),
               preferredIndex != 0 {
                ordered.remove(at: preferredIndex)
                ordered.insert(preferred, at: 0)
            }
            return ordered
        }

        let resolvedURL = try await catalogProvider.resolveDownloadURL(for: wallpaper)
        return [CatalogVideoSource(url: resolvedURL, width: 0, height: 0)]
    }

    private func downloadFileExtension(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.isEmpty {
            return "mp4"
        }
        return ext
    }

    private func isLikelyCatalogVideoResponse(response: URLResponse, sourceURL: URL) -> Bool {
        if let mime = response.mimeType?.lowercased() {
            if mime.hasPrefix("video/") || mime == "application/octet-stream" || mime == "binary/octet-stream" {
                return true
            }
            if mime.hasPrefix("text/") {
                return false
            }
        }
        let ext = sourceURL.pathExtension.lowercased()
        return ["mp4", "webm", "mov", "m4v", "gif"].contains(ext)
    }

    private func isMoeWallsWallpaper(_ wallpaper: CatalogWallpaper) -> Bool {
        wallpaper.attribution == "MoeWalls" || wallpaper.sourcePageURL?.host?.contains("moewalls.com") == true
    }

    private func preferredSource(for wallpaper: CatalogWallpaper) -> CatalogVideoSource? {
        guard !wallpaper.sources.isEmpty else { return nil }
        guard wallpaper.sources.count > 1 else { return wallpaper.sources.first }

        let nativeSources = wallpaper.sources.filter { source in
            isNativePlaybackContainer(source.url)
        }
        let candidateSources = nativeSources.isEmpty ? wallpaper.sources : nativeSources

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let targetWidth = Int(screenFrame.width)
        let targetHeight = Int(screenFrame.height)

        let largerOrEqual = candidateSources.filter { source in
            source.width >= targetWidth && source.height >= targetHeight
        }

        if let best = largerOrEqual.min(by: { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }) {
            return best
        }

        return candidateSources.max(by: { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        })
    }

    private func isNativePlaybackContainer(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v":
            return true
        default:
            return false
        }
    }

    private func shouldUseBrowserStyleHeaders(for sourceURL: URL, wallpaper: CatalogWallpaper) -> Bool {
        guard isMoeWallsWallpaper(wallpaper) else {
            return false
        }

        guard let host = sourceURL.host?.lowercased() else {
            return false
        }

        return host.contains("moewalls.com")
            || host.contains("media.moewalls.com")
            || host.contains("cdn.moewalls.com")
    }

    private func catalogDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func optimizedVideosDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("OptimizedVideos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func downloadedCatalogManifestURL() throws -> URL {
        try catalogDirectoryURL().appendingPathComponent("downloaded-catalog.json")
    }

    private func catalogPreviewImagesDirectoryURL() throws -> URL {
        let directory = try catalogDirectoryURL().appendingPathComponent("PreviewImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localPreviewImageURL(for previewKey: String) throws -> URL {
        try catalogPreviewImagesDirectoryURL().appendingPathComponent("\(previewKey).jpg")
    }

    private func previewImageKey(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.deletingPathExtension().lastPathComponent
    }

    private func existingLocalPreviewImageURL(for previewKey: String) -> URL? {
        guard let url = try? localPreviewImageURL(for: previewKey) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func ensureLocalPreviewImage(for videoURL: URL, legacyWallpaperID: String?) -> URL? {
        let previewKey = previewImageKey(for: videoURL)

        if let existing = existingLocalPreviewImageURL(for: previewKey) {
            return existing
        }

        guard let destinationURL = try? localPreviewImageURL(for: previewKey) else {
            return nil
        }

        if let legacyWallpaperID,
           let legacyURL = existingLocalPreviewImageURL(for: legacyWallpaperID) {
            do {
                try FileManager.default.copyItem(at: legacyURL, to: destinationURL)
                return destinationURL
            } catch {
                return legacyURL
            }
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 960, height: 540)

        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            return nil
        }
    }

    private func registerDownloadedCatalogWallpaper(for wallpaper: CatalogWallpaper, localURL: URL) {
        let normalizedPath = localURL.standardizedFileURL.path
        let localPreviewPath = ensureLocalPreviewImage(for: localURL, legacyWallpaperID: wallpaper.id)?.path
        var updated = downloadedCatalogWallpapers

        let entry = DownloadedCatalogWallpaper(
            id: wallpaper.id,
            wallpaperID: wallpaper.id,
            title: wallpaper.title,
            category: wallpaper.category,
            attribution: wallpaper.attribution,
            previewImageURL: wallpaper.previewImageURL,
            localPreviewPath: localPreviewPath,
            sourcePageURL: wallpaper.sourcePageURL,
            localPath: normalizedPath,
            downloadedAt: Date()
        )

        if let existingIndex = updated.firstIndex(where: { $0.id == entry.id || $0.localPath == entry.localPath }) {
            updated[existingIndex] = entry
        } else {
            updated.append(entry)
        }

        updated.sort(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)
    }

    private func persistDownloadedCatalogWallpapers(_ wallpapers: [DownloadedCatalogWallpaper]) throws {
        let data = try JSONEncoder().encode(wallpapers)
        try data.write(to: try downloadedCatalogManifestURL(), options: .atomic)
    }

    private func syncDownloadedCatalogWallpaperAfterApply(
        wallpaperID: String,
        requestedURL: URL,
        previousVideoPath: String?
    ) {
        guard let appliedURL = appliedVideoURL?.standardizedFileURL else {
            return
        }
        let appliedPath = appliedURL.path
        if let previousVideoPath, previousVideoPath == appliedPath {
            return
        }

        var updated = downloadedCatalogWallpapers
        guard let index = updated.firstIndex(where: { $0.wallpaperID == wallpaperID }) else {
            return
        }

        let normalizedRequestedPath = requestedURL.standardizedFileURL.path
        let normalizedExistingPath = updated[index].localURL.standardizedFileURL.path
        if normalizedExistingPath == appliedPath {
            return
        }

        let normalizedPathToStore: String
        if FileManager.default.fileExists(atPath: appliedPath) {
            normalizedPathToStore = appliedPath
        } else {
            normalizedPathToStore = normalizedRequestedPath
        }

        let current = updated[index]
        updated[index] = DownloadedCatalogWallpaper(
            id: current.id,
            wallpaperID: current.wallpaperID,
            title: current.title,
            category: current.category,
            attribution: current.attribution,
            previewImageURL: current.previewImageURL,
            localPreviewPath: current.localPreviewPath,
            sourcePageURL: current.sourcePageURL,
            localPath: normalizedPathToStore,
            downloadedAt: current.downloadedAt
        )
        downloadedCatalogWallpapers = updated
        try? persistDownloadedCatalogWallpapers(updated)
    }

    private func inferredDownloadedCatalogWallpapersFromDisk() -> [DownloadedCatalogWallpaper] {
        guard let directory = try? catalogDirectoryURL() else {
            return []
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let validExtensions = Set(["mp4", "mov", "m4v", "webm", "gif"])
        let ignoredNames: Set<String> = [
            "waifu-anime-cache.json",
            "waifu-download-links.json",
            "downloaded-catalog.json",
        ]

        let mapped: [DownloadedCatalogWallpaper] = files.compactMap { fileURL in
            let name = fileURL.lastPathComponent
            guard !ignoredNames.contains(name) else { return nil }
            let ext = fileURL.pathExtension.lowercased()
            guard validExtensions.contains(ext) else { return nil }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let downloadedAt = values?.contentModificationDate ?? Date()
            let fileName = fileURL.deletingPathExtension().lastPathComponent

            return DownloadedCatalogWallpaper(
                id: "local-\(fileName)",
                wallpaperID: "local-\(fileName)",
                title: inferredTitleFromDownloadedFileName(fileName),
                category: "Downloaded",
                attribution: "Catalog Cache",
                previewImageURL: nil,
                localPreviewPath: ensureLocalPreviewImage(for: fileURL, legacyWallpaperID: "local-\(fileName)")?.path,
                sourcePageURL: nil,
                localPath: fileURL.standardizedFileURL.path,
                downloadedAt: downloadedAt
            )
        }

        return mapped.sorted(by: { lhs, rhs in
            lhs.downloadedAt > rhs.downloadedAt
        })
    }

    private func inferredTitleFromDownloadedFileName(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { part in
                let word = String(part)
                guard let first = word.first else { return word }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func isCatalogWallpaperAlreadyApplied(_ wallpaper: CatalogWallpaper) -> Bool {
        guard let appliedPath = appliedVideoURL?.standardizedFileURL.path else {
            return false
        }
        guard let downloaded = downloadedCatalogWallpapers.first(where: { $0.wallpaperID == wallpaper.id }) else {
            return false
        }
        return downloaded.localURL.standardizedFileURL.path == appliedPath
    }

    private func showSuccessBanner(_ message: String) {
        successBannerTask?.cancel()
        successBannerMessage = message
        alertMessage = nil
        successBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.successBannerMessage == message {
                self?.successBannerMessage = nil
            }
        }
    }

    private func preservedCachePaths() -> Set<String> {
        var paths: Set<String> = []
        if let appliedVideoURL, (isPlaybackActive || isPlaybackPaused || isRunning) {
            paths.insert(appliedVideoURL.standardizedFileURL.path)
        }
        return paths
    }

    private func clearCatalogCache(preserving preservedPaths: Set<String>) throws {
        let directory = try catalogDirectoryURL()
        let manifestURL = try downloadedCatalogManifestURL()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let standardizedPath = entry.standardizedFileURL.path
            if preservedPaths.contains(standardizedPath) {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }

        downloadedCatalogWallpapers = []
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private func clearOptimizedVideoCache(preserving preservedPaths: Set<String>) throws {
        let directory = try optimizedVideosDirectoryURL()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            if preservedPaths.contains(entry.standardizedFileURL.path) {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func selectVideoForPreview(_ url: URL, summary: String?) {
        pendingPreviewVideoURL = url
        configurePreview(for: url)
        statusMessage = summary
        alertMessage = nil
    }

    func stageCatalogWallpaperForPreview(_ wallpaper: CatalogWallpaper, localURL: URL) {
        registerDownloadedCatalogWallpaper(for: wallpaper, localURL: localURL)
        selectVideoForPreview(localURL, summary: "Wallpaper downloaded. Press Start to apply.")
    }

    func selectLocalVideoForPreview(_ url: URL) {
        selectVideoForPreview(url, summary: "Video loaded into preview. Press Start to apply.")
    }

    private func applySelectionImmediately(_ sourceURL: URL, failureContext: String) {
        guard !isBusy else { return }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await startWallpaper(using: sourceURL, statusSummary: "Wallpaper started.")
            } catch {
                recordBridgeFailure(error, context: failureContext)
                if bridgeFailureCount < bridgeFailureThreshold {
                    alertMessage = "Failed to start: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startWallpaper(using sourceURL: URL, statusSummary: String) async throws {
        guard let controller else { return }

        let prepared = try await prepareVideoURLForPlayback(sourceURL)
        let finalStatus = try await runAsync { try controller.start(videoURL: prepared.url, speed: nil) }

        pendingPreviewVideoURL = nil
        apply(status: finalStatus)
        if sourceURL.standardizedFileURL.path != prepared.url.standardizedFileURL.path,
           await isPreviewPlayableVideo(at: sourceURL) {
            configurePreview(for: sourceURL)
        }
        recordBridgeSuccess()
        statusMessage = prepared.summary ?? statusSummary
        alertMessage = nil
    }

    private func resolveDownloadedCatalogWallpaperURL(_ wallpaper: DownloadedCatalogWallpaper) async throws -> URL {
        if await isPreviewPlayableVideo(at: wallpaper.localURL) {
            return wallpaper.localURL
        }

        let surrogate = CatalogWallpaper(
            id: wallpaper.wallpaperID,
            title: wallpaper.title,
            category: wallpaper.category,
            attribution: wallpaper.attribution,
            previewImageURL: wallpaper.previewImageURL,
            sourcePageURL: wallpaper.sourcePageURL,
            sources: []
        )
        return try await downloadCatalogVideo(for: surrogate)
    }

    private func isPreviewPlayableVideo(at url: URL) async -> Bool {
        if url.pathExtension.lowercased() == "gif" {
            return true
        }

        let asset = AVURLAsset(url: url)

        do {
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return playable && !tracks.isEmpty
        } catch {
            return false
        }
    }

    private func configurePreview(for url: URL?) {
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
            self.previewEndObserver = nil
        }

        if let previewPlayer {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
        }

        guard let url else {
            previewPlayer = nil
            adaptiveGlassAppearance = .default
            return
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.35
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        applyPreviewPlaybackRate(to: player)

        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            player.seek(to: .zero)
            Task { @MainActor [weak self] in
                self?.applyPreviewPlaybackRate(to: player)
            }
        }

        previewPlayer = player
        scheduleAdaptiveGlassRefresh(for: url)
    }

    private func scheduleAdaptiveGlassRefresh(for url: URL) {
        glassAnalysisTask?.cancel()
        let requestedURL = url.standardizedFileURL
        let requestedScaleMode = scaleMode

        glassAnalysisTask = Task.detached(priority: .utility) { [requestedURL, requestedScaleMode] in
            let appearance = Self.adaptiveGlassAppearance(for: requestedURL, scaleMode: requestedScaleMode)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentURL = self.selectedVideoURL?.standardizedFileURL
                let appliedURL = self.appliedVideoURL?.standardizedFileURL
                let pendingURL = self.pendingPreviewVideoURL?.standardizedFileURL
                guard currentURL == requestedURL || appliedURL == requestedURL || pendingURL == requestedURL else {
                    return
                }
                self.adaptiveGlassAppearance = appearance
            }
        }
    }

    nonisolated static func adaptiveGlassAppearance(for url: URL, scaleMode: WallpaperScaleMode) -> AdaptiveGlassAppearance {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 240, height: 135)

        let sampleTime: Double
        switch scaleMode {
        case .fill:
            sampleTime = 0.5
        case .fit, .stretch:
            sampleTime = 0.2
        }

        let time = CMTime(seconds: sampleTime, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return .default
        }
        return adaptiveGlassAppearance(for: cgImage)
    }

    nonisolated static func adaptiveGlassAppearance(for cgImage: CGImage) -> AdaptiveGlassAppearance {
        let width = 120
        let height = 68
        guard let pixels = rgbaPixels(from: cgImage, width: width, height: height) else {
            return .default
        }

        let topStats = luminanceStats(
            pixels: pixels,
            width: width,
            height: height,
            region: CGRect(x: 0.26, y: 0.04, width: 0.48, height: 0.10)
        )
        let bottomStats = luminanceStats(
            pixels: pixels,
            width: width,
            height: height,
            region: CGRect(x: 0.08, y: 0.80, width: 0.84, height: 0.16)
        )

        let topProtection = protectionLevel(for: topStats)
        let bottomProtection = protectionLevel(for: bottomStats)

        return AdaptiveGlassAppearance(
            topGlassAlpha: 1.0 - (0.08 * topProtection),
            bottomGlassAlpha: 1.0 - (0.10 * bottomProtection),
            topProtectionOverlayOpacity: 0.016 * topProtection,
            bottomProtectionOverlayOpacity: 0.020 * bottomProtection,
            bottomButtonProtectionOpacity: 0.014 * bottomProtection,
            bottomButtonHighlightOpacity: max(0.018, 0.055 - (0.040 * bottomProtection))
        )
    }

    nonisolated private static func protectionLevel(for stats: LuminanceStats) -> CGFloat {
        let bright = normalized(stats.mean, lower: 0.72, upper: 0.96)
        let flat = 1.0 - normalized(stats.standardDeviation, lower: 0.07, upper: 0.24)
        let protection = bright * (0.35 + (flat * 0.65))
        return min(max(protection, 0.0), 1.0)
    }

    nonisolated private static func normalized(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0.0), 1.0)
    }

    nonisolated private static func rgbaPixels(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    nonisolated private static func luminanceStats(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: CGRect
    ) -> LuminanceStats {
        let minX = max(Int(CGFloat(width) * region.minX), 0)
        let maxX = min(Int(CGFloat(width) * region.maxX), width)
        let minY = max(Int(CGFloat(height) * region.minY), 0)
        let maxY = min(Int(CGFloat(height) * region.maxY), height)

        var luminanceValues: [CGFloat] = []
        luminanceValues.reserveCapacity(max((maxX - minX) * (maxY - minY), 1))

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = ((y * width) + x) * 4
                let red = CGFloat(pixels[offset]) / 255.0
                let green = CGFloat(pixels[offset + 1]) / 255.0
                let blue = CGFloat(pixels[offset + 2]) / 255.0
                let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                luminanceValues.append(luminance)
            }
        }

        guard !luminanceValues.isEmpty else {
            return LuminanceStats(mean: 0.0, standardDeviation: 0.0)
        }

        let mean = luminanceValues.reduce(0, +) / CGFloat(luminanceValues.count)
        let variance = luminanceValues.reduce(0) { partialResult, value in
            let delta = value - mean
            return partialResult + (delta * delta)
        } / CGFloat(luminanceValues.count)

        return LuminanceStats(mean: mean, standardDeviation: sqrt(variance))
    }

    private struct LuminanceStats {
        let mean: CGFloat
        let standardDeviation: CGFloat
    }

    private func previewPlaybackRate() -> Float {
        Float(max(0.1, min(playbackSpeed, 4.0)))
    }

    private func statusIndicatesActivePlayback(_ status: ControlStatus) -> Bool {
        let paused = status.paused ?? false
        let healthSuspicious = status.health?.suspicious ?? false
        return status.running && !paused && !healthSuspicious
    }

    nonisolated static func previewPlaybackNeedsRestart(
        currentRate: Float,
        desiredRate: Float,
        timeControlStatus: AVPlayer.TimeControlStatus
    ) -> Bool {
        timeControlStatus != .playing || abs(currentRate - desiredRate) > 0.001
    }

    private func applyPreviewPlaybackRate(to player: AVPlayer) {
        guard !previewRenderingSuspended else { return }
        let rate = previewPlaybackRate()
        guard Self.previewPlaybackNeedsRestart(
            currentRate: player.rate,
            desiredRate: rate,
            timeControlStatus: player.timeControlStatus
        ) else {
            return
        }
        player.playImmediately(atRate: rate)
    }

    private func syncPreviewPlaybackRate() {
        guard let previewPlayer else { return }
        applyPreviewPlaybackRate(to: previewPlayer)
    }

    func suspendPreviewRenderingForWindowDrag() {
        guard !previewRenderingSuspended else { return }
        guard let previewPlayer else { return }
        previewRenderingSuspended = true
        suspendedPreviewRate = previewPlayer.rate
        previewPlayer.pause()
    }

    func resumePreviewRenderingAfterWindowDrag() {
        guard previewRenderingSuspended else { return }
        previewRenderingSuspended = false
        suspendedPreviewRate = nil
        syncPreviewPlaybackRate()
    }

    private func startFromAutostartIfNeeded(using status: ControlStatus) async {
        guard !isShuttingDown else { return }
        guard let controller else { return }
        guard !didAttemptAutostartOnLaunch else { return }
        didAttemptAutostartOnLaunch = true

        let autostart = status.autostart ?? status.config.autostart ?? false
        guard autostart else { return }
        guard !status.running else { return }
        guard !status.config.video_path.isEmpty else { return }

        do {
            let updatedStatus = try await runAsync {
                try controller.start(videoURL: nil, speed: nil)
            }
            apply(status: updatedStatus)
            recordBridgeSuccess()
            statusMessage = "Launch at login: wallpaper started."
            alertMessage = nil
        } catch {
            recordBridgeFailure(error, context: "autostart-start")
            if bridgeFailureCount < bridgeFailureThreshold {
                alertMessage = "Launch at login error: \(error.localizedDescription)"
            }
        }
    }

    private func evaluateStatusContract(
        _ status: ControlStatus,
        backgroundUpdate: Bool
    ) {
        guard let version = status.contract_version else { return }
        guard version < expectedStatusContractVersion else { return }

        daemonSuspiciousPolls = max(daemonSuspiciousPolls, daemonSuspiciousThreshold)
        let message = "Control contract mismatch (expected \(expectedStatusContractVersion), got \(version))."
        if !backgroundUpdate {
            alertMessage = message
        } else {
            statusMessage = "Daemon contract warning."
        }
    }

    private func evaluateDaemonHealth(
        _ health: DaemonHealth?,
        backgroundUpdate: Bool
    ) {
        guard let health else {
            daemonSuspiciousPolls = 0
            lowPowerAutoPauseActive = false
            fullscreenAutoPauseActive = false
            return
        }

        let autoPausedForLowPower = health.auto_paused_for_low_power ?? false
        if autoPausedForLowPower && !lowPowerAutoPauseActive {
            lowPowerAutoPauseActive = true
            statusMessage = "Low Power Mode: wallpaper paused automatically."
        } else if !autoPausedForLowPower && lowPowerAutoPauseActive {
            lowPowerAutoPauseActive = false
            statusMessage = "Low Power Mode off: wallpaper resumed."
        }

        let autoPausedForFullscreen = health.auto_paused_for_fullscreen ?? false
        if autoPausedForFullscreen && !fullscreenAutoPauseActive {
            fullscreenAutoPauseActive = true
            statusMessage = "Fullscreen app detected: wallpaper paused."
        } else if !autoPausedForFullscreen && fullscreenAutoPauseActive {
            fullscreenAutoPauseActive = false
            statusMessage = "Fullscreen app closed: wallpaper resumed."
        }

        let suspicious = health.suspicious ?? false
        if suspicious {
            daemonSuspiciousPolls += 1
            if daemonSuspiciousPolls == daemonSuspiciousThreshold {
                let reason = normalizedDaemonReason(health.reason)
                let warning = "Daemon warning: \(reason)."
                if backgroundUpdate {
                    statusMessage = warning
                } else {
                    alertMessage = warning
                }
            }
        } else {
            daemonSuspiciousPolls = 0
        }
    }

    private func normalizedDaemonReason(_ reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "unknown issue"
        }
        return trimmed.replacingOccurrences(of: ",", with: ", ")
    }

    private func configuredVideoNeedingCompatibilityNormalization(from status: ControlStatus) -> URL? {
        let path = status.config.video_path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["webm", "mkv"].contains(ext) {
            return url
        }
        return nil
    }

    private func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        healthMonitorTask?.cancel()
        monitoringTask?.cancel()
    }

    private func recordBridgeSuccess() {
        if bridgeFailureCount >= bridgeFailureThreshold {
            statusMessage = "Native wallpaper runtime recovered."
        }
        bridgeFailureCount = 0
    }

    private func recordBridgeFailure(
        _ error: Error,
        context: String,
        surface: Bool = true
    ) {
        bridgeFailureCount += 1
        let description = error.localizedDescription

        if bridgeFailureCount >= bridgeFailureThreshold {
            alertMessage = "Native wallpaper runtime unstable (\(context)): \(description)"
            statusMessage = "Bridge health warning."
            return
        }

        if surface {
            alertMessage = description
        }
    }

    private func runAsync<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
