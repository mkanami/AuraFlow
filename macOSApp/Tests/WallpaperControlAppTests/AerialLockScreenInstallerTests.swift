import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

private final class AerialRefreshCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class AerialProceedGate: @unchecked Sendable {
    private var remainingAllowedCalls: Int

    init(allowedCalls: Int) {
        remainingAllowedCalls = allowedCalls
    }

    func shouldProceed() -> Bool {
        defer { remainingAllowedCalls -= 1 }
        return remainingAllowedCalls > 0
    }
}

private struct AerialLockScreenFixture {
    static let activeSpaceID =
        "49BAC883-46A3-452D-97ED-8A96BBEDA1B1"
    static let staleSpaceID =
        "E463F460-DA1C-4301-AC48-85776A3C15E2"
    static let displayID =
        "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    static let staleDisplayID =
        "2335F433-2476-462F-B0BA-F7A4DE8FC1E4"
    static let assetID =
        "7C643A39-C0B2-4BA0-8BC2-2EAA47CC580E"
    static let alternateAssetID =
        "44166C39-8566-4ECA-BD16-43159429B52F"
    static let secondAlternateAssetID =
        "80C7B9D0-D9A4-41BB-9E8A-DA676267C50A"

    let root: URL
    let storeURL: URL
    let spacesURL: URL
    let videosURL: URL
    let thumbnailsURL: URL
    let providerURL: URL
    let stateURL: URL
    let assetURL: URL
    let videoURL: URL
    let refreshCounter: AerialRefreshCounter
    let installer: AerialLockScreenInstaller

    init(
        hasExistingAsset: Bool = true,
        providerHasAsset: Bool = true,
        providerAssetIDs: [String]? = nil,
        configuredAssetID: String? = Self.assetID,
        onRefresh: ((URL) -> Void)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowModernLockScreen-\(UUID().uuidString)",
                isDirectory: true
            )
        storeURL = root.appendingPathComponent("Index.plist")
        spacesURL = root.appendingPathComponent("spaces.plist")
        videosURL = root.appendingPathComponent("videos", isDirectory: true)
        thumbnailsURL = root.appendingPathComponent(
            "thumbnails",
            isDirectory: true
        )
        providerURL = root.appendingPathComponent(
            "WallpaperAerialsExtension.appex",
            isDirectory: true
        )
        stateURL = root.appendingPathComponent("state", isDirectory: true)
        assetURL = videosURL
            .appendingPathComponent(Self.assetID)
            .appendingPathExtension("mov")
        videoURL = root.appendingPathComponent("wallpaper.mp4")

        try FileManager.default.createDirectory(
            at: videosURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: thumbnailsURL,
            withIntermediateDirectories: true
        )
        let providerResourcesURL = providerURL
            .appendingPathComponent(
                "Contents/Resources",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: providerResourcesURL,
            withIntermediateDirectories: true
        )
        let providerInfo: [String: Any] = [
            "CFBundleIdentifier":
                "com.apple.wallpaper.extension.aerials",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": "com.apple.wallpaper",
            ],
        ]
        let providerInfoData = try PropertyListSerialization.data(
            fromPropertyList: providerInfo,
            format: .binary,
            options: 0
        )
        try providerInfoData.write(
            to: providerURL
                .appendingPathComponent("Contents/Info.plist")
        )
        let catalogData = try JSONSerialization.data(
            withJSONObject: [
                "assets": providerHasAsset
                    ? (providerAssetIDs ?? [Self.assetID]).map {
                        ["id": $0]
                    }
                    : [],
            ]
        )
        try catalogData.write(
            to: providerResourcesURL
                .appendingPathComponent("entries.json")
        )
        if hasExistingAsset {
            try Data("original-aerial".utf8).write(to: assetURL)
        }
        try Data("new-wallpaper".utf8).write(to: videoURL)

        let originalDesktop = Self.makeMode(
            provider: "com.apple.wallpaper.choice.image",
            configuration: [
                "type": "imageFile",
                "url": ["relative": "file:///original.jpg"],
            ]
        )
        let originalIdle = Self.makeMode(
            provider: "com.apple.wallpaper.choice.screen-saver",
            configuration: [
                "module": [
                    "relative":
                        "file:///System/Library/ExtensionKit/Extensions/Ventura.appex",
                ],
            ]
        )
        let managedDesktop = Self.makeMode(
            provider: "com.apple.wallpaper.choice.image",
            configuration: [
                "type": "imageFile",
                "url": [
                    "relative":
                        "file:///Library/Application%20Support/AuraFlow/last_frame.png",
                ],
            ]
        )
        let managedIdle = Self.makeMode(
            provider: "com.apple.wallpaper.choice.screen-saver",
            configuration: [
                "module": [
                    "relative":
                        "file:///Users/test/Library/Screen%20Savers/AuraFlowLockScreen.saver",
                ],
            ]
        )
        let originalContainer: [String: Any] = [
            "Type": "individual",
            "Desktop": originalDesktop,
            "Idle": originalIdle,
        ]
        let managedContainer: [String: Any] = [
            "Type": "individual",
            "Desktop": managedDesktop,
            "Idle": managedIdle,
        ]
        let store: [String: Any] = [
            "AllSpacesAndDisplays": originalContainer,
            "SystemDefault": originalContainer,
            "Displays": [
                Self.displayID: managedContainer,
                Self.staleDisplayID: managedContainer,
            ],
            "Spaces": [
                Self.activeSpaceID: [
                    "Default": managedContainer,
                    "Displays": [
                        Self.displayID: managedContainer,
                        Self.staleDisplayID: managedContainer,
                    ],
                ],
                Self.staleSpaceID: [
                    "Default": managedContainer,
                    "Displays": [
                        Self.displayID: managedContainer,
                    ],
                ],
            ],
        ]
        let storeData = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try storeData.write(to: storeURL)

        let spaces: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [[
                        "Display Identifier": Self.displayID,
                        "Current Space": [
                            "uuid": Self.activeSpaceID,
                        ],
                        "Spaces": [[
                            "uuid": Self.activeSpaceID,
                        ]],
                    ]],
                    "SpaceAssignments": [
                        "ManagedSpaceOrdering": [[
                            "ManagedDisplayID": Self.displayID,
                            "ManagedSpaceIDs": [Self.activeSpaceID],
                        ]],
                    ],
                ],
            ],
        ]
        let spacesData = try PropertyListSerialization.data(
            fromPropertyList: spaces,
            format: .binary,
            options: 0
        )
        try spacesData.write(to: spacesURL)

        let counter = AerialRefreshCounter()
        refreshCounter = counter
        let refreshStoreURL = storeURL
        installer = AerialLockScreenInstaller(
            fileManager: .default,
            wallpaperStoreURL: storeURL,
            spacesPreferencesURL: spacesURL,
            aerialVideosURL: videosURL,
            aerialThumbnailsURL: thumbnailsURL,
            aerialProviderURL: providerURL,
            stateDirectoryURL: stateURL,
            assetID: configuredAssetID,
            refreshSystem: {
                counter.increment()
                onRefresh?(refreshStoreURL)
            },
            rearmSystem: {
                counter.increment()
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func makeMode(
        provider: String,
        configuration: [String: Any]
    ) -> [String: Any] {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .binary,
            options: 0
        )
        return [
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": [
                "Choices": [[
                    "Provider": provider,
                    "Files": [],
                    "Configuration": data,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }
}

@Test func modernLockScreenUsesAerialAndPrunesDeletedSpaces() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)

    #expect(fixture.installer.isInstalled)
    #expect(fixture.installer.installationConfirmed)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
    let root = try readWallpaperStore(fixture.storeURL)
    let allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    #expect(
        wallpaperStoreContains(
            allSpacesAndDisplays,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    let spaces = try #require(root["Spaces"] as? [String: Any])
    #expect(Set(spaces.keys) == [AerialLockScreenFixture.activeSpaceID])
    let displays = try #require(root["Displays"] as? [String: Any])
    #expect(Set(displays.keys) == [AerialLockScreenFixture.displayID])
    let activeSpace = try #require(
        spaces[AerialLockScreenFixture.activeSpaceID] as? [String: Any]
    )
    let activeDisplays = try #require(
        activeSpace["Displays"] as? [String: Any]
    )
    #expect(
        Set(activeDisplays.keys)
            == [AerialLockScreenFixture.displayID]
    )
    #expect(
        wallpaperStoreContains(
            root,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    #expect(!wallpaperStoreText(root).contains("last_frame"))
    #expect(!wallpaperStoreText(root).contains("AuraFlowLockScreen"))
}

