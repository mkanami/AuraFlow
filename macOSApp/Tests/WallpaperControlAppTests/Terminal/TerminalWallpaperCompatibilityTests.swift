import AppKit
import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private struct CompatibilityEmptyCatalog: TerminalWallpaperCatalogProviding {
    func discover(query: String) -> [TerminalWallpaperCatalogItem] { [] }
}

private struct CompatibilityOfflinePackages: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata { throw URLError(.notConnectedToInternet) }
}

private struct CompatibilityDefaultLaunch: TerminalProgramAnimationResolving {
    func resolve(_ command: TerminalCommandConfiguration) async throws -> TerminalCommandConfiguration {
        command
    }
    func reject(_ command: TerminalCommandConfiguration) async {}
}

@Test(arguments: [false, true]) @MainActor
func wallpaperCardFailureShowsFriendlyMessageKeepsSearchAndRollsBack(cancel: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraWallpaperRollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    store.selectWeb("previous-web")
    let library = TerminalAnimationLibraryStore(url: root.appendingPathComponent("library.json"))
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(), catalogProvider: CompatibilityEmptyCatalog(),
        previewSelectionStore: store, resolveExecutable: { _ in "/test/htop" }, libraryStore: library,
        packageProvider: CompatibilityOfflinePackages(), animationResolver: CompatibilityDefaultLaunch(),
        previewReady: { config, _ in
            #expect(config.command.arguments == ["-d", "20"])
            if cancel { throw CancellationError() }
            throw TerminalWallpaperControllerError.unavailable("No wallpaper output")
        })
    model.setCatalogSearch("htop")
    let deadline = Date().addingTimeInterval(3)
    while model.catalogIsLoading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    model.use(try #require(model.catalogItems.first))
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(store.kind == .web && store.webProjectID == "previous-web")
    #expect(try await library.load().isEmpty)
    model.setCatalogSearch("HTOP")
    while model.catalogIsLoading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.catalogItems.contains { $0.executableCandidates.contains("htop") })
    if !cancel { #expect(model.errorMessage == "Не удалось запустить программу. Пожалуйста, выберите другую.") }
    #expect((model.errorMessage == nil) == cancel)
}

@Test @MainActor func wallpaperLegacyProgramLibraryRecordRemainsVisible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraWallpaperLegacy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = TerminalAnimationLibraryStore(url: root.appendingPathComponent("library.json"))
    let old = TerminalProgramDefinition(id: "local:uname", name: "uname", formula: "", executable: "/usr/bin/uname").preset
    _ = try await library.add(old)
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(), catalogProvider: CompatibilityEmptyCatalog(),
        resolveExecutable: { _ in nil }, libraryStore: library, packageProvider: CompatibilityOfflinePackages())
    model.prepareCatalogIfNeeded()
    model.setCatalogSearch("uname")
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(model.catalogItems.isEmpty)
    #expect(model.libraryPresets.contains { $0.id == old.id })
    #expect(try await library.load() == [old.id])
    #expect(try await library.loadPrograms() == [old])
}

@Test(arguments: ["top", "pt", "ptargrep", "ptar", "grep", "tar", "uname", "figlet", "cowsay", "chkfont", "vm_stat", "iostat", "log"])
func wallpaperSearchIncludesGeneralCLIs(_ name: String) {
    #expect(TerminalWallpaperCompatibility.profile(executable: name) == nil)
    #expect(TerminalWallpaperPreset.search(name).allSatisfy { $0.compatibilityProfile?.executable != name })
    typealias Formula = SystemTerminalProgramSearchProvider.Formula
    let data = [Formula(name: name, desc: "Animated terminal ASCII visualizer", tap: "homebrew/core", disabled: false, executables: [name])]
    #expect(SystemTerminalProgramSearchProvider.results(query: name, formulae: data).first?.program?.name == name)
}

@Test func wallpaperCompatibilityUsesExactPackageBinaryAndReviewedLaunch() {
    typealias Formula = SystemTerminalProgramSearchProvider.Formula
    let data = [Formula(name: "fastfetch", desc: "Static", tap: "homebrew/core", disabled: false,
                        executables: ["fastfetch", "chkfont", "ptargrep", "cava"])]
    let found = SystemTerminalProgramSearchProvider.results(query: "fastfetch", formulae: data)
    #expect(found.count == 4)
    #expect(found.first?.item.arguments == ["--config", "none", "--logo-type", "builtin"])
    #expect(TerminalWallpaperCompatibility.profile(executable: "cava", formula: "fastfetch") == nil)
    #expect(TerminalWallpaperCompatibility.profile(id: "cbonsai-static")?.mode == .static)
    #expect(TerminalWallpaperPreset.preset(id: "cbonsai-static")?.item.arguments == ["-p"])
    for profile in TerminalWallpaperCompatibility.profiles {
        #expect(!profile.verifiedVersions.isEmpty && !profile.verifiedMacOS.isEmpty)
    }
}

@Test func wallpaperSearchAllowsNewPackageVersions() {
    typealias Formula = SystemTerminalProgramSearchProvider.Formula
    let data = [Formula(name: "htop", desc: "Monitor", tap: "homebrew/core", disabled: false,
                        executables: ["htop"], versions: .init(stable: "999.0"))]
    #expect(SystemTerminalProgramSearchProvider.results(query: "htop", formulae: data).first?.program?.name == "htop")
}

