import Foundation
import Testing
@testable import AuraWallpaperEngineCore
@testable import WallpaperControlApp

private final class LocalEngineFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-local-WE-" + UUID().uuidString)
    var library: WallpaperEngineLibrary { WallpaperEngineLibrary(rootURL: root.appendingPathComponent("AuraLibrary")) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func project(_ path: String, type: String = "web", preview: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = type == "video" ? "movie.mp4" : "index.html"
        var metadata = ["type": type, "file": entry, "title": path, "description": "Local fixture"]
        if let preview { metadata["preview"] = preview }
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("project.json"))
        try Data("<html><body>Fixture</body></html>".utf8).write(to: folder.appendingPathComponent(entry))
        return folder
    }
    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AuraFlow-local-WE-" + UUID().uuidString)!
    }
}

@Test func engineLocalDiscoveryFindsEveryLibraryAndProjectCollectionWithoutImporting() throws {
    let f = try LocalEngineFixture()
    let steam = f.root.appendingPathComponent("Steam")
    let other = f.root.appendingPathComponent("Вторая библиотека 🌊")
    _ = try f.project("Steam/steamapps/workshop/content/431960/1", type: "video")
    _ = try f.project("Вторая библиотека 🌊/steamapps/workshop/content/431960/2")
    _ = try f.project("Steam/steamapps/common/wallpaper_engine/projects/myprojects/Own")
    _ = try f.project("Steam/steamapps/common/wallpaper_engine/projects/defaultprojects/Scene", type: "scene")
    _ = try f.project("Steam/steamapps/common/wallpaper_engine/projects/backup/3", type: "application")
    _ = try f.project("Steam/steamapps/common/wallpaper_engine/projects/Direct")
    _ = try f.project("Steam/steamapps/workshop/content/431960/not-a-project/nested/ignore")
    let vdf = "libraryfolders { 0 { path \"\(steam.path)\" } 1 { path \"\(other.path)\" } }"
    let manifest = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
    try Data(vdf.utf8).write(to: manifest)
    // Alias roots and cyclic library manifests must not duplicate entries or loop.
    let alias = f.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: steam)
    try Data("LibraryFolders { 0 \"\(steam.path)\" }".utf8).write(to: other.appendingPathComponent("steamapps/libraryfolders.vdf"))
    let result = WallpaperEngineLocalLibrary.scan(steamRoots: [steam, alias])
    #expect(result.candidates.count == 6)
    #expect(result.candidates.filter(\.supported).count == 4)
    #expect(Set(result.candidates.map(\.type)) == ["video", "web", "scene", "application"])
    #expect(result.warnings.isEmpty)
    #expect(try String(contentsOf: manifest) == vdf)
    #expect(f.library.projects().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.library.rootURL.path))
}

@Test func engineLocalDiscoveryKeepsBrokenProjectsAndSafePreviewsButDoesNotFollowLinks() throws {
    let f = try LocalEngineFixture(), workshop = f.root.appendingPathComponent("Steam/steamapps/workshop/content/431960")
    let scene = try f.project("Steam/steamapps/workshop/content/431960/scene", type: "scene", preview: "preview.png")
    try Data([1]).write(to: scene.appendingPathComponent("preview.png"))
    let web = try f.project("Steam/steamapps/workshop/content/431960/web", preview: "../outside.png")
    let broken = try f.project("Steam/steamapps/workshop/content/431960/broken")
    try Data("{broken".utf8).write(to: broken.appendingPathComponent("project.json"))
    let oversized = try f.project("Steam/steamapps/workshop/content/431960/oversized")
    try Data(repeating: 32, count: 1_048_577).write(to: oversized.appendingPathComponent("project.json"))
    let external = try f.project("Outside")
    try FileManager.default.createSymbolicLink(at: workshop.appendingPathComponent("link"), withDestinationURL: external)
    let result = WallpaperEngineLocalLibrary.scan(steamRoots: [f.root.appendingPathComponent("Steam")])
    #expect(result.candidates.count == 4)
    #expect(result.candidates.allSatisfy { !$0.supported })
    #expect(result.candidates.first { $0.url.lastPathComponent == "scene" }?.previewURL?.lastPathComponent == "preview.png")
    #expect(result.candidates.first { $0.url.lastPathComponent == "web" }?.previewURL == nil)
    #expect(result.candidates.contains { $0.url.lastPathComponent == broken.lastPathComponent && $0.error != nil })
    #expect(result.candidates.contains { $0.url == web.resolvingSymlinksInPath() })
    #expect(result.candidates.contains { $0.url.lastPathComponent == "oversized" && $0.error?.contains("too large") == true })
}

@Test func engineLocalDiscoveryRefreshesNewRemovedAndChangedProjects() throws {
    let f = try LocalEngineFixture(), collection = f.root.appendingPathComponent("Custom")
    let old = try f.project("Custom/1")
    #expect(WallpaperEngineLocalLibrary.scan(steamRoots: [], additionalDirectories: [collection]).candidates.count == 1)
    try FileManager.default.removeItem(at: old)
    _ = try f.project("Custom/2", type: "video")
    let snapshot = WallpaperEngineLocalLibrary.scan(steamRoots: [], additionalDirectories: [collection])
    #expect(snapshot.candidates.count == 1)
    #expect(snapshot.candidates.first?.type == "video")
    try FileManager.default.removeItem(at: collection.appendingPathComponent("2/movie.mp4"))
    #expect(WallpaperEngineLocalLibrary.scan(steamRoots: [], additionalDirectories: [collection]).candidates.first?.supported == false)
    #expect(WallpaperEngineLocalLibrary.scan(steamRoots: [], additionalDirectories: [collection], cancelled: { true }).candidates.isEmpty)
    #expect(WallpaperEngineLocalLibrary.scan(steamRoots: [f.root.appendingPathComponent("missing")]).warnings.isEmpty)
    #expect(f.library.projects().isEmpty)
}

