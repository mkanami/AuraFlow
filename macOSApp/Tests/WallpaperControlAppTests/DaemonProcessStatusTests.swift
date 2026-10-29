import Darwin
import Foundation
import Testing
@testable import AuraWallpaperCore

private func makeDaemonStatusStore() throws -> (root: URL, store: WallpaperRuntimeStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowDaemonStatusTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support", isDirectory: true),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/agent.plist"),
        launchctlRunner: { _ in LaunchctlResult(succeeded: true) }
    )
    try store.ensureDirectories()
    return (root, store)
}

private func launchStatusFixtureProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "exec /usr/bin/tail -f /dev/null"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()

    var executablePath = [Int8](repeating: 0, count: 4_096)
    for _ in 0..<100 {
        if proc_pidpath(
            process.processIdentifier,
            &executablePath,
            UInt32(executablePath.count)
        ) > 0,
           String(cString: executablePath) == "/usr/bin/tail" {
            return process
        }
        usleep(10_000)
    }

    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    throw CocoaError(.fileReadUnknown)
}

private func stopStatusFixtureProcess(_ process: Process) {
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

@Test func statusAndMetricsRejectLiveForeignProcess() throws {
    let fixture = try makeDaemonStatusStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let process = try launchStatusFixtureProcess()
    defer { stopStatusFixtureProcess(process) }

    try fixture.store.savePID(process.processIdentifier)
    let manager = DaemonProcessManager(store: fixture.store)
    #expect(manager.processStatus == .owned)
    #expect(manager.isRunning)

    let foreignIdentity = """
    {"executablePath":"/definitely/not/auraflow","startTimeMicros":1}
    """
    try Data(foreignIdentity.utf8)
        .write(to: fixture.store.daemonIdentityURL, options: .atomic)

    #expect(manager.processStatus == .identityMismatch)
    #expect(manager.isRunning == false)

    let status = fixture.store.status()
    #expect(status.running == false)
    #expect(status.pid == nil)
    #expect(status.health?.available == false)
    #expect(status.health?.reason == "identity-mismatch")

    let metrics = fixture.store.metrics()
    #expect(metrics.running == false)
    #expect(metrics.pid == nil)
    #expect(metrics.daemon_pids == [])
    #expect(metrics.process_count == 0)
    #expect(metrics.health?.available == false)
    #expect(metrics.health?.reason == "identity-mismatch")
}

@Test func orphanCleanupPreservesLoginHandshakeRecoveryWorkerAndRuntimeOwner() throws {
    let fixture = try makeDaemonStatusStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let process = try launchStatusFixtureProcess()
    defer { stopStatusFixtureProcess(process) }
    let pid = Int(process.processIdentifier)
    let manager = DaemonProcessManager(store: fixture.store,
        expectedExecutableURL: URL(fileURLWithPath: "/usr/bin/tail"))
    // A newly started helper is allowed to finish publishing its identity.
    #expect(manager.terminateOrphanedProcesses(minimumAge: 60, processIDs: [pid]).isEmpty)
    #expect(process.isRunning)
    // launchd's PID is protected even before that identity file exists.
    #expect(manager.terminateOrphanedProcesses(minimumAge: 0, processIDs: [pid], protectedPIDs: [pid]).isEmpty)
    try String(pid).write(to: fixture.store.sessionRecoveryPIDURL, atomically: true, encoding: .utf8)
    #expect(manager.terminateOrphanedProcesses(minimumAge: 0, processIDs: [pid]).isEmpty)
    try FileManager.default.removeItem(at: fixture.store.sessionRecoveryPIDURL)
    try fixture.store.savePID(process.processIdentifier)
    #expect(manager.terminateOrphanedProcesses(minimumAge: 0, processIDs: [pid]).isEmpty)
    fixture.store.removePID()
    // An actual unowned helper with the same executable is still cleaned up.
    #expect(manager.terminateOrphanedProcesses(timeout: 0.2, minimumAge: 0, processIDs: [pid]) == [pid])
}

@Test func metricsExposeOwnedProcessResources() throws {
    let fixture = try makeDaemonStatusStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let process = try launchStatusFixtureProcess()
    defer { stopStatusFixtureProcess(process) }

    try fixture.store.savePID(process.processIdentifier)
    let metrics = fixture.store.metrics()

    #expect(metrics.pid == Int(process.processIdentifier))
    #expect(metrics.process_count == 1)
    #expect(metrics.cpu_percent != nil)
    #expect(metrics.memory_mb != nil)
    #expect(metrics.memory_mb ?? 0 > 0)
    #expect(metrics.virtual_memory_mb != nil)
    #expect(metrics.virtual_memory_mb ?? 0 > 0)
    #expect(metrics.thread_count != nil)
    #expect(metrics.thread_count ?? 0 > 0)
}

@Test func daemonProcessStatusDistinguishesUnknownStaleAndMissingPID() throws {
    let fixture = try makeDaemonStatusStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let process = try launchStatusFixtureProcess()
    try fixture.store.savePID(process.processIdentifier)
    let manager = DaemonProcessManager(store: fixture.store)

    try FileManager.default.removeItem(at: fixture.store.daemonIdentityURL)
    #expect(manager.processStatus == .unknown)
    #expect(manager.isRunning == false)

    stopStatusFixtureProcess(process)
    #expect(manager.processStatus == .stalePID)
    #expect(manager.isRunning == false)

    fixture.store.removePID()
    #expect(manager.processStatus == .noPID)
    #expect(manager.isRunning == false)
}

@Test func lockScreenAgentStartedMarkerIsIndependentFromGenerationReadyMarker() throws {
    let fixture = try makeDaemonStatusStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(fixture.store.isLockScreenAgentStarted() == false)
    #expect(fixture.store.isLockScreenAgentReady() == false)

    fixture.store.markLockScreenAgentStarted(true)
    #expect(fixture.store.isLockScreenAgentStarted())
    #expect(fixture.store.isLockScreenAgentReady() == false)

    fixture.store.markLockScreenAgentReady(true)
    fixture.store.markLockScreenAgentStarted(false)
    #expect(fixture.store.isLockScreenAgentStarted() == false)
    #expect(fixture.store.isLockScreenAgentReady())

    fixture.store.markLockScreenOnlyAgent(false)
    #expect(fixture.store.isLockScreenAgentReady() == false)
}
