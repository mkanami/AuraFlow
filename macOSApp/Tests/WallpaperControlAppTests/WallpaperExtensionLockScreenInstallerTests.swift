import Foundation
import Testing
@testable import WallpaperControlApp

private struct WallpaperExtensionFixture {
    let root: URL
    let storeURL: URL
    let extensionURL: URL
    let documentsURL: URL
    let backupURL: URL
    let videoURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowWallpaperExtension-\(UUID().uuidString)", isDirectory: true)
        storeURL = root.appendingPathComponent("Index.plist")
        extensionURL = root.appendingPathComponent("AuraFlowWallpaperExtension.appex", isDirectory: true)
        documentsURL = root.appendingPathComponent("container/Documents", isDirectory: true)
        backupURL = root.appendingPathComponent("idle-backup.plist")
        videoURL = root.appendingPathComponent("lock.mov")

        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: videoURL.path, contents: Data("video".utf8))

        let original = [
            "SystemDefault": [
                "Desktop": ["Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [["relative": "file:///original-desktop.jpg"]],
                ]]]],
                "Idle": ["Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Configuration": Data("original-aerial".utf8),
                ]]]],
            ],
        ] as [String: Any]
        let data = try PropertyListSerialization.data(
            fromPropertyList: original,
            format: .binary,
            options: 0
        )
        try data.write(to: storeURL, options: .atomic)
    }

    func makeInstaller(
        restartAction: @escaping () -> Void = {},
        notifyAction: @escaping () -> Void = {},
        activateAction: @escaping () throws -> Void = {}
    ) -> WallpaperExtensionLockScreenInstaller {
        WallpaperExtensionLockScreenInstaller(
            extensionBundleURL: extensionURL,
            extensionDocumentsURL: documentsURL,
            wallpaperStoreURL: storeURL,
            backupURL: backupURL,
            restartWallpaperAgentAction: restartAction,
            notifyExtensionLibraryChangedAction: notifyAction,
            activateSelectionAction: activateAction
        )
    }

    func readStore() throws -> [String: Any] {
        let data = try Data(contentsOf: storeURL)
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func wallpaperExtensionActivatesExactlyOnceUntilRemove() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }
    var activationCount = 0
    let installer = fixture.makeInstaller(
        activateAction: { activationCount += 1 }
    )

    try installer.install(videoURL: fixture.videoURL, activate: true)
    try installer.install(videoURL: fixture.videoURL, activate: true)
    #expect(activationCount == 1)

    try installer.uninstall()
    try installer.install(videoURL: fixture.videoURL, activate: true)
    #expect(activationCount == 2)
}

@Test func wallpaperExtensionChangesIdleButPreservesDesktop() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }
    var restartCount = 0
    var notifyCount = 0
    let installer = fixture.makeInstaller(
        restartAction: { restartCount += 1 },
        notifyAction: { notifyCount += 1 }
    )

    try installer.install(videoURL: fixture.videoURL)

    let installed = try fixture.readStore()
    let systemDefault = try #require(installed["SystemDefault"] as? [String: Any])
    let desktop = try #require(systemDefault["Desktop"] as? [String: Any])
    let desktopContent = try #require(desktop["Content"] as? [String: Any])
    let desktopChoices = try #require(desktopContent["Choices"] as? [[String: Any]])
    #expect(desktopChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.image")

    let idle = try #require(systemDefault["Idle"] as? [String: Any])
    let idleContent = try #require(idle["Content"] as? [String: Any])
    let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
    #expect(idleChoices.first?["Provider"] as? String == "com.andrijvergeles.auraflow.wallpaper-extension")
    #expect(restartCount == 1)
    #expect(notifyCount == 1)
    #expect(installer.isInstalled)

    let deployedFiles = try FileManager.default.contentsOfDirectory(
        at: fixture.documentsURL.appendingPathComponent("videos/A2A1B4DD-6CB6-4AF2-8F9D-2A6730B43218"),
        includingPropertiesForKeys: nil
    )
    #expect(deployedFiles.contains(where: { $0.pathExtension == "mov" }))
}

