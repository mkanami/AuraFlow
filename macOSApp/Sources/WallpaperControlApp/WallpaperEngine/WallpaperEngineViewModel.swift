import AppKit
import AuraWallpaperEngineCore
import AuraWallpaperCore
import AuraTerminalWallpaperCore
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WallpaperEngineViewModel: ObservableObject {
    @Published private(set) var projects: [WallpaperEngineProject]
    @Published var candidates: [WallpaperEngineCandidate] = []
    @Published var selectedCandidates: Set<String> = []
    @Published var showsProjectPicker = false
    @Published var showsProperties = false
    @Published var libraryIsSelected = false
    @Published private(set) var isImporting = false
    @Published private(set) var isBusy = false
    @Published private(set) var runtimeActive = WebWallpaperRuntime.active
    @Published var error: String?
    @Published var message: String?
    @Published private(set) var values: [String: ProjectValue] = [:]
    private let library: WallpaperEngineLibrary
    let selection: WallpaperPreviewSelectionStore
    var videoPreview: ((WallpaperEngineProject) -> Void)?
    var videoActive: (() -> Bool)?
    var terminalActive: (() -> Bool)?
    var runtimeIsActive: () -> Bool = { WebWallpaperRuntime.active }
    var startWallpaper: @MainActor (WebWallpaperConfiguration) async throws -> Void = { config in
        try await Task.detached(priority: .userInitiated) { try WebWallpaperController.start(config) }.value
    }
    var removeWallpaper: @MainActor () async throws -> Void = {
        try await Task.detached(priority: .userInitiated) { try WebWallpaperController.remove() }.value
    }
    private var timer: Timer?
    private var importTask: Task<Void, Never>?
    private var importGeneration = 0
    private var propertyTask: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var cachedConfig: WebWallpaperConfiguration?

    init(selection: WallpaperPreviewSelectionStore, library: WallpaperEngineLibrary = WallpaperEngineLibrary()) {
        self.selection = selection; self.library = library; projects = library.projects()
        observer = selection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.reloadValues() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRuntime() }
        }
        reloadValues()
    }
    deinit { timer?.invalidate(); importTask?.cancel(); propertyTask?.cancel() }
    var selectedProject: WallpaperEngineProject? { projects.first { $0.id == selection.webProjectID } }
    var previewConfiguration: WebWallpaperConfiguration? {
        guard let project = selectedProject else { return nil }
        if cachedConfig?.project.id != project.id {
            cachedConfig = WebWallpaperConfiguration(project: project, values: values)
        }
        cachedConfig?.values = values
        return cachedConfig
    }
    var canStart: Bool { selection.kind == .web && selectedProject != nil && !isBusy && videoActive?() != true && terminalActive?() != true && !runtimeActive }
    func chooseImport() {
        guard !isImporting else { return }
        let lastPath = UserDefaults.standard.string(forKey: "WallpaperEngineLastImportDirectory")
        importGeneration += 1; let generation = importGeneration
        isImporting = true; error = nil
        importTask = Task {
            let directory = await Task.detached(priority: .userInitiated) {
                WallpaperEngineImportLocation.preferredDirectory(
                    steamRoots: WallpaperEngineImportLocation.defaultSteamRoots(),
                    lastDirectory: lastPath.map { URL(fileURLWithPath: $0) })
            }.value
            guard generation == importGeneration, !Task.isCancelled else { return }
            isImporting = false
            let panel = NSOpenPanel()
            panel.title = "Import Wallpaper Engine"; panel.prompt = "Import"
            panel.message = "Choose a downloaded project folder, project.json, or the Workshop 431960 folder."
            panel.directoryURL = directory
            panel.canChooseDirectories = true; panel.canChooseFiles = true
            panel.allowedContentTypes = [.json, .folder]; panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                let parent = url.deletingLastPathComponent()
                UserDefaults.standard.set(parent.path, forKey: "WallpaperEngineLastImportDirectory")
                discover(url)
            }
        }
    }
    func discover(_ url: URL) {
        guard !isImporting else { return }
        importGeneration += 1; let generation = importGeneration
        isImporting = true; error = nil
        importTask = Task {
            do {
                let library = self.library
                let found = try await Task.detached(priority: .userInitiated) { try library.candidates(at: url) }.value
                guard generation == importGeneration else { return }
                candidates = found
                selectedCandidates = Set(found.filter(\.supported).map(\.id))
                if found.count == 1, found[0].supported { isImporting = false; importSelected(); return }
                showsProjectPicker = true
            } catch { if generation == importGeneration { self.error = error.localizedDescription } }
            if generation == importGeneration { isImporting = false }
        }
    }
    func importSelected() {
        guard !isImporting else { return }
        let sources = candidates.filter { $0.supported && selectedCandidates.contains($0.id) }.map(\.url)
        showsProjectPicker = false; isImporting = true; error = nil
        importGeneration += 1; let generation = importGeneration
        importTask = Task {
            var imported: [WallpaperEngineProject] = []
            let library = self.library
            let worker = Task.detached(priority: .userInitiated) {
                var results: [WallpaperEngineProject] = []
                for source in sources {
                    try Task.checkCancellation()
                    results.append(try library.importProject(at: source, cancelled: { Task.isCancelled }))
                }
                return results
            }
            do {
                imported = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == importGeneration, !Task.isCancelled else { return }
                projects = library.projects(); libraryIsSelected = true
                if let project = imported.first { select(project) }
                message = "Imported \(imported.count) project(s). Preview only; use Start to apply."
            } catch is CancellationError { }
            catch { if generation == importGeneration { self.error = error.localizedDescription; projects = library.projects() } }
            if generation == importGeneration { isImporting = false }
        }
    }
    func cancelImport() {
        importGeneration += 1; importTask?.cancel(); importTask = nil; isImporting = false; showsProjectPicker = false
    }
    func select(_ project: WallpaperEngineProject) {
        error = nil; message = "\(project.title) is in preview. Use Start to apply."
        if project.type == .video { videoPreview?(project) }
        else { selection.selectWeb(project.id); reloadValues() }
    }
    private func reloadValues() {
        values = selectedProject.map { library.values(for: $0) } ?? [:]
        objectWillChange.send()
    }
    func setValue(_ value: ProjectValue, for property: WallpaperEngineProperty) {
        guard let project = selectedProject, property.editable else { return }
        values[property.id] = property.validated(value)
        do { try library.saveValues(values, for: project) } catch { self.error = error.localizedDescription }
        propertyTask?.cancel()
        let newValues = values
        propertyTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let status = WebWallpaperRuntime.status, status.projectID == project.id,
                  var config = WebWallpaperRuntime.read(WebWallpaperConfiguration.self, from: "config.json"), config.generation == status.generation else { return }
            config.values = newValues
            do { try WebWallpaperRuntime.write(config, to: "config.json") } catch { self.error = error.localizedDescription }
        }
    }
    func start() {
        guard canStart, let config = previewConfiguration else { return }
        isBusy = true; error = nil
        Task {
            do {
                try await startWallpaper(config)
                message = "Web wallpaper started. Lock Screen uses a still frame."
            } catch { self.error = error.localizedDescription }
            refreshRuntime(); isBusy = false
        }
    }
    func remove() {
        guard !isBusy else { return }
        isBusy = true; error = nil
        Task {
            do { try await removeWallpaper() }
            catch { self.error = error.localizedDescription }
            refreshRuntime(); isBusy = false
        }
    }
    func refreshRuntime() {
        let active = runtimeIsActive()
        if runtimeActive != active { runtimeActive = active }
        if let failure = WebWallpaperRuntime.status?.error, error != failure { error = failure }
        if !isBusy, FileManager.default.fileExists(atPath: WebWallpaperRuntime.url("route-active").path), WebWallpaperRuntime.agentPID == nil {
            error = "The Web wallpaper helper stopped. Use Remove to restore the previous wallpaper route, then try Start again."
        }
    }
}

