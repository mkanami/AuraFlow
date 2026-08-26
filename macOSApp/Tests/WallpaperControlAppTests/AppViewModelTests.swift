import Testing
import AVFoundation
@testable import WallpaperControlApp

private func writeTinyGIF(to url: URL) throws {
    let bytes: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
        0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
        0x01, 0x00, 0x3B,
    ]
    try Data(bytes).write(to: url, options: .atomic)
}

private func solidImage(width: Int, height: Int, value: UInt8) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: value, count: width * height * bytesPerPixel)

    for index in stride(from: 3, to: pixels.count, by: 4) {
        pixels[index] = 255
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

@Test func catalogOriginHeaderValueIncludesSchemeAndHost() {
    let url = URL(string: "https://moewalls.com/anime/neon-ruins-live-wallpaper/")!
    #expect(catalogOriginHeaderValue(for: url) == "https://moewalls.com")
}

@Test func catalogOriginHeaderValuePreservesExplicitPort() {
    let url = URL(string: "http://localhost:8080/path")!
    #expect(catalogOriginHeaderValue(for: url) == "http://localhost:8080")
}

@Test func bundledToolExecutableResolvesFromResourcesBin() throws {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("auraflow-bundled-bin-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = tempRoot.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    let ffmpegURL = binDirectory.appendingPathComponent("ffmpeg")
    try "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: ffmpegURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegURL.path)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    #expect(auraFlowBundledToolExecutable(named: "ffmpeg", resourcesURL: tempRoot) == ffmpegURL.path)
}

@MainActor
@Test func previewSetsPlayerWhenVideoSelected() throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-test.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }
    viewModel.selectLocalVideoForPreview(tempURL)

    #expect(viewModel.previewPlayer != nil)
    #expect(viewModel.previewPlayer?.currentItem != nil)
}

@MainActor
@Test func localVideoSelectionStaysInPreviewUntilStart() throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local-preview-only.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    viewModel.selectLocalVideoForPreview(tempURL)

    #expect(viewModel.previewPlayer != nil)
    #expect(viewModel.previewPlayer?.currentItem != nil)
    #expect(controller.lastConfiguredVideoURL == nil)
    #expect(controller.startCallCount == 0)
    #expect(viewModel.isRunning == false)
}

@MainActor
@Test func lockScreenToggleCanBeEnabledFromPreviewBeforeStart() throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lock-screen-preview-toggle.mp4")
    FileManager.default.createFile(
        atPath: tempURL.path,
        contents: Data(),
        attributes: nil
    )
    defer { try? FileManager.default.removeItem(at: tempURL) }

    #expect(viewModel.canToggleShowOnLockScreen)
    viewModel.selectLocalVideoForPreview(tempURL)

    #expect(viewModel.canToggleShowOnLockScreen)
    #expect(viewModel.canPreviewLockScreen == false)
}

