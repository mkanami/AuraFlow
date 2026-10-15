import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import Foundation
import ImageIO
import Testing
@testable import AuraTerminalWallpaperAgent

@Test func terminalPublicationWaitsForContentAndRetainsSuccessfulStaticOutput() {
    var parser = VTParser(columns: 20, rows: 4)
    var state = TerminalOutputPublicationState()
    state.receive(parser.grid.snapshot())
    #expect(!state.canPublish(childRunning: true))
    parser.feed(Data("Darwin\r\n".utf8))
    state.receive(parser.grid.snapshot())
    #expect(state.canPublish(childRunning: true))
    #expect(!state.canPublish(childRunning: false))
    state.finish(0)
    #expect(state.canPublish(childRunning: false))
    #expect(state.error == nil)

    // A restart cannot inherit eligibility from the previous source.
    state = TerminalOutputPublicationState()
    #expect(!state.canPublish(childRunning: true))
}

@Test func terminalPublicationRejectsFailureAndEmptyCompletionButAcceptsColoredPixels() {
    var parser = VTParser(columns: 20, rows: 4)
    var state = TerminalOutputPublicationState()
    state.finish(0)
    #expect(!state.canPublish(childRunning: false))
    #expect(state.error?.contains("without visible output") == true)
    parser.feed(Data("\u{1b}[41m  ".utf8))
    state.receive(parser.grid.snapshot())
    #expect(state.canPublish(childRunning: false))
    state.finish(1)
    #expect(!state.canPublish(childRunning: true))
    #expect(state.error?.contains("status 1") == true)
}

/// Real PTY → parser → Metal → PNG/IOSurface, without touching the user's
/// configuration, saver route, library, or native Lock Screen assertions.
@Test @MainActor func terminalStaticUnamePublishesNonblackLockFrameAfterChildExit() async throws {
    try await checkTerminalPublication(
        command: TerminalCommandConfiguration(executable: "/usr/bin/uname"),
        staticOutput: true
    )
}

@Test @MainActor func terminalLiveOutputDoesNotSeedAnEmptyTexture() async throws {
    try await checkTerminalPublication(
        command: TerminalCommandConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.2; while :; do printf '\\033[Hvisual frame'; sleep 0.05; done"]
        ),
        staticOutput: false
    )
}

@Test @MainActor func terminalAnimatedLolcatPublishesFullLiveLockFrame() async throws {
    guard let executable = TerminalExecutableLocator.resolve("lolcat") else { return }
    try await checkTerminalPublication(
        command: .init(executable: executable), staticOutput: false,
        render: .init(pixelMode: .fixed, fixedWidth: 640, fixedHeight: 480,
                      columns: 153, rows: 48, fontSize: 18, textScale: 1),
        requireBottomContent: true
    )
}

@Test @MainActor func terminalStaticCompletionReplacesAnEarlierPartialSeed() async throws {
    try await checkTerminalPublication(
        command: .init(executable: "/bin/sh", arguments: ["-c",
            "printf '\\033[Hfirst frame'; sleep 0.4; printf '\\033[48;2;128;255;64m\\033[2Jcomplete frame'"]),
        staticOutput: true, requireBottomContent: true
    )
}

@Test @MainActor func terminalFailedAndEmptyCommandsDoNotPublishLockFrames() async throws {
    try await checkTerminalPublication(
        command: TerminalCommandConfiguration(executable: "/usr/bin/false"),
        staticOutput: false, expectedFailure: "status 1"
    )
    try await checkTerminalPublication(
        command: TerminalCommandConfiguration(executable: "/usr/bin/true"),
        staticOutput: false, expectedFailure: "without visible output"
    )
}

@Test @MainActor func terminalDesktopSeedSettlesPartialStartupWithoutContinuousBackgroundEncoding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSeedSettling-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root)
    var now: TimeInterval = 1000
    let publisher = TerminalLockScreenFramePublisher(store: store, clock: { now })
    defer { publisher.revoke() }
    let first = Data([0, 0, 255, 255]), complete = Data([0, 255, 0, 255])
    publisher.publishDesktopSeed(first, width: 1, height: 1)
    let deadline = Date().addingTimeInterval(2)
    while store.loadLockScreenHeartbeat() == nil && Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let original = try Data(contentsOf: store.lockScreenFrameURL)
    #expect(!publisher.needsDesktopSeed)
    now += 0.49
    #expect(!publisher.needsDesktopSeed)
    now += 0.02
    #expect(publisher.needsDesktopSeed)
    publisher.publishDesktopSeed(complete, width: 1, height: 1)
    let updatedDeadline = Date().addingTimeInterval(2)
    while (try? Data(contentsOf: store.lockScreenFrameURL)) == original && Date() < updatedDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(try Data(contentsOf: store.lockScreenFrameURL) != original)
    let completionDeadline = Date().addingTimeInterval(2)
    while publisher.isWritingFrame && Date() < completionDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    for _ in 0..<2 {
        now += 0.51
        #expect(publisher.needsDesktopSeed)
        publisher.publishDesktopSeed(complete, width: 1, height: 1)
        let writeDeadline = Date().addingTimeInterval(2)
        while publisher.isWritingFrame && Date() < writeDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    now = 1010
    #expect(!publisher.needsDesktopSeed)
    publisher.setLockScreenActive(true)
    #expect(!publisher.needsDesktopSeed)
    publisher.setLockScreenActive(false)
    #expect(!publisher.needsDesktopSeed)
    publisher.beginDesktopGeneration()
    #expect(publisher.needsDesktopSeed)
}

