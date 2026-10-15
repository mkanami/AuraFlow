import AuraTerminalWallpaperCore
import Combine
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

@Test @MainActor
func terminalStartAndRestartDoNotShowUpdatedConfirmation() async throws {
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(controller: controller, resolveExecutable: { _ in nil })
    viewModel.start()
    while viewModel.isBusy { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(controller.startCount == 1)
    #expect(viewModel.status.running)
    #expect(viewModel.statusMessage == nil)
    viewModel.statusMessage = "Earlier confirmation"
    viewModel.restart()
    while viewModel.isBusy { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(viewModel.status.running)
    #expect(viewModel.statusMessage == nil)
    controller.rejectStart = true
    viewModel.start()
    while viewModel.isBusy { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(viewModel.errorMessage != nil)
    #expect(viewModel.statusMessage == nil)
}

@Test @MainActor
func terminalStatusPollingPublishesOnlyActualChanges() async throws {
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(controller: controller, resolveExecutable: { _ in nil })
    var changes = 0
    let observation = viewModel.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }
    for _ in 0..<4 {
        viewModel.refresh()
        while viewModel.statusRefreshInFlight {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    #expect(changes == 0)
    _ = try controller.start(config: .defaultConfig)
    viewModel.refresh()
    while viewModel.statusRefreshInFlight {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(viewModel.status.running)
    #expect(changes == 1)
    _ = try controller.stop()
    viewModel.refresh()
    while viewModel.statusRefreshInFlight {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(!viewModel.status.running)
    #expect(changes == 2)
}

@Test @MainActor
func terminalSettingsEditsStillPersistButMessagesCannotOverwriteSelection() async throws {
    let store = makePreviewSelectionStore()
    store.selectTerminal(.defaultConfig)
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(
        controller: controller, previewSelectionStore: store, resolveExecutable: { _ in nil }
    )
    viewModel.fontSize = 20
    viewModel.fontSize = 24
    viewModel.textScale = 1.5
    let deadline = Date().addingTimeInterval(2)
    while store.terminalConfiguration?.render.fontSize != 24
            || store.terminalConfiguration?.render.textScale != 1.5 {
        #expect(Date() < deadline)
        if Date() >= deadline { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(!controller.currentStatus.running)
    #expect(controller.startCount == 0)

    var newSelection = TerminalWallpaperConfig.defaultConfig
    newSelection.command.executable = "/usr/local/bin/new-preview"
    store.selectTerminal(newSelection)
    viewModel.statusMessage = "Status updated"
    viewModel.errorMessage = "Diagnostic only"
    viewModel.refresh()
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(store.terminalConfiguration == newSelection.normalized())

    store.selectVideo()
    viewModel.fontSize = 18
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(store.kind == .video)
    #expect(store.terminalConfiguration == nil)
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
    var homebrewAvailable: Bool { !needsHomebrew }
    func prepareHomebrew(onStage: @escaping @Sendable (String) -> Void) async throws {
        stage("Preparing Homebrew…", callback: onStage)
        needsHomebrew = false
    }

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
func terminalCatalogFuzzyPresetMatchDoesNotScanWhileTyping() {
    let recorder = TerminalDiscoveryRecorder()
    let viewModel = makeViewModel(provider: StubTerminalCatalogProvider(recorder: recorder, items: []))

    viewModel.setCatalogSearch("lavac")

    #expect(viewModel.catalogItems.map(\.id) == ["lavat"])
    #expect(viewModel.catalogIsLoading)
    #expect(recorder.count == 0)
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

    viewModel.setCatalogSearch("lavat")

    #expect(viewModel.catalogIsLoading)
    #expect(recorder.count == 0)
}

@Test @MainActor
func terminalFeaturedPresetsKeepOriginalOrderAndUseOnlyReviewedFormulae() {
    let availability = TerminalPresetAvailability(installed: ["lavat", "pipes"])
    let viewModel = TerminalWallpaperViewModel(
        controller: StubTerminalWallpaperController(),
        resolveExecutable: { availability.resolve($0) },
        packageProvider: StubAvailableAnimationPackages(),
        previewReady: { _, _ in }
    )

    #expect(viewModel.featuredPresets.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes"])
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
        resolveExecutable: { availability.resolve($0) },
        packageProvider: StubAvailableAnimationPackages(),
        previewReady: { _, _ in }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "asciiquarium")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["asciiquarium"])
    #expect(controller.startCount == 0)
    #expect(previewStore.kind == .terminal)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "asciiquarium")
    #expect(viewModel.isPreviewSelected(TerminalWallpaperPreset.preset(id: "asciiquarium")!.item))
    #expect(viewModel.statusMessage == nil)

    viewModel.use(TerminalWallpaperPreset.preset(id: "lavat")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["asciiquarium"])
    #expect(controller.startCount == 0)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "lavat")
    #expect(viewModel.statusMessage == nil)
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
        resolveExecutable: { availability.resolve($0) },
        packageProvider: StubAvailableAnimationPackages(),
        previewReady: { _, _ in }
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
        resolveExecutable: { availability.resolve($0) },
        packageProvider: StubAvailableAnimationPackages(),
        previewReady: { _, _ in }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "pipes")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(viewModel.needsHomebrew)
    #expect(installer.calls.isEmpty)
    #expect(previewStore.kind == .video)
    viewModel.prepareHomebrew()
    try await waitForTerminalAction(viewModel)
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
        resolveExecutable: { availability.resolve($0) },
        packageProvider: StubAvailableAnimationPackages(),
        previewReady: { _, _ in }
    )

    viewModel.use(TerminalWallpaperPreset.preset(id: "lavat")!.item)
    try await waitForTerminalAction(viewModel)
    #expect(installer.calls == ["lavat"])
    #expect(controller.startCount == 0)
    #expect(viewModel.errorMessage == nil)
    #expect(previewStore.terminalConfiguration?.command.catalogItemID == "lavat")
}

@Test @MainActor
func terminalDiscoveredSearchDoesNotRunOrInstallAndRejectsUnregisteredItem() async throws {
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
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(viewModel.catalogItems.map(\.id) == ["local:true"])
    #expect(recorder.count == 1)
    #expect(installer.calls.isEmpty && controller.startCount == 0 && previewStore.kind == .video)
    viewModel.use(item)
    try await waitForTerminalAction(viewModel)

    #expect(installer.calls.isEmpty)
    #expect(controller.startCount == 0)
    #expect(previewStore.kind == .video)
    #expect(viewModel.errorMessage != nil)
}

@Test func terminalInstallerRejectsAnythingOutsideReviewedPresets() async {
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

@Test @MainActor
func terminalWallpaperPreviewSummaryDoesNotUseDraftOrRuntimeSelection() throws {
    let store = makePreviewSelectionStore()
    let controller = StubTerminalWallpaperController()
    var active = TerminalWallpaperConfig.defaultConfig
    active.command = TerminalCommandConfiguration(catalogItemID: "cmatrix", executable: "/usr/bin/true")
    _ = try controller.start(config: active)
    let viewModel = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: store)

    #expect(viewModel.previewTitle == nil)
    #expect(viewModel.activeWallpaperTitle == "CMatrix")
    viewModel.setExecutable("/usr/local/bin/draft-command")
    #expect(viewModel.previewTitle == nil)

    var preview = active
    preview.command.catalogItemID = "lavat"
    store.selectTerminal(preview)
    #expect(viewModel.previewTitle == "lavat")
    #expect(viewModel.activeWallpaperTitle == "CMatrix")
    #expect(viewModel.isActive(TerminalWallpaperPreset.preset(id: "cmatrix")!.item))
    #expect(!viewModel.isPreviewSelected(TerminalWallpaperPreset.preset(id: "cmatrix")!.item))
    #expect(viewModel.isPreviewSelected(TerminalWallpaperPreset.preset(id: "lavat")!.item))

    store.selectVideo()
    #expect(viewModel.previewTitle == nil)
    #expect(viewModel.activeWallpaperTitle == "CMatrix")
    store.selectWeb("web-project")
    #expect(viewModel.previewTitle == nil)
    #expect(controller.startCount == 1)
}

@Test @MainActor
func terminalWallpaperPreviewSummarySupportsCustomCommandsWithoutApplying() {
    let store = makePreviewSelectionStore()
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: store)
    var configuration = TerminalWallpaperConfig.defaultConfig
    configuration.command = TerminalCommandConfiguration(executable: "/usr/local/bin/my-animation")
    store.selectTerminal(configuration)

    #expect(viewModel.previewTitle == "my-animation")
    #expect(viewModel.activeWallpaperTitle == nil)
    #expect(controller.startCount == 0)
}

@Test @MainActor
func terminalCustomPreviewUsesSelectionStateInsteadOfRepeatedInstructions() async throws {
    let store = makePreviewSelectionStore()
    let controller = StubTerminalWallpaperController()
    let viewModel = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: store)
    viewModel.statusMessage = "Previous runtime action"

    #expect(viewModel.selectCustomExecutable(URL(fileURLWithPath: "/usr/local/bin/my-animation")))
    try await waitForTerminalAction(viewModel)
    #expect(viewModel.previewTitle == "my-animation")
    #expect(viewModel.statusMessage == nil)
    #expect(viewModel.errorMessage == nil)

    viewModel.statusMessage = "Previous runtime action"
    viewModel.showCurrentCommandInPreview()
    try await waitForTerminalAction(viewModel)
    #expect(viewModel.previewTitle == "my-animation")
    #expect(viewModel.statusMessage == nil)
    #expect(controller.startCount == 0)
}

private struct StubAvailableAnimationPackages: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        TerminalAnimationPackageMetadata(name: preset.formula, version: preset.compatibilityProfile!.verifiedVersions[0], disabled: false, executables: [preset.compatibilityProfile!.executable])
    }
}

@MainActor
private func waitForTerminalAction(_ viewModel: TerminalWallpaperViewModel) async throws {
    let deadline = Date().addingTimeInterval(3)
    while viewModel.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!viewModel.isBusy)
}
