import Darwin
import Foundation
import Testing
@testable import AuraTerminalWallpaperCore
@testable import WallpaperControlApp

private final class SilentOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var code: Int32?
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func finish(_ value: Int32) { lock.lock(); defer { lock.unlock() }; code = value }
    func read() -> (Data, Int32?) { lock.lock(); defer { lock.unlock() }; return (bytes, code) }
}

@Test func visualOnlyLaunchUsesFixedPolicyAndPreservesEveryArgument() throws {
    let args = ["a b", "$(afplay file)", "-p", "(allow default)", "", "кириллица"]
    let launch = try TerminalVisualOnlyLaunch(executable: "/some path/program", arguments: args)
    #expect(launch.executable == "/usr/bin/sandbox-exec")
    #expect(launch.arguments == [launch.executable, "-p", TerminalVisualOnlyLaunch.profile, "/some path/program"] + args)
    #expect(TerminalVisualOnlyLaunch.profile.contains("device-microphone"))
    #expect(TerminalVisualOnlyLaunch.profile.contains("iokit-open"))
    #expect(TerminalVisualOnlyLaunch.profile.contains("appleevent-send"))
    #expect(throws: TerminalPTYError.audioIsolationUnavailable) {
        try TerminalVisualOnlyLaunch(executable: "/bin/sh", arguments: [], isExecutable: { _ in false })
    }
}

private func silentProbe() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-silent-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let binary = root.appendingPathComponent("probe")
    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        let source = try #require(Bundle.module.url(forResource: "TerminalSilentProbe", withExtension: "txt"))
        process.arguments = ["-x", "c", source.path, "-o", binary.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]) { _, new in new }
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return binary
    } catch { try? FileManager.default.removeItem(at: root); throw error }
}

private func silentPTYOutput(command: TerminalCommandConfiguration) async throws -> Data {
    let session = TerminalPTYSession()
    let output = SilentOutput()
    try session.start(command: command, columns: 80, rows: 24,
                      onData: { output.append($0) }, onExit: { output.finish($0) })
    defer { session.stop() }
    for _ in 0..<300 {
        let (bytes, code) = output.read()
        if let code { try #require(code == 0, "\(String(decoding: bytes, as: UTF8.self))"); return bytes }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw TerminalPTYError.spawnFailed("Silent probe timed out")
}

@Test func visualOnlyPTYBlocksAudioAndMicrophoneIncludingShellDescendantsButKeepsVisuals() async throws {
    let binary = try silentProbe()
    defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
    // Baseline runs only policy/IPC queries, never playback or recording.
    let baseline = Process(), pipe = Pipe()
    baseline.executableURL = binary; baseline.standardOutput = pipe
    try baseline.run(); baseline.waitUntilExit()
    let outside = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(baseline.terminationStatus == 0 && outside.contains("MIC:0"))
    try #require(outside.contains("AUDIO:0"), "The baseline audio service is unavailable; cannot validate IPC denial")

    for command in [
        TerminalCommandConfiguration(executable: binary.path, arguments: ["silent"]),
        TerminalCommandConfiguration(executable: "/bin/sh", arguments: ["-c", "\"$1\" silent", "probe", binary.path]),
        TerminalCommandConfiguration(executable: "/usr/bin/env", arguments: [binary.path, "silent"])
    ] {
        let bytes = try await silentPTYOutput(command: command)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("MIC:0") && !text.contains("EVENTS:0") && !text.contains("AUDIO:0"))
        var parser = VTParser(columns: 80, rows: 24)
        parser.feed(bytes)
        let visual = parser.grid.snapshot().cells.map(\.text).joined()
        #expect(visual.contains("VISUAL: retained"))
        #expect(parser.grid.snapshot().cells.contains { $0.style.foreground == .indexed(6) })
    }
}

@Test func visualOnlyPTYDoesNotInterpretArgumentsOrBeepForTerminalBells() async throws {
    let bytes = try await silentPTYOutput(command: .init(executable: "/usr/bin/printf",
        arguments: ["\\a%s", "$(not executed) • статичный вывод"]))
    var parser = VTParser(columns: 80, rows: 24)
    parser.feed(bytes)
    #expect(parser.grid.snapshot().cells.map(\.text).joined().contains("$(not executed) • статичный вывод"))
    #expect(!parser.grid.snapshot().cells.contains { $0.text.contains("\u{7}") })
}

@Test(arguments: ["asciiquarium", "lavat", "cmatrix", "pipes", "cbonsai", "nyancat"])
func visualOnlyInstalledAnimationsStillRenderInRealPTY(id: String) async throws {
    let item = try #require(TerminalWallpaperCatalog.item(id: id))
    guard item.resolvedExecutable() != nil else { return } // Never install software in a test.
    let session = TerminalPTYSession(), output = SilentOutput()
    let pid = try session.start(command: item.commandConfiguration(), columns: 100, rows: 30,
        onData: { output.append($0) }, onExit: { output.finish($0) })
    defer { session.stop() }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let (first, exit) = output.read()
    try #require(exit == nil && session.childPID == pid, "\(id): \(String(decoding: first.prefix(1200), as: UTF8.self))")
    var parser = VTParser(columns: 100, rows: 30)
    parser.feed(first)
    // Nyan Cat draws colored spaces rather than printable glyphs.
    #expect(parser.grid.snapshot().cells.contains {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ($0.style.background != .default && $0.style.background != .indexed(0)
                && $0.style.background != .rgb(0, 0, 0))
    })
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(output.read().0.count > first.count)
}
