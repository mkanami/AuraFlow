import AppKit
import AuraTerminalWallpaperCore
import Foundation
import ImageIO
import Testing
@testable import AuraTerminalWallpaperAgent

@Test(arguments: [false, true]) @MainActor
func terminalRendererReenablesLockScreenWithoutRestartingCommand(animated: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockCheckbox-\(UUID())")
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/test.plist"))
    let sharedConfigURL = root.appendingPathComponent("config.json")
    try store.ensureDirectories()
    func setEnabled(_ enabled: Bool) throws {
        try JSONSerialization.data(withJSONObject: ["show_on_lock_screen": enabled])
            .write(to: sharedConfigURL, options: .atomic)
    }
    try setEnabled(false)
    let output = animated
        ? "i=0; while :; do printf '\\033[Hframe %s' \"$i\"; i=$((i+1)); sleep 0.05; done"
        : "printf '\\033[44m\\033[2Jstatic composition'"
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh",
        arguments: ["-c", "printf x >> launches; " + output], workingDirectory: root.path),
        render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 20, rows: 4),
        behavior: .init(allDisplays: false, pauseOnFullscreen: false))
    try store.saveConfig(config)
    let delegate = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false)
    defer {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try? FileManager.default.removeItem(at: root)
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    func pumpUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
    }
    await pumpUntil { store.loadSharedFrameDescriptor() != nil && store.loadHealth()?.childRunning == animated }
    try #require(store.loadSharedFrameDescriptor() != nil)
    #expect(store.loadLockScreenHeartbeat() == nil)
    let pid = store.loadPID()
    for _ in 0..<2 {
        let requestedAt = Date().timeIntervalSince1970
        try setEnabled(true)
        try store.saveCommand(TerminalWallpaperRuntimeCommand(action: .update, config: config))
        await pumpUntil { (store.loadLockScreenHeartbeat()?.updatedAt ?? 0) > requestedAt }
        try #require((store.loadLockScreenHeartbeat()?.updatedAt ?? 0) > requestedAt)
        let source = try #require(CGImageSourceCreateWithURL(store.lockScreenFrameURL as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(frame.width == 320 && frame.height == 240)
        #expect(store.loadPID() == pid)
        try setEnabled(false)
        try store.saveCommand(TerminalWallpaperRuntimeCommand(action: .update, config: config))
        await pumpUntil { store.loadLockScreenHeartbeat() == nil }
        #expect(store.loadLockScreenHeartbeat() == nil)
        #expect(store.loadSharedFrameDescriptor() != nil)
        #expect(store.loadHealth()?.childRunning == animated)
    }
    #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
}
