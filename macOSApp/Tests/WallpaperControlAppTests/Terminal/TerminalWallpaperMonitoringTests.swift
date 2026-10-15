import AuraTerminalWallpaperCore
import Darwin
import Foundation
import Testing
@testable import WallpaperControlApp

@Test func terminalMonitoringIncludesBusyChildAndExcludesUnrelatedProcesses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraMonitoring-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let childFile = root.appendingPathComponent("child.pid")
    let descendantFile = root.appendingPathComponent("descendant.pid")
    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/bin/bash")
    agent.arguments = ["-c", #"/bin/bash -c '/bin/bash -c "while :; do :; done" & printf "%s" "$!" > "$1"; wait' monitoring-child "$2" & child=$!; printf '%s' "$child" > "$1"; wait"#, "monitoring-test", childFile.path, descendantFile.path]
    agent.standardOutput = FileHandle.nullDevice
    agent.standardError = FileHandle.nullDevice
    try agent.run()
    var child: pid_t?
    var descendant: pid_t?
    defer {
        if let descendant { kill(descendant, SIGCONT); kill(descendant, SIGKILL) }
        if let child { kill(child, SIGCONT); kill(child, SIGKILL) }
        if agent.isRunning { kill(agent.processIdentifier, SIGKILL) }
        agent.waitUntilExit()
    }
    for _ in 0..<100 where child == nil || descendant == nil {
        child = (try? String(contentsOf: childFile)).flatMap(Int32.init)
        descendant = (try? String(contentsOf: descendantFile)).flatMap(Int32.init)
        if child == nil || descendant == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    let childPID = try #require(child)
    let descendantPID = try #require(descendant)

    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    unrelated.arguments = ["-f", "/dev/null"]
    unrelated.standardOutput = FileHandle.nullDevice
    unrelated.standardError = FileHandle.nullDevice
    try unrelated.run()
    defer { kill(unrelated.processIdentifier, SIGKILL); unrelated.waitUntilExit() }

    let sampler = WallpaperProcessResourceSampler()
    let first = try #require(sampler.sample(rootPID: Int(agent.processIdentifier), expectedExecutableName: "bash"))
    #expect(first.pids == [Int(agent.processIdentifier), Int(childPID), Int(descendantPID)].sorted())
    #expect(!first.pids.contains(Int(unrelated.processIdentifier)))
    #expect(first.memoryMB > 0 && first.virtualMemoryMB >= first.memoryMB)
    #expect(first.threadCount >= 3)
    try await Task.sleep(nanoseconds: 250_000_000)
    let busy = try #require(sampler.sample(rootPID: Int(agent.processIdentifier), expectedExecutableName: "bash"))
    #expect(busy.cpuPercent > 10)
    #expect(kill(descendantPID, SIGSTOP) == 0)
    try await Task.sleep(nanoseconds: 100_000_000)
    _ = sampler.sample(rootPID: Int(agent.processIdentifier), expectedExecutableName: "bash")
    try await Task.sleep(nanoseconds: 250_000_000)
    let paused = try #require(sampler.sample(rootPID: Int(agent.processIdentifier), expectedExecutableName: "bash"))
    #expect(paused.cpuPercent < busy.cpuPercent)
    #expect(sampler.sample(rootPID: Int(agent.processIdentifier), expectedExecutableName: "AuraTerminalWallpaperAgent") == nil)
}

@Test func terminalMonitoringUsesFreshHealthAndKeepsStaticWallpaperAgentResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraMonitoringStatic-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root)
    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    agent.arguments = ["-f", "/dev/null"]
    agent.standardOutput = FileHandle.nullDevice
    agent.standardError = FileHandle.nullDevice
    try agent.run()
    defer { if agent.isRunning { kill(agent.processIdentifier, SIGKILL) }; agent.waitUntilExit() }
    try store.savePID(agent.processIdentifier)
    try store.saveConfig(.init(command: .init(executable: "/usr/bin/uname")))
    try store.saveHealth(.init(available: true, fresh: true, running: true, childRunning: false,
                               screens: 2, columns: 80, rows: 24, frames: 1))
    let monitoring = TerminalWallpaperMonitoring(store: store, expectedExecutableName: "tail")
    let snapshot = try #require(monitoring.snapshot())
    #expect(snapshot.isTerminal && snapshot.terminalProgram == "uname")
    #expect(snapshot.metrics.running && snapshot.metrics.cpu_percent != nil)
    #expect(snapshot.metrics.memory_mb ?? 0 > 0)
    #expect(snapshot.metrics.daemon_pids == [Int(agent.processIdentifier)])
    #expect(snapshot.metrics.health?.fresh == true && snapshot.metrics.health?.screens == 2)
    #expect(snapshot.terminalHealth?.columns == 80)
    // Stale geometry is not presented as current; OS resource queries still work.
    try store.saveHealth(.init(available: true, fresh: true, running: true, screens: 9,
                               updatedAt: Date().timeIntervalSince1970 - 10))
    let stale = try #require(monitoring.snapshot())
    #expect(stale.metrics.health?.reason == "stale-health")
    #expect(stale.metrics.health?.screens == nil && stale.terminalHealth == nil)
    #expect(stale.metrics.memory_mb ?? 0 > 0)
    // A persisted live foreign PID must not masquerade as a terminal helper.
    #expect(TerminalWallpaperMonitoring(store: store).snapshot() == nil)
    kill(agent.processIdentifier, SIGKILL)
    agent.waitUntilExit()
    #expect(monitoring.snapshot() == nil)
}

private final class MonitoringSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WallpaperMonitoringSnapshot?
    func set(_ snapshot: WallpaperMonitoringSnapshot?) { lock.lock(); defer { lock.unlock() }; value = snapshot }
    func read() -> WallpaperMonitoringSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}

@Test @MainActor func terminalMonitoringFollowsAppliedRuntimeInsteadOfPreviewAndFallsBackToVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraMonitoringRouting-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = MonitoringSnapshotSource()
    source.set(WallpaperMonitoringSnapshot(metrics: .init(running: true, pid: 101, cpu_percent: 35, memory_mb: 45), terminalProgram: "cbonsai"))
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("preview.json"))
    selection.selectVideo()
    let model = AppViewModel(controller: MockNativeWallpaperController(), appSupportDirectoryURL: root,
                             previewSelectionStore: selection, terminalMonitoringSnapshot: { source.read() })
    defer { model.closeMonitoring() }
    model.openMonitoring()
    for _ in 0..<100 where model.monitoringSnapshot?.isTerminal != true {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.monitoringSnapshot?.terminalProgram == "cbonsai")
    #expect(model.monitoringSnapshot?.metrics.cpu_percent == 35)
    #expect(model.monitoringErrorMessage == nil)
    source.set(nil)
    model.refreshMonitoring()
    for _ in 0..<100 where model.monitoringSnapshot?.isTerminal != false {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.monitoringSnapshot?.isTerminal == false)
    #expect(model.monitoringSnapshot?.metrics.running == false)
    #expect(model.monitoringSnapshot?.metrics.pid == nil)
    #expect(model.monitoringErrorMessage == nil)
}