@MainActor
@Test func lastWallpaperPreviewSurvivesRestartAndRemove() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("preview-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let videoURL = root.appendingPathComponent("last-wallpaper.mp4")
    FileManager.default.createFile(atPath: videoURL.path, contents: Data([1, 2, 3]))
    let previewStateURL = root.appendingPathComponent("last_preview.json")

    let firstViewModel = AppViewModel(
        controller: MockNativeWallpaperController(),
        previewStateURL: previewStateURL
    )
    firstViewModel.selectLocalVideoForPreview(videoURL)

    let restartedController = MockNativeWallpaperController()
    let restartedViewModel = AppViewModel(
        controller: restartedController,
        previewStateURL: previewStateURL
    )

    #expect(restartedViewModel.currentVideoURL == videoURL.standardizedFileURL)
    #expect(restartedViewModel.previewPlayer?.currentItem != nil)

    restartedViewModel.clearWallpaper()
    for _ in 0..<20 {
        if restartedController.clearCallCount == 1 && !restartedViewModel.isBusy {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(restartedController.clearCallCount == 1)
    #expect(restartedViewModel.currentVideoURL == videoURL.standardizedFileURL)
    #expect(restartedViewModel.previewPlayer?.currentItem != nil)
}

@MainActor
@Test func firstLaunchWithoutWallpaperKeepsPreviewEmpty() {
    let previewStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("missing-preview-\(UUID().uuidString).json")
    let viewModel = AppViewModel(
        controller: MockNativeWallpaperController(),
        previewStateURL: previewStateURL
    )

    #expect(viewModel.currentVideoURL == nil)
    #expect(viewModel.previewPlayer == nil)
}

@MainActor
@Test func localVideoSelectionReplacesRunningWallpaperImmediately() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.local-preview-start")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.local-preview-start")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let firstURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local-preview-first.mp4")
    let secondURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local-preview-second.mp4")
    FileManager.default.createFile(atPath: firstURL.path, contents: Data(), attributes: nil)
    FileManager.default.createFile(atPath: secondURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    viewModel.selectLocalVideoForPreview(firstURL)
    let firstPreviewPlayer = try #require(viewModel.previewPlayer)
    viewModel.start()

    for _ in 0..<20 {
        if controller.lastConfiguredVideoURL == firstURL && controller.startCallCount == 1 && viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.lastConfiguredVideoURL == firstURL)
    #expect(controller.startCallCount == 1)
    #expect(viewModel.isRunning)
    #expect(viewModel.previewPlayer === firstPreviewPlayer)

    viewModel.selectLocalVideoForPreview(secondURL)
    for _ in 0..<20 {
        if controller.lastConfiguredVideoURL == secondURL && controller.startCallCount == 2 && viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.lastConfiguredVideoURL == secondURL)
    #expect(controller.startCallCount == 2)
    #expect(viewModel.isRunning)
}

@MainActor
@Test func localWallpaperSelectionStoresSeparateCopyAndKeepsOriginal() async throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)
    let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("local-import-\(UUID().uuidString).mp4")
    FileManager.default.createFile(
        atPath: sourceURL.path,
        contents: Data("original-wallpaper".utf8),
        attributes: nil
    )

    var importedWallpaper: DownloadedCatalogWallpaper?
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        if let importedWallpaper {
            try? FileManager.default.removeItem(at: importedWallpaper.localURL)
            if let previewURL = importedWallpaper.localPreviewURL {
                try? FileManager.default.removeItem(at: previewURL)
            }
        }

        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuraFlow/Catalog/downloaded-catalog.json")
        if let data = try? Data(contentsOf: manifestURL),
           var entries = try? JSONDecoder().decode([DownloadedCatalogWallpaper].self, from: data) {
            entries.removeAll {
                $0.sourcePageURL?.standardizedFileURL.path == sourceURL.standardizedFileURL.path
            }
            if let updatedData = try? JSONEncoder().encode(entries) {
                try? updatedData.write(to: manifestURL, options: .atomic)
            }
        }
    }

    viewModel.selectLocalVideoForPreview(sourceURL)

    for _ in 0..<80 {
        importedWallpaper = viewModel.downloadedCatalogWallpapers.first {
            $0.sourcePageURL?.standardizedFileURL.path == sourceURL.standardizedFileURL.path
        }
        if importedWallpaper != nil {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    let imported = try #require(importedWallpaper)
    #expect(imported.localURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: imported.localURL.path))
    #expect(imported.attribution == "This Mac")
}

@MainActor
@Test func pausedWallpaperStartResumesWithoutReloading() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.paused-start-resume")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.paused-start-resume")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resume-current-wallpaper.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    viewModel.selectLocalVideoForPreview(tempURL)
    viewModel.start()

    for _ in 0..<20 {
        if controller.startCallCount == 1 && viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    viewModel.stop()
    for _ in 0..<20 {
        if viewModel.isPlaybackPaused {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    viewModel.start()
    for _ in 0..<20 {
        if controller.resumeCallCount == 1 && viewModel.isPlaybackActive {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.startCallCount == 1)
    #expect(controller.resumeCallCount == 1)
    #expect(controller.lastConfiguredVideoURL == tempURL)
    #expect(viewModel.isPlaybackActive)
}

@MainActor
@Test func catalogDownloadStagesPreviewUntilStart() throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catalog-preview-only.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    let wallpaper = CatalogWallpaper(
        id: "catalog-preview-only",
        title: "Catalog Preview Only",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/catalog-preview-only"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/catalog-preview-only.mp4")!, width: 1920, height: 1080)]
    )

    viewModel.stageCatalogWallpaperForPreview(wallpaper, localURL: tempURL)

    #expect(viewModel.previewPlayer != nil)
    #expect(viewModel.previewPlayer?.currentItem != nil)
    #expect(controller.lastConfiguredVideoURL == nil)
    #expect(controller.startCallCount == 0)
    #expect(viewModel.isRunning == false)
    #expect(viewModel.statusMessage == "Wallpaper downloaded. Press Start to apply.")
}

