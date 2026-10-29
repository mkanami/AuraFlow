import Foundation
import Testing
@testable import AuraWallpaperCore

private func ownershipMode(_ provider: String, configuration: [String: Any] = [:], options: Data? = nil) throws -> [String: Any] {
    ["Content": ["Choices": [["Provider": provider, "Files": [],
        "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)]],
        "EncodedOptionValues": options ?? Data()]]
}

@Test func missingUserWallpaperMustNeverInventStoneOrVentura() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraOwnership-\(UUID())")
    let transaction = WallpaperStoreTransaction(wallpaperStoreURL: root.appendingPathComponent("Index.plist"),
        spacesPreferencesURL: root.appendingPathComponent("spaces.plist"))
    let desktop = try ownershipMode(WallpaperPlatformConstants.imageProviderID,
        configuration: ["url": ["relative": "file:///Users/test/AuraFlow/last_frame.png"]])
    let idle = try ownershipMode(WallpaperPlatformConstants.screenSaverProviderID,
        configuration: ["module": ["relative": "file:///Users/test/Library/Screen%20Savers/AuraFlowLockScreen.saver"]])
    let data = try PropertyListSerialization.data(fromPropertyList: ["SystemDefault": ["Desktop": desktop, "Idle": idle]], format: .binary, options: 0)
    #expect(throws: (any Error).self) { try transaction.cleanedWallpaperStoreData(from: data) }
}

@Test func fallbackKeepsTheUsersCompleteAutomaticAppearanceDescriptor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraAppearance-\(UUID())")
    let transaction = WallpaperStoreTransaction(wallpaperStoreURL: root.appendingPathComponent("Index.plist"),
        spacesPreferencesURL: root.appendingPathComponent("spaces.plist"))
    let options = try PropertyListSerialization.data(fromPropertyList: ["values": ["appearance": "automatic", "customOption": "keep"]], format: .binary, options: 0)
    let user = try ownershipMode("com.apple.wallpaper.choice.sequoia", options: options)
    let aura = try ownershipMode(WallpaperPlatformConstants.screenSaverProviderID,
        configuration: ["module": ["relative": "file:///Users/test/Library/Screen%20Savers/AuraFlowLockScreen.saver"]])
    let data = try PropertyListSerialization.data(fromPropertyList: ["SystemDefault": ["Desktop": user, "Idle": aura]], format: .binary, options: 0)
    let result = try transaction.cleanedWallpaperStoreData(from: data)
    let decoded = try #require(try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: [String: Any]])
    #expect((decoded["SystemDefault"]?["Desktop"] as? NSDictionary)?.isEqual(user) == true)
    #expect((decoded["SystemDefault"]?["Idle"] as? NSDictionary)?.isEqual(user) == true)
}

@Test func auraIdleDoesNotAuthorizeRepairingTheUsersAutomaticSequoiaDesktop() throws {
    let user = try ownershipMode("com.apple.wallpaper.choice.sequoia",
        options: PropertyListSerialization.data(fromPropertyList: ["values": ["appearance": "automatic"]], format: .binary, options: 0))
    let aura = try ownershipMode(WallpaperPlatformConstants.screenSaverProviderID,
        configuration: ["module": ["relative": "file:///Users/test/Library/Screen%20Savers/AuraFlowLockScreen.saver"]])
    let root: [String: Any] = ["SystemDefault": ["Desktop": user, "Idle": aura]]
    #expect(!WallpaperDesktopSupport.hasManagedDesktopReferences(in: root))
    #expect(WallpaperDesktopSupport.recordedUserDesktopImageURL(in: root) == nil)
}

@Test func desktopRepairCannotSelectAnUnrelatedImageFromWallpaperMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraKnownWallpaper-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let unrelated = root.appendingPathComponent("unused-system-thumbnail.png")
    let selected = root.appendingPathComponent("DefaultDesktop-user-photo.png")
    try Data("image".utf8).write(to: unrelated)
    try Data("image".utf8).write(to: selected)
    let user = try ownershipMode("com.apple.wallpaper.choice.sequoia")
    let native: [String: Any] = ["SystemDefault": ["Desktop": user], "Thumbnail": unrelated.absoluteString]
    #expect(WallpaperDesktopSupport.recordedUserDesktopImageURL(in: native) == nil)
    let image = try ownershipMode(WallpaperPlatformConstants.imageProviderID,
        configuration: ["url": ["relative": selected.absoluteString]])
    #expect(WallpaperDesktopSupport.recordedUserDesktopImageURL(in: ["SystemDefault": ["Desktop": image]]) == selected)
}

