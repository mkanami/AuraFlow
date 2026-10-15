import AuraWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class TerminalSaverStoreFixture {
    let root: URL
    let storeURL: URL
    let journalURL: URL
    let saverURL: URL
    var stopCount = 0
    var startCount = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AuraFlowTerminalSaverStore-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("Index.plist")
        journalURL = root.appendingPathComponent("backup.json")
        saverURL = root.appendingPathComponent("AuraFlowLockScreen.saver", isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func coordinator() -> TerminalScreenSaverStoreCoordinator {
        TerminalScreenSaverStoreCoordinator(
            storeURL: storeURL,
            journalURL: journalURL,
            saverURL: saverURL,
            stopWallpaperAgent: { [self] in stopCount += 1 },
            startWallpaperAgent: { [self] in startCount += 1 }
        )
    }

    func mode(provider: String, config: [String: Any] = [:]) throws -> [String: Any] {
        ["Content": ["Choices": [[
            "Provider": provider,
            "Files": [],
            "Configuration": try PropertyListSerialization.data(
                fromPropertyList: config, format: .binary, options: 0
            ),
        ]]]]
    }

    func save(_ root: [String: Any]) throws {
        try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        ).write(to: storeURL, options: .atomic)
    }

    func load() throws -> [String: Any] {
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: storeURL), format: nil
        ) as! [String: Any]
    }

    func provider(_ mode: Any?) -> String? {
        guard let mode = mode as? [String: Any],
              let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else { return nil }
        return choices.first?["Provider"] as? String
    }
}

@Test func terminalSaverSelectsModernIdleWithoutChangingDesktopAndRestoresLinkedRoute() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    let oldIdle = try fixture.mode(provider: WallpaperPlatformConstants.aerialProviderID)
    try fixture.save([
        "AllSpacesAndDisplays": ["Type": "linked", "Linked": desktop],
        "SystemDefault": ["Type": "individual", "Desktop": desktop, "Idle": oldIdle],
    ])
    let coordinator = fixture.coordinator()
    try coordinator.activate()
    try coordinator.activate()
    let active = try fixture.load()
    let all = active["AllSpacesAndDisplays"] as! [String: Any]
    let system = active["SystemDefault"] as! [String: Any]
    #expect(fixture.provider(all["Desktop"]) == WallpaperPlatformConstants.imageProviderID)
    #expect(fixture.provider(all["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)
    #expect(fixture.provider(system["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)
    let idle = all["Idle"] as! [String: Any]
    let content = idle["Content"] as! [String: Any]
    let choice = (content["Choices"] as! [[String: Any]])[0]
    let config = try PropertyListSerialization.propertyList(
        from: choice["Configuration"] as! Data, format: nil
    ) as! [String: Any]
    #expect((config["module"] as? [String: String])?["relative"]
        == URL(fileURLWithPath: fixture.saverURL.path, isDirectory: false).absoluteString)
    #expect(fixture.stopCount == 2)
    #expect(fixture.startCount == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))

    try coordinator.restoreIfOwned()
    let restored = try fixture.load()
    let restoredAll = restored["AllSpacesAndDisplays"] as! [String: Any]
    let restoredSystem = restored["SystemDefault"] as! [String: Any]
    #expect(restoredAll["Type"] as? String == "linked")
    #expect(fixture.provider(restoredAll["Linked"]) == WallpaperPlatformConstants.imageProviderID)
    #expect(restoredAll["Idle"] == nil)
    #expect(fixture.provider(restoredSystem["Idle"]) == WallpaperPlatformConstants.aerialProviderID)
    #expect(fixture.stopCount == 3)
    #expect(fixture.startCount == 3)
    #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
}

@Test func terminalSaverRearmsWallpaperAgentWhenItsRouteIsAlreadySelected() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    let saverURL = URL(fileURLWithPath: fixture.saverURL.standardizedFileURL.path, isDirectory: false)
    let selectedSaver = try fixture.mode(
        provider: WallpaperPlatformConstants.screenSaverProviderID,
        config: ["module": ["relative": saverURL.absoluteString]]
    )
    try fixture.save(["SystemDefault": [
        "Type": "individual", "Desktop": desktop, "Idle": selectedSaver,
    ]])

    try fixture.coordinator().activate()

    #expect(fixture.stopCount == 1)
    #expect(fixture.startCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    let system = try fixture.load()["SystemDefault"] as! [String: Any]
    #expect(fixture.provider(system["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)
}

@Test func terminalSaverSelectsEveryDisplayAndRestoresEachPreviousIdle() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    let first = try fixture.mode(provider: "first-saver")
    let second = try fixture.mode(provider: "second-saver")
    try fixture.save([
        "Displays": [
            "one": ["Type": "individual", "Desktop": desktop, "Idle": first],
            "two": ["Type": "individual", "Desktop": desktop, "Idle": second],
        ],
    ])
    let coordinator = fixture.coordinator()
    try coordinator.activate()
    let active = try fixture.load()["Displays"] as! [String: [String: Any]]
    #expect(fixture.provider(active["one"]?["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)
    #expect(fixture.provider(active["two"]?["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)

    try coordinator.restoreIfOwned()
    let restored = try fixture.load()["Displays"] as! [String: [String: Any]]
    #expect(fixture.provider(restored["one"]?["Idle"]) == "first-saver")
    #expect(fixture.provider(restored["two"]?["Idle"]) == "second-saver")
}

