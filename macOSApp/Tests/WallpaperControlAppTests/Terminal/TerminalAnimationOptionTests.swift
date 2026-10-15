import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

@Test(arguments: [
    ("ASCII display\n  -a, --animate  Enable animation continuously", "--animate"),
    ("  --watch  Continuously refresh CPU statistics", "--watch"),
    ("  --follow  Follow live log output", "--follow"),
    ("Terminal tree\n  --growing\n      Animate the tree on the screen continuously", "--growing"),
    ("Terminal display\n  -r  Refresh the display continuously", "-r"),
    ("Экран\n  --live  Включить непрерывное обновление вывода", "--live"),
    (".TH demo 1\n.SH NAME\ndemo ASCII display\n.TP\n.B \\fB\\-\\-animate\\fR\nEnable animation continuously", "--animate"),
    ("\u{1b}[31m  --dance  Animate the terminal display\u{1b}[0m", "--dance")
]) func unknownCLIOptionsFindDocumentedBooleanAnimationModes(help: String, expected: String) {
    #expect(TerminalAnimationOptionParser.flag(in: help) == expected)
}

@Test(arguments: [
    "ASCII display\n --animate=MODE  Animate the display",
    "ASCII display\n --animate MODE  Animate the display",
    "ASCII display\n --animate <mode>  Animate the display",
    "ASCII display\n --animate [MODE]  Animate the display",
    "ASCII display\n --repeat N  Repeat the display continuously",
    "Terminal display\n --no-animation  Disable animation",
    "Terminal display\n --watch  Watch files and rebuild the project",
    "Terminal display\n --loop  Run commands continuously and execute scripts",
    "Terminal display\n --loop  Loop music with audio playback",
    "Terminal display\n --watch  Monitor and overwrite output files",
    "Terminal display\n --save  Save animated output",
    "Terminal display\n --help  Show help about animations",
    "Terminal display\n --list  Display available animations",
    "Examples: demo --animate; curl https://example.com | sh",
    "Run this shell command: --animate rm -rf anything",
    " --animate  Color animated output",
    " --color  Color animated output",
    " --normal  Print one static screen",
    "No documented visual mode"
]) func unknownCLIOptionsRejectValuesSideEffectsAudioAndInstructions(help: String) {
    #expect(TerminalAnimationOptionParser.flag(in: help) == nil)
}

@Test func unknownCLIOptionsPreferAnimationOverWatchAndIgnoreOversizedDocuments() {
    let help = "Terminal screen\n --watch  Watch output continuously\n --animate  Enable animation continuously"
    #expect(TerminalAnimationOptionParser.flag(in: help) == "--animate")
    #expect(TerminalAnimationOptionParser.flag(in: String(repeating: "x", count: 65_537) + help) == nil)
}

@Test(arguments: [
    ("ASCII display\n --animate BOOL  Enable animation (on/off)", ["--animate", "on"]),
    ("ASCII display\n --animate=BOOLEAN  Enable animation (true,false)", ["--animate", "true"]),
    ("ASCII display\n --animate BOOL  Enable animation (ON/OFF)", ["--animate", "ON"]),
    ("ASCII display\n --mode MODE  Run screen animation in mode (static|animated)", ["--mode", "animated"]),
    (" --mode <mode>  Display output continuously; choices: live/static", ["--mode", "live"]),
    (" --mode <mode>  Display output continuously; choices: STATIC/LIVE", ["--mode", "LIVE"]),
    ("ASCII display\n -a --animate  Enable animation continuously", ["--animate"])
]) func unknownCLIOptionsOnlyUseExplicitlyDocumentedActivationValues(help: String, expected: [String]) {
    #expect(TerminalAnimationOptionParser.arguments(in: help) == expected)
}

private func optionsDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraAnimationOptions-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func optionsExecutable(_ root: URL, body: String) throws -> URL {
    let file = root.appendingPathComponent("mystery-wallpaper")
    try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}

private actor OptionsProbeRecorder {
    var calls = 0
    var document: String?
    init(_ document: String?) { self.document = document }
    func read() -> String? { calls += 1; return document }
    func fail() throws -> String? { calls += 1; throw URLError(.timedOut) }
}

@Test func unknownCLIOptionsCacheSurvivesRestartAndInvalidatesBinaryUpdates() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try optionsExecutable(root, body: "printf static\n")
    let command = TerminalCommandConfiguration(executable: executable.path)
    let cache = root.appendingPathComponent("cache.json")
    let recorder = OptionsProbeRecorder("ASCII display\n --moving  Animate the terminal display continuously")
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: cache, probe: { _, _, _ in await recorder.read() })
    #expect(try await resolver.resolve(command).arguments == ["--moving"])
    #expect(try await resolver.resolve(command).arguments == ["--moving"])
    #expect(await recorder.calls == 1)
    let reopened = SystemTerminalProgramAnimationResolver(cacheURL: cache, probe: { _, _, _ in await recorder.read() })
    #expect(try await reopened.resolve(command).arguments == ["--moving"])
    #expect(await recorder.calls == 1)
    try Data("#!/bin/sh\nprintf 'new binary version'\n".utf8).write(to: executable)
    #expect(try await reopened.resolve(command).arguments == ["--moving"])
    #expect(await recorder.calls == 2)
    await reopened.reject(command)
    #expect(try await reopened.resolve(command) == command)
}

