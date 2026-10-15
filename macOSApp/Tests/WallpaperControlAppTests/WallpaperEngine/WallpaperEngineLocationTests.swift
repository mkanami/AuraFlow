import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AuraWallpaperEngineCore
@testable import WallpaperControlApp

private final class EngineLocationFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-WE-locations-" + UUID().uuidString)
    let defaults: UserDefaults
    let defaultsName = "AuraFlow-WE-locations-" + UUID().uuidString
    var library: WallpaperEngineLibrary { WallpaperEngineLibrary(rootURL: root.appendingPathComponent("Managed")) }
    init() throws {
        defaults = UserDefaults(suiteName: defaultsName)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
    func project(_ path: String) throws -> URL {
        let url = try directory(path)
        try Data(#"{"type":"web","file":"index.html","title":"Обои 🌊"}"#.utf8).write(to: url.appendingPathComponent("project.json"))
        try Data("<html><body>Local project</body></html>".utf8).write(to: url.appendingPathComponent("index.html"))
        return url
    }
    @MainActor func model(roots: [URL] = []) -> WallpaperEngineViewModel {
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        selection.selectVideo()
        let model = WallpaperEngineViewModel(selection: selection, library: library,
            libraryDefaults: defaults, steamRootsProvider: { roots })
        model.chooseCollectionLocation = { _ in Issue.record("Unexpected collection chooser"); return nil }
        model.showLocationPanel = { _ in Issue.record("Unexpected native location panel"); return nil }
        return model
    }
}

@Test func engineLocationResolvesCustomInstallationAndUsesSameFoldersAsScan() throws {
    let f = try EngineLocationFixture()
    let steam = try f.directory("Steam"), external = try f.directory("Игры 🌊")
    let workshop = try f.directory("Игры 🌊/steamapps/workshop/content/431960")
    _ = try f.project("Игры 🌊/steamapps/workshop/content/431960/123")
    _ = try f.project("Steam/steamapps/common/My Custom Engine/projects/myprojects/Own")
    let projects = steam.appendingPathComponent("steamapps/common/My Custom Engine/projects")
    try Data("libraryfolders { 1 { path \"\(external.path)\" } }".utf8)
        .write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
    let manifest = #"AppState { appid "431960" installdir "My Custom Engine" }"#
    try Data(manifest.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_431960.acf"))
    let locations = WallpaperEngineLibraryLocations.resolve(steamRoots: [steam])
    #expect(Set(locations.collections.map(\.url)) == [workshop, projects])
    #expect(locations.warnings.isEmpty)
    #expect(WallpaperEngineLibraryLocations.preferredDirectory(in: locations, lastDirectory: nil) == nil)
    #expect(WallpaperEngineLibraryLocations.preferredDirectory(in: locations, lastDirectory: projects) == projects)
    let snapshot = WallpaperEngineLocalLibrary.scan(steamRoots: [steam])
    #expect(Set(snapshot.collectionDirectories) == Set(locations.collections.map(\.url)))
    #expect(snapshot.candidates.count == 2)
    #expect(f.library.projects().isEmpty)
    #expect(try String(contentsOf: steam.appendingPathComponent("steamapps/appmanifest_431960.acf")) == manifest)
}

@Test(arguments: ["../escape", "/absolute", #"C:\Engine"#, "", "folder/../escape", "folder//engine"])
func engineLocationRejectsUnsafeInstallDirectories(path: String) {
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
    #expect(WallpaperEngineImportLocation.installationDirectory(in:
        "AppState { appid 431960 installdir \"\(escaped)\" }") == nil)
}

@Test func engineLocationIgnoresMalformedAndWrongAppManifestsButKeepsConventionalProjects() throws {
    let f = try EngineLocationFixture()
    let steam = try f.directory("Steam/steamapps").deletingLastPathComponent()
    let projects = try f.directory("Steam/steamapps/common/wallpaper_engine/projects")
    for manifest in ["broken {", "AppState { appid 42 installdir Other }", String(repeating: "x", count: 1_048_577)] {
        try Data(manifest.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_431960.acf"))
        #expect(WallpaperEngineLibraryLocations.resolve(steamRoots: [steam]).collections.map(\.url) == [projects])
    }
    #expect(WallpaperEngineImportLocation.installationDirectory(in:
        #"AppState { appid 431960 installdir "Обои\\Engine" }"#) == "Обои/Engine")
}

@Test func engineLocationDeduplicatesAliasesAndExcludesManagedLibrary() throws {
    let f = try EngineLocationFixture()
    let custom = try f.directory("Local 🌊")
    _ = try f.project("Local 🌊/1")
    _ = try f.project("Managed/1")
    let alias = f.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: custom)
    let locations = WallpaperEngineLibraryLocations.resolve(steamRoots: [],
        additionalDirectories: [custom, alias, f.library.rootURL, f.root.appendingPathComponent("missing")],
        excludedDirectories: [f.library.rootURL])
    #expect(locations.collections.map(\.url) == [custom])
    #expect(WallpaperEngineLibraryLocations.preferredDirectory(in: locations, lastDirectory: alias) == custom)
    #expect(WallpaperEngineLibraryLocations.resolve(steamRoots: [f.root], cancelled: { true }).collections.isEmpty)
    let snapshot = WallpaperEngineLocalLibrary.scan(steamRoots: [], additionalDirectories: [f.root], excludedDirectories: [f.library.rootURL])
    #expect(snapshot.candidates.count == 1)
}

@Test @MainActor func engineLocationLibraryAndImportPanelsShareTheVerifiedWorkshop() async throws {
    let f = try EngineLocationFixture()
    let workshop = try f.directory("Steam/steamapps/workshop/content/431960")
    let model = f.model(roots: [f.root.appendingPathComponent("Steam")])
    var requests: [WallpaperEngineLocationPanelRequest] = []
    model.showLocationPanel = { requests.append($0); return nil }
    await model.chooseLocation(importing: false)
    await model.chooseLocation(importing: true)
    #expect(requests.map(\.directory) == [workshop, workshop])
    #expect(requests.map(\.importing) == [false, true])
    #expect(model.error == nil)
    #expect(!model.isLocatingLibrary && !model.isImporting)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
    #expect(f.defaults.string(forKey: "WallpaperEngineLastLibraryDirectory") == nil)
}

@Test @MainActor func engineLocationMultipleCollectionsRequireChoiceAndDetectRemovedDisk() async throws {
    let f = try EngineLocationFixture()
    let a = try f.directory("Steam/steamapps/workshop/content/431960")
    let b = try f.directory("External/steamapps/workshop/content/431960")
    let model = f.model(roots: [f.root.appendingPathComponent("Steam"), f.root.appendingPathComponent("External")])
    var choices = 0, panels = 0
    model.chooseCollectionLocation = { urls in choices += 1; #expect(Set(urls) == [a, b]); return b }
    model.showLocationPanel = { request in panels += 1; #expect(request.directory == b); return nil }
    await model.chooseLocation(importing: false)
    #expect(choices == 1 && panels == 1)
    // Simulate a drive removed between collection choice and presentation.
    model.chooseCollectionLocation = { _ in try? FileManager.default.removeItem(at: b); return b }
    await model.chooseLocation(importing: false)
    #expect(panels == 1)
    #expect(model.error?.contains("no longer available") == true)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
}

@Test @MainActor func engineLocationRemembersExplicitCollectionAndRefreshesWithoutStartingAnything() async throws {
    let f = try EngineLocationFixture()
    let custom = try f.directory("Custom"), other = try f.directory("Other")
    _ = try f.project("Custom/1"); _ = try f.project("Other/2")
    let model = f.model()
    var starts = 0
    model.startWallpaper = { _ in starts += 1 }
    model.showLocationPanel = { request in #expect(request.directory == nil); return custom }
    await model.chooseLocation(importing: false)
    #expect(model.localProjects.count == 1)
    #expect(model.collectionDirectories == [custom])
    #expect(model.projects.isEmpty && starts == 0)
    #expect(model.selection.kind == .video)
    #expect(f.defaults.string(forKey: "WallpaperEngineLastLibraryDirectory") == custom.path)
    model.rememberLibraryDirectory(other)
    let relaunched = f.model()
    relaunched.showLocationPanel = { request in #expect(request.directory == custom); return nil }
    await relaunched.chooseLocation(importing: false)
    #expect(relaunched.error == nil)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories")?.count == 2)
}

@Test @MainActor func engineLocationMissingSourceOffersManualChoiceAndCancellationDoesNotPersist() async throws {
    let f = try EngineLocationFixture(), model = f.model(roots: [f.root.appendingPathComponent("missing")])
    var requests = 0
    f.defaults.set(f.root.appendingPathComponent("disconnected").path, forKey: "WallpaperEngineLastLibraryDirectory")
    model.showLocationPanel = { request in requests += 1; #expect(request.directory == nil); return nil }
    await model.chooseLocation(importing: false)
    #expect(requests == 1 && model.error == nil)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
    #expect(model.selection.kind == .video)
    let cancelled = Task { await model.chooseLocation(importing: false) }
    cancelled.cancel(); await cancelled.value
    #expect(requests == 1 && !model.isLocatingLibrary)
}

@Test @MainActor func engineLocationRetainedImportStillCopiesOnlyChosenProjectToPreview() async throws {
    let f = try EngineLocationFixture()
    let source = try f.project("Steam/steamapps/workshop/content/431960/1")
    let model = f.model(roots: [f.root.appendingPathComponent("Steam")])
    var starts = 0
    model.startWallpaper = { _ in starts += 1 }
    model.showLocationPanel = { request in #expect(request.importing); return source.appendingPathComponent("index.html") }
    await model.chooseLocation(importing: true)
    while model.isImporting { await Task.yield() }
    #expect(model.projects.count == 1)
    #expect(model.selection.kind == .web && model.libraryIsSelected)
    #expect(model.error == nil && starts == 0)
}

@Test @MainActor func engineLocationCancelledCollectionChoiceDoesNotOpenPanelOrSaveAnything() async throws {
    let f = try EngineLocationFixture()
    _ = try f.directory("Steam/steamapps/workshop/content/431960")
    _ = try f.directory("Other/steamapps/workshop/content/431960")
    let model = f.model(roots: [f.root.appendingPathComponent("Steam"), f.root.appendingPathComponent("Other")])
    model.chooseCollectionLocation = { _ in nil }
    await model.chooseLocation(importing: false)
    #expect(model.error == nil && !model.isLocatingLibrary)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
}

@Test @MainActor func engineLocationDiscardedSearchNeverPresentsAStalePanel() async throws {
    let f = try EngineLocationFixture()
    let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
    let selection = WallpaperPreviewSelectionStore(selectionURL: f.root.appendingPathComponent("selection.json"))
    let model = WallpaperEngineViewModel(selection: selection, library: f.library, libraryDefaults: f.defaults,
        steamRootsProvider: { started.signal(); proceed.wait(); return [] })
    model.showLocationPanel = { _ in Issue.record("Presented a cancelled search"); return nil }
    let task = Task { await model.chooseLocation(importing: true) }
    let waitForStart: @Sendable () -> Void = { started.wait() }
    await Task.detached { waitForStart() }.value
    model.cancelImport()
    proceed.signal()
    await task.value
    #expect(!model.isImporting && !model.isLocatingLibrary)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
}

@Test @MainActor func engineLocationMissingChosenFolderIsReportedWithoutPersisting() async throws {
    let f = try EngineLocationFixture(), folder = try f.directory("Steam/steamapps/workshop/content/431960")
    let model = f.model(roots: [f.root.appendingPathComponent("Steam")])
    model.showLocationPanel = { _ in try FileManager.default.removeItem(at: folder); return folder }
    await model.chooseLocation(importing: false)
    #expect(model.error?.contains("cannot be read") == true)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
}

@Test @MainActor func engineLocationRejectsUnrelatedAndManagedFoldersWithoutSavingThem() async throws {
    let f = try EngineLocationFixture()
    let unrelated = try f.directory("Unrelated")
    _ = try f.project("Managed/1")
    let model = f.model()
    for folder in [unrelated, f.library.rootURL] {
        model.showLocationPanel = { _ in folder }
        await model.chooseLocation(importing: false)
        #expect(model.error?.contains("No Wallpaper Engine collection") == true)
        #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == nil)
    }
}

@Test @MainActor func engineLocationConfirmedCustomCollectionRemainsUsableWhenEmpty() async throws {
    let f = try EngineLocationFixture(), collection = try f.directory("Custom")
    let source = try f.project("Custom/1")
    let model = f.model()
    model.showLocationPanel = { _ in collection }
    await model.chooseLocation(importing: false)
    try FileManager.default.removeItem(at: source)
    await model.refreshLocalLibrary()
    #expect(model.localProjects.isEmpty && model.collectionDirectories == [collection])
    model.showLocationPanel = { request in #expect(request.directory == collection); return nil }
    await model.chooseLocation(importing: false)
    #expect(model.error == nil)
}

@Test @MainActor func engineLocationNestedAssetImportRemembersProjectNotAssetsDirectory() async throws {
    let f = try EngineLocationFixture(), source = try f.project("Project")
    let assets = try f.directory("Project/assets")
    try FileManager.default.moveItem(at: source.appendingPathComponent("index.html"), to: assets.appendingPathComponent("index.html"))
    try Data(#"{"type":"web","file":"assets/index.html","title":"Nested"}"#.utf8).write(to: source.appendingPathComponent("project.json"))
    let model = f.model()
    model.showLocationPanel = { _ in assets.appendingPathComponent("index.html") }
    await model.chooseLocation(importing: true)
    while model.isImporting { await Task.yield() }
    #expect(model.error == nil)
    #expect(f.defaults.stringArray(forKey: "WallpaperEngineLibraryDirectories") == [source.path])
    #expect(f.defaults.string(forKey: "WallpaperEngineLastImportDirectory") == source.path)
    #expect(f.defaults.string(forKey: "WallpaperEngineLastLibraryDirectory") == nil)
}

@Test func engineLocationUnavailableFolderIsNotOfferedAsVerifiedCollection() throws {
    let f = try EngineLocationFixture(), folder = try f.directory("Steam/steamapps/workshop/content/431960")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let locations = WallpaperEngineLibraryLocations.resolve(steamRoots: [f.root.appendingPathComponent("Steam")])
    #expect(locations.collections.isEmpty)
    #expect(!locations.warnings.isEmpty)
    #expect(!WallpaperEngineLibraryLocations.isAccessibleDirectory(folder))
}

@Suite(.serialized) @MainActor struct EngineLibraryHeaderTests {
    @Test(arguments: [false, true])
    func libraryFolderIsOnlyInEngineTabAndHeaderHasNoImport(engineTab: Bool) async throws {
        let f = try EngineLocationFixture(), model = f.model()
        model.libraryIsSelected = engineTab
        let hosting = NSHostingView(rootView: WallpaperEngineLibrarySwitch(model: model).padding(16))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        var requests = 0
        model.showLocationPanel = { request in
            requests += 1
            #expect(!request.importing)
            return nil
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 810, y: 40),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(requests == (engineTab ? 1 : 0))
    }
}