@Test func wallpaperDiagnosticsPreservesCauseBeforeLongHelp() {
    let help = "No pattern specified\nUsage: ptargrep <pattern> <tar file>\n" + String(repeating: "option description\n", count: 100)
    #expect(TerminalProgramDiagnostics.summary(help) == "No pattern specified")
    #expect(TerminalProgramDiagnostics.isHelpOrPrompt("ASCII tool\nUsage: tool [options]"))
    #expect(TerminalProgramDiagnostics.isHelpOrPrompt("Enter your password:"))
    #expect(!TerminalProgramDiagnostics.isHelpOrPrompt("CPU 12%\nMemory 2 GB"))
}

/// Run with AURAFLOW_WALLPAPER_COMPATIBILITY_AUDIT=1. Missing programs fail
/// rather than silently skipping a preset. This renders the actual preview,
/// checks persistence, then keeps every live program running for 30 seconds.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AURAFLOW_WALLPAPER_COMPATIBILITY_AUDIT"] == "1"),
      arguments: TerminalWallpaperCompatibility.profiles)
@MainActor func wallpaperCompatibilityAudit(_ profile: TerminalWallpaperCompatibilityProfile) async throws {
    let executable = try #require(profile.item.resolvedExecutable(), "Install \(profile.formula) before auditing")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraWallpaperAudit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store,
        runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = .init(catalogItemID: profile.id, executable: executable, arguments: profile.arguments)
    config.render.columns = 120; config.render.rows = 40
    let operation = UUID()
    store.beginTemporaryTerminal(config, operationID: operation)
    defer { store.selectVideo() }
    try await preview.waitUntilReady(configuration: config, operationID: operation, timeout: 10)
    try store.commitTemporaryTerminal(operationID: operation)
    let first = try #require(preview.snapshot)
    #expect(first.hasVisibleContent)
    let duration = profile.mode == .static ? 1.0 : 30.0
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(preview.previewError == nil)
        #expect(preview.snapshot?.hasVisibleContent == true)
        if profile.mode != .static { #expect(preview.previewProcessIsRunning && preview.previewProcessExitCode == nil) }
    }
    let final = try #require(preview.snapshot)
    if profile.mode == .static {
        if final.cells != first.cells {
            let differences = zip(first.cells, final.cells).enumerated().filter { $0.element.0 != $0.element.1 }
            print("STATIC CHANGES", profile.id, first.columns, first.rows, final.columns, final.rows,
                  "count", differences.count, differences.prefix(8).map { ($0.offset, $0.element.0.text, $0.element.1.text) })
        }
        #expect(Bool(final.cells == first.cells), "Static frame must remain unchanged")
    }
    else { #expect(Bool(final.cells != first.cells), "Live wallpaper must update") }
    let reopened = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(reopened.terminalConfiguration?.command == config.command)
    if let directory = ProcessInfo.processInfo.environment["AURAFLOW_TERMINAL_RENDER_ARTIFACTS"] {
        let frame = try await terminalGPUFrame(final, width: 1200, height: 800)
        try saveTerminalFrame(frame, name: "compatibility-\(profile.id)", directory: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["profile": profile.id, "testedVersions": profile.verifiedVersions,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": profile.mode.rawValue, "arguments": profile.arguments, "stableSeconds": duration]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("compatibility-\(profile.id).json"))
    }
}

private struct GeneralCLIErrorCatalog: TerminalWallpaperCatalogProviding {
    let path: String
    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        [.init(id: "discovered:\(path)", title: "input-cli", subtitle: "Local program", category: .utilities,
               systemImage: "terminal", executableCandidates: [path])]
    }
}

@Test @MainActor func wallpaperCardRealFailedCLIShowsFriendlyErrorAndPreservesPreviousSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraGeneralCLIFailure-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("input-cli")
    try Data("#!/bin/sh\nprintf 'No pattern specified\\nUsage: input-cli <pattern> <file>\\n'\nexit 1\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    store.selectWeb("previous-web")
    let preview = TerminalWallpaperPreviewModel(selectionStore: store,
        runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
    let library = TerminalAnimationLibraryStore(url: root.appendingPathComponent("library.json"))
    let model = TerminalWallpaperViewModel(controller: ProgramTestController(), catalogProvider: GeneralCLIErrorCatalog(path: executable.path),
        previewSelectionStore: store, libraryStore: library, packageProvider: CompatibilityOfflinePackages(),
        animationResolver: CompatibilityDefaultLaunch(),
        previewReady: { config, id in try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 2) })
    model.setCatalogSearch("input-cli")
    let deadline = Date().addingTimeInterval(5)
    while model.catalogIsLoading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let card = try #require(model.catalogItems.first)
    #expect(card.id == "local:input-cli")
    model.use(card)
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.isBusy)
    #expect(model.errorMessage == "Не удалось запустить программу. Пожалуйста, выберите другую.")
    #expect(store.kind == .web && store.webProjectID == "previous-web")
    #expect(try await library.load().isEmpty)
    #expect(model.catalogItems.contains { $0.id == card.id })
}