@Test func wallpaperExtensionUninstallCopiesCurrentDesktopToIdleAndNeverRestoresSavedAerial() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }
    let installer = fixture.makeInstaller()

    try installer.install(videoURL: fixture.videoURL)

    // Simulate a stale backup produced by an older AuraFlow release. Remove
    // must ignore it even when it contains the Golden Gate/Aerial provider.
    let staleBackup = [
        "SystemDefault": [
            "Desktop": ["Content": ["Choices": [[
                "Provider": "com.apple.wallpaper.choice.image",
                "Files": [["relative": "file:///old-desktop.jpg"]],
            ]]]],
            "Idle": ["Content": ["Choices": [[
                "Provider": "com.apple.wallpaper.choice.aerials",
                "Configuration": Data("golden-gate".utf8),
            ]]]],
        ],
    ] as [String: Any]
    let staleData = try PropertyListSerialization.data(
        fromPropertyList: staleBackup,
        format: .binary,
        options: 0
    )
    try staleData.write(to: fixture.backupURL, options: .atomic)
    try installer.uninstall()

    let restored = try fixture.readStore()
    let systemDefault = try #require(restored["SystemDefault"] as? [String: Any])
    let desktop = try #require(systemDefault["Desktop"] as? [String: Any])
    let desktopContent = try #require(desktop["Content"] as? [String: Any])
    let desktopChoices = try #require(desktopContent["Choices"] as? [[String: Any]])
    #expect(desktopChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.image")

    let idle = try #require(systemDefault["Idle"] as? [String: Any])
    let idleContent = try #require(idle["Content"] as? [String: Any])
    let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
    #expect(idleChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.image")
    let idleFiles = try #require(idleChoices.first?["Files"] as? [[String: Any]])
    #expect(idleFiles.first?["relative"] as? String == "file:///original-desktop.jpg")
    #expect(!installer.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test func wallpaperExtensionReplacesStaleDeploymentMedia() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }

    let entryURL = fixture.documentsURL
        .appendingPathComponent("videos/A2A1B4DD-6CB6-4AF2-8F9D-2A6730B43218", isDirectory: true)
    try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
    let staleURL = entryURL.appendingPathComponent("lock_screen.mp4")
    FileManager.default.createFile(atPath: staleURL.path, contents: Data("stale".utf8))

    let installer = fixture.makeInstaller()
    try installer.install(videoURL: fixture.videoURL)

    let installed = try fixture.readStore()
    let systemDefault = try #require(installed["SystemDefault"] as? [String: Any])
    let idle = try #require(systemDefault["Idle"] as? [String: Any])
    let idleContent = try #require(idle["Content"] as? [String: Any])
    let choices = try #require(idleContent["Choices"] as? [[String: Any]])
    let file = try #require(choices.first?["Files"] as? [[String: Any]])
    #expect(file.first?["relative"] as? String == fixture.documentsURL
        .appendingPathComponent("videos/A2A1B4DD-6CB6-4AF2-8F9D-2A6730B43218/lock_screen.mov")
        .absoluteString)
    #expect(FileManager.default.fileExists(atPath: entryURL.appendingPathComponent("lock_screen.mov").path))
    #expect(!FileManager.default.fileExists(atPath: staleURL.path))
}

@Test func wallpaperExtensionUninstallRestoresEverySpaceFromItsOwnDesktop() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }

    func mode(_ path: String) -> [String: Any] {
        ["Content": ["Choices": [[
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [["relative": path]],
        ]]]]
    }
    let store = [
        "Spaces": [
            "space-one": [
                "Desktop": mode("file:///user-one.jpg"),
                "Idle": mode("file:///old-idle-one.jpg"),
            ],
            "space-two": [
                "Displays": [
                    "display-a": [
                        "Desktop": mode("file:///user-two.jpg"),
                        "Idle": mode("file:///old-idle-two.jpg"),
                    ],
                ],
            ],
        ],
    ] as [String: Any]
    let data = try PropertyListSerialization.data(
        fromPropertyList: store,
        format: .binary,
        options: 0
    )
    try data.write(to: fixture.storeURL, options: .atomic)

    let installer = fixture.makeInstaller()
    try installer.install(videoURL: fixture.videoURL)
    try installer.uninstall()

    let restored = try fixture.readStore()
    let spaces = try #require(restored["Spaces"] as? [String: Any])
    let one = try #require(spaces["space-one"] as? [String: Any])
    #expect(NSDictionary(dictionary: try #require(one["Idle"] as? [String: Any]))
        .isEqual(to: try #require(one["Desktop"] as? [String: Any])))

    let two = try #require(spaces["space-two"] as? [String: Any])
    let displays = try #require(two["Displays"] as? [String: Any])
    let display = try #require(displays["display-a"] as? [String: Any])
    #expect(NSDictionary(dictionary: try #require(display["Idle"] as? [String: Any]))
        .isEqual(to: try #require(display["Desktop"] as? [String: Any])))
}
