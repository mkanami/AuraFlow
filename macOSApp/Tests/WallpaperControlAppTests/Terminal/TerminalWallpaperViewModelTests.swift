import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class TerminalDiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var cancellationValue = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var cancellations: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationValue
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func recordCancellation() {
        lock.lock()
        cancellationValue += 1
        lock.unlock()
    }
}

private struct StubTerminalCatalogProvider: TerminalWallpaperCatalogProviding {
    let recorder: TerminalDiscoveryRecorder
    let items: [TerminalWallpaperCatalogItem]

    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        recorder.record()
        return items
    }
}

private struct CancellationAwareTerminalCatalogProvider: TerminalWallpaperCatalogProviding {
    let recorder: TerminalDiscoveryRecorder
    let betaItems: [TerminalWallpaperCatalogItem]

    func discover(query: String) -> [TerminalWallpaperCatalogItem] {
        recorder.record()
        if query == "alpha" {
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.01)
            }
            recorder.recordCancellation()
            return makeDiscoveredTerminalItems(count: 1, prefix: "alpha")
        }
        return betaItems
    }
}

private final class StubTerminalWallpaperController: TerminalWallpaperControlling, @unchecked Sendable {
    private(set) var currentStatus: TerminalWallpaperStatus
    private(set) var startCount = 0
    var rejectStart = false

    init() {
        currentStatus = TerminalWallpaperStatus(
            running: false,
            config: .defaultConfig
        )
    }

    func status() throws -> TerminalWallpaperStatus { currentStatus }
    func ensureCanStart() throws {
        if rejectStart { throw TerminalWallpaperControllerError.videoWallpaperAlreadyRunning }
    }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        try ensureCanStart()
        startCount += 1
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

private final class TerminalPresetAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<String>

    init(installed: Set<String> = []) { self.installed = installed }

    func resolve(_ item: TerminalWallpaperCatalogItem) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installed.contains(item.id) ? "/usr/bin/true" : nil
    }

    func markInstalled(_ id: String) {
        lock.lock()
        installed.insert(id)
        lock.unlock()
    }
}

private final class StubTerminalWallpaperInstaller: TerminalWallpaperInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installedIDs: [String] = []
    private var recordedStages: [String] = []
    let availability: TerminalPresetAvailability
    var shouldFail = false
    var needsHomebrew = false

    init(availability: TerminalPresetAvailability) { self.availability = availability }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return installedIDs
    }

    var stages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStages
    }

    private func stage(_ value: String, callback: @Sendable (String) -> Void) {
        lock.lock()
        recordedStages.append(value)
        lock.unlock()
        callback(value)
    }

    private func record(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        installedIDs.append(id)
        return shouldFail
    }

    func install(
        preset: TerminalWallpaperPreset,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws {
        let fail = record(preset.id)
        if needsHomebrew { stage("Preparing Homebrew…", callback: onStage) }
        stage("Installing…", callback: onStage)
        if fail { throw TerminalWallpaperInstallError.commandFailed("mock failure") }
        availability.markInstalled(preset.id)
    }
}

private func makeDiscoveredTerminalItems(count: Int, prefix: String = "tool") -> [TerminalWallpaperCatalogItem] {
    (0..<count).map { index in
        TerminalWallpaperCatalogItem(
            id: "discovered:/usr/bin/true-\(prefix)-\(index)",
            title: index == 0 ? prefix : "\(prefix)-\(index)",
            subtitle: "Test terminal executable",
            category: index.isMultiple(of: 2) ? .applications : .utilities,
            systemImage: "terminal",
            executableCandidates: ["/usr/bin/true"]
        )
    }
}

@MainActor
private func makePreviewSelectionStore() -> WallpaperPreviewSelectionStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-preview-selection-tests-\(UUID().uuidString)", isDirectory: true)
    return WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
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
func terminalCatalogStartsWithFourFeaturedWallpapersWithoutScanning() {
    let recorder = TerminalDiscoveryRecorder()
    let provider = StubTerminalCatalogProvider(recorder: recorder, items: [])
    let viewModel = makeViewModel(provider: provider)

    viewModel.prepareCatalogIfNeeded()

    #expect(viewModel.catalogItems.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes"])
    #expect(recorder.count == 0)
}

@Test @MainActor
func terminalCatalogSearchDiscoversOnceAndNeverShowsLongList() async throws {
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
    #expect(viewModel.catalogItems.count == 1)
    #expect(viewModel.catalogItems.first?.title == "tool")
}

