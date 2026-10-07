import Foundation
import Testing

@Test func lockScreenPresentsPublishedFrameBeforeAnimationStartsAndRestoresExpiredRoute() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockFirstFrame-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let saver = package.appendingPathComponent("Sources/AuraFlowLockScreenSaver")
    let rendering = package.appendingPathComponent("Sources/AuraLockScreenRendering")
    let fixture = try #require(Bundle.module.url(forResource: "LockScreenFirstFrameProbe", withExtension: "m"))
    let executable = root.appendingPathComponent("probe")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["clang", "-fobjc-arc", "-fmodules", "-Wno-deprecated-declarations",
        "-I" + saver.path, "-I" + rendering.appendingPathComponent("include").path,
        "-framework", "AppKit", "-framework", "ScreenSaver", "-framework", "AVFoundation",
        "-framework", "ImageIO", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "IOSurface",
        fixture.path, saver.appendingPathComponent("AuraFlowLockScreen.m").path,
        rendering.appendingPathComponent("AuraFlowTerminalSurface.m").path, "-o", executable.path]
    try await runFirstFrameProbeProcess(compile)
    try #require(compile.terminationStatus == 0)
    let process = Process(), output = Pipe()
    process.executableURL = executable
    process.arguments = [root.path]
    process.standardOutput = output
    let execution = Task { try await runFirstFrameProbeProcess(process) }
    let timeout = Task.detached {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel() }
    let result = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    try await execution.value
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: result, as: UTF8.self).hasPrefix("first-frame-before-start "))
    print(String(decoding: result, as: UTF8.self))
}

private func runFirstFrameProbeProcess(_ process: Process) async throws {
    // Foundation's waitUntilExit can miss its run-loop notification after a
    // short-lived AppKit probe exits. Register completion before launching.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
}