@Test func modernLockScreenConfirmationRejectsAStaleWallpaperStore() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let originalStore = try Data(contentsOf: fixture.storeURL)
    try fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.installer.installationConfirmed)

    try originalStore.write(to: fixture.storeURL, options: .atomic)
    #expect(!fixture.installer.installationConfirmed)
}

@Test func modernLockScreenRecoversFromOneStaleWallpaperAgentFlush() throws {
    var staleStoreData: Data?
    let fixture = try AerialLockScreenFixture(onRefresh: { storeURL in
        try? staleStoreData?.write(to: storeURL, options: .atomic)
    })
    defer { fixture.cleanup() }
    staleStoreData = try Data(contentsOf: fixture.storeURL)

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.installer.installationConfirmed)
    #expect(fixture.refreshCounter.count == 1)
    let root = try readWallpaperStore(fixture.storeURL)
    #expect(wallpaperStoreContains(
        root,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
}

@Test func modernLockScreenOnlyPreservesDesktopRoute() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let root = try readWallpaperStore(fixture.storeURL)
    let allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    let idle = try #require(
        allSpacesAndDisplays["Idle"] as? [String: Any]
    )

    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.image",
        assetID: nil
    ))
    #expect(
        wallpaperStoreContains(
            idle,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    #expect(fixture.installer.installationConfirmed)
    #expect(fixture.refreshCounter.count == 1)
}

@Test func lockOnlyApplyKeepsLatestDesktopWhenSourceChanges() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModes(
        in: root,
        provider: "com.apple.wallpaper.choice.user-latest"
    )
    try writeWallpaperStore(root, to: fixture.storeURL)
    let latestDesktopRoutes = testDesktopRouteData(in: root)

    let secondVideoURL = fixture.root.appendingPathComponent("wallpaper-b.mp4")
    try Data("second-wallpaper".utf8).write(to: secondVideoURL)
    try fixture.installer.installLockScreenOnly(videoURL: secondVideoURL)

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == latestDesktopRoutes)
    #expect(fixture.refreshCounter.count == 1)
}

@Test func lockOnlyRepairRefreshesStaleAssetSignature() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    var marker = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as? [String: Any]
    )
    marker["assetSignature"] = "stale-asset-signature"
    try JSONSerialization.data(
        withJSONObject: marker,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: markerURL, options: .atomic)

    #expect(
        !fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid
    )

    _ = try fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )

    let repairedMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as? [String: Any]
    )
    #expect(repairedMarker["assetSignature"] as? String != "stale-asset-signature")
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid
    )
}