@Test @MainActor
func terminalCatalogFuzzyPresetMatchDoesNotScanExecutables() {
    let recorder = TerminalDiscoveryRecorder()
    let viewModel = makeViewModel(provider: StubTerminalCatalogProvider(recorder: recorder, items: []))

    viewModel.setCatalogSearch("lavac")

    #expect(viewModel.catalogItems.map(\.id) == ["lavat"])
    #expect(!viewModel.catalogIsLoading)
    #expect(recorder.count == 0)
}

@Test @MainActor
func terminalExactSearchCapsUnknownCommandsAtFive() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let many = makeDiscoveredTerminalItems(count: 30).map { item in
        TerminalWallpaperCatalogItem(
            id: item.id,
            title: "tool",
            subtitle: item.subtitle,
            category: item.category,
            systemImage: item.systemImage,
            executableCandidates: item.executableCandidates
        )
    }
    let viewModel = makeViewModel(provider: StubTerminalCatalogProvider(recorder: recorder, items: many))

    viewModel.setCatalogSearch("tool")
    try await waitForCatalogDiscovery(viewModel, recorder: recorder)

    #expect(viewModel.catalogItems.count == 5)
    #expect(viewModel.catalogItems.allSatisfy { $0.title == "tool" })
}

@Test func systemTerminalCatalogCachesExactQueriesUntilRefresh() {
    let recorder = TerminalDiscoveryRecorder()
    let items = makeDiscoveredTerminalItems(count: 1, prefix: "alpha")
        + makeDiscoveredTerminalItems(count: 1, prefix: "beta")
    let provider = SystemTerminalWallpaperCatalogProvider { query in
        recorder.record()
        return items.filter { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
    }

    #expect(provider.discover(query: "alpha").count == 1)
    #expect(provider.discover(query: "alpha").count == 1)
    #expect(recorder.count == 1)

    provider.refresh()
    _ = provider.discover(query: "alpha")
    #expect(recorder.count == 2)
}

@Test @MainActor
func terminalCatalogSearchShowsLoadingInsteadOfFalseNoMatchesDuringDebounce() {
    let recorder = TerminalDiscoveryRecorder()
    let provider = StubTerminalCatalogProvider(recorder: recorder, items: makeDiscoveredTerminalItems(count: 1))
    let viewModel = makeViewModel(provider: provider)

    viewModel.setCatalogSearch("tool")

    #expect(viewModel.catalogIsLoading)
    #expect(recorder.count == 0)
}

@Test @MainActor
func terminalCatalogCancelsAnObsoleteSearchAlreadyInProgress() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let provider = CancellationAwareTerminalCatalogProvider(
        recorder: recorder,
        betaItems: makeDiscoveredTerminalItems(count: 2, prefix: "beta")
    )
    let viewModel = TerminalWallpaperViewModel(
        controller: StubTerminalWallpaperController(),
        catalogProvider: provider
    )

    viewModel.setCatalogSearch("alpha")
    for _ in 0..<50 where recorder.count == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(recorder.count == 1)

    viewModel.setCatalogSearch("beta")
    try await Task.sleep(nanoseconds: 400_000_000)
    for _ in 0..<50 where viewModel.catalogIsLoading {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(recorder.cancellations == 1)
    #expect(viewModel.catalogItems.count == 1)
    #expect(viewModel.catalogItems.first?.title == "beta")
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
    #expect(viewModel.catalogItems.first?.title == "beta")
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

@MainActor
private func waitForTerminalAction(_ viewModel: TerminalWallpaperViewModel) async throws {
    for _ in 0..<100 where viewModel.isBusy {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Test @MainActor
func terminalFeaturedPresetsSortInstalledFirstAndUseOnlyAllowlistedFormulae() {
    let availability = TerminalPresetAvailability(installed: ["lavat", "pipes"])
    let viewModel = TerminalWallpaperViewModel(
        controller: StubTerminalWallpaperController(),
        resolveExecutable: { availability.resolve($0) }
    )

    #expect(viewModel.featuredPresets.map(\.id) == ["lavat", "pipes", "asciiquarium", "cmatrix"])
    #expect(TerminalWallpaperPreset.featured.map(\.formula) == ["asciiquarium", "lavat", "cmatrix", "pipes-sh"])
    #expect(TerminalWallpaperPreset.preset(id: "discovered:/bin/sh") == nil)
}

@Test @MainActor
func terminalPresetInstallationThenPreviewAndSwitchDoesNotStartRuntime() async throws {
    let availability = TerminalPresetAvailability(installed: ["lavat"])
    let installer = StubTerminalWallpaperInstaller(availability: availability)
    let controller = StubTerminalWallpaperController()
    let previewStore = makePreviewSelectionStore()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller,
        installer: installer,
        previewSelectionStore: previewStore,
        resolveExecutable: { availability.resolve($0) }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "asciiquarium")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["asciiquarium"])
    #expect(controller.startCount == 0)
    #expect(previewStore.kind == .terminal)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "asciiquarium")
    #expect(viewModel.isPreviewSelected(TerminalWallpaperPreset.preset(id: "asciiquarium")!.item))

    viewModel.use(TerminalWallpaperPreset.preset(id: "lavat")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["asciiquarium"])
    #expect(controller.startCount == 0)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "lavat")
}

@Test @MainActor
func terminalPresetInstallationFailureDoesNotLaunch() async throws {
    let availability = TerminalPresetAvailability()
    let installer = StubTerminalWallpaperInstaller(availability: availability)
    installer.shouldFail = true
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller,
        installer: installer,
        resolveExecutable: { availability.resolve($0) }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "lavat")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(controller.startCount == 0)
    #expect(viewModel.errorMessage?.contains("mock failure") == true)
    viewModel.refresh()
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(viewModel.errorMessage?.contains("mock failure") == true)
}

@Test @MainActor
func terminalPresetCanBootstrapMissingHomebrewThroughInstaller() async throws {
    let availability = TerminalPresetAvailability()
    let installer = StubTerminalWallpaperInstaller(availability: availability)
    installer.needsHomebrew = true
    let controller = StubTerminalWallpaperController()
    let previewStore = makePreviewSelectionStore()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller,
        installer: installer,
        previewSelectionStore: previewStore,
        resolveExecutable: { availability.resolve($0) }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "pipes")!.item)
    try await waitForTerminalAction(viewModel)

    #expect(installer.stages == ["Preparing Homebrew…", "Installing…"])
    #expect(controller.startCount == 0)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "pipes")
}

