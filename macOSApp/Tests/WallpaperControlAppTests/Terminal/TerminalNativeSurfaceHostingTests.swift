import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import QuartzCore
import Testing
@testable import AuraTerminalWallpaperAgent

@MainActor
private final class RecordingTerminalNativeDriver: TerminalLockScreenNativeDriving {
    var layers: [CALayer] = []
    var holdNextPresentation = false
    var held: CheckedContinuation<Void, Never>?
    var failNextPresentation = false
    var onPresentation: ((Bool) throws -> Void)?

    func makeDisplay(_ id: UInt32) async throws -> TerminalNativeDisplayLease {
        let layer = CALayer()
        layers.append(layer)
        return TerminalNativeDisplayLease(assertion: NSObject(), layer: layer)
    }
    func makePresentation(for display: TerminalNativeDisplayLease, locked: Bool) async throws -> AnyObject {
        try onPresentation?(locked)
        if holdNextPresentation {
            holdNextPresentation = false
            await withCheckedContinuation { held = $0 }
        }
        if failNextPresentation {
            failNextPresentation = false
            throw CocoaError(.fileReadUnknown)
        }
        return NSObject()
    }
}

@MainActor private func settleTerminalNativePresentation() async {
    for _ in 0..<20 { await Task.yield() }
}

