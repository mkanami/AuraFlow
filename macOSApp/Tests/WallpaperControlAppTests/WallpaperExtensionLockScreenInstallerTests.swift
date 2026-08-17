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
        notifyAction: @escaping () -> Void = {}
    ) -> WallpaperExtensionLockScreenInstaller {
        WallpaperExtensionLockScreenInstaller(
            extensionBundleURL: extensionURL,
            extensionDocumentsURL: documentsURL,
            wallpaperStoreURL: storeURL,
            backupURL: backupURL,
            restartWallpaperAgentAction: restartAction,
            notifyExtensionLibraryChangedAction: notifyAction,
            activateSelectionAction: {},
            deactivateSelectionAction: {}
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

@Test func wallpaperExtensionUninstallRestoresOnlyIdleSelection() throws {
    let fixture = try WallpaperExtensionFixture()
    defer { fixture.cleanup() }
    let installer = fixture.makeInstaller()

    try installer.install(videoURL: fixture.videoURL)
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
    #expect(idleChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.aerials")
    #expect(!installer.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
}
