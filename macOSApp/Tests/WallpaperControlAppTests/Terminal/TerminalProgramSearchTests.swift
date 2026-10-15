import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private func programTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-program-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct ProgramLocalDiscovery: TerminalWallpaperCatalogProviding {
    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        guard query == "uname" else { return [] }
        return [.init(id: "discovered:/usr/bin/uname", title: "uname", subtitle: "Local program",
                      category: .utilities, systemImage: "terminal", executableCandidates: ["/usr/bin/uname"])]
    }
}

private struct ProgramTestPackages: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        return .init(name: preset.formula, version: "999.0", disabled: false, executables: [preset.executableName])
    }
}

private struct ProgramOfflinePackages: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        throw URLError(.notConnectedToInternet)
    }
}

private struct ProgramForbiddenInstaller: TerminalWallpaperInstalling {
    func install(preset: TerminalWallpaperPreset, onStage: @escaping @Sendable (String) -> Void) async throws {
        Issue.record("Installed local programs must not enter the installer")
        throw CancellationError()
    }
}

private struct ProgramOfflineSearch: TerminalProgramSearchProviding {
    func search(_ query: String) async throws -> [TerminalWallpaperPreset] { throw URLError(.notConnectedToInternet) }
}

private struct ProgramOrderedLocalResults: TerminalWallpaperCatalogProviding {
    let items: [TerminalWallpaperCatalogItem]
    func discover(query: String) -> [TerminalWallpaperCatalogItem] { items }
}

private struct ProgramDelayedOrderedResults: TerminalProgramSearchProviding {
    let presets: [TerminalWallpaperPreset]
    func search(_ query: String) async throws -> [TerminalWallpaperPreset] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return presets
    }
}

final class ProgramTestController: TerminalWallpaperControlling, @unchecked Sendable {
    func status() throws -> TerminalWallpaperStatus { .init(running: false, config: .defaultConfig) }
    func ensureCanStart() throws { Issue.record("Search must not start wallpaper") }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop start"); return try status() }
    func stop() throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop stop"); return try status() }
    func terminate() throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop terminate"); return try status() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop restart"); return try status() }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected runtime update"); return try status() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected runtime resize"); return try status() }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected login update"); return try status() }
}

@Test func programSearchIncludesAllCoreCLIsAndFiltersInvalidMetadata() {
    typealias Formula = SystemTerminalProgramSearchProvider.Formula
    let formulae = [
        Formula(name: "figlet", desc: "Static ASCII text", tap: "homebrew/core", disabled: false, executables: ["figlet", "chkfont"]),
        Formula(name: "fastfetch", desc: "System information", tap: "homebrew/core", disabled: false, executables: ["fastfetch"]),
        Formula(name: "libtext", desc: "Static ASCII text", tap: "homebrew/core", disabled: false, executables: []),
        Formula(name: "unsafe", desc: "Static ASCII text", tap: "other/tap", disabled: false, executables: ["unsafe"]),
        Formula(name: "old", desc: "Static ASCII text", tap: "homebrew/core", disabled: true, executables: ["old"]),
        Formula(name: "bad/name", desc: "Static ASCII text", tap: "homebrew/core", disabled: false, executables: ["bad"])
    ]
    #expect(SystemTerminalProgramSearchProvider.results(query: "figlet", formulae: formulae).first?.program?.name == "figlet")
    #expect(Set(SystemTerminalProgramSearchProvider.results(query: "static", formulae: formulae).compactMap { $0.program?.name }) == ["figlet", "chkfont"])
    #expect(SystemTerminalProgramSearchProvider.results(query: "fast", formulae: formulae).first?.item.arguments == ["--config", "none", "--logo-type", "builtin"])
    #expect(SystemTerminalProgramSearchProvider.results(query: "figlet; rm", formulae: formulae).isEmpty)
}