@MainActor
@Test func switchingPreviewReusesPlayerAndReplacesItemWithoutDetachingLayer() throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stable-preview-player-first.mp4")
    let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stable-preview-player-second.mp4")
    FileManager.default.createFile(atPath: firstURL.path, contents: Data(), attributes: nil)
    FileManager.default.createFile(atPath: secondURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    viewModel.selectLocalVideoForPreview(firstURL)
    let originalPlayer = try #require(viewModel.previewPlayer)

    viewModel.selectLocalVideoForPreview(secondURL)

    #expect(viewModel.previewPlayer === originalPlayer)
    let currentAsset = try #require(originalPlayer.currentItem?.asset as? AVURLAsset)
    #expect(currentAsset.url.standardizedFileURL == secondURL.standardizedFileURL)
}

@MainActor
@Test func speedUpdateKeepsPreviewPlayerWhenWallpaperIsOnlyInPreview() async throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-speed-keepalive.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    viewModel.selectLocalVideoForPreview(tempURL)
    #expect(viewModel.previewPlayer != nil)

    viewModel.updateSpeed(1.0)

    for _ in 0..<20 {
        if viewModel.isBusy == false {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(viewModel.previewPlayer != nil)
    #expect(viewModel.previewPlayer?.currentItem != nil)
    #expect(controller.startCallCount == 0)
}

@Test func previewPlaybackNeedsRestartWhenPausedAtTargetRate() {
    #expect(
        AppViewModel.previewPlaybackNeedsRestart(
            currentRate: 1.0,
            desiredRate: 1.0,
            timeControlStatus: .paused
        )
    )
    #expect(
        AppViewModel.previewPlaybackNeedsRestart(
            currentRate: 1.0,
            desiredRate: 1.0,
            timeControlStatus: .playing
        ) == false
    )
}

@Test func adaptiveGlassAppearanceKeepsDarkWallpaperFullyTransparent() {
    let image = solidImage(width: 120, height: 68, value: 36)
    let appearance = AppViewModel.adaptiveGlassAppearance(for: image)

    #expect(appearance.topGlassAlpha == 1.0)
    #expect(appearance.bottomGlassAlpha == 1.0)
    #expect(appearance.bottomButtonProtectionOpacity == 0.0)
}

@Test func adaptiveGlassAppearanceProtectsBrightFlatWallpaper() {
    let image = solidImage(width: 120, height: 68, value: 248)
    let appearance = AppViewModel.adaptiveGlassAppearance(for: image)

    #expect(appearance.topGlassAlpha < 0.97)
    #expect(appearance.bottomGlassAlpha < 0.95)
    #expect(appearance.bottomButtonProtectionOpacity > 0.005)
    #expect(appearance.bottomButtonHighlightOpacity < 0.04)
}

@MainActor
@Test func downloadedWallpaperAppliesImmediately() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.downloaded-immediate")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.downloaded-immediate")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("downloaded-immediate.gif")
    try writeTinyGIF(to: tempURL)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    let wallpaper = DownloadedCatalogWallpaper(
        id: "downloaded-immediate",
        wallpaperID: "downloaded-immediate",
        title: "Immediate Apply Test",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        localPreviewPath: nil,
        sourcePageURL: nil,
        localPath: tempURL.path,
        downloadedAt: Date()
    )

    viewModel.applyDownloadedCatalogWallpaper(wallpaper)

    for _ in 0..<60 {
        if controller.lastConfiguredVideoURL != nil && controller.startCallCount > 0 && viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.lastConfiguredVideoURL != nil)
    #expect(controller.startCallCount == 1)
    #expect(viewModel.isRunning)
}