@Test func terminalSaverRestorePreservesUserChangedScreenSaverChoice() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    let oldIdle = try fixture.mode(provider: WallpaperPlatformConstants.aerialProviderID)
    try fixture.save(["SystemDefault": [
        "Type": "individual", "Desktop": desktop, "Idle": oldIdle,
    ]])
    let coordinator = fixture.coordinator()
    try coordinator.activate()
    var root = try fixture.load()
    var system = root["SystemDefault"] as! [String: Any]
    system["Idle"] = try fixture.mode(provider: "user-chosen-saver")
    root["SystemDefault"] = system
    try fixture.save(root)

    try coordinator.restoreIfOwned()
    let restored = try fixture.load()["SystemDefault"] as! [String: Any]
    #expect(fixture.provider(restored["Idle"]) == "user-chosen-saver")
    #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
}

@Test func terminalSaverRebasesWallpaperAgentShutdownWrite() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    try fixture.save(["SystemDefault": ["Type": "individual", "Desktop": desktop]])
    var shutdowns = 0
    let coordinator = TerminalScreenSaverStoreCoordinator(
        storeURL: fixture.storeURL,
        journalURL: fixture.journalURL,
        saverURL: fixture.saverURL,
        stopWallpaperAgent: {
            shutdowns += 1
            guard shutdowns == 1 else { return }
            try fixture.save(["SystemDefault": [
                "Type": "individual", "Desktop": desktop, "Idle": try fixture.mode(provider: "new-choice"),
            ]])
        },
        startWallpaperAgent: {}
    )
    try coordinator.activate()
    let active = try fixture.load()["SystemDefault"] as! [String: Any]
    #expect(fixture.provider(active["Idle"]) == WallpaperPlatformConstants.screenSaverProviderID)
    try coordinator.restoreIfOwned()
    let restored = try fixture.load()["SystemDefault"] as! [String: Any]
    #expect(fixture.provider(restored["Idle"]) == "new-choice")
}

@Test func terminalSaverWaitsForNewWallpaperAgentInsteadOfOpenExit() {
    var samples: [Set<Int32>] = [[41], [41], [72]]
    var polls = 0
    let ready = TerminalScreenSaverStoreCoordinator.waitForFreshWallpaperAgent(
        excluding: [41],
        processIDs: {
            polls += 1
            return samples.removeFirst()
        },
        sleep: { _ in }
    )
    #expect(ready)
    #expect(polls == 3)
}

@Test func terminalSaverDoesNotLaunchWallpaperAgentTwiceAfterLaunchFailure() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID)
    try fixture.save(["SystemDefault": ["Type": "individual", "Desktop": desktop]])
    var starts = 0
    let coordinator = TerminalScreenSaverStoreCoordinator(
        storeURL: fixture.storeURL,
        journalURL: fixture.journalURL,
        saverURL: fixture.saverURL,
        stopWallpaperAgent: {},
        startWallpaperAgent: {
            starts += 1
            throw TerminalScreenSaverStoreCoordinator.StoreError.wallpaperAgentUnavailable
        }
    )
    #expect(throws: TerminalScreenSaverStoreCoordinator.StoreError.self) {
        try coordinator.activate()
    }
    #expect(starts == 1)
}

@Test func terminalSaverCheckboxOffRestoresCurrentUserDesktopInsteadOfOldIdle() throws {
    let fixture = try TerminalSaverStoreFixture()
    defer { fixture.cleanup() }
    let desktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID, config: ["user": "original"])
    let oldIdle = try fixture.mode(provider: WallpaperPlatformConstants.aerialProviderID, config: ["asset": "Golden Gate"])
    try fixture.save(["SystemDefault": ["Type": "individual", "Desktop": desktop, "Idle": oldIdle]])
    let coordinator = fixture.coordinator()
    try coordinator.activate()
    var active = try fixture.load()
    let latestDesktop = try fixture.mode(provider: WallpaperPlatformConstants.imageProviderID, config: ["user": "new selection"])
    var route = active["SystemDefault"] as! [String: Any]
    route["Desktop"] = latestDesktop
    active["SystemDefault"] = route
    try fixture.save(active)
    try coordinator.restoreCurrentDesktopIfOwned()
    let restored = (try fixture.load())["SystemDefault"] as! [String: Any]
    #expect((restored["Idle"] as? NSDictionary)?.isEqual(latestDesktop) == true)
    #expect((restored["Desktop"] as? NSDictionary)?.isEqual(latestDesktop) == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
}