@Test func lockOnlyRepairRestoresDriftedIdleWithoutChangingDesktopRoutes() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let desktopBefore = testDesktopRouteData(in: root)

    // Simulate macOS replacing one Idle route with its own wallpaper after a
    // few lock/unlock cycles. The user Desktop remains the live source.
    var allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Idle"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.alternateAssetID]
    )
    root["AllSpacesAndDisplays"] = allSpaces
    try writeWallpaperStore(root, to: fixture.storeURL)

    let drifted = fixture.installer.lockScreenOnlyStatus(
        videoURL: fixture.videoURL
    )
    #expect(!drifted.wallpaperStoreValid)

    _ = try fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == desktopBefore)
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).wallpaperStoreValid
    )
    // The fixture uses a non-canonical provider, so repairing only Idle does
    // not restart a real WallpaperAgent.
    #expect(fixture.refreshCounter.count == 1)
}

@Test func lockOnlyRepairDoesNotOverwriteDesktopChangedDuringRepair() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    var allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Idle"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.alternateAssetID]
    )
    root["AllSpacesAndDisplays"] = allSpaces
    try writeWallpaperStore(root, to: fixture.storeURL)

    let latestDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: ["revision": 2]
    )
    root = try readWallpaperStore(fixture.storeURL)
    allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Desktop"] = latestDesktop
    root["AllSpacesAndDisplays"] = allSpaces
    let latestRoot = root
    fixture.installer.lockOnlyRepairCommitHook = {
        try? writeWallpaperStore(latestRoot, to: fixture.storeURL)
    }

    _ = try fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )
    root = try readWallpaperStore(fixture.storeURL)
    allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktopAfter = try #require(
        allSpaces["Desktop"] as? [String: Any]
    )
    #expect(wallpaperModeData(desktopAfter) == wallpaperModeData(latestDesktop))
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).wallpaperStoreValid == false
    )
}

@Test func linkedWallpaperNeverPromotesIntoDesktopDuringLockSession() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let userLinkedMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [:]
    )
    var linkedRoot = try readWallpaperStore(fixture.storeURL)
    let linkedContainer: [String: Any] = [
        "Type": "linked",
        "Linked": userLinkedMode,
    ]
    linkedRoot["AllSpacesAndDisplays"] = linkedContainer
    linkedRoot["SystemDefault"] = linkedContainer
    linkedRoot["Displays"] = [String: Any]()
    linkedRoot["Spaces"] = [String: Any]()
    try writeWallpaperStore(linkedRoot, to: fixture.storeURL)

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var root = try readWallpaperStore(fixture.storeURL)
    var container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    var desktop = try #require(container["Desktop"] as? [String: Any])
    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
    let idle = try #require(container["Idle"] as? [String: Any])
    #expect(wallpaperStoreContains(
        idle,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))

    let desktopBeforeLock = wallpaperModeData(desktop)
    let idleBeforeLock = wallpaperModeData(idle)
    let promoted = try fixture.installer
        .activateLockScreenForCurrentSession()
    #expect(promoted == false)
    root = try readWallpaperStore(fixture.storeURL)
    container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    desktop = try #require(container["Desktop"] as? [String: Any])
    let lockIdle = try #require(container["Idle"] as? [String: Any])
    #expect(wallpaperModeData(desktop) == desktopBeforeLock)
    #expect(wallpaperModeData(lockIdle) == idleBeforeLock)
    #expect(container["Type"] as? String == "individual")
    #expect(fixture.refreshCounter.count == 1)

    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    root = try readWallpaperStore(fixture.storeURL)
    container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    desktop = try #require(container["Desktop"] as? [String: Any])
    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
}

@Test func linkedWallpaperChangedByUserSurvivesLockOnlyRemove() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    let originalContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        ),
    ]
    root["AllSpacesAndDisplays"] = originalContainer
    root["SystemDefault"] = originalContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let latestContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sonoma",
            configuration: [:]
        ),
    ]
    root = try readWallpaperStore(fixture.storeURL)
    root["AllSpacesAndDisplays"] = latestContainer
    root["SystemDefault"] = latestContainer
    try writeWallpaperStore(root, to: fixture.storeURL)

    try fixture.installer.uninstall()

    root = try readWallpaperStore(fixture.storeURL)
    let restoredContainer = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredLinked = try #require(
        restoredContainer["Linked"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        restoredLinked,
        provider: "com.apple.wallpaper.choice.sonoma",
        assetID: nil
    ))
}

@Test func linkedWallpaperRemoveUsesCurrentDesktopNotOlderJournal() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    let originalContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        ),
    ]
    root["AllSpacesAndDisplays"] = originalContainer
    root["SystemDefault"] = originalContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var split = try #require(root[key] as? [String: Any])
        var latestDesktop = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sonoma",
            configuration: [:]
        )
        latestDesktop["LastSet"] = Date().addingTimeInterval(60)
        latestDesktop["LastUse"] = Date().addingTimeInterval(60)
        split["Desktop"] = latestDesktop
        root[key] = split
    }
    try writeWallpaperStore(root, to: fixture.storeURL)

    // Exercise the old journal path; it must not become authoritative for a
    // later Remove.
    _ = try fixture.installer.rearmForNextLock(videoURL: fixture.videoURL)

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var split = try #require(root[key] as? [String: Any])
        var staleDesktop = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        )
        staleDesktop["LastSet"] = Date().addingTimeInterval(-60)
        staleDesktop["LastUse"] = Date().addingTimeInterval(-60)
        split["Desktop"] = staleDesktop
        root[key] = split
    }
    try writeWallpaperStore(root, to: fixture.storeURL)

    _ = try fixture.installer.activateLockScreenForCurrentSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let split = try #require(root[key] as? [String: Any])
        let desktop = try #require(split["Desktop"] as? [String: Any])
        #expect(wallpaperStoreContains(
            desktop,
            provider: "com.apple.wallpaper.choice.sequoia",
            assetID: nil
        ))
    }

    // Simulate a journal written by an older build that accidentally kept
    // Aura's managed Idle route next to the newest user Desktop.
    try Data(contentsOf: fixture.storeURL).write(
        to: fixture.stateURL
            .appendingPathComponent("Index.latest-user.plist"),
        options: .atomic
    )

    try fixture.installer.uninstall()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let restored = try #require(root[key] as? [String: Any])
        #expect(restored["Type"] as? String == "linked")
        #expect(restored["Desktop"] == nil)
        #expect(restored["Idle"] == nil)
        let linked = try #require(restored["Linked"] as? [String: Any])
        #expect(wallpaperStoreContains(
            linked,
            provider: "com.apple.wallpaper.choice.sequoia",
            assetID: nil
        ))
    }
}

