import AuraTerminalWallpaperCore
import Foundation
import Testing

@Test func terminalRuntimeRejectsReusedPIDEvenWhenTheProcessExists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalIdentity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
    try store.savePID()
    #expect(store.status().running)
    let identityURL = root.appendingPathComponent("agent-identity.json")
    var identity = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any])
    identity["startTimeMicros"] = 1
    try JSONSerialization.data(withJSONObject: identity).write(to: identityURL, options: .atomic)
    #expect(!store.status().running)
    #expect(!store.processIsAlive(pid: Int(getpid())))
}

@Test func legacyTerminalPIDCannotClaimAnUnrelatedProcessAfterReboot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLegacyIdentity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
    try store.ensureDirectories()
    try String(getpid()).write(to: store.pidURL, atomically: true, encoding: .utf8)
    #expect(!store.status().running)
}