@Test @MainActor
func terminalPreviewSelectionDoesNotRunWallpaperConflictPreflight() async throws {
    let availability = TerminalPresetAvailability()
    let installer = StubTerminalWallpaperInstaller(availability: availability)
    let controller = StubTerminalWallpaperController()
    controller.rejectStart = true
    let previewStore = makePreviewSelectionStore()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller,
        installer: installer,
        previewSelectionStore: previewStore,
        resolveExecutable: { availability.resolve($0) }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "lavat")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["lavat"])
    #expect(controller.startCount == 0)
    #expect(viewModel.errorMessage == nil)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "lavat")
}

@Test @MainActor
func terminalExactCommandUsesWallpaperWithoutInstallingPackage() async throws {
    let recorder = TerminalDiscoveryRecorder()
    let controller = StubTerminalWallpaperController()
    let availability = TerminalPresetAvailability()
    let installer = StubTerminalWallpaperInstaller(availability: availability)
    let item = makeDiscoveredTerminalItems(count: 1, prefix: "mytool")[0]
    let previewStore = makePreviewSelectionStore()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller,
        catalogProvider: StubTerminalCatalogProvider(recorder: recorder, items: [item]),
        installer: installer,
        previewSelectionStore: previewStore
    )

    viewModel.setCatalogSearch("mytool")
    try await waitForCatalogDiscovery(viewModel, recorder: recorder)
    viewModel.use(item)
    try await waitForTerminalAction(viewModel)

    #expect(installer.calls.isEmpty)
    #expect(controller.startCount == 0)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == item.id)
}

@Test func terminalInstallerRejectsAnythingOutsideFourPresets() async {
    let invalid = [
        TerminalWallpaperPreset(id: "sh", description: "no", formula: "unsafe-formula"),
        TerminalWallpaperPreset(id: "lavat", description: "Flowing lava lamp", formula: "unsafe-formula"),
    ]
    for preset in invalid {
        do {
            try await SystemTerminalWallpaperInstaller().install(preset: preset) { _ in }
            Issue.record("An unapproved formula was accepted")
        } catch {
            #expect(error is TerminalWallpaperInstallError)
        }
    }
}