@Test func latestUserAerialResolvesItsSystemWallpaperURL() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let userAssetID = "44166C39-8566-4ECA-BD16-43159429B52F"
    let userMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": userAssetID]
    )
    let container: [String: Any] = [
        "Type": "linked",
        "Linked": userMode,
    ]
    let root: [String: Any] = [
        "AllSpacesAndDisplays": container,
        "SystemDefault": container,
        "Displays": [String: Any](),
        "Spaces": [String: Any](),
    ]
    try writeWallpaperStore(root, to: fixture.storeURL)

    let resolved = fixture.installer.latestUserSystemWallpaperURL(
        from: try Data(contentsOf: fixture.storeURL),
        managedAssetID: AerialLockScreenFixture.assetID
    )

    #expect(
        resolved
            == fixture.videosURL
                .appendingPathComponent(userAssetID)
                .appendingPathExtension("mov")
                .standardizedFileURL.absoluteString
    )
}

@Test func lockOnlyRemoveMirrorsTheLiveDesktopWithoutReplayingSnapshots() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    // Exercise many user changes while Aura remains installed. Only the last
    // live Desktop route is allowed to matter to Remove.
    for revision in 1...100 {
        var root = try readWallpaperStore(fixture.storeURL)
        root = replaceTestDesktopModes(
            in: root,
            provider: "com.apple.wallpaper.choice.user-\(revision)"
        )
        try writeWallpaperStore(root, to: fixture.storeURL)
    }

    let refreshCountBeforeRemove = fixture.refreshCounter.count
    let raceProvider = "com.apple.wallpaper.choice.user-race-winner"
    var hookCalls = 0
    fixture.installer.lockOnlyRemovalCommitHook = {
        hookCalls += 1
        guard hookCalls == 1,
              var root = try? readWallpaperStore(fixture.storeURL)
        else {
            return
        }
        root = replaceTestDesktopModes(
            in: root,
            provider: raceProvider
        )
        try? writeWallpaperStore(root, to: fixture.storeURL)
    }

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    let root = try readWallpaperStore(fixture.storeURL)
    let containers = testWallpaperContainers(in: root)
    #expect(!containers.isEmpty)
    for container in containers {
        if (container["Type"] as? String) == "linked" {
            let linked = try #require(
                container["Linked"] as? [String: Any]
            )
            #expect(wallpaperStoreContains(
                linked,
                provider: raceProvider,
                assetID: nil
            ))
            continue
        }
        let desktop = try #require(
            container["Desktop"] as? [String: Any]
        )
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(idle))
        #expect(wallpaperStoreContains(
            desktop,
            provider: raceProvider,
            assetID: nil
        ))
    }
    #expect(!wallpaperStoreContains(
        root,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
    #expect(hookCalls >= 2)
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
    #expect(!fixture.installer.isInstalled)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
}

@Test func lockOnlyRemoveKeepsAnAlreadyLinkedUserRoute() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let linkedMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sonoma",
        configuration: [:]
    )
    let linkedContainer: [String: Any] = [
        "Type": "linked",
        "Linked": linkedMode,
    ]
    root["AllSpacesAndDisplays"] = linkedContainer
    root["SystemDefault"] = linkedContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedMode = wallpaperModeData(linkedMode)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(root[key] as? [String: Any])
        let linked = try #require(
            container["Linked"] as? [String: Any]
        )
        #expect(wallpaperModeData(linked) == expectedMode)
        #expect(container["Desktop"] == nil)
        #expect(container["Idle"] == nil)
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
}

@Test func lockOnlyRemoveAcceptsRestoredWallpaperAsCurrentDesktop() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let restoredDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.image",
        configuration: [
            "type": "imageFile",
            "url": [
                "relative":
                    "file:///Users/test/Library/Application%20Support/"
                    + "AuraFlow/Restored%20Wallpapers/current.jpeg",
            ],
        ]
    )
    let expectedMode = wallpaperModeData(restoredDesktop)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = restoredDesktop
        root[key] = container
    }
    try writeWallpaperStore(root, to: fixture.storeURL)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(root[key] as? [String: Any])
        let desktop = try #require(
            container["Desktop"] as? [String: Any]
        )
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == expectedMode)
        #expect(wallpaperModeData(idle) == expectedMode)
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
    #expect(!fixture.installer.isInstalled)
}

@Test func lockOnlyRemovePreservesDistinctSpaceAndDisplayDesktops() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    #expect(expectedDesktopRoutes.count > 2)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    for container in testWallpaperContainers(in: root) {
        guard let desktop = container["Desktop"] as? [String: Any]
        else { continue }
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(idle))
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
}