@MainActor private func checkTerminalPublication(
    command: TerminalCommandConfiguration, staticOutput: Bool, expectedFailure: String? = nil,
    render: TerminalRenderConfiguration = .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240,
                                                columns: 20, rows: 4, fontSize: 18, textScale: 1),
    requireBottomContent: Bool = false
) async throws {
    _ = NSApplication.shared
    var render = render
    if requireBottomContent, let width = render.fixedWidth,
       let columns = render.columns, let rows = render.rows {
        // Match the source canvas to this fixture's grid aspect ratio. A
        // deliberately wider grid in a fixed 4:3 canvas has valid Fit padding;
        // those black margins do not indicate missing final CLI output.
        let metrics = TerminalFontMetrics.cellMetrics(for: render)
        render.fixedHeight = Int((Double(width) * Double(rows) * metrics.height
            / (Double(columns) * metrics.width)).rounded())
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraStaticPublication-\(UUID().uuidString)", isDirectory: true)
    let store = TerminalWallpaperRuntimeStore(
        appSupportURL: root,
        launchAgentURL: root.appendingPathComponent("LaunchAgents/test.plist")
    )
    let config = TerminalWallpaperConfig(
        command: command,
        render: render,
        behavior: TerminalWallpaperBehavior(allDisplays: false, pauseOnFullscreen: false)
    )
    try store.saveConfig(config)
    let delegate = TerminalWallpaperAgentDelegate(
        configurationURL: store.configURL, managesLockScreenPresentation: false
    )
    defer {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try? FileManager.default.removeItem(at: root)
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let expectedFailure,
           store.loadHealth()?.lastError?.contains(expectedFailure) == true { break }
        if store.loadLockScreenHeartbeat() != nil,
           store.loadSharedFrameDescriptor() != nil,
           store.loadHealth()?.running == true,
           !staticOutput || store.loadHealth()?.childRunning == false,
           !requireBottomContent || terminalPNGHasBottomContent(store.lockScreenFrameURL) { break }
        // Pump AppKit's timers and display pass, just as NSApplication.run does.
        pumpTerminalAppKit()
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let health = try #require(store.loadHealth())
    if let expectedFailure {
        #expect(!health.running)
        #expect(!health.childRunning)
        #expect(health.lastError?.contains(expectedFailure) == true)
        #expect(store.loadLockScreenHeartbeat() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))
        return
    }
    #expect(health.running)
    #expect(health.childRunning == !staticOutput)
    #expect(health.lastError == nil)
    #expect(store.loadSharedFrameDescriptor() != nil)
    #expect(store.loadLockScreenHeartbeat()?.pid == Int(getpid()))
    let source = try #require(CGImageSourceCreateWithURL(store.lockScreenFrameURL as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == render.fixedWidth)
    #expect(image.height == render.fixedHeight)
    let pixels = try #require(image.dataProvider?.data) as Data
    #expect(pixels.enumerated().contains { index, value in index % 4 != 3 && value > 40 })
    if requireBottomContent { #expect(terminalPNGHasBottomContent(store.lockScreenFrameURL)) }

    // A completed CLI retains its publication lease and its final image.
    let heartbeat = try #require(store.loadLockScreenHeartbeat())
    let leaseDeadline = Date().addingTimeInterval(2.5)
    while Date() < leaseDeadline {
        pumpTerminalAppKit()
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect((store.loadLockScreenHeartbeat()?.updatedAt ?? 0) > heartbeat.updatedAt)
    #expect(FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))

    if staticOutput {
        // Changing layout after EOF must resize the retained parser, not erase it.
        let originalFrame = try Data(contentsOf: store.lockScreenFrameURL)
        var updated = config
        updated.render.columns = 25
        updated.render.rows = 6
        try store.saveCommand(TerminalWallpaperRuntimeCommand(action: .update, config: updated))
        let resizeDeadline = Date().addingTimeInterval(3)
        while (try? Data(contentsOf: store.lockScreenFrameURL)) == originalFrame,
              Date() < resizeDeadline {
            pumpTerminalAppKit()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try Data(contentsOf: store.lockScreenFrameURL) != originalFrame)
        #expect(store.loadHealth()?.childRunning == false)
        #expect(store.loadHealth()?.running == true)
        #expect(store.loadHealth()?.lastError == nil)

        // Restart with another one-shot command gets its own fresh seed.
        let resizedFrame = try Data(contentsOf: store.lockScreenFrameURL)
        updated.command = TerminalCommandConfiguration(
            executable: "/usr/bin/printf", arguments: ["\\033[42m replacement frame"]
        )
        try store.saveCommand(TerminalWallpaperRuntimeCommand(action: .restart, config: updated))
        let restartDeadline = Date().addingTimeInterval(3)
        while (try? Data(contentsOf: store.lockScreenFrameURL)) == resizedFrame,
              Date() < restartDeadline {
            pumpTerminalAppKit()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try Data(contentsOf: store.lockScreenFrameURL) != resizedFrame)
    }
}

private func terminalPNGHasBottomContent(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let data = image.dataProvider?.data else { return false }
    let pixels = data as Data
    let start = image.height * 9 / 10 * image.bytesPerRow
    return pixels[start...].enumerated().contains { index, value in index % 4 != 3 && value > 40 }
}

@MainActor private func pumpTerminalAppKit() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