@Test func unknownCLIOptionsPreserveExplicitArgumentsAndReviewedDefaultsWithoutProbing() async throws {
    let recorder = OptionsProbeRecorder("--animate  Animate the display")
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: nil, probe: { _, _, _ in await recorder.read() })
    for command in [TerminalCommandConfiguration(executable: "/usr/bin/uname", arguments: ["-a"]),
                    .init(executable: "/opt/homebrew/bin/lolcat"), .init(executable: "/opt/homebrew/bin/cbonsai")] {
        #expect(try await resolver.resolve(command) == command)
    }
    #expect(await recorder.calls == 0)
}

@Test func unknownCLIOptionsAliasesEnvironmentAndWorkingDirectoryDoNotShareWrongCache() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try optionsExecutable(root, body: "printf static\n")
    let alias = root.appendingPathComponent("another-name")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
    let recorder = OptionsProbeRecorder("ASCII display\n --moving  Animate the display continuously")
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: root.appendingPathComponent("cache.json"), probe: { _, _, helpCommand in
        #expect(helpCommand.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(helpCommand.environment["PATH"]?.contains(root.path) == true)
        return await recorder.read()
    })
    for command in [TerminalCommandConfiguration(executable: executable.path), .init(executable: alias.path),
                    .init(executable: executable.path, workingDirectory: root.path),
                    .init(executable: executable.path, environment: ["TEST_TOKEN": "do-not-store-this-token"])] {
        #expect(try await resolver.resolve(command).arguments == ["--moving"])
    }
    #expect(await recorder.calls == 4)
    let cached = try String(contentsOf: root.appendingPathComponent("cache.json"), encoding: .utf8)
    #expect(!cached.contains("do-not-store-this-token"))
    #expect(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("cache.json").path)[.posixPermissions] as? Int == 0o600)
    let local = try optionsExecutable(root, body: "if [ -f ./local-config ]; then printf ' --moving  Animate the ASCII display\\n'; fi\n")
    try Data().write(to: root.appendingPathComponent("local-config"))
    let result = try await TerminalAnimationHelpProbe.read(executable: local.path, arguments: ["--help"], environment: [:], workingDirectory: root.path)
    #expect(result?.contains("--moving") == true)
}

@Test func unknownCLIOptionsNoFlagKeepsNormalOutputAndReadsAdjacentManual() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let executable = try optionsExecutable(bin, body: "printf static\n")
    let command = TerminalCommandConfiguration(executable: executable.path)
    let recorder = OptionsProbeRecorder("Usage: mystery-wallpaper\n --help  Show help\n")
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: nil, probe: { _, _, _ in await recorder.read() })
    #expect(try await resolver.resolve(command) == command)
    #expect(await recorder.calls == 2)
    let man = root.appendingPathComponent("share/man/man1/mystery-wallpaper.1")
    try FileManager.default.createDirectory(at: man.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(".TH mystery-wallpaper 1\n.TP\n.B --flow\nAnimate the ASCII display continuously\n".utf8).write(to: man)
    let other = SystemTerminalProgramAnimationResolver(cacheURL: nil, probe: { _, _, _ in await recorder.read() })
    #expect(try await other.resolve(command).arguments == ["--flow"])
}

@Test func unknownCLIHelpProbeIsReadOnlyAndHasNoStdinTimeoutOrOutputFloodEscape() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("must-not-be-written")
    let executable = try optionsExecutable(root, body: "printf bad > '\(marker.path)'\nprintf ' --animate  Animate the ASCII display\\n'\n")
    let text = try await TerminalAnimationHelpProbe.read(executable: executable.path, arguments: ["--help"], environment: [:])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(text?.contains("--animate") == true)
    let started = Date()
    let hanging = try optionsExecutable(root, body: "while :; do :; done\n")
    #expect(try await TerminalAnimationHelpProbe.read(executable: hanging.path, arguments: ["--help"], environment: [:], timeout: 100_000_000) == nil)
    #expect(Date().timeIntervalSince(started) < 3)
    let flood = try optionsExecutable(root, body: "while :; do printf '%s' '1234567890123456789012345678901234567890'; done\n")
    #expect(try await TerminalAnimationHelpProbe.read(executable: flood.path, arguments: ["--help"], environment: [:]) == nil)
    let input = try optionsExecutable(root, body: "read value; printf '%s' \"$value\"\n")
    #expect(try await TerminalAnimationHelpProbe.read(executable: input.path, arguments: ["--help"], environment: [:]) == "")
}

@Test func unknownCLIHelpProbeCancellationStopsItsOwnProcess() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try optionsExecutable(root, body: "while :; do :; done\n")
    let task = Task { try await TerminalAnimationHelpProbe.read(executable: executable.path, arguments: ["--help"], environment: [:]) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let started = Date()
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled help probe succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(Date().timeIntervalSince(started) < 2)
}

