import Foundation
import Testing
@testable import AuraTerminalWallpaperCore
@testable import WallpaperControlApp

private func installPreviewDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraInstallPreview-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class InstallPreviewCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [String] = []
    private var executable: String?
    func append(_ stage: String) { lock.lock(); defer { lock.unlock() }; stages.append(stage) }
    var output: [String] { lock.lock(); defer { lock.unlock() }; return stages }
    func finish(path: String) { lock.lock(); defer { lock.unlock() }; executable = path }
    func resolve() -> String? { lock.lock(); defer { lock.unlock() }; return executable }
}

@Test func lolcatInputIsPrivateBoundedAndDoesNotOverrideCustomArguments() throws {
    let root = try installPreviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = try TerminalLolcatVisualInput(columns: 80, rows: 24, temporaryDirectory: root)
    let another = try TerminalLolcatVisualInput(columns: 80, rows: 24, temporaryDirectory: root)
    defer { input.stop(); another.stop() }
    let text = TerminalLolcatVisualInput.sample(columns: 80, rows: 24)
    #expect(text.contains("#") && text.contains("@"))
    #expect(text.utf8.count < 2_000)
    #expect(TerminalLolcatVisualInput.sample(columns: Int.max, rows: Int.max).utf8.count < 512_000)
    #expect(!TerminalLolcatVisualInput.sample(columns: Int.min, rows: Int.min).isEmpty)
    #expect(input.directory != another.directory)
    #expect(try FileManager.default.attributesOfItem(atPath: input.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: input.fifoURL.path)[.posixPermissions] as? Int == 0o600)
    #expect(input.arguments == ["--force", "--truecolor", input.fifoURL.path])
    #expect(text != TerminalLolcatVisualInput.sample(columns: 80, rows: 24, phase: 1))
    var parser = VTParser(columns: 80, rows: 24)
    parser.feed(Data(text.utf8))
    let snapshot = parser.grid.snapshot()
    for row in 0..<24 {
        #expect((0..<80).contains { snapshot.cell(column: $0, row: row).text != " " })
    }
    #expect(!text.hasSuffix("\n") && !text.hasSuffix("\r"))
    #expect(TerminalLolcatVisualInput.applies(to: .init(executable: "lolcat"), executable: "/opt/homebrew/bin/lolcat"))
    #expect(!TerminalLolcatVisualInput.applies(to: .init(executable: "lolcat", arguments: ["my-file.txt"]), executable: "/opt/homebrew/bin/lolcat"))
    #expect(!TerminalLolcatVisualInput.applies(to: .init(executable: "cat"), executable: "/bin/cat"))
    input.stop()
    #expect(!FileManager.default.fileExists(atPath: input.directory.path))
    #expect(FileManager.default.fileExists(atPath: another.fifoURL.path))
}

@Test(arguments: [(80, 24), (153, 48)]) @MainActor
func lolcatInstalledPreviewStartsQuicklyAndKeepsAnimating(columns: Int, rows: Int) async throws {
    guard let executable = TerminalExecutableLocator.resolve("lolcat") else { return }
    let root = try installPreviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = .init(catalogItemID: "brew:lolcat:lolcat", executable: executable)
    config.render.columns = columns; config.render.rows = rows
    let id = UUID()
    let started = Date()
    store.beginTemporaryTerminal(config, operationID: id)
    try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 3)
    print("lolcat \(columns)x\(rows) first visible preview: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    #expect(preview.snapshot?.hasVisibleContent == true)
    #expect(preview.snapshot?.cells.contains { $0.style.foreground != .default } == true)
    let first = try #require(preview.snapshot)
    try store.commitTemporaryTerminal(operationID: id)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(preview.previewError == nil && preview.snapshot?.hasVisibleContent == true)
    let final = try #require(preview.snapshot)
    #expect(final.cells != first.cells)
    for row in 0..<rows {
        #expect((0..<columns).contains { final.cell(column: $0, row: row).text != " " })
    }
    #expect(store.terminalConfiguration?.command.arguments == [])
    #expect(!runtime.status().running)
    store.selectVideo()
}

private struct InstallForbiddenMetadata: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        Issue.record("Already installed executables must not require the network")
        throw URLError(.notConnectedToInternet)
    }
}

@Test func fastInstallerRechecksLocalExecutableBeforeAnyNetworkOrHomebrew() async throws {
    let preset = TerminalProgramDefinition(id: "brew:lolcat:lolcat", name: "lolcat", formula: "lolcat", executable: nil).preset
    let installer = SystemTerminalWallpaperInstaller(
        packageProvider: InstallForbiddenMetadata(), resolveExecutable: { _ in "/test/lolcat" },
        resolveBrew: { Issue.record("Homebrew should not be consulted"); return nil },
        runCommand: { _, _, _, _ in Issue.record("Unexpected install process"); throw CancellationError() }
    )
    try await installer.install(preset: preset) { _ in Issue.record("Unexpected installation stage") }
}