@Test func programLibraryReadsLegacyIDsAndPersistsDiscoveredProgramsWithoutDuplicates() async throws {
    let directory = try programTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.json")
    try Data(#"{"version":1,"animationIDs":["nyancat","unknown","nyancat"]}"#.utf8).write(to: url)
    let library = TerminalAnimationLibraryStore(url: url)
    #expect(try await library.load() == ["nyancat"])
    let program = TerminalProgramDefinition(id: "local:uname", name: "uname", formula: "", executable: "/usr/bin/uname").preset
    _ = try await library.add(program)
    _ = try await library.add(program)
    let restarted = TerminalAnimationLibraryStore(url: url)
    #expect(try await restarted.load() == ["nyancat", "local:uname"])
    #expect(try await restarted.loadPrograms() == [program])
    let forged = TerminalWallpaperPreset(id: "local:uname", description: "unsafe", formula: "bad/tap", program: program.program)
    await #expect(throws: (any Error).self) { _ = try await library.add(forged) }
    #expect(try await restarted.load() == ["nyancat", "local:uname"])
}

@Test(arguments: [0, 7]) @MainActor
func programStaticPTYKeepsOutputButRejectsFailedExit(code: Int) async throws {
    let directory = try programTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store,
        runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime")),
        windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = .init(executable: "/bin/sh", arguments: ["-c", "printf 'STATIC OUTPUT'; exit \(code)"])
    let id = UUID()
    store.beginTemporaryTerminal(config, operationID: id)
    if code == 0 {
        try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 2)
        try store.commitTemporaryTerminal(operationID: id)
        let snapshot = try #require(preview.snapshot)
        try await Task.sleep(nanoseconds: 750_000_000)
        #expect(preview.snapshot?.revision == snapshot.revision)
        #expect(preview.snapshot?.cells.contains(where: { $0.text == "S" }) == true)
    } else {
        await #expect(throws: (any Error).self) { try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 2) }
        store.rollbackTemporaryTerminal(operationID: id)
        #expect(store.kind == .video)
    }
    store.selectVideo()
}

@Test @MainActor
func programLocalSearchFindsGeneralCLIWithoutLaunchingOrSaving() async throws {
    let directory = try programTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let library = TerminalAnimationLibraryStore(url: directory.appendingPathComponent("library.json"))
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(),
        catalogProvider: ProgramLocalDiscovery(), installer: ProgramForbiddenInstaller(), previewSelectionStore: store,
        libraryStore: library, packageProvider: ProgramOfflinePackages(), programSearchProvider: ProgramOfflineSearch(),
        previewReady: { _, _ in Issue.record("Search launched an unsupported utility") })
    model.setCatalogSearch("uname")
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(model.catalogItems.first?.id == "local:uname")
    #expect(model.searchError != nil && !model.catalogIsLoading)
    #expect(store.kind == .video && !model.isBusy)
    #expect(try await library.load().isEmpty)
}

private struct ProgramSlowSearch: TerminalProgramSearchProviding {
    func search(_ query: String) async throws -> [TerminalWallpaperPreset] {
        if query == "old-cli" {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
        }
        return [TerminalProgramDefinition(id: "brew:\(query):\(query)", name: query, formula: query, executable: nil).preset]
    }
}

@Test @MainActor
func programLateInternetResultsCannotReplaceNewQuery() async throws {
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(),
        catalogProvider: ProgramLocalDiscovery(), resolveExecutable: { _ in nil },
        packageProvider: ProgramOfflinePackages(), programSearchProvider: ProgramSlowSearch())
    model.setCatalogSearch("old-cli")
    try await Task.sleep(nanoseconds: 250_000_000)
    model.setCatalogSearch("new-cli")
    try await Task.sleep(nanoseconds: 450_000_000)
    #expect(model.catalogItems.map(\.id) == ["brew:new-cli:new-cli"])
    #expect(!model.catalogIsLoading)
}