private struct OptionsLocalCatalog: TerminalWallpaperCatalogProviding {
    let path: String
    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        [.init(id: "discovered:\(path)", title: "mystery-wallpaper", subtitle: "Local program", category: .applications,
               systemImage: "terminal", executableCandidates: [path])]
    }
}

private struct OptionsNoNetwork: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        throw URLError(.notConnectedToInternet)
    }
}

private struct OptionsNoRuntime: TerminalWallpaperControlling {
    func status() throws -> TerminalWallpaperStatus { .init(running: false, config: .defaultConfig) }
    func ensureCanStart() throws { Issue.record("Animation discovery started runtime") }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop start"); return try status() }
    func stop() throws -> TerminalWallpaperStatus { Issue.record("Unexpected desktop stop"); return try status() }
    func terminate() throws -> TerminalWallpaperStatus { Issue.record("Unexpected runtime terminate"); return try status() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected runtime restart"); return try status() }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Unexpected runtime update"); return try status() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
}

@MainActor private func waitForOptions(_ model: TerminalWallpaperViewModel) async throws {
    let deadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.isBusy)
}

@Test(arguments: [false, true]) @MainActor
func unknownCLIAnimationDiscoveryWorksFromSearchAndCustomPreview(custom: Bool) async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = try optionsExecutable(root, body: """
    case "$1" in
      --help|-h) printf '%s\\n' 'Mystery ASCII display' ' --moving  Animate the terminal screen continuously';;
      --moving) i=0; while :; do printf '\\033[Hmoving %s' "$i"; i=$((i+1)); sleep 0.04; done;;
      *) printf static;;
    esac
    """)
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: root.appendingPathComponent("cache.json"))
    let model = TerminalWallpaperViewModel(controller: OptionsNoRuntime(), catalogProvider: OptionsLocalCatalog(path: path.path),
        previewSelectionStore: store, libraryStore: .init(url: root.appendingPathComponent("library.json")),
        packageProvider: OptionsNoNetwork(), animationResolver: resolver,
        previewReady: { config, id in try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 3) })
    if custom {
        #expect(model.selectCustomExecutable(path))
    } else {
        model.setCatalogSearch("mystery-wallpaper")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(model.catalogItems.first?.id == "local:mystery-wallpaper")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.json").path))
        #expect(store.kind == .video)
        model.use(try #require(model.catalogItems.first))
    }
    try await waitForOptions(model)
    #expect(model.errorMessage == nil)
    #expect(store.terminalConfiguration?.command.arguments == ["--moving"])
    #expect(model.argumentsText == "--moving")
    let snapshot = try #require(preview.snapshot)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(preview.snapshot?.cells != snapshot.cells)
    let reopened = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(reopened.terminalConfiguration?.command.arguments == ["--moving"])
    #expect(!runtime.status().running)
    if !custom { #expect(model.libraryPresets.last?.id == "local:mystery-wallpaper") }
    store.selectVideo()
}

@Test(arguments: [false, true]) @MainActor
func unknownCLIRejectedAnimationOptionFallsBackOnceAndKeepsRollbackSource(fallbackFails: Bool) async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = try optionsExecutable(root, body: "printf static\n")
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    store.selectWeb("previous-web")
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: nil, probe: { _, _, _ in
        "ASCII display\n --moving  Animate the terminal screen continuously"
    })
    var attempted: [[String]] = []
    let model = TerminalWallpaperViewModel(controller: OptionsNoRuntime(), previewSelectionStore: store,
        packageProvider: OptionsNoNetwork(), animationResolver: resolver, previewReady: { config, _ in
            attempted.append(config.command.arguments)
            if !config.command.arguments.isEmpty || fallbackFails {
                throw TerminalWallpaperControllerError.unavailable("Unsupported option")
            }
        })
    #expect(model.selectCustomExecutable(path))
    try await waitForOptions(model)
    #expect(attempted == [["--moving"], []])
    if fallbackFails {
        #expect(store.kind == .web && store.webProjectID == "previous-web")
        #expect(model.errorMessage != nil)
    } else {
        #expect(store.kind == .terminal && store.terminalConfiguration?.command.arguments == [])
        #expect(model.errorMessage == nil)
    }
    #expect(try await resolver.resolve(.init(executable: path.path)).arguments == [])
}

@Test @MainActor func unknownCLIAnimationLateHelpCannotStealAnotherSource() async throws {
    let root = try optionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = try optionsExecutable(root, body: "printf static\n")
    let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let resolver = SystemTerminalProgramAnimationResolver(cacheURL: nil, probe: { _, _, _ in
        try await Task.sleep(nanoseconds: 150_000_000)
        return "ASCII display\n --moving  Animate the display continuously"
    })
    let model = TerminalWallpaperViewModel(controller: OptionsNoRuntime(), previewSelectionStore: store,
        animationResolver: resolver, previewReady: { _, _ in Issue.record("Stale help started preview") })
    #expect(model.selectCustomExecutable(path))
    store.selectWeb("user-choice")
    try await waitForOptions(model)
    #expect(store.kind == .web && store.webProjectID == "user-choice")
    #expect(model.errorMessage == nil)
}