@Test @MainActor func engineLocalLibraryDoesNotChangePreviewOrRuntimeAndImportsOnlyOnPreview() async throws {
    let f = try LocalEngineFixture(), steam = f.root.appendingPathComponent("Steam")
    let source = try f.project("Steam/steamapps/workshop/content/431960/1")
    _ = try f.project("Steam/steamapps/workshop/content/431960/2", type: "scene")
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    selection.selectVideo()
    let model = WallpaperEngineViewModel(selection: selection, library: f.library,
        libraryDefaults: f.defaults(), steamRootsProvider: { [steam] })
    var starts = 0
    model.startWallpaper = { _ in starts += 1 }
    await model.refreshLocalLibrary()
    #expect(model.libraryCount == 2)
    #expect(model.projects.isEmpty)
    #expect(selection.kind == .video)
    #expect(starts == 0)
    #expect(!model.showsProjectPicker)
    let unsupported = try #require(model.localProjects.first { !$0.supported })
    model.previewLocalProject(unsupported)
    #expect(!model.isImporting)
    let candidate = try #require(model.localProjects.first { $0.supported })
    model.previewLocalProject(candidate)
    while model.isImporting { await Task.yield() }
    #expect(model.error == nil)
    #expect(model.projects.count == 1)
    #expect(selection.kind == .web)
    #expect(starts == 0)
    #expect(model.managedProjects.isEmpty)
    #expect(model.libraryCount == 2)
    model.previewLocalProject(candidate)
    while model.isImporting { await Task.yield() }
    #expect(model.projects.count == 1)
    // The managed copy stays usable when the source disk/project disappears.
    try FileManager.default.removeItem(at: source)
    await model.refreshLocalLibrary()
    #expect(model.localProjects.count == 1)
    #expect(model.managedProjects.count == 1)
    #expect(model.libraryCount == 2)
    #expect(model.selectedProject?.entryURL != nil)
}

@Test @MainActor func engineLocalLibraryRemembersCustomCollectionsAcrossLaunchesAndCancelsStaleScans() async throws {
    let f = try LocalEngineFixture(), collection = f.root.appendingPathComponent("Custom")
    _ = try f.project("Custom/1", type: "video")
    let defaults = f.defaults()
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    let model = WallpaperEngineViewModel(selection: selection, library: f.library,
        libraryDefaults: defaults, steamRootsProvider: { [] })
    model.rememberLibraryDirectory(collection)
    model.rememberLibraryDirectory(collection)
    #expect(defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories")?.count == 1)
    let relaunched = WallpaperEngineViewModel(selection: selection, library: f.library,
        libraryDefaults: defaults, steamRootsProvider: { [] })
    await relaunched.refreshLocalLibrary()
    #expect(relaunched.libraryCount == 1)
    let task = Task { await relaunched.refreshLocalLibrary() }
    task.cancel()
    await task.value
    #expect(!relaunched.isScanningLibrary)
    #expect(relaunched.libraryCount == 1)
    #expect(relaunched.projects.isEmpty)
    #expect(selection.kind == .video)
}

@Test func engineLocalOriginIsOptionalForOldLibraryRecords() throws {
    let f = try LocalEngineFixture(), source = try f.project("Source")
    let project = try f.library.importProject(at: source)
    #expect(project.sourcePath == source.resolvingSymlinksInPath().path)
    var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    record.removeValue(forKey: "sourcePath")
    let legacy = try JSONDecoder().decode(WallpaperEngineProject.self, from: JSONSerialization.data(withJSONObject: record))
    #expect(legacy.sourcePath == nil)
    #expect(legacy.id == project.id)
}

@Test func engineLocalDiscoveryResolvesWindowsLibrariesInsideWinePrefixes() throws {
    let f = try LocalEngineFixture()
    let steam = f.root.appendingPathComponent("Bottle/drive_c/Program Files (x86)/Steam")
    _ = try f.project("Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/1")
    _ = try f.project("Bottle/drive_c/Games/SteamLibrary/steamapps/workshop/content/431960/2", type: "video")
    let manifest = #"libraryfolders { 0 { path "C:\\Program Files (x86)\\Steam" } 1 { path "C:\\Games\\SteamLibrary" } }"#
    try Data(manifest.utf8).write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
    #expect(WallpaperEngineLocalLibrary.scan(steamRoots: [steam]).candidates.count == 2)
}

@Test @MainActor func engineLocalLibraryAcceptsWholeSteamFoldersAndVideoPreviewStaysExplicit() async throws {
    let f = try LocalEngineFixture(), steam = f.root.appendingPathComponent("Steam")
    _ = try f.project("Steam/steamapps/workshop/content/431960/1", type: "video")
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    let model = WallpaperEngineViewModel(selection: selection, library: f.library,
        libraryDefaults: f.defaults(), steamRootsProvider: { [] })
    model.rememberLibraryDirectory(steam)
    var preview: WallpaperEngineProject?
    model.videoPreview = { preview = $0 }
    await model.refreshLocalLibrary()
    #expect(model.libraryCount == 1)
    #expect(preview == nil)
    model.previewLocalProject(try #require(model.localProjects.first))
    while model.isImporting { await Task.yield() }
    #expect(preview?.type == .video)
    #expect(model.libraryCount == 1)
    #expect(model.error == nil)
}
