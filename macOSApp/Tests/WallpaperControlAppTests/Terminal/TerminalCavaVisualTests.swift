import Darwin
import Foundation
import Testing
@testable import AuraTerminalWallpaperCore
@testable import WallpaperControlApp

private func cavaTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-cava-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func cavaVisualSignalIsBoundedStereoAndChangesOverTimeWithoutDevices() {
    var first = TerminalCavaVisualSignal(), second = TerminalCavaVisualSignal()
    let bytes = first.nextChunk()
    #expect(bytes == second.nextChunk())
    #expect(bytes.count == 2048)
    let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(samples.contains { $0 != 0 })
    for index in stride(from: 0, to: samples.count, by: 2) { #expect(samples[index] == samples[index + 1]) }
    var later = Data()
    for _ in 0..<150 { later = first.nextChunk() }
    #expect(later.count == bytes.count && later != bytes)
}

@Test func cavaVisualConfigurationUsesOnlyPrivateFIFOAndNeverUserAudioConfiguration() throws {
    let root = try cavaTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let one = try TerminalCavaVisualInput(temporaryDirectory: root)
    let two = try TerminalCavaVisualInput(temporaryDirectory: root)
    defer { one.stop(); two.stop() }
    #expect(one.directory != two.directory)
    let text = try String(contentsOf: one.configurationURL, encoding: .utf8)
    #expect(text.contains("method = fifo") && text.contains("sample_rate = 44100"))
    #expect(text.contains("method = noncurses") && text.contains("higher_cutoff_freq = 10000"))
    #expect(text.contains(one.fifoURL.path))
    for forbidden in ["portaudio", "coreaudio", "auto_input", "source = auto", "source = tap", "/.config/cava"] {
        #expect(!text.contains(forbidden))
    }
    #expect(try FileManager.default.attributesOfItem(atPath: one.directory.path)[.posixPermissions] as? Int == 0o700)
    var fifoAttributes = stat()
    #expect(lstat(one.fifoURL.path, &fifoAttributes) == 0)
    #expect(fifoAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    one.start(); two.start()
    one.stop(); one.stop()
    #expect(!FileManager.default.fileExists(atPath: one.directory.path))
    #expect(FileManager.default.fileExists(atPath: two.configurationURL.path))
}

@Test func cavaVisualProfileDoesNotOverrideOtherProgramsOrExplicitCustomArguments() {
    #expect(TerminalCavaVisualInput.applies(to: .init(catalogItemID: "local:cava", executable: "cava"), executable: "/opt/homebrew/bin/cava"))
    #expect(TerminalCavaVisualInput.applies(to: .init(catalogItemID: "brew:cava:cava", executable: "cava"), executable: "/opt/homebrew/bin/cava"))
    #expect(!TerminalCavaVisualInput.applies(to: .init(executable: "cava", arguments: ["-v"]), executable: "/opt/homebrew/bin/cava"))
    #expect(!TerminalCavaVisualInput.applies(to: .init(executable: "cmatrix"), executable: "/opt/homebrew/bin/cmatrix"))
    #expect(TerminalProgramDefinition(id: "local:cava", name: "cava", formula: "", executable: nil).preset.description.contains("No audio"))
}

private final class CavaOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var code: Int32?
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func finish(_ value: Int32) { lock.lock(); defer { lock.unlock() }; code = value }
    func read() -> (Data, Int32?) { lock.lock(); defer { lock.unlock() }; return (bytes, code) }
}

@Test(arguments: [(80, 24), (153, 48)]) @MainActor
func cavaInstalledRealPTYAnimatesWithoutAudioAndSupportsPauseResizeAndStop(columns: Int, rows: Int) async throws {
    guard let executable = TerminalExecutableLocator.resolve("cava") else { return }
    let session = TerminalPTYSession(environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "HOME": NSHomeDirectory()])
    let output = CavaOutputCapture()
    let pid = try session.start(command: .init(catalogItemID: "local:cava", executable: executable),
        columns: columns, rows: rows, onData: { output.append($0) }, onExit: { output.finish($0) })
    defer { session.stop() }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let (first, exit) = output.read()
    try #require(exit == nil && session.childPID == pid, "CAVA exited: \(String(decoding: first.prefix(2000), as: UTF8.self))")
    var parser = VTParser(columns: columns, rows: rows)
    parser.feed(first)
    let before = parser.grid.snapshot()
    #expect(before.cells.contains { $0.text.unicodeScalars.contains { (0x2580...0x259F).contains($0.value) } })
    #expect(before.cells.contains { $0.style.foreground != .default })
    try await Task.sleep(nanoseconds: 900_000_000)
    let subsequent = output.read().0.dropFirst(first.count)
    parser.feed(Data(subsequent))
    let animated = parser.grid.snapshot().cells != before.cells
    #expect(animated)
    try session.setPaused(true)
    #expect(session.isPaused)
    try await Task.sleep(nanoseconds: 200_000_000)
    let pausedBytes = output.read().0.count
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(output.read().0.count == pausedBytes)
    try session.resize(columns: 100, rows: 30)
    try session.setPaused(false)
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(output.read().0.count > pausedBytes)
    session.stop()
    #expect(session.childPID == nil)
    // stop bounds foreground work and may reap a slow CLI on its worker.
    let stopDeadline = Date().addingTimeInterval(2)
    while kill(pid, 0) == 0, Date() < stopDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test @MainActor
func cavaPreviewIsReadyAndContinuesWithoutAnyRuntimeOrAudioStart() async throws {
    guard let executable = TerminalExecutableLocator.resolve("cava") else { return }
    let directory = try cavaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = .init(catalogItemID: "brew:cava:cava", executable: executable)
    let operation = UUID()
    store.beginTemporaryTerminal(config, operationID: operation)
    try await preview.waitUntilReady(configuration: config, operationID: operation, timeout: 3)
    let snapshot = try #require(preview.snapshot)
    try store.commitTemporaryTerminal(operationID: operation)
    try await Task.sleep(nanoseconds: 600_000_000)
    let animated = preview.snapshot?.cells != snapshot.cells
    #expect(animated)
    #expect(!runtime.status().running)
    #expect(store.terminalConfiguration?.command.arguments == [])
    store.selectVideo()
}

@Test @MainActor
func terminalFailedLaunchShowsProgramReasonWithoutANSIEscapes() async throws {
    let directory = try cavaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store,
        runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime")), windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = .init(executable: "/bin/sh", arguments: ["-c", "printf '\\033[31mInvalid configuration\\033[0m'; exit 1"])
    let operation = UUID()
    store.beginTemporaryTerminal(config, operationID: operation)
    do {
        try await preview.waitUntilReady(configuration: config, operationID: operation, timeout: 2)
        Issue.record("A failed program was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Invalid configuration"))
        #expect(!error.localizedDescription.contains("\u{1b}"))
    }
    store.rollbackTemporaryTerminal(operationID: operation)
    #expect(store.kind == .video)
}
