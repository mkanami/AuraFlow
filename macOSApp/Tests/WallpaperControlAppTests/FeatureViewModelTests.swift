import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor
func catalogViewModelOwnsFilteringAndGroupSelection() {
    let viewModel = CatalogViewModel()
    viewModel.wallpapers = [
        CatalogWallpaper(
            id: "anime-1",
            title: "Forest Spirit",
            category: "Anime",
            attribution: "MoeWalls",
            previewImageURL: nil,
            sourcePageURL: nil,
            sources: []
        ),
        CatalogWallpaper(
            id: "scenic-1",
            title: "Quiet Lake",
            category: "Scenic",
            attribution: "AuraFlow",
            previewImageURL: nil,
            sourcePageURL: nil,
            sources: []
        ),
    ]

    viewModel.searchText = "forest"
    #expect(viewModel.filteredWallpapers.map(\.id) == ["anime-1"])

    viewModel.searchText = ""
    viewModel.toggleGroup(.scenic)
    #expect(viewModel.filteredWallpapers.map(\.id) == ["scenic-1"])
    #expect(viewModel.count(in: .anime) == 1)
    #expect(viewModel.scrollTargetID == "scenic-1")
}

@Test @MainActor
func previewViewModelPersistsAndRestoresItsSeed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-FeatureViewModelTests")
        .appendingPathComponent(UUID().uuidString)
    let videoURL = directory.appendingPathComponent("preview.mp4")
    let stateURL = directory.appendingPathComponent("preview.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data("fixture".utf8).write(to: videoURL)

    let viewModel = PreviewViewModel(previewStateURL: stateURL)
    viewModel.saveSeed(
        for: videoURL,
        playbackSpeed: 1.25,
        scaleMode: .fit
    )

    let restored = viewModel.loadSavedSeed()
    #expect(restored?.video_path == videoURL.standardizedFileURL.path)
    #expect(restored?.playback_speed == 1.25)
    #expect(restored?.scale_mode == WallpaperScaleMode.fit.rawValue)
    #expect(PreviewViewModel.validPreviewURL(for: restored!) == videoURL.standardizedFileURL)
}

@Test @MainActor
func lifecycleViewModelStartsInAnIdleState() {
    let viewModel = LifecycleViewModel()

    #expect(viewModel.isRunning == false)
    #expect(viewModel.isPlaybackActive == false)
    #expect(viewModel.isPlaybackPaused == false)
    #expect(viewModel.isLockScreenOnlyActive == false)
    #expect(viewModel.isLockScreenPreviewActive == false)
    #expect(viewModel.state == .idle)
    #expect(viewModel.isBusy == false)
}
