import Darwin
import Foundation
import Testing
@testable import AuraTerminalWallpaperCore

@Test func wallpaperMotionDefaultsAreSharedAndNeverOverrideExplicitArguments() {
    for (name, expected) in [("cbonsai", ["-l", "-i"]), ("nyancat", ["-n", "-s"]),
                             ("vm_stat", ["2"]), ("iostat", ["-w", "2"])] {
        for id in [nil, "local:\(name)", "brew:\(name):\(name)"] as [String?] {
            let command = TerminalCommandConfiguration(catalogItemID: id, executable: name)
            #expect(TerminalWallpaperLaunchDefaults.arguments(for: command, executable: "/custom/bin/\(name)") == expected)
        }
        let explicit = TerminalCommandConfiguration(executable: name, arguments: ["--help"])
        #expect(TerminalWallpaperLaunchDefaults.arguments(for: explicit, executable: "/custom/bin/\(name)") == ["--help"])
    }
    for name in ["uname", "printf", "unknown-cli", "cat", "rm", "curl"] {
        #expect(TerminalWallpaperLaunchDefaults.arguments(for: .init(executable: name), executable: "/bin/\(name)") == [])
    }
}

private final class MotionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: VTParser
    private var exit: Int32?
    private var bytes = 0
    init(columns: Int = 80, rows: Int = 24) { parser = VTParser(columns: columns, rows: rows) }
    func feed(_ data: Data) { lock.lock(); defer { lock.unlock() }; parser.feed(data); bytes += data.count }
    func finish(_ code: Int32) { lock.lock(); defer { lock.unlock() }; exit = code }
    func read() -> (TerminalGridSnapshot, Int32?, Int) {
        lock.lock(); defer { lock.unlock() }; return (parser.grid.snapshot(), exit, bytes)
    }
    func resize(columns: Int, rows: Int) { lock.lock(); defer { lock.unlock() }; parser.resize(columns: columns, rows: rows) }
}

// No catalog ID: this also exercises launches from arbitrary installed-command
// search and custom commands, not only the six reviewed preset cards.
@Test(arguments: ["asciiquarium", "lavat", "cmatrix", "pipes.sh", "cbonsai", "nyancat", "htop", "lolcat", "cava"])
func installedVisualProgramsKeepChangingInOnePTYByDefault(name: String) async throws {
    guard let executable = TerminalExecutableLocator.resolve(name) else { return }
    let session = TerminalPTYSession()
    let capture = MotionCapture()
    let pid = try session.start(command: .init(executable: executable), columns: 80, rows: 24,
                                onData: { capture.feed($0) }, onExit: { capture.finish($0) })
    defer { session.stop() }
    let deadline = Date().addingTimeInterval(5)
    while !capture.read().0.hasVisibleContent && capture.read().1 == nil && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let (first, exit, _) = capture.read()
    try #require(exit == nil && first.hasVisibleContent, "\(name): launch failed, exit \(String(describing: exit))")
    let animationDeadline = Date().addingTimeInterval(3)
    while capture.read().0.cells == first.cells && Date() < animationDeadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(capture.read().0.cells != first.cells, "\(name) should keep moving")
    #expect(capture.read().1 == nil && session.childPID == pid)
}

@Test func lolcatMotionSupportsPauseResumeResizeAndOwnedProcessStop() async throws {
    guard let executable = TerminalExecutableLocator.resolve("lolcat") else { return }
    let session = TerminalPTYSession()
    let capture = MotionCapture()
    let pid = try session.start(command: .init(executable: executable), columns: 80, rows: 24,
                                onData: { capture.feed($0) }, onExit: { capture.finish($0) })
    defer { session.stop() }
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(capture.read().0.hasVisibleContent)
    try session.setPaused(true)
    try await Task.sleep(nanoseconds: 150_000_000)
    let frozen = capture.read()
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(capture.read().2 == frozen.2)
    capture.resize(columns: 100, rows: 30)
    try session.resize(columns: 100, rows: 30)
    try session.setPaused(false)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let snapshot = capture.read().0
        if (0..<100).contains(where: { snapshot.cell(column: $0, row: 29).text != " " }) { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(capture.read().2 > frozen.2)
    #expect((0..<100).contains { capture.read().0.cell(column: $0, row: 29).text != " " })
    #expect(session.childPID == pid && capture.read().1 == nil)
    session.stop()
    #expect(session.childPID == nil)
    let stopDeadline = Date().addingTimeInterval(2)
    while kill(pid, 0) == 0 && Date() < stopDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test func arbitraryStaticCLIIsNotRelaunchedAndArbitraryLiveCLIIsNotFrozen() async throws {
    // Deterministic stand-ins for unknown CLIs. A one-shot invocation is never
    // repeated, while changing output from an unregistered executable streams.
    for live in [false, true] {
        let capture = MotionCapture()
        let session = TerminalPTYSession()
        let script = live
            ? "i=0; while :; do printf '\\033[Hframe %s' \"$i\"; i=$((i+1)); sleep 0.05; done"
            : "printf 'one-shot output'"
        try session.start(command: .init(executable: "/bin/sh", arguments: ["-c", script]), columns: 80, rows: 24,
                          onData: { capture.feed($0) }, onExit: { capture.finish($0) })
        defer { session.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let first = capture.read()
        #expect(first.0.hasVisibleContent)
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = capture.read()
        if live {
            #expect(later.0.cells != first.0.cells && later.1 == nil)
        } else {
            #expect(later.0.cells == first.0.cells && later.1 == 0)
            #expect(later.2 == first.2 && session.childPID == nil)
        }
    }
}