@MainActor
@Test func downloadedCatalogImageUsesCachedFileWithoutRedownload() async throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("downloaded-catalog-image.jpg")
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tempURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let wallpaper = DownloadedCatalogWallpaper(
        id: "downloaded-catalog-image",
        wallpaperID: "downloaded-catalog-image",
        title: "Catalog Image Test",
        category: "Scenic",
        attribution: "Fixture",
        previewImageURL: nil,
        localPreviewPath: nil,
        sourcePageURL: nil,
        localPath: tempURL.path,
        downloadedAt: Date()
    )

    viewModel.applyDownloadedCatalogWallpaper(wallpaper)

    for _ in 0..<40 {
        if controller.startCallCount == 1 {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.startCallCount == 1)
    #expect(controller.lastConfiguredVideoURL?.standardizedFileURL == tempURL.standardizedFileURL)
}

@MainActor
@Test func catalogBackNavigatesDetailThenExitsCatalog() async throws {
    let controller = MockNativeWallpaperController()
    let expectedWallpaper = CatalogWallpaper(
        id: "test-wallpaper",
        title: "Test Wallpaper",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/test-wallpaper"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/test-wallpaper.mp4")!, width: 1920, height: 1080)]
    )
    let viewModel = AppViewModel(
        controller: controller,
        catalogProvider: MockCatalogProvider(wallpapers: [expectedWallpaper])
    )

    viewModel.openCatalog()
    #expect(viewModel.isCatalogOpen)

    viewModel.openCatalogWallpaper(expectedWallpaper)
    #expect(viewModel.selectedCatalogWallpaper == expectedWallpaper)

    viewModel.navigateBackFromCatalog()
    #expect(viewModel.selectedCatalogWallpaper == nil)
    #expect(viewModel.isCatalogOpen)

    // Immediate retap should be ignored to avoid accidental reopen after Back.
    viewModel.openCatalogWallpaper(expectedWallpaper)
    #expect(viewModel.selectedCatalogWallpaper == nil)

    viewModel.navigateBackFromCatalog()
    #expect(viewModel.isCatalogOpen == false)
}

@Test func managedCatalogInterleavesCuratedAndLiveWallpapers() async throws {
    let liveWallpaper = CatalogWallpaper(
        id: "live-wallpaper",
        title: "Live Wallpaper",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/live"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/live.mp4")!, width: 1920, height: 1080)]
    )
    let secondLiveWallpaper = CatalogWallpaper(
        id: "second-live-wallpaper",
        title: "Second Live Wallpaper",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/second-live"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/second-live.mp4")!, width: 1920, height: 1080)]
    )
    let curatedWallpaper = CatalogWallpaper(
        id: "curated-wallpaper",
        title: "Curated Wallpaper",
        category: "Stable",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/curated"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/curated.mp4")!, width: 1920, height: 1080)]
    )
    let secondCuratedWallpaper = CatalogWallpaper(
        id: "second-curated-wallpaper",
        title: "Second Curated Wallpaper",
        category: "Stable",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/second-curated"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/second-curated.mp4")!, width: 1920, height: 1080)]
    )
    let provider = ManagedWallpaperCatalogProvider(
        animeProvider: MockCatalogProvider(wallpapers: [liveWallpaper, secondLiveWallpaper]),
        animeNatureProvider: MockCatalogProvider(wallpapers: []),
        scenicProvider: MockCatalogProvider(wallpapers: []),
        curatedCatalog: [curatedWallpaper, secondCuratedWallpaper]
    )

    let catalog = try await provider.fetchCatalog()

    #expect(catalog.map(\.id) == [
        "curated-wallpaper",
        "live-wallpaper",
        "second-curated-wallpaper",
        "second-live-wallpaper"
    ])
}

@Test func managedCatalogUsesCuratedFallbackWhenLiveProviderFails() async throws {
    let curatedWallpaper = CatalogWallpaper(
        id: "curated-wallpaper",
        title: "Curated Wallpaper",
        category: "Stable",
        attribution: "Fixture",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/curated"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/curated.mp4")!, width: 1920, height: 1080)]
    )
    let provider = ManagedWallpaperCatalogProvider(
        animeProvider: FailingCatalogProvider(),
        animeNatureProvider: MockCatalogProvider(wallpapers: []),
        scenicProvider: MockCatalogProvider(wallpapers: []),
        curatedCatalog: [curatedWallpaper]
    )

    let catalog = try await provider.fetchCatalog()

    #expect(catalog.map(\.id) == ["curated-wallpaper"])
}