@Suite(.serialized)
struct TerminalNativeSurfaceHostingTests {
    @Test @MainActor
    func rebootedTerminalPromotesItsLiveRouteBeforeNativeLockAndRestoresUserChoicesOnUnlockAndStop() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNativeHandoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("unused.plist"))
        try store.savePID(getpid())
        try Data("{\"show_on_lock_screen\":true}".utf8).write(to: root.appendingPathComponent("config.json"))
        let index = root.appendingPathComponent("Index.plist")
        let journal = store.appSupportURL.appendingPathComponent("screen-saver-wallpaper-store-backup.json")
        try Data("{\"routes\":[]}".utf8).write(to: journal)
        let saver = root.appendingPathComponent("AuraFlowLockScreen.saver")
        let user: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.sonoma", "Configuration": Data()]],
            "EncodedOptionValues": try PropertyListSerialization.data(fromPropertyList: ["values": [:]], format: .binary, options: 0)]]
        let aura: [String: Any] = ["Content": ["Choices": [["Provider": WallpaperPlatformConstants.screenSaverProviderID,
            "Configuration": try PropertyListSerialization.data(fromPropertyList: ["module": ["relative": saver.absoluteString]], format: .binary, options: 0)]]]]
        let original: [String: Any] = ["SystemDefault": ["Desktop": user, "Idle": aura]]
        try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0).write(to: index)
        func desktop() throws -> NSDictionary {
            let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: index), format: nil) as! [String: [String: Any]]
            return root["SystemDefault"]!["Desktop"] as! NSDictionary
        }
        let driver = RecordingTerminalNativeDriver()
        driver.onPresentation = { locked in
            #expect((try? desktop().isEqual(locked ? aura : user)) == true, "The source must be selected before its system presentation is requested")
        }
        var locked = false
        var starts = 0
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, startScreenSaver: {
            #expect((try? desktop().isEqual(aura)) == true)
            #expect(driver.layers.allSatisfy { $0.superlayer != nil })
            starts += 1
            return 0
        }, nativeDriver: driver,
            displaysProvider: { [.init(id: 31, frame: NSRect(x: 0, y: 0, width: 800, height: 600))] },
            orderNativeWindow: { _ in }, runtimeStore: store,
            routeCoordinator: ScreenSaverRouteRecovery(storeURL: index, journalURL: journal, saverURL: saver))
        defer { presentation.stop() }
        presentation.start()
        await settleTerminalNativePresentation()
        #expect(starts == 0)
        locked = true
        presentation.handleLockNotification(true)
        await settleTerminalNativePresentation()
        #expect(starts == 1)
        locked = false
        presentation.handleLockNotification(false)
        await settleTerminalNativePresentation()
        #expect(try desktop().isEqual(user))
        locked = true
        presentation.handleLockNotification(true)
        await settleTerminalNativePresentation()
        #expect(starts == 2)
        presentation.stop()
        #expect(try desktop().isEqual(user))
    }

    @Test @MainActor
    func loginLockScreenHostsEveryNativeDisplayLayerBeforeStartingTheSaver() async throws {
        _ = NSApplication.shared
        let driver = RecordingTerminalNativeDriver()
        var locked = false
        var starts = 0
        var windows: [NSWindow] = []
        let screens = [TerminalLockScreenDisplay(id: 101, frame: NSRect(x: -1200, y: 0, width: 1200, height: 1600)),
                       TerminalLockScreenDisplay(id: 202, frame: NSRect(x: 0, y: 200, width: 1920, height: 1080))]
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked },
            startScreenSaver: {
                #expect(driver.layers.count == screens.count)
                #expect(driver.layers.allSatisfy { $0.superlayer != nil }, "A ready assertion without a hosted layer cannot present Aura")
                starts += 1
                return 0
            }, routeRecovery: { false }, nativeDriver: driver, displaysProvider: { screens }, orderNativeWindow: { windows.append($0) })
        defer { presentation.stop() }
        presentation.start()
        await settleTerminalNativePresentation()
        #expect(driver.layers.count == screens.count)
        #expect(driver.layers.allSatisfy { $0.superlayer != nil })
        #expect(windows.map(\.frame) == screens.map(\.frame))
        #expect(windows.allSatisfy { !$0.isVisible && $0.alphaValue == 0 && $0.ignoresMouseEvents && !$0.isOpaque })
        locked = true
        presentation.handleLockNotification(true)
        await settleTerminalNativePresentation()
        #expect(starts == 1)
        presentation.stop()
        #expect(driver.layers.allSatisfy { $0.superlayer == nil })
    }

    @Test @MainActor
    func aFailedRebindKeepsThePreviousHostedLayerUntilTheReplacementCommits() async {
        _ = NSApplication.shared
        let driver = RecordingTerminalNativeDriver()
        var now: TimeInterval = 100
        let screens = [TerminalLockScreenDisplay(id: 9, frame: NSRect(x: 0, y: 0, width: 800, height: 600))]
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { false }, uptime: { now },
            startScreenSaver: { Issue.record("An unlocked rebind must never start the saver"); return 0 },
            routeRecovery: { false }, nativeDriver: driver, displaysProvider: { screens }, orderNativeWindow: { _ in })
        defer { presentation.stop() }
        presentation.start()
        await settleTerminalNativePresentation()
        let original = driver.layers[0]
        driver.holdNextPresentation = true
        presentation.recoverAfterSystemChange()
        await settleTerminalNativePresentation()
        #expect(driver.held != nil && driver.layers.count == 2)
        #expect(original.superlayer != nil)
        driver.failNextPresentation = true
        driver.held?.resume()
        await settleTerminalNativePresentation()
        #expect(original.superlayer != nil)
        #expect(driver.layers[1].superlayer == nil)
        now += 5
        presentation.pollSession()
        await settleTerminalNativePresentation()
        #expect(driver.layers.count == 3)
        #expect(original.superlayer == nil)
        #expect(driver.layers[2].superlayer != nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func aLateNativeCompletionAfterUnlockOrStopCannotStartTheSaver(stop: Bool) async {
        _ = NSApplication.shared
        let driver = RecordingTerminalNativeDriver()
        var locked = false
        var starts = 0
        let screens = [TerminalLockScreenDisplay(id: 77, frame: NSRect(x: 0, y: 0, width: 640, height: 480))]
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked },
            startScreenSaver: { starts += 1; return 0 }, routeRecovery: { false },
            nativeDriver: driver, displaysProvider: { screens }, orderNativeWindow: { _ in })
        defer { presentation.stop() }
        presentation.start()
        await settleTerminalNativePresentation()
        driver.holdNextPresentation = true
        locked = true
        presentation.handleLockNotification(true)
        await settleTerminalNativePresentation()
        #expect(driver.held != nil)
        if stop { presentation.stop() }
        else { locked = false; presentation.handleLockNotification(false) }
        driver.held?.resume()
        await settleTerminalNativePresentation()
        #expect(starts == 0)
        if stop { #expect(driver.layers.allSatisfy { $0.superlayer == nil }) }
        else { #expect(driver.layers.allSatisfy { $0.superlayer != nil }) }
    }

    @Test @MainActor
    func loginBeforeDisplayEnumerationRetriesHostingWithoutAnUnrequestedLock() async {
        _ = NSApplication.shared
        let driver = RecordingTerminalNativeDriver()
        var now: TimeInterval = 100
        var screens: [TerminalLockScreenDisplay] = []
        var locked = false
        var starts = 0
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, uptime: { now },
            startScreenSaver: { starts += 1; return 0 }, routeRecovery: { false }, nativeDriver: driver,
            displaysProvider: { screens }, orderNativeWindow: { _ in })
        defer { presentation.stop() }
        presentation.start()
        await settleTerminalNativePresentation()
        #expect(driver.layers.isEmpty && starts == 0)
        screens = [TerminalLockScreenDisplay(id: 300, frame: NSRect(x: 0, y: -1080, width: 1920, height: 1080))]
        now += 5
        presentation.pollSession()
        await settleTerminalNativePresentation()
        #expect(driver.layers.count == 1 && driver.layers[0].superlayer != nil)
        #expect(starts == 0)
        locked = true
        presentation.pollSession()
        await settleTerminalNativePresentation()
        #expect(starts == 1)
    }
}