private actor InstallMetadataRecorder {
    var count = 0
    func fetch(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        count += 1
        return (Data(#"{"name":"lolcat","tap":"homebrew/core","executables":["lolcat"],"disabled":false,"versions":{"stable":"100.0.1"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func fastInstallerReusesVerifiedMetadataAndStreamsProgressWithoutSkippingDependencies() async throws {
    let recorder = InstallMetadataRecorder()
    let provider = SystemTerminalAnimationPackageProvider(cacheURL: nil, fetch: { await recorder.fetch($0) })
    let preset = TerminalProgramDefinition(id: "brew:lolcat:lolcat", name: "lolcat", formula: "lolcat", executable: nil).preset
    _ = try await provider.metadata(for: preset) // Availability check.
    let capture = InstallPreviewCapture()
    let installer = SystemTerminalWallpaperInstaller(packageProvider: provider,
        resolveExecutable: { _ in capture.resolve() }, resolveBrew: { "/test/brew" },
        runCommand: { executable, arguments, environment, output in
            #expect(executable == "/test/brew")
            #expect(arguments == ["install", "--formula", "homebrew/core/lolcat"])
            #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
            #expect(environment["HOMEBREW_NO_INSTALL_UPGRADE"] == "1")
            #expect(environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == nil)
            #expect(!arguments.contains("--ignore-dependencies") && !arguments.contains("--force-bottle"))
            output("==> Down"); output("loading package\n")
            output("==> Downloading another package\n")
            output("==> Installing dependencies for lolcat: ruby\n")
            output("==> Pouring ruby.bottle.tar.gz\n")
            capture.finish(path: "/test/lolcat")
            return (0, "Installed")
        })
    try await installer.install(preset: preset) { capture.append($0) }
    #expect(await recorder.count == 1)
    #expect(capture.output == ["Installing lolcat…", "Downloading packages…", "Installing dependencies…", "Installing prebuilt package…"])
    // A second selection cannot redownload or reverify an installed program.
    try await installer.install(preset: preset) { _ in Issue.record("Repeated download") }
    #expect(await recorder.count == 1)
}

@Test func installerOutputArrivesBeforeExitAndCancellationStopsOnlyOwnedProcess() async throws {
    let capture = InstallPreviewCapture()
    let task = Task {
        try await SystemTerminalWallpaperInstaller.run("/bin/sh",
            arguments: ["-c", "printf 'download started\\n'; sleep 10"], onOutput: { capture.append($0) })
    }
    let deadline = Date().addingTimeInterval(2)
    while capture.output.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(capture.output.joined().contains("download started"))
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

private struct InstallPreviewDiscovery: TerminalWallpaperCatalogProviding {
    func discover(query: String) -> [TerminalWallpaperCatalogItem] { [] }
}

private struct InstallPreviewSearch: TerminalProgramSearchProviding {
    let preset: TerminalWallpaperPreset
    func search(_ query: String) async throws -> [TerminalWallpaperPreset] { [preset] }
}

private struct InstallPreviewController: TerminalWallpaperControlling {
    func status() throws -> TerminalWallpaperStatus { .init(running: false, config: .defaultConfig) }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Preview started desktop/Lock Screen"); return try status() }
    func stop() throws -> TerminalWallpaperStatus { Issue.record("Preview stopped desktop/Lock Screen"); return try status() }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try start(config: config) }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Preview changed runtime settings"); return try status() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
}

@Test @MainActor
func lolcatInstallAutomaticallyShowsRealPreviewAndPersistsOneCard() async throws {
    // Simulate only Homebrew completion; preview runs the actual installed
    // executable, through the normal visual-only PTY and readiness handshake.
    guard let executable = TerminalExecutableLocator.resolve("lolcat") else { return }
    let root = try installPreviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = InstallPreviewCapture()
    let recorder = InstallMetadataRecorder()
    let provider = SystemTerminalAnimationPackageProvider(cacheURL: nil, fetch: { await recorder.fetch($0) })
    let preset = TerminalProgramDefinition(id: "brew:lolcat:lolcat", name: "lolcat", formula: "lolcat", executable: nil).preset
    let installer = SystemTerminalWallpaperInstaller(packageProvider: provider,
        resolveExecutable: { _ in capture.resolve() }, resolveBrew: { "/test/brew" },
        runCommand: { _, _, _, output in
            capture.append("install")
            output("==> Pouring lolcat\n")
            capture.finish(path: executable)
            return (0, "Installed")
        })
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store,
        runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime")),
        windowIsVisible: { true })
    let libraryURL = root.appendingPathComponent("library.json")
    let model = TerminalWallpaperViewModel(controller: InstallPreviewController(),
        catalogProvider: InstallPreviewDiscovery(), installer: installer, previewSelectionStore: store,
        resolveExecutable: { _ in capture.resolve() }, libraryStore: .init(url: libraryURL),
        packageProvider: provider, programSearchProvider: InstallPreviewSearch(preset: preset),
        previewReady: { config, id in try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 3) })
    model.setCatalogSearch("lolcat")
    let searchDeadline = Date().addingTimeInterval(3)
    while model.catalogItems.first?.id != preset.id && Date() < searchDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let item = try #require(model.catalogItems.first)
    #expect(item.id == preset.id)
    #expect(store.kind == .video) // Searching cannot install or run it.
    for _ in 0..<2 {
        model.use(item)
        let deadline = Date().addingTimeInterval(4)
        while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!model.isBusy && model.errorMessage == nil && !model.status.running)
        #expect(preview.snapshot?.hasVisibleContent == true)
        #expect(store.terminalConfiguration?.command.catalogItemID == preset.id)
        #expect(model.libraryPresets.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes", preset.id])
    }
    #expect(capture.output == ["install"])
    #expect(await recorder.count == 1)
    let reopened = TerminalAnimationLibraryStore(url: libraryURL)
    #expect(try await reopened.load() == [preset.id])
    #expect(try await reopened.loadPrograms() == [preset])
    store.selectVideo()
}