@Test func lockOnlyRemoveNeverReplaysBackupWhenMarkerIsCorrupt() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let liveDesktopStore = try Data(contentsOf: fixture.storeURL)
    try Data("{broken-marker".utf8).write(
        to: fixture.stateURL.appendingPathComponent("installation.json"),
        options: .atomic
    )

    #expect(throws: AerialLockScreenInstallerError.self) {
        try fixture.installer
            .uninstallLockScreenOnlyPreservingCurrentDesktop()
    }
    #expect(try Data(contentsOf: fixture.storeURL) == liveDesktopStore)
}

@Test func modernLockScreenOnlyNeverMutatesDesktopAtSessionBoundary() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    #expect(fixture.installer.isLockScreenOnlyInstallation)

    var root = try readWallpaperStore(fixture.storeURL)
    var allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktopBeforeLock = wallpaperModeData(
        try #require(allSpacesAndDisplays["Desktop"] as? [String: Any])
    )

    let promoted = try fixture.installer
        .activateLockScreenForCurrentSession()
    #expect(promoted == false)
    #expect(fixture.refreshCounter.count == 1)
    root = try readWallpaperStore(fixture.storeURL)
    allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let lockDesktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    #expect(wallpaperModeData(lockDesktop) == desktopBeforeLock)

    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    root = try readWallpaperStore(fixture.storeURL)
    allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    #expect(wallpaperModeData(restoredDesktop) == desktopBeforeLock)
    #expect(fixture.installer.isLockScreenOnlyInstallation)
}

@Test func modernLockScreenOnlyRestoresLatestUserDesktopRoute() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    var changedContainer = try #require(
        changedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    var changedDesktop = try #require(
        changedContainer["Desktop"] as? [String: Any]
    )
    var changedContent = try #require(
        changedDesktop["Content"] as? [String: Any]
    )
    var changedChoices = try #require(
        changedContent["Choices"] as? [[String: Any]]
    )
    changedChoices[0]["Provider"] = "com.apple.wallpaper.choice.sequoia"
    changedChoices[0]["Configuration"] = Data()
    changedChoices[0]["Files"] = []
    changedContent["Choices"] = changedChoices
    changedDesktop["Content"] = changedContent
    changedContainer["Desktop"] = changedDesktop
    changedRoot["AllSpacesAndDisplays"] = changedContainer
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)

    _ = try fixture.installer.activateLockScreenForCurrentSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    let restoredContainer = try #require(
        restoredRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        restoredContainer["Desktop"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        restoredDesktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
}

@Test func lockOnlyRestoreDoesNotReplaySnapshotWithoutActiveLock() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    var changedContainer = try #require(
        changedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    changedContainer["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [:]
    )
    changedRoot["AllSpacesAndDisplays"] = changedContainer
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)
    let userStoreData = try Data(contentsOf: fixture.storeURL)

    let restored = try fixture.installer
        .restoreDesktopAfterLockScreenSession()

    #expect(!restored)
    #expect(try Data(contentsOf: fixture.storeURL) == userStoreData)
}

@Test func modernLockScreenOnlyUninstallKeepsDesktopChangedByUser() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    func withDesktop(_ value: Any?, provider: String) throws -> [String: Any] {
        var container = try #require(value as? [String: Any])
        container["Desktop"] = AerialLockScreenFixture.makeMode(
            provider: provider,
            configuration: [:]
        )
        return container
    }
    changedRoot["AllSpacesAndDisplays"] = try withDesktop(
        changedRoot["AllSpacesAndDisplays"],
        provider: "com.apple.wallpaper.choice.sequoia"
    )
    var mixedSystemDefault = try #require(
        changedRoot["SystemDefault"] as? [String: Any]
    )
    mixedSystemDefault["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.assetID]
    )
    changedRoot["SystemDefault"] = mixedSystemDefault
    var changedDisplays = try #require(
        changedRoot["Displays"] as? [String: Any]
    )
    changedDisplays[AerialLockScreenFixture.displayID] = try withDesktop(
        changedDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.sonoma"
    )
    changedRoot["Displays"] = changedDisplays
    var changedSpaces = try #require(
        changedRoot["Spaces"] as? [String: Any]
    )
    var changedSpace = try #require(
        changedSpaces[AerialLockScreenFixture.activeSpaceID]
            as? [String: Any]
    )
    changedSpace["Default"] = try withDesktop(
        changedSpace["Default"],
        provider: "com.apple.wallpaper.choice.monterey"
    )
    var changedSpaceDisplays = try #require(
        changedSpace["Displays"] as? [String: Any]
    )
    changedSpaceDisplays[AerialLockScreenFixture.displayID] = try withDesktop(
        changedSpaceDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.big-sur"
    )
    changedSpace["Displays"] = changedSpaceDisplays
    changedSpaces[AerialLockScreenFixture.activeSpaceID] = changedSpace
    changedRoot["Spaces"] = changedSpaces
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)

    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    func expectDesktop(_ value: Any?, provider: String) throws {
        let container = try #require(value as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(wallpaperStoreContains(
            desktop,
            provider: provider,
            assetID: nil
        ))
    }
    let restoredContainer = try #require(
        restoredRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    try expectDesktop(
        restoredContainer,
        provider: "com.apple.wallpaper.choice.sequoia"
    )
    try expectDesktop(
        restoredRoot["SystemDefault"],
        provider: "com.apple.wallpaper.choice.image"
    )
    let restoredDisplays = try #require(
        restoredRoot["Displays"] as? [String: Any]
    )
    try expectDesktop(
        restoredDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.sonoma"
    )
    let restoredSpaces = try #require(
        restoredRoot["Spaces"] as? [String: Any]
    )
    let restoredSpace = try #require(
        restoredSpaces[AerialLockScreenFixture.activeSpaceID]
            as? [String: Any]
    )
    try expectDesktop(
        restoredSpace["Default"],
        provider: "com.apple.wallpaper.choice.monterey"
    )
    let restoredSpaceDisplays = try #require(
        restoredSpace["Displays"] as? [String: Any]
    )
    try expectDesktop(
        restoredSpaceDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.big-sur"
    )
    let restoredIdle = try #require(restoredContainer["Idle"] as? [String: Any])
    #expect(wallpaperStoreContains(
        restoredIdle,
        provider: "com.apple.wallpaper.choice.screen-saver",
        assetID: nil
    ))
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
}

