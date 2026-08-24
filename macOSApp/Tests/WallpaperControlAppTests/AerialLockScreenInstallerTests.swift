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
        providerHasAsset: Bool = true
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
                    ? [["id": Self.assetID]]
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
        installer = AerialLockScreenInstaller(
            fileManager: .default,
            wallpaperStoreURL: storeURL,
            spacesPreferencesURL: spacesURL,
            aerialVideosURL: videosURL,
            aerialThumbnailsURL: thumbnailsURL,
            aerialProviderURL: providerURL,
            stateDirectoryURL: stateURL,
            assetID: Self.assetID,
            refreshSystem: {
                counter.increment()
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
