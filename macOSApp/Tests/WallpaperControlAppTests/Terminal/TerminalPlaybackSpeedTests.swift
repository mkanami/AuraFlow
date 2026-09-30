import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class NativeSpeedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bytes.count }
}

@Suite(.serialized)
struct TerminalPlaybackSpeedTests {
    private func config(_ executable: String, _ args: [String] = [], native: Double? = nil) -> TerminalWallpaperConfig {
        TerminalWallpaperConfig(command: TerminalCommandConfiguration(executable: executable, arguments: args), nativeSpeed: native)
    }

    private func compiledNativeProbe(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-native-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let binary = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-x", "c", Bundle.module.url(forResource: "TerminalNativeSpeedProbe", withExtension: "txt")!.path, "-o", binary.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]) { _, new in new }
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return binary
    }

    @Test @MainActor func previewDebouncesAfterReleaseAndRestartsOnlyForLaunchFlags() async throws {
        for name in ["lavat", "cmatrix"] {
            let binary = try compiledNativeProbe(name: name)
            let root = binary.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
            selection.selectTerminal(config(binary.path, native: 5))
            let model = TerminalWallpaperPreviewModel(selectionStore: selection,
                runtimeStore: TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime")),
                windowIsVisible: { true })
            func text() -> String { model.snapshot?.cells.prefix(40).map(\.text).joined() ?? "" }
            for _ in 0..<100 {
                if text().contains("SPEED:05") { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(text().contains("SPEED:05"))
            let oldGeneration = model.previewGeneration
            selection.setAdjustingTerminalSpeed(true)
            selection.setTerminalNativeSpeed(2)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(text().contains("SPEED:05"))
            #expect(model.previewGeneration == oldGeneration)
            let oldRevision = model.snapshot?.revision ?? 0
            selection.setAdjustingTerminalSpeed(false)
            // A second committed value inside debounce cancels the first.
            try await Task.sleep(nanoseconds: 100_000_000)
            selection.setTerminalNativeSpeed(3)
            selection.setAdjustingTerminalSpeed(false)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(text().contains("SPEED:05"))
            for _ in 0..<100 {
                if text().contains("SPEED:03") { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(text().contains("SPEED:03"))
            #expect((model.snapshot?.revision ?? 0) > oldRevision)
            #expect(model.previewGeneration == (name == "cmatrix" ? oldGeneration : oldGeneration + 2))
            selection.setTerminalNativeSpeed(9)
            selection.selectVideo()
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(model.configuration == nil)
            #expect(model.snapshot == nil)
        }
    }

    @Test func onlyVerifiedProgramsHaveSpeedControls() {
        for name in ["asciiquarium", "nyancat", "unknown", "/bin/sh", "/usr/bin/env"] {
            let original = config(name, ["-f", "30"], native: 100)
            #expect(TerminalNativeSpeed.profile(for: original.command) == nil)
            #expect(TerminalNativeSpeed.launchCommand(for: original) == original.command)
        }
        for (name, profile) in [("cmatrix", TerminalNativeSpeed.cmatrix), ("lavat", .lavat), ("pipes.sh", .pipes), ("neo", .neo)] {
            #expect(TerminalNativeSpeed.profile(for: config("/opt/homebrew/bin/\(name)").command) == profile)
        }
        var mismatched = config("cmatrix")
        mismatched.command.catalogItemID = "asciiquarium"
        #expect(TerminalNativeSpeed.profile(for: mismatched.command) == nil)
    }

    @Test func nativeFlagsPreserveOtherArgumentsAndReplaceAllSpeedFlags() {
        let cases: [(TerminalWallpaperConfig, [String])] = [
            (config("cmatrix", ["-bu4", "-C", "blue", "-u", "3"], native: 2), ["-u", "2", "-b", "-C", "blue"]),
            (config("lavat", ["-g", "-c", "FF0000", "-s3", "-r", "7", "-s", "4"], native: 8), ["-s", "8", "-g", "-c", "FF0000", "-r", "7"]),
            (config("pipes.sh", ["-p", "3", "-f20", "-t", "1", "-c", "2", "-f", "30"], native: 60), ["-f", "60", "-p", "3", "-t", "1", "-c", "2"]),
            (config("neo", ["--fps", "30", "--speed=8", "-S", "10", "-S12", "--color", "blue"], native: 16), ["-S", "16", "--fps", "30", "--color", "blue"]),
            (config("neo", ["--message", "-S", "-m", "--speed=5", "--", "-S99"], native: 4), ["-S", "4", "--message", "-S", "-m", "--speed=5", "--", "-S99"]),
            (config("lavat", ["-F", "-s", "--", "-s99"], native: 5), ["-s", "5", "-F", "-s", "--", "-s99"])
        ]
        for (original, expected) in cases {
            let launch = TerminalNativeSpeed.launchCommand(for: original)
            #expect(launch.arguments == expected)
            #expect(launch.executable == original.command.executable)
            #expect(launch.environment == original.command.environment)
            #expect(original.render.maxFPS == 30)
        }
    }

    @Test func cmatrixUsesDigitsExceptScreensaverModeAndDelayTen() {
        for delay in 0...9 {
            let selected = config("cmatrix", native: Double(delay))
            #expect(TerminalNativeSpeed.cmatrix.input(for: selected) == Data(String(delay).utf8))
        }
        #expect(TerminalNativeSpeed.cmatrix.input(for: config("cmatrix", ["-abs"], native: 3)) == nil)
        #expect(TerminalNativeSpeed.cmatrix.input(for: config("cmatrix", native: 10)) == nil)
        // A literal -s in a color argument must not disable interactive keys.
        #expect(TerminalNativeSpeed.cmatrix.input(for: config("cmatrix", ["-C", "-s"], native: 3)) == Data("3".utf8))
        for name in ["lavat", "pipes.sh", "neo"] {
            let selected = config(name, native: 5)
            #expect(TerminalNativeSpeed.profile(for: selected.command)?.input(for: selected) == nil)
        }
    }

    @Test func legacyRatesMigrateToNativeUnitsAndRespectCustomDefaults() throws {
        var original = config("cmatrix", ["-u", "6"])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "playback_speed")
        json.removeValue(forKey: "native_speed")
        let old = try JSONDecoder().decode(TerminalWallpaperConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.playbackSpeed == 1)
        #expect(TerminalNativeSpeed.cmatrix.value(for: old) == 6)
        original.playbackSpeed = 2
        #expect(TerminalNativeSpeed.cmatrix.value(for: original) == 3)
        original = config("pipes.sh", ["-f", "60"])
        original.playbackSpeed = 0.5
        #expect(TerminalNativeSpeed.pipes.value(for: original) == 30)
        original.nativeSpeed = 80
        #expect(TerminalNativeSpeed.pipes.value(for: original) == 80)
        #expect(try JSONDecoder().decode(TerminalWallpaperConfig.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func normalizationAndUnchangedQuantizedValuesDoNotRestart() {
        for (name, value, expected) in [("cmatrix", -4.0, 0.0), ("cmatrix", 99, 10), ("lavat", 0, 1), ("lavat", 99, 10), ("pipes.sh", 0, 20), ("pipes.sh", 900, 100)] {
            let selected = config(name, native: value).normalized()
            #expect(selected.nativeSpeed == expected)
            #expect(selected.render.maxFPS == 30)
        }
        #expect(config("lavat", native: .nan).normalized().nativeSpeed == nil)
        #expect(!TerminalNativeSpeed.changed(from: config("lavat", native: 4.1), to: config("lavat", native: 4.2)))
        #expect(TerminalNativeSpeed.changed(from: config("lavat", native: 4), to: config("lavat", native: 5)))
        #expect(!TerminalNativeSpeed.changed(from: config("asciiquarium"), to: config("asciiquarium", native: 5)))
        #expect(TerminalNativeSpeed.neo.sliderRange(for: config("neo", ["-S", "100"], native: 20))
            == TerminalNativeSpeed.neo.sliderRange(for: config("neo", ["-S", "100"], native: 300)))
    }

    @Test func restartedParserCanContinueRevisionWithoutRetainingOldCells() {
        var parser = VTParser(columns: 20, rows: 2, initialRevision: 500_000)
        parser.feed(Data("NEW FRAME".utf8))
        let snapshot = parser.grid.snapshot()
        #expect(snapshot.revision > 500_000)
        #expect(snapshot.cell(column: 0, row: 0).text == "N")
        #expect(snapshot.cell(column: 0, row: 1).text == " ")
    }

    @Test func writesNativeInputWithoutReplacingChildOrInjectingClock() throws {
        let output = NativeSpeedOutput()
        let session = TerminalPTYSession(environment: [:])
        defer { session.stop() }
        let script = "stty raw -echo; if test -z \"${DYLD_INSERT_LIBRARIES-}${AURAFLOW_TERMINAL_CLOCK_CONTROL-}${AURAFLOW_TERMINAL_CLOCK_BIN-}\"; then printf clean; fi; printf ready; dd bs=1 count=1 2>/dev/null; printf done; sleep 2"
        let pid = try session.start(command: TerminalCommandConfiguration(executable: "/bin/sh", arguments: ["-c", script]),
                                    columns: 80, rows: 24, onData: { output.append($0) }, onExit: { _ in })
        let deadline = Date().addingTimeInterval(3)
        while !output.text.contains("ready"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(output.text.contains("cleanready"))
        try session.writeInput(Data("2".utf8))
        while !output.text.contains("done"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(output.text.contains("2done"))
        #expect(session.childPID == pid)
        #expect(throws: TerminalPTYError.notRunning) { try TerminalPTYSession().writeInput(Data("2".utf8)) }
    }

    @Test func staleOrUnsupportedSpeedCannotModifyActiveWallpaper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-native-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root)
        var active = config("cmatrix")
        active.render.fontSize = 22
        try store.saveConfig(active)
        try store.savePID()
        let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"))
        _ = try controller.updateNativeSpeed(2, matching: config("lavat").command)
        #expect(store.loadConfig() == active)
        #expect(store.loadCommand() == nil)
        _ = try controller.updateNativeSpeed(2, matching: active.command)
        active.nativeSpeed = 2
        #expect(store.loadConfig() == active)
        #expect(store.loadCommand()?.action == .update)
        store.removeCommand()
        _ = try controller.updateNativeSpeed(2, matching: active.command)
        #expect(store.loadCommand() == nil)
        active = config("asciiquarium")
        try store.saveConfig(active)
        _ = try controller.updateNativeSpeed(2, matching: active.command)
        #expect(store.loadConfig() == active)
        #expect(store.loadCommand() == nil)
    }

    @Test @MainActor func sliderUsesNativeUnitsCommitsOnReleaseAndLeavesVideoAlone() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-native-slider-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        store.selectTerminal(config("cmatrix"))
        let model = AppViewModel(appSupportDirectoryURL: root, previewSelectionStore: store)
        #expect(model.showsPreviewSpeedControl)
        #expect(model.previewSpeedLabel == "40 ms")
        #expect(model.previewSpeedControlValue == 6)
        #expect(model.previewSpeedRange == 0...10)
        model.setSpeedEditing(true)
        model.setPreviewPlaybackSpeed(8)
        #expect(store.isAdjustingTerminalSpeed)
        #expect(store.terminalConfiguration?.nativeSpeed == 2)
        #expect(model.previewSpeedControlValue == 8)
        #expect(model.playbackSpeed == 1) // Native units never enter AVPlayer's rate.
        #expect(WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json")).terminalConfiguration?.nativeSpeed == nil)
        model.updateSpeed(8)
        #expect(!store.isAdjustingTerminalSpeed)
        #expect(WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json")).terminalConfiguration?.nativeSpeed == 2)
        for name in ["asciiquarium", "nyancat", "unknown"] {
            store.selectTerminal(config(name))
            #expect(!model.showsPreviewSpeedControl)
            model.updateSpeed(9)
            #expect(store.terminalConfiguration?.nativeSpeed == nil)
        }
        store.selectVideo()
        #expect(model.showsPreviewSpeedControl)
        #expect(model.playbackSpeed == 1)
        #expect(model.previewSpeedRange == 0.25...2)
        #expect(model.previewSpeedLabel == "1.00x")
    }

    @Test func installedNativeAnimationsAcceptFlagsAndCmatrixAcceptsLiveKey() throws {
        let paths = ["/opt/homebrew/bin/cmatrix", "/opt/homebrew/bin/lavat", "/opt/homebrew/bin/pipes.sh",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/neo").path]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let selected = config(path)
            let session = TerminalPTYSession()
            let output = NativeSpeedOutput()
            defer { session.stop() }
            let pid = try session.start(command: TerminalNativeSpeed.launchCommand(for: selected), columns: 100, rows: 32,
                                        onData: { output.append($0) }, onExit: { _ in })
            Thread.sleep(forTimeInterval: 0.35)
            #expect(output.count > 0)
            #expect(session.childPID == pid)
            if TerminalNativeSpeed.profile(for: selected.command) == .cmatrix {
                try session.writeInput(Data("1".utf8))
                let before = output.count
                Thread.sleep(forTimeInterval: 0.2)
                #expect(output.count > before)
                #expect(session.childPID == pid)
            }
        }
    }
}