@Test func modernLockScreenUninstallRestoresCleanStoreAndAerialAsset() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackup = try Data(
        contentsOf: fixture.stateURL
            .appendingPathComponent("Index.before-auraflow.plist")
    )
    try fixture.installer.uninstall()

    #expect(!fixture.installer.isInstalled)
    #expect(try Data(contentsOf: fixture.storeURL) == exactStoreBackup)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
    let root = try readWallpaperStore(fixture.storeURL)
    #expect(!wallpaperStoreText(root).contains("last_frame"))
    #expect(!wallpaperStoreText(root).contains("AuraFlowLockScreen"))
    #expect(
        wallpaperStoreContains(
            root,
            provider: "com.apple.wallpaper.choice.screen-saver",
            assetID: nil
        )
    )
}

@Test func healthyModernLockScreenSyncIsANoOp() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 1)

    try fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 1)
    #expect(
        wallpaperChoiceProviders(try readWallpaperStore(fixture.storeURL))
            == Array(
                repeating: "com.apple.wallpaper.choice.aerials",
                count: wallpaperChoiceProviders(
                    try readWallpaperStore(fixture.storeURL)
                ).count
            )
    )
}

@Test func modernLockScreenRearmsProviderAfterEveryUnlock() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackupURL = fixture.stateURL
        .appendingPathComponent("Index.before-auraflow.plist")
    let exactStoreBackup = try Data(contentsOf: exactStoreBackupURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)

    for expectedRefreshCount in 2...12 {
        try fixture.installer.rearmForNextLock(
            videoURL: fixture.videoURL
        )
        #expect(
            fixture.refreshCounter.count == expectedRefreshCount
        )
        #expect(
            try Data(contentsOf: exactStoreBackupURL)
                == exactStoreBackup
        )
        #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
        #expect(
            try Data(contentsOf: fixture.assetURL)
                == Data("new-wallpaper".utf8)
        )
        let providers = wallpaperChoiceProviders(
            try readWallpaperStore(fixture.storeURL)
        )
        #expect(!providers.isEmpty)
        #expect(
            providers.allSatisfy {
                $0 == "com.apple.wallpaper.choice.aerials"
            }
        )
    }
}

@Test func cancelledModernLockScreenRearmDoesNotRefreshProvider() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)

    let didRearm = try fixture.installer.rearmForNextLock(
        videoURL: fixture.videoURL,
        shouldProceed: { false }
    )

    #expect(!didRearm)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
}

@Test func lockDuringModernLockScreenRepairRollsBackWithoutRefresh() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)
    let tamperedAsset = Data("tampered-during-session".utf8)
    try tamperedAsset.write(to: fixture.assetURL, options: .atomic)
    let gate = AerialProceedGate(allowedCalls: 1)

    let didRepair = try fixture.installer.repair(
        videoURL: fixture.videoURL,
        shouldProceed: gate.shouldProceed
    )

    #expect(!didRepair)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(try Data(contentsOf: fixture.assetURL) == tamperedAsset)
}

@Test func cancellationAfterJournalDoesNotTouchSystemFiles() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)
    let tamperedAsset = Data("tampered-before-journal-cancel".utf8)
    try tamperedAsset.write(to: fixture.assetURL, options: .atomic)
    let sentinelDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
        [.modificationDate: sentinelDate],
        ofItemAtPath: fixture.storeURL.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: sentinelDate],
        ofItemAtPath: fixture.assetURL.path
    )
    let gate = AerialProceedGate(allowedCalls: 2)

    let didRepair = try fixture.installer.repair(
        videoURL: fixture.videoURL,
        shouldProceed: gate.shouldProceed
    )

    let storeAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.storeURL.path
    )
    let assetAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.assetURL.path
    )
    #expect(!didRepair)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(try Data(contentsOf: fixture.assetURL) == tamperedAsset)
    #expect(storeAttributes[.modificationDate] as? Date == sentinelDate)
    #expect(assetAttributes[.modificationDate] as? Date == sentinelDate)
}

@Test func modernLockScreenRepairsTamperedAssetAndStore() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    try Data(repeating: 0x5A, count: 13).write(
        to: fixture.assetURL,
        options: .atomic
    )

    var root = try readWallpaperStore(fixture.storeURL)
    var systemDefault = try #require(
        root["SystemDefault"] as? [String: Any]
    )
    systemDefault["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.image",
        configuration: [
            "type": "imageFile",
            "url": ["relative": "file:///tampered.jpg"],
        ]
    )
    root["SystemDefault"] = systemDefault
    try writeWallpaperStore(root, to: fixture.storeURL)

    try fixture.installer.install(videoURL: fixture.videoURL)

    #expect(fixture.refreshCounter.count == 2)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
    let repairedProviders = wallpaperChoiceProviders(
        try readWallpaperStore(fixture.storeURL)
    )
    #expect(!repairedProviders.isEmpty)
    #expect(
        repairedProviders.allSatisfy {
            $0 == "com.apple.wallpaper.choice.aerials"
        }
    )
}