enum WebWallpaperController {
    private static let lock = NSRecursiveLock()
    static func start(_ original: WebWallpaperConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        guard !WallpaperRuntimeStore().status().running,
              !TerminalWallpaperRuntimeStore().status().running,
              !FileManager.default.fileExists(atPath: WallpaperRuntimeStore.defaultAppSupportURL().appendingPathComponent("lock_screen_only_source.json").path),
              !WebWallpaperRuntime.active else { throw WallpaperEngineError.invalid("Remove the current wallpaper before starting Web wallpaper.") }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AuraWebWallpaperAgent")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw WallpaperEngineError.invalid("The Web wallpaper helper is not bundled.") }
        var config = original; config.generation = UUID().uuidString
        try? FileManager.default.removeItem(at: WebWallpaperRuntime.url("stop"))
        try WebWallpaperRuntime.write(config, to: "config.json")
        let process = Process(); process.executableURL = helper
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(20)
            var ready = false
            while Date() < deadline, process.isRunning {
                if let status = WebWallpaperRuntime.status, status.generation == config.generation {
                    if let error = status.error { throw WallpaperEngineError.invalid(error) }
                    if status.ready { ready = true; break }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard ready else { throw WallpaperEngineError.invalid("Web wallpaper did not produce its first Lock Screen frame.") }
            try LockScreenSaverInstaller().activateForWeb()
            try Data(config.generation.utf8).write(to: WebWallpaperRuntime.url("route-active"), options: .atomic)
        } catch {
            process.terminate()
            process.waitUntilExit()
            do {
                try LockScreenSaverInstaller().restoreAfterWeb()
                try? FileManager.default.removeItem(at: WebWallpaperRuntime.url("route-active"))
            } catch let restoreError {
                try? Data(config.generation.utf8).write(to: WebWallpaperRuntime.url("route-active"), options: .atomic)
                throw WallpaperEngineError.invalid("\(error.localizedDescription) Restore failed: \(restoreError.localizedDescription). Use Remove to retry restoration.")
            }
            throw error
        }
    }
    static func remove() throws {
        lock.lock(); defer { lock.unlock() }
        if let pid = WebWallpaperRuntime.agentPID {
            try Data().write(to: WebWallpaperRuntime.url("stop"), options: .atomic)
            let deadline = Date().addingTimeInterval(3)
            while WebWallpaperRuntime.isAgent(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !WebWallpaperRuntime.isAgent(pid) else { throw WallpaperEngineError.invalid("The Web wallpaper helper did not stop. Try Remove again.") }
        }
        try LockScreenSaverInstaller().restoreAfterWeb()
        try? FileManager.default.removeItem(at: WebWallpaperRuntime.url("route-active"))
        for name in ["agent.pid", "status.json", "stop"] { try? FileManager.default.removeItem(at: WebWallpaperRuntime.url(name)) }
        let frames = (try? FileManager.default.contentsOfDirectory(at: WebWallpaperRuntime.root, includingPropertiesForKeys: nil)) ?? []
        for frame in frames where frame.pathExtension == "png" { try? FileManager.default.removeItem(at: frame) }
    }
}

struct WebWallpaperPreviewSurface: NSViewRepresentable {
    @ObservedObject var model: WallpaperEngineViewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WebWallpaperView {
        let view = WebWallpaperView(frame: .zero)
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: WebWallpaperView, context: Context) { context.coordinator.refresh() }
    static func dismantleNSView(_ view: WebWallpaperView, coordinator: Coordinator) { coordinator.stop(); view.unload() }
    @MainActor final class Coordinator {
        weak var view: WebWallpaperView?
        let model: WallpaperEngineViewModel
        var token: String?
        var visible = false
        var timer: Timer?
        init(model: WallpaperEngineViewModel) { self.model = model }
        func attach(_ view: WebWallpaperView) {
            self.view = view
            view.onError = { [weak model] text in model?.error = text }
            view.onWarning = { [weak model] text in model?.message = text }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        func refresh() {
            guard let view else { return }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool == true
            let shown = !locked && !NSApp.isHidden && view.window?.isVisible == true && view.window?.isMiniaturized != true && view.window?.occlusionState.contains(.visible) == true
            guard shown, model.selection.kind == .web, let config = model.previewConfiguration else {
                if visible { view.freeze { _ in }; visible = false; token = nil }
                return
            }
            visible = true
            if token != config.generation { token = config.generation; view.load(config) }
            else { view.update(values: config.values, fps: config.fps) }
        }
        func stop() { timer?.invalidate(); timer = nil }
        deinit { timer?.invalidate() }
    }
}
