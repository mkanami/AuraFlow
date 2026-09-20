import AuraTerminalWallpaperCore
import Foundation
import Combine

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
    @Published private(set) var status: TerminalWallpaperStatus
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let controller: TerminalWallpaperControlling

    init(controller: TerminalWallpaperControlling? = nil) {
        let resolvedController: TerminalWallpaperControlling
        if let controller {
            resolvedController = controller
        } else if let native = try? NativeTerminalWallpaperController() {
            resolvedController = native
        } else {
            resolvedController = UnavailableTerminalWallpaperController()
        }
        self.controller = resolvedController
        let config = (try? resolvedController.status().config) ?? .defaultConfig
        executable = config.command.executable
        argumentsText = config.command.arguments.joined(separator: "\n")
        selectedCatalogItemID = config.command.catalogItemID
        catalogItems = TerminalWallpaperCatalog.availableItems()
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
        for category: TerminalWallpaperCatalogCategory,
        matching query: String = ""
    ) -> [TerminalWallpaperCatalogItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogItems.filter { item in
            guard item.category == category else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(normalizedQuery)
                || item.subtitle.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func refreshCatalog() {
        catalogItems = TerminalWallpaperCatalog.availableItems()
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
        let command = item.commandConfiguration()
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
