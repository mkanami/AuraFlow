import AppKit
import Foundation
import Testing
@testable import AuraWallpaperEngineCore
@testable import WallpaperControlApp

private final class EngineFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-WE-tests-" + UUID().uuidString)
    var library: WallpaperEngineLibrary { WallpaperEngineLibrary(rootURL: root.appendingPathComponent("library")) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func project(_ name: String = "project", type: String = "web", entry: String = "index.html", properties: [String: Any] = [:]) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta: [String: Any] = ["type": type, "file": entry, "title": "Обои 🌊", "description": "Local project", "general": ["properties": properties]]
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("project.json"))
        let asset = folder.appendingPathComponent(entry.replacingOccurrences(of: "\\", with: "/"))
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html><body style='background:red'>Local</body></html>".utf8).write(to: asset)
        return folder
    }
}

@Test
func engineImportLocationParsesModernAndLegacySteamLibraries() {
    let modern = #"""
    "libraryfolders" {
        // "path" "/not-a-library"
        "0" { "path" "/Steam Main" "apps" { "431960" "12345" } }
        "1" { "path" "/Volumes/Игры/SteamLibrary" }
        "2" { "path" "D:\\SteamLibrary" }
        "extra" { "path" "/not-numeric" }
    }
    "other" { "path" "/unrelated" }
    """#
    #expect(WallpaperEngineImportLocation.libraryPaths(in: modern) == ["/Steam Main", "/Volumes/Игры/SteamLibrary", #"D:\SteamLibrary"#])
    #expect(WallpaperEngineImportLocation.libraryPaths(in: "LibraryFolders { 0 \"/Steam\" 1 \"/External Steam\" TimeNextStatsReport 42 }") == ["/Steam", "/External Steam"])
    #expect(WallpaperEngineImportLocation.libraryPaths(in: "\"libraryfolders\" { \"0\" { \"path\" \"/broken\"").isEmpty)
    #expect(WallpaperEngineImportLocation.libraryPaths(in: String(repeating: "x", count: 1_048_577)).isEmpty)
}

@Test
func engineImportLocationFindsWorkshopInAdditionalSteamLibrary() throws {
    let f = try EngineFixture()
    let steam = f.root.appendingPathComponent("Steam"), external = f.root.appendingPathComponent("Другие игры")
    let steamapps = steam.appendingPathComponent("steamapps")
    let workshop = external.appendingPathComponent("steamapps/workshop/content/431960")
    try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workshop, withIntermediateDirectories: true)
    let vdf = "\"libraryfolders\" { \"1\" { \"path\" \"\(external.path)\" } }"
    try Data(vdf.utf8).write(to: steamapps.appendingPathComponent("libraryfolders.vdf"))
    let chosen = WallpaperEngineImportLocation.preferredDirectory(steamRoots: [steam], lastDirectory: f.root)
    #expect(chosen?.resolvingSymlinksInPath() == workshop.resolvingSymlinksInPath())
    #expect(!FileManager.default.fileExists(atPath: workshop.appendingPathComponent("project.json").path))
    // Discovery does not import, create files or mutate Steam configuration.
    #expect(try String(contentsOf: steamapps.appendingPathComponent("libraryfolders.vdf")) == vdf)
    #expect(f.library.projects().isEmpty)
}

@Test
func engineImportLocationFallsBackWithoutSteamOrDownloadedContent() throws {
    let f = try EngineFixture(), steam = f.root.appendingPathComponent("Steam")
    #expect(WallpaperEngineImportLocation.preferredDirectory(steamRoots: [steam]) == nil)
    #expect(WallpaperEngineImportLocation.preferredDirectory(steamRoots: [steam], lastDirectory: f.root) == f.root)
    let steamapps = steam.appendingPathComponent("steamapps")
    try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
    #expect(WallpaperEngineImportLocation.preferredDirectory(steamRoots: [steam])?.resolvingSymlinksInPath() == steamapps.resolvingSymlinksInPath())
    try Data("broken".utf8).write(to: steamapps.appendingPathComponent("libraryfolders.vdf"))
    let authored = steamapps.appendingPathComponent("common/wallpaper_engine/projects/myprojects")
    try FileManager.default.createDirectory(at: authored, withIntermediateDirectories: true)
    #expect(WallpaperEngineImportLocation.preferredDirectory(steamRoots: [steam], lastDirectory: f.root)?.resolvingSymlinksInPath() == authored.resolvingSymlinksInPath())
    let file = f.root.appendingPathComponent("not-a-directory")
    try Data().write(to: file)
    #expect(WallpaperEngineImportLocation.preferredDirectory(steamRoots: [], lastDirectory: file) == nil)
}

@Test(arguments: ["video", "web"])
func engineImportsExplicitTypeAndUnicodeWithoutChangingSource(type: String) throws {
    let f = try EngineFixture()
    let source = try f.project(type: type, entry: type == "video" ? "assets\\movie.mp4" : "assets\\index.html")
    let before = try Data(contentsOf: source.appendingPathComponent("project.json"))
    let imported = try f.library.importProject(at: source.appendingPathComponent("project.json"))
    #expect(imported.type.rawValue == type)
    #expect(imported.title == "Обои 🌊")
    #expect(!imported.entryPath.contains("\\"))
    #expect(imported.rootURL.path.hasPrefix(f.library.rootURL.path + "/"))
    #expect(FileManager.default.fileExists(atPath: imported.entryURL.path))
    #expect(try Data(contentsOf: source.appendingPathComponent("project.json")) == before)
}

@Test(arguments: ["scene", "application", "unknown"])
func engineNeverInfersVideoFromSceneAssets(type: String) throws {
    let f = try EngineFixture(), source = try f.project(type: type, entry: "movie.mp4")
    #expect(throws: WallpaperEngineError.self) { try f.library.importProject(at: source) }
    #expect(f.library.projects().isEmpty)
    #expect(try f.library.candidates(at: source).first?.supported == false)
}

@Test(arguments: ["../outside.html", "/etc/passwd", "C:\\secret.html", "nested\\..\\escape.html", ""])
func engineRejectsEscapingAssetPaths(path: String) throws {
    let f = try EngineFixture()
    #expect(throws: WallpaperEngineError.self) { try WallpaperEngineLibrary.relativePath(path, in: f.root) }
}

@Test
func engineRejectsMissingFilesMalformedJSONAndSymlinks() throws {
    let f = try EngineFixture(), source = try f.project()
    try FileManager.default.removeItem(at: source.appendingPathComponent("index.html"))
    #expect(throws: WallpaperEngineError.self) { try f.library.importProject(at: source) }
    try Data("{}".utf8).write(to: f.root.appendingPathComponent("outside.html"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("index.html"), withDestinationURL: f.root.appendingPathComponent("outside.html"))
    #expect(throws: WallpaperEngineError.self) { try f.library.importProject(at: source) }
    try Data("{broken".utf8).write(to: source.appendingPathComponent("project.json"))
    #expect(throws: WallpaperEngineError.self) { try f.library.importProject(at: source) }
    #expect(f.library.projects().isEmpty)
}

@Test
func engineRejectsAssetSymlinksEvenIfEntryIsRegular() throws {
    let f = try EngineFixture(), source = try f.project()
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("hidden.txt"), withDestinationURL: source.appendingPathComponent("index.html"))
    #expect(throws: WallpaperEngineError.self) { try f.library.importProject(at: source) }
    #expect(f.library.projects().isEmpty)
}

@Test
func engineDeduplicatesContentButKeepsChangedVersions() throws {
    let f = try EngineFixture(), source = try f.project()
    let a = try f.library.importProject(at: source)
    let b = try f.library.importProject(at: source)
    #expect(a.id == b.id)
    #expect(f.library.projects().count == 1)
    try Data("changed".utf8).write(to: source.appendingPathComponent("index.html"))
    let c = try f.library.importProject(at: source)
    #expect(c.id != a.id)
    #expect(f.library.projects().count == 2)
    #expect(try String(contentsOf: a.entryURL).contains("Local"))
}

@Test
func engineCancellationRollsBackStagingAndRegistration() throws {
    let f = try EngineFixture(), source = try f.project()
    var calls = 0
    #expect(throws: CancellationError.self) {
        try f.library.importProject(at: source, cancelled: { calls += 1; return calls >= 4 })
    }
    #expect(f.library.projects().isEmpty)
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: f.library.rootURL.path)) ?? []
    #expect(contents.allSatisfy { !$0.hasPrefix(".import-") })
}

@Test
func engineBatchScansOnlyImmediateProjectsAndLabelsUnsupported() throws {
    let f = try EngineFixture()
    _ = try f.project("431960/1", type: "video", entry: "movie.mp4")
    _ = try f.project("431960/2", type: "web")
    _ = try f.project("431960/3", type: "scene", entry: "movie.mp4")
    _ = try f.project("431960/elsewhere/nested")
    let candidates = try f.library.candidates(at: f.root.appendingPathComponent("431960"))
    #expect(candidates.count == 3)
    #expect(candidates.filter(\.supported).count == 2)
    #expect(candidates.last?.type == "scene")
}

@Test
func enginePropertiesAreValidatedAndSavedOutsideSourceJSON() throws {
    let f = try EngineFixture()
    let source = try f.project(properties: [
        "speed": ["type": "slider", "value": 4, "min": 1, "max": 10],
        "color": ["type": "color", "value": "1 0 0"],
        "enabled": ["type": "bool", "value": true],
        "text": ["type": "textinput", "value": "hello"],
        "choice": ["type": "combo", "value": "a", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"]]],
        "file": ["type": "file", "value": "asset.png"]
    ])
    let project = try f.library.importProject(at: source)
    let original = try Data(contentsOf: project.rootURL.appendingPathComponent("project.json"))
    try f.library.saveValues(["speed": .number(500), "enabled": .bool(false), "color": .string("bad"), "text": .string("new"), "choice": .string("b")], for: project)
    let saved = f.library.values(for: project)
    #expect(saved["speed"] == .number(10))
    #expect(saved["enabled"] == .bool(false))
    #expect(saved["color"] == .string("1 0 0"))
    #expect(saved["text"] == .string("new"))
    #expect(saved["choice"] == .string("b"))
    #expect(saved["file"] == .string("asset.png"))
    #expect(project.warnings.contains { $0.contains("File/directory") })
    #expect(try Data(contentsOf: project.rootURL.appendingPathComponent("project.json")) == original)
}

@Test @MainActor
func engineWebChoicePersistsAndOldVideoTerminalChoicesStillDecode() throws {
    let f = try EngineFixture(), url = f.root.appendingPathComponent("selection.json")
    try Data("{\"kind\":\"video\"}".utf8).write(to: url)
    let selection = WallpaperPreviewSelectionStore(selectionURL: url)
    #expect(selection.kind == .video)
    selection.selectWeb("project-id")
    let restored = WallpaperPreviewSelectionStore(selectionURL: url)
    #expect(restored.kind == .web)
    #expect(restored.webProjectID == "project-id")
    restored.selectVideo()
    #expect(restored.webProjectID == nil)
}

@Test @MainActor
func engineSelectingPreviewDoesNotStartWallpaperAndRespectsConflicts() throws {
    let f = try EngineFixture(), project = try f.library.importProject(at: f.project())
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    let model = WallpaperEngineViewModel(selection: selection, library: f.library)
    let before = WebWallpaperRuntime.status
    model.select(project)
    #expect(selection.kind == .web)
    #expect(WebWallpaperRuntime.status == before)
    #expect(model.previewConfiguration?.project.id == project.id)
    #expect(model.previewConfiguration?.generation == model.previewConfiguration?.generation)
    model.videoActive = { true }; #expect(!model.canStart)
    model.videoActive = { false }; model.terminalActive = { true }; #expect(!model.canStart)
    #expect(selection.webProjectID == project.id)
}

@Test
func engineMenuRoutingBlocksCrossTypeStartAndRemovesActualRuntime() {
    for kind in [WallpaperPreviewKind.video, .terminal] {
        #expect(!WallpaperMenuActionPolicy.canStart(previewKind: kind, terminalRuntimeActive: false, videoRuntimeActive: false, terminalReady: true, videoReady: true, isBusy: false, webRuntimeActive: true))
    }
    #expect(!WallpaperMenuActionPolicy.canStart(previewKind: .web, terminalRuntimeActive: true, videoRuntimeActive: false, terminalReady: true, videoReady: true, isBusy: false, webReady: true))
    #expect(!WallpaperMenuActionPolicy.canStart(previewKind: .web, terminalRuntimeActive: false, videoRuntimeActive: true, terminalReady: true, videoReady: true, isBusy: false, webReady: true))
    #expect(WallpaperMenuActionPolicy.canStart(previewKind: .web, terminalRuntimeActive: false, videoRuntimeActive: false, terminalReady: true, videoReady: true, isBusy: false, webReady: true))
    #expect(WallpaperMenuActionPolicy.removeTarget(terminalRuntimeActive: false, videoRuntimeActive: false, webRuntimeActive: true) == .web)
    #expect(WallpaperMenuActionPolicy.removeTarget(terminalRuntimeActive: false, videoRuntimeActive: false) == .none)
}

@Test
func engineWebPauseAndGenerationPoliciesDiscardStaleFrames() {
    #expect(WebWallpaperPausePolicy.shouldUnload(visible: false, locked: false, fullscreen: false, pauseOnFullscreen: true))
    #expect(WebWallpaperPausePolicy.shouldUnload(visible: true, locked: true, fullscreen: false, pauseOnFullscreen: true))
    #expect(WebWallpaperPausePolicy.shouldUnload(visible: true, locked: false, fullscreen: true, pauseOnFullscreen: true))
    #expect(!WebWallpaperPausePolicy.shouldUnload(visible: true, locked: false, fullscreen: true, pauseOnFullscreen: false))
    var gate = WebWallpaperGenerationGate(); let token = gate.generation
    #expect(gate.accepts(token)); gate.replace(); #expect(!gate.accepts(token))
    #expect(!WebWallpaperRuntime.isAgent(getpid()))
}

@Test
func engineReadinessRequiresEveryDisplaySnapshot() throws {
    let f = try EngineFixture(), image = f.root.appendingPathComponent("frame.png")
    try Data([1]).write(to: image)
    var state = WebWallpaperStatus(pid: getpid(), generation: "g", projectID: "p", frames: ["1": image.path])
    state.expectedDisplays = ["1", "2"]
    #expect(!state.ready)
    state.frames["2"] = image.path; #expect(state.ready)
    state.error = "failed"; #expect(!state.ready)
}

@Test @MainActor
func engineStartRemoveAndFailureKeepSelectedPreviewAlive() async throws {
    let f = try EngineFixture(), project = try f.library.importProject(at: f.project())
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    let model = WallpaperEngineViewModel(selection: selection, library: f.library)
    var running = false, starts = 0, removes = 0
    model.runtimeIsActive = { running }; model.refreshRuntime()
    model.startWallpaper = { config in #expect(config.project.id == project.id); starts += 1; running = true }
    model.removeWallpaper = { removes += 1; running = false }
    model.select(project); #expect(starts == 0)
    let previewGeneration = model.previewConfiguration?.generation
    model.start()
    while model.isBusy { await Task.yield() }
    #expect(starts == 1); #expect(model.runtimeActive)
    #expect(selection.webProjectID == project.id)
    model.remove()
    while model.isBusy { await Task.yield() }
    #expect(removes == 1); #expect(!model.runtimeActive)
    #expect(model.previewConfiguration?.generation == previewGeneration)
    model.startWallpaper = { _ in throw WallpaperEngineError.invalid("Test load failure") }
    model.start()
    while model.isBusy { await Task.yield() }
    #expect(model.error == "Test load failure")
    #expect(!model.runtimeActive)
    #expect(selection.kind == .web)
    #expect(model.previewConfiguration?.generation == previewGeneration)
}
