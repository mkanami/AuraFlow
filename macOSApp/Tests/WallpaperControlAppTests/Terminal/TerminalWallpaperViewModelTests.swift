import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class TerminalDiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private struct StubTerminalCatalogProvider: TerminalWallpaperCatalogProviding {
    let recorder: TerminalDiscoveryRecorder
    let items: [TerminalWallpaperCatalogItem]

    func discover() -> [TerminalWallpaperCatalogItem] {
        recorder.record()
        return items
    }
}

private final class StubTerminalWallpaperController: TerminalWallpaperControlling {
    private(set) var currentStatus: TerminalWallpaperStatus

    init() {
        currentStatus = TerminalWallpaperStatus(
            running: false,
            config: .defaultConfig
        )
    }

    func status() throws -> TerminalWallpaperStatus { currentStatus }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        currentStatus = TerminalWallpaperStatus(running: true, config: config)
        return currentStatus
    }
    func stop() throws -> TerminalWallpaperStatus {
        currentStatus.running = false
        return currentStatus
    }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        currentStatus = TerminalWallpaperStatus(running: true, config: config)
        return currentStatus
    }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        currentStatus.config = config
        return currentStatus
    }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        currentStatus.config = config
        return currentStatus
    }
    func setLaunchAtLogin(
        _ enabled: Bool,
        config: TerminalWallpaperConfig
    ) throws -> TerminalWallpaperStatus {
        currentStatus.config = config
        return currentStatus
    }
}

private func makeDiscoveredTerminalItems(count: Int, prefix: String = "tool") -> [TerminalWallpaperCatalogItem] {
    (0..<count).map { index in
        TerminalWallpaperCatalogItem(
            id: "discovered:/usr/bin/true-\(prefix)-\(index)",
            title: "\(prefix.capitalized) \(index)",
            subtitle: "Test terminal executable",
            category: index.isMultiple(of: 2) ? .applications : .utilities,
            systemImage: "terminal",
            executableCandidates: ["/usr/bin/true"]
        )
    }
}

@MainActor
private func makeViewModel(
    provider: StubTerminalCatalogProvider
) -> TerminalWallpaperViewModel {
    TerminalWallpaperViewModel(
        controller: StubTerminalWallpaperController(),
        catalogProvider: provider
    )
}

@MainActor
private func waitForCatalogDiscovery(
    _ viewModel: TerminalWallpaperViewModel,
    recorder: TerminalDiscoveryRecorder
) async throws {
    for _ in 0..<50 {
        if recorder.count > 0 && !viewModel.catalogIsLoading {
            return
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

@Test @MainActor
func terminalCatalogStartsWithAtMostTwoDemoAppsWithoutScanning() {
    let recorder = TerminalDiscoveryRecorder()
    let provider = StubTerminalCatalogProvider(recorder: recorder, items: [])
    let viewModel = makeViewModel(provider: provider)

    viewModel.prepareCatalogIfNeeded()

    #expect(viewModel.catalogItems.count <= 2)
    #expect(viewModel.catalogItems.allSatisfy { $0.id == "btop" || $0.id == "htop" })
    #expect(recorder.count == 0)
}

@Test @MainActor
func terminalCatalogSearchDiscoversOnceAndPaginatesOnlyOnTrigger() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let provider = StubTerminalCatalogProvider(
        recorder: recorder,
        items: makeDiscoveredTerminalItems(count: 50)
    )
    let viewModel = makeViewModel(provider: provider)

    viewModel.prepareCatalogIfNeeded()
    viewModel.setCatalogSearch("tool")
    try await waitForCatalogDiscovery(viewModel, recorder: recorder)

    #expect(recorder.count == 1)
    #expect(viewModel.catalogItems.count == 24)
    #expect(viewModel.catalogHasMore)

    viewModel.loadMoreCatalogItems()
    #expect(viewModel.catalogItems.count == 48)
    #expect(viewModel.catalogHasMore)

    viewModel.loadMoreCatalogItems()
    #expect(viewModel.catalogItems.count == 50)
    #expect(!viewModel.catalogHasMore)
}

@Test @MainActor
func terminalCatalogDebounceKeepsOnlyLatestSearchQuery() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let items = makeDiscoveredTerminalItems(count: 30, prefix: "alpha")
        + makeDiscoveredTerminalItems(count: 30, prefix: "beta")
    let provider = StubTerminalCatalogProvider(recorder: recorder, items: items)
    let viewModel = makeViewModel(provider: provider)

    viewModel.setCatalogSearch("alpha")
    try await Task.sleep(nanoseconds: 40_000_000)
    viewModel.setCatalogSearch("beta")
    try await waitForCatalogDiscovery(viewModel, recorder: recorder)

    #expect(recorder.count == 1)
    #expect(viewModel.catalogSearch == "beta")
    #expect(viewModel.catalogItems.allSatisfy { $0.title.localizedCaseInsensitiveContains("beta") })
}

@Test @MainActor
func terminalCatalogReopeningDoesNotRescanUntilExplicitRefresh() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let provider = StubTerminalCatalogProvider(
        recorder: recorder,
        items: makeDiscoveredTerminalItems(count: 2)
    )
    let viewModel = makeViewModel(provider: provider)

    viewModel.prepareCatalogIfNeeded()
    viewModel.prepareCatalogIfNeeded()
    #expect(recorder.count == 0)

    viewModel.setCatalogSearch("tool")
    try await waitForCatalogDiscovery(viewModel, recorder: recorder)
    #expect(recorder.count == 1)

    viewModel.prepareCatalogIfNeeded()
    #expect(recorder.count == 1)

    viewModel.refreshCatalog()
    #expect(recorder.count == 1)
    #expect(viewModel.catalogSearch.isEmpty)
}