@Test func defaultCatalogDoesNotBundleThirdPartyWallpapers() {
    #expect(CatalogWallpaper.defaultCatalog.isEmpty)
}

@MainActor
@Test func catalogGroupFilterConstrainsSearchResults() async throws {
    let animeWallpaper = CatalogWallpaper(
        id: "anime-rain",
        title: "Anime Rain",
        category: "Anime",
        attribution: "MoeWalls",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://moewalls.com/anime/anime-rain-live-wallpaper/"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/anime-rain.mp4")!, width: 1920, height: 1080)]
    )
    let scenicWallpaper = CatalogWallpaper(
        id: "forest-rain",
        title: "Forest Rain",
        category: "Nature",
        attribution: "Mixkit",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://mixkit.co/free-stock-video/forest-rain/"),
        sources: [CatalogVideoSource(url: URL(string: "https://example.com/forest-rain.mp4")!, width: 1920, height: 1080)]
    )
    let viewModel = AppViewModel(
        controller: MockNativeWallpaperController(),
        catalogProvider: MockCatalogProvider(wallpapers: [animeWallpaper, scenicWallpaper])
    )

    viewModel.openCatalog()
    for _ in 0..<20 {
        if viewModel.catalogWallpapers.count == 2 {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(viewModel.filteredCatalogWallpapers.map(\.id) == ["anime-rain", "forest-rain"])

    viewModel.toggleCatalogGroup(.anime)
    viewModel.catalogSearchText = "rain"
    #expect(viewModel.filteredCatalogWallpapers.map(\.id) == ["anime-rain"])

    viewModel.catalogSearchText = "forest"
    #expect(viewModel.filteredCatalogWallpapers.isEmpty)

    viewModel.toggleCatalogGroup(.scenic)
    #expect(viewModel.filteredCatalogWallpapers.map(\.id) == ["forest-rain"])

    viewModel.toggleCatalogGroup(.scenic)
    #expect(viewModel.selectedCatalogGroup == nil)
    #expect(viewModel.filteredCatalogWallpapers.map(\.id) == ["forest-rain"])
}

@MainActor
@Test func startIgnoresRequestsWhileWallpaperIsAlreadyRunning() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.start-preview")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.start-preview")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("start-preview-test.gif")
    try writeTinyGIF(to: tempURL)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    let wallpaper = DownloadedCatalogWallpaper(
        id: "start-preview-test",
        wallpaperID: "start-preview-test",
        title: "Start Preview Test",
        category: "Anime",
        attribution: "Fixture",
        previewImageURL: nil,
        localPreviewPath: nil,
        sourcePageURL: nil,
        localPath: tempURL.path,
        downloadedAt: Date()
    )

    viewModel.applyDownloadedCatalogWallpaper(wallpaper)

    for _ in 0..<60 {
        if controller.lastConfiguredVideoURL != nil && controller.startCallCount == 1 && viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    viewModel.start()
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(controller.lastConfiguredVideoURL != nil)
    #expect(controller.startCallCount == 1)
    #expect(viewModel.isRunning)
}

@MainActor
@Test func startAndStopButtonsTrackRunningAndPausedWallpaperState() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.button-state")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.button-state")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("button-state-test.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    viewModel.selectLocalVideoForPreview(tempURL)
    #expect(viewModel.isStartButtonHighlighted)
    #expect(viewModel.isStopButtonHighlighted == false)
    #expect(viewModel.canStart)
    #expect(viewModel.canStop == false)

    viewModel.start()
    for _ in 0..<20 {
        if viewModel.isRunning {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(viewModel.isRunning)
    #expect(viewModel.isPlaybackPaused == false)
    #expect(viewModel.isStartButtonHighlighted == false)
    #expect(viewModel.isStopButtonHighlighted == false)
    #expect(viewModel.canStart == false)
    #expect(viewModel.canStop)

    viewModel.stop()
    for _ in 0..<20 {
        if viewModel.isPlaybackPaused && viewModel.isRunning == false {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(viewModel.isRunning == false)
    #expect(viewModel.isPlaybackPaused)
    #expect(viewModel.isStartButtonHighlighted == false)
    #expect(viewModel.isStopButtonHighlighted)
    #expect(viewModel.canStart)
    #expect(viewModel.canStop == false)
}

@MainActor
@Test func suspiciousRunningDaemonKeepsStopAvailable() async throws {
    let controller = MockNativeWallpaperController()
    let viewModel = AppViewModel(controller: controller)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("suspicious-running-test.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    controller.configuredVideoURL = tempURL
    controller.statusRunning = true
    controller.statusPaused = false
    controller.statusHealth = DaemonHealth(
        contract_version: 2,
        available: true,
        fresh: true,
        suspicious: true,
        reason: "time_stuck",
        updated_at: Date().timeIntervalSince1970,
        lag_seconds: 0,
        screens: 1,
        windows: 1,
        player_rate: 1.0,
        stall_events: 1,
        recovery_events: 0,
        consecutive_stall_polls: 1,
        paused: false,
        manual_paused: false,
        low_power_mode: false,
        auto_paused_for_low_power: false,
        pause_on_fullscreen: true,
        fullscreen_app_detected: false,
        auto_paused_for_fullscreen: false,
        blend_interpolation_enabled: false,
        blend_interpolation_active: false,
        scale_mode: "fill"
    )

    await viewModel.loadStatus()

    #expect(viewModel.isRunning)
    #expect(viewModel.isPlaybackActive == false)
    #expect(viewModel.isPlaybackPaused == false)
    #expect(viewModel.canStart == false)
    #expect(viewModel.canStop)
    #expect(viewModel.isStartButtonHighlighted == false)
    #expect(viewModel.isStopButtonHighlighted == false)
}

@MainActor
@Test func activeLockScreenOnlyWallpaperKeepsStopAvailable() async throws {
    let controller = MockNativeWallpaperController()
    controller.statusRunning = false
    controller.statusPaused = false
    controller.statusHealth = DaemonHealth(
        available: true,
        fresh: true,
        suspicious: false,
        reason: "ok"
    )
    let viewModel = AppViewModel(controller: controller)

    await viewModel.loadStatus()

    #expect(viewModel.isLockScreenOnlyActive)
    #expect(viewModel.canStop)

    viewModel.stop()
    for _ in 0..<20 {
        if controller.stopCallCount == 1 { break }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.stopCallCount == 1)
    #expect(viewModel.isLockScreenOnlyActive == false)
    #expect(viewModel.canStop == false)
    #expect(viewModel.statusMessage == "Lock Screen wallpaper stopped.")
}

@MainActor
@Test func startForcesPlaybackWhenSetVideoReturnsSuspiciousRunningState() async throws {
    let controller = MockNativeWallpaperController()
    let defaults = UserDefaults(suiteName: "AppViewModelTests.suspicious-start")!
    defaults.removePersistentDomain(forName: "AppViewModelTests.suspicious-start")
    let optimizationStore = VideoOptimizationStore(defaults: defaults)
    optimizationStore.save(
        VideoOptimizationSettings(
            enabled: false,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: true,
            forceSoftwareAV1Encode: false,
            profile: .quality
        )
    )
    let viewModel = AppViewModel(controller: controller, optimizationStore: optimizationStore)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("suspicious-start-test.mp4")
    FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
    }

    controller.setVideoStatusOverride = ControlStatus(
        running: true,
        config: ControlConfig(
            video_path: tempURL.path,
            playback_speed: 1.0,
            volume: 0.0,
            autostart: false
        ),
        pid: 1234,
        autostart: false,
        paused: false,
        health: DaemonHealth(
            contract_version: 2,
            available: true,
            fresh: true,
            suspicious: true,
            reason: "missing_heartbeat",
            updated_at: Date().timeIntervalSince1970,
            lag_seconds: 0,
            screens: 1,
            windows: 1,
            player_rate: 0,
            stall_events: 0,
            recovery_events: 0,
            consecutive_stall_polls: 0,
            paused: false,
            manual_paused: false,
            low_power_mode: false,
            auto_paused_for_low_power: false,
            pause_on_fullscreen: true,
            fullscreen_app_detected: false,
            auto_paused_for_fullscreen: false,
            blend_interpolation_enabled: false,
            blend_interpolation_active: false,
            scale_mode: "fill"
        )
    )

    viewModel.selectLocalVideoForPreview(tempURL)
    viewModel.start()

    for _ in 0..<20 {
        if controller.startCallCount == 1 && viewModel.isPlaybackActive {
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(controller.lastConfiguredVideoURL == tempURL)
    #expect(controller.startCallCount == 1)
    #expect(viewModel.isPlaybackActive)
    #expect(viewModel.canStop)
}

final class MockNativeWallpaperController: WallpaperControlling {
    var configuredVideoURL: URL?
    var lastConfiguredVideoURL: URL?
    var startCallCount = 0
    var clearCallCount = 0
    var resumeCallCount = 0
    var stopCallCount = 0
    var statusRunning = false
    var statusPaused: Bool?
    var statusHealth: DaemonHealth?
    var statusShowOnLockScreen = false
    var syncLockScreenCallCount = 0
    var setVideoStatusOverride: ControlStatus?

    func status() throws -> ControlStatus {
        statusPayload(running: statusRunning, paused: statusPaused, health: statusHealth)
    }

    func start(videoURL: URL?, speed: Double?) throws -> ControlStatus {
        startCallCount += 1
        if let videoURL {
            configuredVideoURL = videoURL
            lastConfiguredVideoURL = videoURL
        }
        statusRunning = true
        statusPaused = false
        statusHealth = nil
        return statusPayload(running: true, paused: false, health: nil)
    }

    func resume() throws -> ControlStatus {
        resumeCallCount += 1
        statusRunning = true
        statusPaused = false
        statusHealth = nil
        return statusPayload(running: true, paused: false, health: nil)
    }

    func stop() throws -> ControlStatus {
        stopCallCount += 1
        statusRunning = false
        statusPaused = true
        statusHealth = nil
        return statusPayload(running: false, paused: true, health: nil)
    }

    func clearWallpaper() throws -> ControlStatus {
        clearCallCount += 1
        statusRunning = false
        statusPaused = false
        configuredVideoURL = nil
        lastConfiguredVideoURL = nil
        statusHealth = nil
        return statusPayload(running: false, paused: false, health: nil)
    }

    func setVideo(_ url: URL) throws -> ControlStatus {
        configuredVideoURL = url
        lastConfiguredVideoURL = url
        if let setVideoStatusOverride {
            return setVideoStatusOverride
        }
        statusRunning = false
        statusPaused = true
        statusHealth = nil
        return statusPayload(running: false, paused: true, health: nil)
    }

    func setSpeed(_ speed: Double) throws -> ControlStatus {
        try status()
    }

    func setInterpolation(_ enabled: Bool) throws -> ControlStatus {
        try status()
    }

    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus {
        try status()
    }

    func setShowOnLockScreen(_ enabled: Bool) throws -> ControlStatus {
        try status()
    }

    func syncLockScreenSaver() throws {
        syncLockScreenCallCount += 1
    }

    func beginLockScreenPreview() throws -> ControlStatus {
        try status()
    }

    func endLockScreenPreview() throws -> ControlStatus {
        try status()
    }

    func setScaleMode(_ mode: WallpaperScaleMode) throws -> ControlStatus {
        try status()
    }

    func setAutostart(_ enabled: Bool) throws -> ControlStatus {
        try status()
    }

    func metrics() throws -> DaemonMetrics {
        DaemonMetrics(running: false)
    }

    private func statusPayload(
        running: Bool,
        paused: Bool? = nil,
        health: DaemonHealth? = nil
    ) -> ControlStatus {
        ControlStatus(
            running: running,
            config: ControlConfig(
                video_path: configuredVideoURL?.path ?? "",
                playback_speed: 1.0,
                volume: 0.0,
                autostart: false,
                show_on_lock_screen: statusShowOnLockScreen
            ),
            pid: running ? 1234 : nil,
            autostart: false,
            paused: paused ?? !running,
            health: health
        )
    }
}

actor MockCatalogProvider: WallpaperCatalogProviding {
    let wallpapers: [CatalogWallpaper]

    init(wallpapers: [CatalogWallpaper]) {
        self.wallpapers = wallpapers
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        wallpapers
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        wallpapers
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        wallpaper.sources.first?.url ?? URL(string: "https://example.com/fallback.mp4")!
    }
}

actor FailingCatalogProvider: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        nil
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        throw URLError(.notConnectedToInternet)
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        throw URLError(.badURL)
    }
}
