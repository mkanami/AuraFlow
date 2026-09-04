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