@Test func modernLockScreenCreatesAndRemovesReservedAssetOnFreshMac() throws {
    let fixture = try AerialLockScreenFixture(hasExistingAsset: false)
    defer { fixture.cleanup() }

    #expect(fixture.installer.isAvailable)
    #expect(!FileManager.default.fileExists(atPath: fixture.assetURL.path))

    try fixture.installer.install(videoURL: fixture.videoURL)
    #expect(FileManager.default.fileExists(atPath: fixture.assetURL.path))
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )

    try fixture.installer.uninstall()
    #expect(!FileManager.default.fileExists(atPath: fixture.assetURL.path))
}

@Test func lockOnlyUsesFreeSlotsAndRotatesAfterRemove() throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        providerAssetIDs: [
            AerialLockScreenFixture.assetID,
            AerialLockScreenFixture.alternateAssetID,
            AerialLockScreenFixture.secondAlternateAssetID,
        ],
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    let originalSystemAsset = try Data(contentsOf: fixture.assetURL)
    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let firstMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    let firstAssetID = try #require(firstMarker["assetID"] as? String)
    #expect(firstAssetID != AerialLockScreenFixture.assetID)
    #expect(try Data(contentsOf: fixture.assetURL) == originalSystemAsset)

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()
    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let secondMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    let secondAssetID = try #require(secondMarker["assetID"] as? String)
    #expect(secondAssetID != firstAssetID)
    #expect(secondAssetID != AerialLockScreenFixture.assetID)
    #expect(try Data(contentsOf: fixture.assetURL) == originalSystemAsset)
}

@Test func lockOnlyCanUseCatalogThumbnailWithoutReplacingUserAerialMovie() throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        providerAssetIDs: [
            AerialLockScreenFixture.assetID,
            AerialLockScreenFixture.alternateAssetID,
        ],
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    let catalogThumbnail = fixture.thumbnailsURL
        .appendingPathComponent(AerialLockScreenFixture.alternateAssetID)
        .appendingPathExtension("png")
    try Data("catalog-thumbnail".utf8).write(to: catalogThumbnail)
    let originalSystemAsset = try Data(contentsOf: fixture.assetURL)

    try fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let marker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    #expect(marker["assetID"] as? String == AerialLockScreenFixture.alternateAssetID)
    #expect(try Data(contentsOf: fixture.assetURL) == originalSystemAsset)

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()
    #expect(try Data(contentsOf: catalogThumbnail) == Data("catalog-thumbnail".utf8))
}

@Test func modernLockScreenRejectsProviderWithoutReservedAsset() throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: false,
        providerHasAsset: false
    )
    defer { fixture.cleanup() }

    #expect(!fixture.installer.isAvailable)
    #expect(throws: AerialLockScreenInstallerError.self) {
        try fixture.installer.install(videoURL: fixture.videoURL)
    }
}

@Test func modernProviderRemovalInvalidatesAvailability() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    #expect(fixture.installer.isAvailable)
    try FileManager.default.removeItem(at: fixture.providerURL)

    #expect(fixture.installer.isAvailable == false)
}

@Test func lockOnlyFailsWithoutOverwritingWhenEverySlotIsOccupied() throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    let storeBefore = try Data(contentsOf: fixture.storeURL)
    let assetBefore = try Data(contentsOf: fixture.assetURL)
    #expect(fixture.installer.isAvailable)
    #expect(throws: AerialLockScreenInstallerError.self) {
        try fixture.installer.installLockScreenOnly(
            videoURL: fixture.videoURL
        )
    }
    #expect(try Data(contentsOf: fixture.storeURL) == storeBefore)
    #expect(try Data(contentsOf: fixture.assetURL) == assetBefore)
}

@Test func incompleteModernLockScreenJournalIsRetried() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    let markerData = try Data(contentsOf: markerURL)
    var marker = try #require(
        JSONSerialization.jsonObject(with: markerData)
            as? [String: Any]
    )
    marker["completed"] = false
    try JSONSerialization.data(
        withJSONObject: marker,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: markerURL, options: .atomic)

    try fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 2)
    let completedData = try Data(contentsOf: markerURL)
    let completedMarker = try #require(
        JSONSerialization.jsonObject(with: completedData)
            as? [String: Any]
    )
    #expect(completedMarker["completed"] as? Bool == true)
}

@Test func corruptModernLockScreenMarkerStillRestoresBackup() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackup = try Data(
        contentsOf: fixture.stateURL
            .appendingPathComponent("Index.before-auraflow.plist")
    )
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    try Data("{not-json".utf8).write(
        to: markerURL,
        options: .atomic
    )

    try fixture.installer.uninstall()

    #expect(!fixture.installer.isInstalled)
    #expect(try Data(contentsOf: fixture.storeURL) == exactStoreBackup)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
}

private func readWallpaperStore(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    )
}

private func writeWallpaperStore(
    _ root: [String: Any],
    to url: URL
) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )
    try data.write(to: url, options: .atomic)
}

private func replaceTestDesktopModes(
    in root: [String: Any],
    provider: String
) -> [String: Any] {
    var result = root
    let mode = AerialLockScreenFixture.makeMode(
        provider: provider,
        configuration: [:]
    )
    func replace(_ value: Any) -> Any {
        guard var container = value as? [String: Any] else {
            return value
        }
        if container["Desktop"] != nil {
            container["Desktop"] = mode
        } else if container["Linked"] != nil {
            container["Linked"] = mode
        }
        return container
    }

    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        if let value = result[key] {
            result[key] = replace(value)
        }
    }
    if let displays = result["Displays"] as? [String: Any] {
        result["Displays"] = displays.mapValues(replace)
    }
    if let spaces = result["Spaces"] as? [String: Any] {
        result["Spaces"] = spaces.mapValues { value in
            guard var space = value as? [String: Any] else {
                return value
            }
            if let defaultValue = space["Default"] {
                space["Default"] = replace(defaultValue)
            }
            if let displays = space["Displays"] as? [String: Any] {
                space["Displays"] = displays.mapValues(replace)
            }
            return space
        }
    }
    return result
}

