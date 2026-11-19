import Foundation
import Testing
@testable import WallpaperControlApp

@Suite struct AppResourcesTests {
    @Test func packagedAppPrefersEmbeddedResourcesAfterRelocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlow installed \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appendingPathComponent("AuraFlow.app"))
        let resources = try #require(app.resourceURL)
            .appendingPathComponent("\(AppResources.bundleName).bundle")
        try FileManager.default.copyItem(at: try #require(AppResources.bundle).bundleURL, to: resources)
        let resolved = try #require(AppResources.resolveBundle(mainBundle: app, packageBundle: {
            Issue.record("An installed app must not consult the build machine's resources")
            return .main
        }))
        #expect(resolved.bundleURL.standardizedFileURL.path == resources.standardizedFileURL.path)
        try AppResources.validate(bundle: resolved)
    }

    @Test func incompleteAppDoesNotFallBackToBuildMachineOrRootBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appendingPathComponent("AuraFlow.app"))
        try FileManager.default.copyItem(at: try #require(AppResources.bundle).bundleURL,
            to: app.bundleURL.appendingPathComponent("\(AppResources.bundleName).bundle"))
        #expect(AppResources.resolveBundle(mainBundle: app, packageBundle: {
            Issue.record("A local SwiftPM build must not mask an incomplete installed app")
            return .main
        }) == nil)
        #expect(throws: AppResources.ResourceError.self) { try AppResources.validate(bundle: nil) }
        let message = AppResources.ResourceError.missingBundle.localizedDescription
        #expect(message.contains("resources are missing"))
        #expect(message.contains("copy the entire AuraFlow.app"))
        #expect(!message.contains(".build"))
    }

    @Test func swiftPMTestsCanUseTheirGeneratedResourceBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hostURL = root.appendingPathComponent("TestHost.bundle")
        try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)
        let host = try #require(Bundle(url: hostURL))
        let expected = try #require(AppResources.bundle)
        #expect(AppResources.resolveBundle(mainBundle: host, packageBundle: { expected }) === expected)
        try AppResources.validate()
        for site in LearnedAnimeSite.allCases {
            #expect(!(try LearnedCatalogAPI.load(site)).operations.isEmpty)
        }
        #expect(!MusicCatalogReview.bundled().isEmpty)
        #expect(!MusicWallpaperCatalogProvider.bundledSelections().isEmpty)
    }

    @Test(arguments: [false, true]) func missingAndDamagedFilesHaveActionableErrors(damaged: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Resources.bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if damaged {
            try Data("damaged JSON".utf8).write(to: url.appendingPathComponent("desktophut-api.json"))
        }
        let bundle = try #require(Bundle(url: url))
        do {
            try AppResources.validate(bundle: bundle)
            Issue.record("Incomplete resources must fail validation")
        } catch {
            #expect(error.localizedDescription.contains("desktophut-api.json"))
            #expect(error.localizedDescription.contains(damaged ? "damaged" : "missing"))
            #expect(error.localizedDescription.contains("Download AuraFlow again"))
        }
    }

    private func makeApp(at url: URL) throws -> Bundle {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"),
            withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.auraflow.resource-test.\(UUID().uuidString)",
                     "CFBundlePackageType": "APPL", "CFBundleExecutable": "WallpaperControlApp"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: url))
    }
}
