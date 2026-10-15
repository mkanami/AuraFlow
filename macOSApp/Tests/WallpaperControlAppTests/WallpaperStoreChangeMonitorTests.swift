import Foundation
import Testing
@testable import AuraWallpaperCore

private final class MonitorCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: WallpaperStoreChangeMonitor?
    private var count = 0

    var callbackCount: Int { lock.withLock { count } }
    func attach(_ monitor: WallpaperStoreChangeMonitor) { lock.withLock { self.monitor = monitor } }
    func stopFromCallback() {
        let monitor = lock.withLock { count += 1; return self.monitor }
        monitor?.stop()
    }
}

@Test func wallpaperStoreMonitorCanStopInsideItsOwnCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = root.appendingPathComponent("Index.plist")
    try Data("initial".utf8).write(to: store, options: .atomic)
    let state = MonitorCallbackState()
    let monitor = WallpaperStoreChangeMonitor(directoryURL: root, storeURL: store) { _ in
        state.stopFromCallback()
    }
    state.attach(monitor)
    defer { monitor.stop() }
    #expect(monitor.start())
    try Data("changed".utf8).write(to: store, options: .atomic)
    let deadline = Date().addingTimeInterval(3)
    while state.callbackCount == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    // This external stop also waits for the callback to return. Previously
    // stopping from that callback trapped in a recursive dispatch_sync.
    monitor.stop()
    #expect(state.callbackCount == 1)
    try Data("after stop".utf8).write(to: store, options: .atomic)
    try await Task.sleep(for: .milliseconds(150))
    #expect(state.callbackCount == 1)
}