private func testWallpaperContainers(
    in root: [String: Any]
) -> [[String: Any]] {
    var result: [[String: Any]] = []
    func append(_ value: Any?) {
        if let container = value as? [String: Any] {
            result.append(container)
        }
    }
    append(root["AllSpacesAndDisplays"])
    append(root["SystemDefault"])
    if let displays = root["Displays"] as? [String: Any] {
        for value in displays.values { append(value) }
    }
    if let spaces = root["Spaces"] as? [String: Any] {
        for value in spaces.values {
            guard let space = value as? [String: Any] else { continue }
            append(space["Default"])
            if let displays = space["Displays"] as? [String: Any] {
                for display in displays.values { append(display) }
            }
        }
    }
    return result
}

private func replaceTestDesktopModesDistinctly(
    in root: [String: Any]
) -> [String: Any] {
    var result = root
    var revision = 0
    func replace(_ value: Any) -> Any {
        guard var container = value as? [String: Any] else {
            return value
        }
        revision += 1
        let mode = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.route-\(revision)",
            configuration: [:]
        )
        if container["Desktop"] != nil {
            container["Desktop"] = mode
        } else if container["Linked"] != nil {
            container["Linked"] = mode
        }
        return container
    }
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        if let value = result[key] { result[key] = replace(value) }
    }
    if var displays = result["Displays"] as? [String: Any] {
        for key in displays.keys.sorted() {
            if let value = displays[key] { displays[key] = replace(value) }
        }
        result["Displays"] = displays
    }
    if var spaces = result["Spaces"] as? [String: Any] {
        for spaceID in spaces.keys.sorted() {
            guard var space = spaces[spaceID] as? [String: Any] else {
                continue
            }
            if let value = space["Default"] {
                space["Default"] = replace(value)
            }
            if var displays = space["Displays"] as? [String: Any] {
                for displayID in displays.keys.sorted() {
                    if let value = displays[displayID] {
                        displays[displayID] = replace(value)
                    }
                }
                space["Displays"] = displays
            }
            spaces[spaceID] = space
        }
        result["Spaces"] = spaces
    }
    return result
}

private func testDesktopRouteData(
    in root: [String: Any]
) -> [String: Data] {
    var result: [String: Data] = [:]
    func append(_ path: String, _ value: Any?) {
        guard let container = value as? [String: Any] else { return }
        let key = container["Desktop"] != nil ? "Desktop" : "Linked"
        guard let mode = container[key] as? [String: Any],
              let data = wallpaperModeData(mode)
        else { return }
        result[path + "." + key] = data
    }
    append("AllSpacesAndDisplays", root["AllSpacesAndDisplays"])
    append("SystemDefault", root["SystemDefault"])
    if let displays = root["Displays"] as? [String: Any] {
        for key in displays.keys.sorted() {
            append("Displays.\(key)", displays[key])
        }
    }
    if let spaces = root["Spaces"] as? [String: Any] {
        for spaceID in spaces.keys.sorted() {
            guard let space = spaces[spaceID] as? [String: Any] else {
                continue
            }
            append("Spaces.\(spaceID).Default", space["Default"])
            if let displays = space["Displays"] as? [String: Any] {
                for displayID in displays.keys.sorted() {
                    append(
                        "Spaces.\(spaceID).Displays.\(displayID)",
                        displays[displayID]
                    )
                }
            }
        }
    }
    return result
}

private func wallpaperModeData(_ mode: [String: Any]) -> Data? {
    try? PropertyListSerialization.data(
        fromPropertyList: mode,
        format: .xml,
        options: 0
    )
}

private func wallpaperChoiceProviders(_ value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        var providers: [String] = []
        if let provider = dictionary["Provider"] as? String {
            providers.append(provider)
        }
        for nestedValue in dictionary.values {
            providers.append(
                contentsOf: wallpaperChoiceProviders(nestedValue)
            )
        }
        return providers
    }
    if let array = value as? [Any] {
        return array.flatMap(wallpaperChoiceProviders)
    }
    return []
}

private func wallpaperStoreContains(
    _ value: Any,
    provider: String,
    assetID: String?
) -> Bool {
    if let dictionary = value as? [String: Any] {
        if dictionary["Provider"] as? String == provider {
            guard let assetID else { return true }
            guard let data = dictionary["Configuration"] as? Data,
                  let configuration =
                    try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    ) as? [String: Any]
            else {
                return false
            }
            return configuration["assetID"] as? String == assetID
        }
        return dictionary.values.contains {
            wallpaperStoreContains(
                $0,
                provider: provider,
                assetID: assetID
            )
        }
    }
    if let array = value as? [Any] {
        return array.contains {
            wallpaperStoreContains(
                $0,
                provider: provider,
                assetID: assetID
            )
        }
    }
    return false
}

private func wallpaperStoreText(_ value: Any) -> String {
    if let string = value as? String {
        return string
    }
    if let data = value as? Data,
       let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
       ) {
        return wallpaperStoreText(propertyList)
    }
    if let dictionary = value as? [String: Any] {
        return dictionary
            .map { wallpaperStoreText($0.key) + wallpaperStoreText($0.value) }
            .joined(separator: " ")
    }
    if let array = value as? [Any] {
        return array.map(wallpaperStoreText).joined(separator: " ")
    }
    return String(describing: value)
}