@Test func programPackageMetadataMustVerifyExecutableAndCoreTap() async throws {
    let preset = TerminalProgramDefinition(id: "brew:fastfetch:fastfetch", name: "fastfetch", formula: "fastfetch", executable: nil).preset
    let provider = SystemTerminalAnimationPackageProvider(cacheURL: nil, fetch: { request in
        (Data(#"{"name":"figlet","tap":"homebrew/core","executables":["other"],"disabled":false,"versions":{"stable":"1"}}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: (any Error).self) { _ = try await provider.metadata(for: preset) }
}

@Test func programInternetIndexIsCachedForOfflineRestart() async throws {
    let directory = try programTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.json")
    let provider = SystemTerminalProgramSearchProvider(cacheURL: url, fetch: { request in
        #expect(request.timeoutInterval == 10 && request.url?.path == "/api/formula.json")
        return (Data(#"[{"name":"figlet","tap":"homebrew/core","desc":"Static ASCII text","disabled":false,"executables":["figlet","chkfont"]}]"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    #expect(try await provider.search("figlet").first?.id == "brew:figlet:figlet")
    let offline = SystemTerminalProgramSearchProvider(cacheURL: url, fetch: { _ in throw URLError(.notConnectedToInternet) })
    #expect(Set(try await offline.search("static").compactMap { $0.program?.name }) == ["figlet", "chkfont"])
}

private func rankedProgram(_ name: String, formula: String? = nil) -> TerminalWallpaperPreset {
    if let formula {
        return TerminalProgramDefinition(id: "brew:\(formula):\(name)", name: name, formula: formula, executable: nil).preset
    }
    return TerminalProgramDefinition(id: "local:\(name)", name: name, formula: "", executable: nil).preset
}

@Test(arguments: ["htop", " HTOP ", "HtOp"])
func programRankingExactExecutableAlwaysBeatsPrefixSubstringAndFuzzy(query: String) {
    let values = ["autopoint", "getopt", "getopts", "top", "my-htop", "htop-extra", "htop"].map { rankedProgram($0) }
    let ranked = TerminalProgramSearchRanking.presets(values, query: query)
    #expect(ranked.first?.item.title == "htop")
    #expect(ranked.dropFirst().first?.item.title == "htop-extra")
    #expect(ranked[2].item.title == "my-htop")
    #expect(ranked.count == values.count)
    let displayedTitle = TerminalWallpaperCatalogItem(id: "monitor", title: "System Monitor", subtitle: "",
        category: .utilities, systemImage: "terminal", executableCandidates: ["/some/path/htop"])
    #expect(TerminalProgramSearchRanking.items([values[0].item, displayedTitle], query: query).first?.id == "monitor")
}

@Test(arguments: [("аквариум", "asciiquarium"), ("ЛАВА", "lavat"), ("matrix", "cmatrix")])
func programRankingKeepsExactAnimationAliasesAheadOfOtherSources(query: String, expected: String) {
    let matches = [rankedProgram("some-tool")] + TerminalWallpaperPreset.search(query)
    #expect(TerminalProgramSearchRanking.presets(matches, query: query).first?.id == expected)
}

@Test func programRankingExactResultsAreNotLostToLocalLimitOrDuplicates() {
    let fuzzy = (0..<40).map { rankedProgram("htop-extra-\($0)").item }
    let exact = rankedProgram("htop").item
    let provider = SystemTerminalWallpaperCatalogProvider(searchItems: { _ in fuzzy + [exact, exact] }, indexItems: { fuzzy + [exact] })
    let results = provider.search(query: " HTOP ")
    #expect(results.count == 24)
    #expect(results.first?.title == "htop")
    #expect(results.filter { $0.title == "htop" }.count == 1)
    #expect(Set(results.map(\.id)).count == results.count)
}

@Test func programRankingExactOnlineResultsSurvivePackageLimit() {
    typealias Formula = SystemTerminalProgramSearchProvider.Formula
    let fuzzy = (0..<40).map { Formula(name: "a-package-\($0)", desc: "htop alternative", tap: "homebrew/core", disabled: false, executables: ["a-program-\($0)"]) }
    let exact = Formula(name: "htop", desc: "Process viewer", tap: "homebrew/core", disabled: false, executables: ["htop"])
    let results = SystemTerminalProgramSearchProvider.results(query: " HTOP ", formulae: fuzzy + [exact])
    #expect(results.count == 24)
    #expect(results.first?.id == "brew:htop:htop")
}

@Test(arguments: [true, false]) @MainActor
func programRankingIsReappliedAfterLocalAndLateOnlineResults(localHasExact: Bool) async throws {
    let directory = try programTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let names = ["autopoint", "getopt", "getopts", "top"] + (localHasExact ? ["htop"] : [])
    let localItems = try names.map { name -> TerminalWallpaperCatalogItem in
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        return .init(id: "discovered:\(file.path)", title: name, subtitle: "Local program", category: .utilities,
                     systemImage: "terminal", executableCandidates: [file.path])
    }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(),
        catalogProvider: ProgramOrderedLocalResults(items: localItems), installer: ProgramForbiddenInstaller(),
        previewSelectionStore: store, libraryStore: TerminalAnimationLibraryStore(url: directory.appendingPathComponent("library.json")),
        packageProvider: ProgramTestPackages(),
        programSearchProvider: ProgramDelayedOrderedResults(presets: [rankedProgram("other-tool", formula: "other-tool"), rankedProgram("htop", formula: "htop")]))
    model.setCatalogSearch("HTOP")
    let deadline = Date().addingTimeInterval(3)
    while model.catalogItems.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    if localHasExact { #expect(model.catalogItems.first?.title == "htop") }
    while model.catalogIsLoading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.catalogIsLoading)
    #expect(model.catalogItems.first?.title == "htop")
    #expect(model.catalogItems.filter { $0.title == "htop" }.count == 1)
    #expect(!model.isBusy && !model.status.running && store.kind == .video)
    model.setCatalogSearch("")
    #expect(model.catalogItems.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes"])
}