@Test func aSystemPreviewFileIsNotEvidenceOfTheUsersWallpaperSelection() throws {
    let placeholder = try ownershipMode(WallpaperPlatformConstants.imageProviderID,
        configuration: ["url": ["relative": "file:///System/Library/CoreServices/DefaultDesktop.heic"]])
    #expect(WallpaperDesktopSupport.recordedUserDesktopImageURL(in: ["SystemDefault": ["Desktop": placeholder]]) == nil)
}

@Test func changingOnlyAppearanceWhileAuraIsSuspendedIsPreservedAsAUserChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraAppearanceLease-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = root.appendingPathComponent("Index.plist"), journal = root.appendingPathComponent("journal.json")
    let saver = root.appendingPathComponent("AuraFlowLockScreen.saver")
    let user = try ownershipMode("com.apple.wallpaper.choice.sequoia",
        options: PropertyListSerialization.data(fromPropertyList: ["values": ["appearance": "automatic"]], format: .binary, options: 0))
    let aura = try ownershipMode(WallpaperPlatformConstants.screenSaverProviderID,
        configuration: ["module": ["relative": saver.absoluteString]])
    func save(_ idle: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: ["SystemDefault": ["Desktop": user, "Idle": idle]], format: .binary, options: 0).write(to: store)
    }
    try save(aura)
    try Data("{\"routes\":[]}".utf8).write(to: journal)
    let recovery = ScreenSaverRouteRecovery(storeURL: store, journalURL: journal, saverURL: saver)
    #expect(try recovery.suspendIfNeeded(shouldProceed: { true }))
    let changed = try ownershipMode("com.apple.wallpaper.choice.sequoia",
        options: PropertyListSerialization.data(fromPropertyList: ["values": ["appearance": "dark"]], format: .binary, options: 0))
    try save(changed)
    let selected = try Data(contentsOf: store)
    #expect(try !recovery.recoverIfNeeded())
    #expect(try Data(contentsOf: store) == selected)
}

@Test func systemDefaultPreviewCannotReplaceTheLastRecordedAutomaticUserProvider() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNativeUser-\(UUID())")
    let transaction = WallpaperStoreTransaction(wallpaperStoreURL: root.appendingPathComponent("Index.plist"),
        spacesPreferencesURL: root.appendingPathComponent("spaces.plist"))
    let user = try ownershipMode("com.apple.wallpaper.choice.sequoia",
        options: PropertyListSerialization.data(fromPropertyList: ["values": ["appearance": "automatic"]], format: .binary, options: 0))
    let preview = try ownershipMode(WallpaperPlatformConstants.imageProviderID,
        configuration: ["url": ["relative": "file:///System/Library/CoreServices/DefaultDesktop.heic"]])
    let aura = try ownershipMode(WallpaperPlatformConstants.aerialProviderID, configuration: ["assetID": "aura-slot"])
    func data(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
    let original = try data(["AllSpacesAndDisplays": ["Desktop": user, "Idle": user], "SystemDefault": ["Desktop": user, "Idle": user]])
    let current = try data(["AllSpacesAndDisplays": ["Desktop": aura, "Idle": aura], "SystemDefault": ["Desktop": preview, "Idle": aura]])
    let restored = try transaction.wallpaperStoreDataByPreservingUserDesktops(from: current,
        restoringManagedModesFrom: original, managedAssetID: "aura-slot", propagateGlobalDesktopChanges: true)
    let decoded = try #require(try PropertyListSerialization.propertyList(from: restored, format: nil) as? [String: [String: Any]])
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        #expect((decoded[key]?["Desktop"] as? NSDictionary)?.isEqual(user) == true)
    }
    #expect(WallpaperDesktopSupport.isUserWallpaperMode(user))
    #expect(!WallpaperDesktopSupport.isUserWallpaperMode(preview))
}
