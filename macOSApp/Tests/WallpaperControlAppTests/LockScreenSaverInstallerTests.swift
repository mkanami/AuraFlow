import Foundation
import Testing
@testable import WallpaperControlApp

private final class InMemoryScreenSaverPreferences: ScreenSaverPreferenceManaging {
    var selectedModule: ScreenSaverModulePreference?
    var idleTime: Int
    var acceptsChanges = true
    var ignoresChanges = false

    init(
        selectedModule: ScreenSaverModulePreference?,
        idleTime: Int
    ) {
        self.selectedModule = selectedModule
        self.idleTime = idleTime
    }

    func apply(
        module: ScreenSaverModulePreference?,
        idleTime: Int?
    ) -> Bool {
        guard acceptsChanges else { return false }
        guard !ignoresChanges else { return true }
        selectedModule = module
        if let idleTime {
            self.idleTime = idleTime
        }
        return true
    }
}

private struct ScreenSaverSelectionFixture {
    let root: URL
    let destinationURL: URL
    let backupURL: URL
    let previousModule: ScreenSaverModulePreference
    let preferences: InMemoryScreenSaverPreferences
    let coordinator: ScreenSaverSelectionCoordinator

    init(idleTime: Int = 0) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowScreenSaverSelection-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        destinationURL = root.appendingPathComponent(
            "AuraFlowLockScreen.saver",
            isDirectory: true
        )
        backupURL = root.appendingPathComponent("screen_saver_backup.json")
        previousModule = ScreenSaverModulePreference(
            moduleName: "Ventura",
            path: "/System/Library/ExtensionKit/Extensions/Ventura.appex",
            type: 0
        )
        preferences = InMemoryScreenSaverPreferences(
            selectedModule: previousModule,
            idleTime: idleTime
        )
        coordinator = ScreenSaverSelectionCoordinator(
            fileManager: .default,
            preferences: preferences,
            destinationURL: destinationURL,
            backupURL: backupURL
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func screenSaverActivationSelectsAuraFlowAndPreservesDisabledTimeout() async throws {
    let fixture = try ScreenSaverSelectionFixture()
    defer { fixture.cleanup() }

    try fixture.coordinator.activate()

    #expect(fixture.preferences.selectedModule?.moduleName == "AuraFlowLockScreen")
    #expect(fixture.preferences.selectedModule?.pointsTo(fixture.destinationURL) == true)
    #expect(fixture.preferences.idleTime == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test func screenSaverDeactivationRestoresPreviousSettings() async throws {
    let fixture = try ScreenSaverSelectionFixture()
    defer { fixture.cleanup() }

    try fixture.coordinator.activate()
    try fixture.coordinator.restoreIfNeeded()

    #expect(fixture.preferences.selectedModule == fixture.previousModule)
    #expect(fixture.preferences.idleTime == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test func screenSaverRestoreWithoutBackupPreservesCurrentTimeout() async throws {
    let fixture = try ScreenSaverSelectionFixture()
    defer { fixture.cleanup() }

    try fixture.coordinator.activate()
    try FileManager.default.removeItem(at: fixture.backupURL)
    try fixture.coordinator.restoreIfNeeded()

    #expect(fixture.preferences.selectedModule == fixture.previousModule)
    #expect(fixture.preferences.idleTime == 0)
}

@Test func screenSaverActivationPreservesExistingPositiveTimeout() async throws {
    let fixture = try ScreenSaverSelectionFixture(idleTime: 900)
    defer { fixture.cleanup() }

    try fixture.coordinator.activate()

    #expect(fixture.preferences.idleTime == 900)
}

@Test func screenSaverActivationReportsRejectedPreferences() async throws {
    let fixture = try ScreenSaverSelectionFixture()
    defer { fixture.cleanup() }
    fixture.preferences.acceptsChanges = false

    #expect(throws: LockScreenSaverInstallerError.self) {
        try fixture.coordinator.activate()
    }
    #expect(fixture.preferences.selectedModule == fixture.previousModule)
    #expect(fixture.preferences.idleTime == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test func screenSaverRestoreKeepsBackupWhenPreferencesIgnoreUpdate() async throws {
    let fixture = try ScreenSaverSelectionFixture()
    defer { fixture.cleanup() }

    try fixture.coordinator.activate()
    fixture.preferences.ignoresChanges = true

    #expect(throws: LockScreenSaverInstallerError.self) {
        try fixture.coordinator.restoreIfNeeded()
    }
    #expect(
        fixture.preferences.selectedModule?.pointsTo(
            fixture.destinationURL
        ) == true
    )
    #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test func failedActivationRestoresExistingScreenSaverBundle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "AuraFlowScreenSaverRollback-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let templateURL = root.appendingPathComponent(
        "Template.saver",
        isDirectory: true
    )
    let destinationURL = root.appendingPathComponent(
        "AuraFlowLockScreen.saver",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: templateURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: destinationURL,
        withIntermediateDirectories: true
    )
    let newMarkerURL = templateURL.appendingPathComponent("new")
    let oldMarkerURL = destinationURL.appendingPathComponent("old")
    FileManager.default.createFile(
        atPath: newMarkerURL.path,
        contents: Data("new".utf8),
        attributes: nil
    )
    FileManager.default.createFile(
        atPath: oldMarkerURL.path,
        contents: Data("old".utf8),
        attributes: nil
    )
    let videoURL = root.appendingPathComponent("wallpaper.mp4")
    FileManager.default.createFile(
        atPath: videoURL.path,
        contents: Data([0]),
        attributes: nil
    )

    let previousModule = ScreenSaverModulePreference(
        moduleName: "Ventura",
        path: "/System/Library/ExtensionKit/Extensions/Ventura.appex",
        type: 0
    )
    let preferences = InMemoryScreenSaverPreferences(
        selectedModule: previousModule,
        idleTime: 0
    )
    preferences.acceptsChanges = false
    let backupURL = root.appendingPathComponent("preferences.json")
    let installer = LockScreenSaverInstaller(
        fileManager: .default,
        templateURL: templateURL,
        destinationURL: destinationURL,
        preferences: preferences,
        preferenceBackupURL: backupURL,
        signatureVerifier: { _ in }
    )

    await expectAsyncThrowing(LockScreenSaverInstallerError.self) {
        try await installer.install(videoURL: videoURL)
    }
    #expect(
        FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("old").path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("new").path
        )
    )
}
