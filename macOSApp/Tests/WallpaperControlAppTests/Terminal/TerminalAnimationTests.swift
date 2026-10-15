import AppKit
import AuraTerminalWallpaperCore
import Foundation
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Test(arguments: [("LAVAT", "lavat"), ("лава", "lavat"), ("аквариум", "asciiquarium"),
                  ("рыбки", "asciiquarium"), ("матрица", "cmatrix"), ("трубы", "pipes"),
                  ("бонсай", "cbonsai"), ("нян кот", "nyancat"), ("cbonsai", "cbonsai"),
                  ("лават", "lavat"), ("lavac", "lavat"), ("nyanca", "nyancat")])
func animationSearchFindsReviewedNamesAliasesAndTypos(query: String, id: String) {
    #expect(TerminalWallpaperPreset.search(query).first?.id == id)
}

@Test func animationSearchNeverIncludesRandomCommands() {
    for query in ["rm", "sh", "curl", "brew install", "/bin/sh", "nonexistent animation"] {
        #expect(TerminalWallpaperPreset.search(query).isEmpty)
    }
    #expect(TerminalWallpaperPreset.search("c").count > 1)
    #expect(TerminalWallpaperPreset.all.count == 7)
    #expect(TerminalWallpaperPreset.preset(id: "cbonsai")?.item.arguments == ["-l", "-i"])
    #expect(TerminalWallpaperPreset.preset(id: "nyancat")?.item.arguments == ["-n", "-s"])
    for id in ["cbonsai", "nyancat"] {
        let command = TerminalCommandConfiguration(catalogItemID: id, executable: id)
        #expect(TerminalNativeSpeed.profile(for: command) == nil)
    }
}

private func animationTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-animation-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func animationLibraryPersistsDeduplicatesAndPreservesOrder() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.json")
    let library = TerminalAnimationLibraryStore(url: url)
    #expect(try await library.load() == [])
    _ = try await library.add("nyancat")
    _ = try await library.add("cbonsai")
    _ = try await library.add("nyancat")
    #expect(try await TerminalAnimationLibraryStore(url: url).load() == ["nyancat", "cbonsai"])
    await #expect(throws: TerminalWallpaperInstallError.self) { try await library.add("/bin/sh") }
}

@Test func animationLibraryDoesNotOverwriteCorruptData() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.json")
    let bytes = Data("invalid".utf8)
    try bytes.write(to: url)
    await #expect(throws: (any Error).self) { try await TerminalAnimationLibraryStore(url: url).add("cbonsai") }
    #expect(try Data(contentsOf: url) == bytes)
}

private actor AnimationNetworkRecorder {
    var calls = 0
    var active = 0
    var maximum = 0
    var clock = Date()
    func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.timeoutInterval == 10)
        #expect(request.url?.host == "formulae.brew.sh")
        calls += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        let name = request.url!.deletingPathExtension().lastPathComponent
        let binary = name == "pipes-sh" ? "pipes.sh" : name
        return (Data("{\"name\":\"\(name)\",\"tap\":\"homebrew/core\",\"executables\":[\"\(binary)\"],\"disabled\":false,\"versions\":{\"stable\":\"1.0\"}}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func animationPackageChecksAreBoundedAndCachedAcrossRestart() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("cache.json")
    let recorder = AnimationNetworkRecorder()
    let now = Date()
    let provider = SystemTerminalAnimationPackageProvider(cacheURL: url, now: { now }, fetch: { try await recorder.response($0) })
    try await withThrowingTaskGroup(of: Void.self) { group in
        for preset in TerminalWallpaperPreset.all {
            group.addTask { _ = try await provider.metadata(for: preset) }
        }
        try await group.waitForAll()
    }
    #expect(await recorder.calls == 6)
    #expect(await recorder.maximum <= 3)
    let cached = SystemTerminalAnimationPackageProvider(cacheURL: url, now: { now }, fetch: { _ in throw URLError(.notConnectedToInternet) })
    #expect(try await cached.metadata(for: TerminalWallpaperPreset.all[0]).version == "1.0")
    let expired = SystemTerminalAnimationPackageProvider(cacheURL: url, now: { now.addingTimeInterval(86_401) }, fetch: { try await recorder.response($0) })
    _ = try await expired.metadata(for: TerminalWallpaperPreset.all[0])
    #expect(await recorder.calls == 7)
}

@Test(arguments: [404, 500, 200])
func animationPackageRejectsMissingOrInvalidMetadata(status: Int) async throws {
    let provider = SystemTerminalAnimationPackageProvider(cacheURL: nil, fetch: { request in
        (Data("{\"name\":\"unsafe\",\"disabled\":false,\"versions\":{\"stable\":\"1\"}}".utf8),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: (any Error).self) { try await provider.metadata(for: TerminalWallpaperPreset.all[0]) }
}

private struct OfflineAnimationPackages: TerminalAnimationPackageProviding {
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        throw URLError(.notConnectedToInternet)
    }
}

private struct EmptyAnimationDiscovery: TerminalWallpaperCatalogProviding {
    func discover(query: String) -> [TerminalWallpaperCatalogItem] { [] }
}

@MainActor
private func waitForAnimationAction(_ model: TerminalWallpaperViewModel) async throws {
    let deadline = Date().addingTimeInterval(3)
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.isBusy)
}

@Test @MainActor
func animationInstalledOfflineSavesOnlyConfirmedPreview() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let library = TerminalAnimationLibraryStore(url: directory.appendingPathComponent("library.json"))
    var readyCalls = 0
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(),
        catalogProvider: EmptyAnimationDiscovery(), previewSelectionStore: store,
        resolveExecutable: { _ in "/usr/bin/true" }, libraryStore: library,
        packageProvider: OfflineAnimationPackages(), previewReady: { _, id in
            readyCalls += 1
            #expect(store.pendingOperationID == id)
            let saved = try await library.load()
            #expect(saved.isEmpty)
            #expect(!store.hasSavedSelection)
        }
    )
    model.use(TerminalWallpaperPreset.preset(id: "cbonsai")!.item)
    try await waitForAnimationAction(model)
    #expect(readyCalls == 1)
    #expect(model.errorMessage == nil)
    #expect(!model.status.running)
    #expect(try await library.load() == ["cbonsai"])
    #expect(model.libraryPresets.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes", "cbonsai"])
    #expect(WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json")).terminalConfiguration?.command.catalogItemID == "cbonsai")
}

@Test @MainActor
func animationReadinessFailureRestoresPreviousSourceAndDoesNotSave() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    store.selectWeb("previous")
    let library = TerminalAnimationLibraryStore()
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(),
        catalogProvider: EmptyAnimationDiscovery(), previewSelectionStore: store,
        resolveExecutable: { _ in "/usr/bin/true" }, libraryStore: library,
        packageProvider: OfflineAnimationPackages(), previewReady: { _, _ in throw URLError(.timedOut) }
    )
    model.use(TerminalWallpaperPreset.preset(id: "nyancat")!.item)
    try await waitForAnimationAction(model)
    #expect(store.kind == .web && store.webProjectID == "previous")
    #expect(try await library.load().isEmpty)
    #expect(model.errorMessage != nil)
    #expect(!model.status.running)
}

@Test @MainActor
func animationUserSourceChangeWinsAndCancellingPreviewDoesNotSave() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let library = TerminalAnimationLibraryStore()
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(),
        catalogProvider: EmptyAnimationDiscovery(), previewSelectionStore: store,
        resolveExecutable: { _ in "/usr/bin/true" }, libraryStore: library,
        packageProvider: OfflineAnimationPackages(), previewReady: { _, _ in
            store.selectWeb("new-source")
        }
    )
    model.use(TerminalWallpaperPreset.preset(id: "cbonsai")!.item)
    try await waitForAnimationAction(model)
    #expect(store.kind == .web && store.webProjectID == "new-source")
    #expect(try await library.load().isEmpty)
    #expect(model.errorMessage == nil)
}

@Test @MainActor
func animationReadinessRequiresNonemptyFrameAndLivingPTY() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = TerminalCommandConfiguration(executable: "/bin/sh", arguments: ["-c", "printf 'live frame'; sleep 3"])
    let id = UUID()
    store.beginTemporaryTerminal(config, operationID: id)
    try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 2)
    #expect(preview.snapshot?.cells.contains(where: { $0.text == "l" }) == true)
    store.rollbackTemporaryTerminal(operationID: id)
    config.command.arguments = ["-c", "sleep 3"]
    let emptyID = UUID()
    store.beginTemporaryTerminal(config, operationID: emptyID)
    await #expect(throws: (any Error).self) { try await preview.waitUntilReady(configuration: config, operationID: emptyID, timeout: 0.15) }
    store.rollbackTemporaryTerminal(operationID: emptyID)
    config.command.executable = "/nonexistent/animation"
    let failedID = UUID()
    store.beginTemporaryTerminal(config, operationID: failedID)
    await #expect(throws: (any Error).self) { try await preview.waitUntilReady(configuration: config, operationID: failedID, timeout: 0.15) }
    store.rollbackTemporaryTerminal(operationID: failedID)
}

@Test func animationInstallCancellationStopsOwnedChildren() async throws {
    let start = Date()
    let task = Task { try await SystemTerminalWallpaperInstaller.run("/bin/sh", arguments: ["-c", "sleep 30 & wait"]) }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 3)
    let result = try await SystemTerminalWallpaperInstaller.run("/usr/bin/printf", arguments: ["finished"])
    #expect(result.code == 0 && result.output == "finished")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AURAFLOW_VERIFY_TUI_ANIMATIONS"] == "1"),
      arguments: ["asciiquarium", "lavat", "cmatrix", "pipes", "cbonsai", "nyancat"])
@MainActor
func animationRealPTYProducesContinuousFrames(id: String) async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    let item = try #require(TerminalWallpaperPreset.preset(id: id)?.item)
    let path = try #require(item.resolvedExecutable())
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = TerminalCommandConfiguration(catalogItemID: id, executable: path, arguments: item.arguments)
    let operationID = UUID()
    store.beginTemporaryTerminal(config, operationID: operationID)
    defer { store.rollbackTemporaryTerminal(operationID: operationID) }
    try await preview.waitUntilReady(configuration: config, operationID: operationID)
    let revision = try #require(preview.snapshot?.revision)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(try #require(preview.snapshot?.revision) > revision)
    #expect(!runtime.status().running)
}

private struct AnimationTestController: TerminalWallpaperControlling {
    func status() throws -> TerminalWallpaperStatus { TerminalWallpaperStatus(running: false, config: .defaultConfig) }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Preview must not start runtime"); return try status() }
    func stop() throws -> TerminalWallpaperStatus { Issue.record("Preview must not stop runtime"); return try status() }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try start(config: config) }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { Issue.record("Preview must not update runtime"); return try status() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try update(config: config) }
}

private struct ReviewedTestPackages: TerminalAnimationPackageProviding {
    var disabled = false
    func metadata(for preset: TerminalWallpaperPreset) async throws -> TerminalAnimationPackageMetadata {
        TerminalAnimationPackageMetadata(name: preset.formula, version: preset.compatibilityProfile!.verifiedVersions[0], disabled: disabled, executables: [preset.compatibilityProfile!.executable])
    }
}

private final class DelayedAnimationInstaller: TerminalWallpaperInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false
    func resolve(_ item: TerminalWallpaperCatalogItem) -> String? {
        lock.lock(); defer { lock.unlock() }
        return installed ? "/usr/bin/true" : nil
    }
    private func finish() { lock.lock(); installed = true; lock.unlock() }
    func removeExecutable() { lock.lock(); installed = false; lock.unlock() }
    func install(preset: TerminalWallpaperPreset, onStage: @escaping @Sendable (String) -> Void) async throws {
        onStage("Installing…")
        try await Task.sleep(nanoseconds: 150_000_000)
        finish()
    }
}

@Test(arguments: [false, true]) @MainActor
func animationChangingSourceOrCancellingDuringInstallCannotStealPreview(cancel: Bool) async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let installer = DelayedAnimationInstaller()
    let library = TerminalAnimationLibraryStore()
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(), installer: installer,
        previewSelectionStore: store, resolveExecutable: { installer.resolve($0) }, libraryStore: library,
        packageProvider: ReviewedTestPackages(), previewReady: { _, _ in Issue.record("Obsolete choice reached preview") }
    )
    model.use(TerminalWallpaperPreset.preset(id: "cbonsai")!.item)
    try await Task.sleep(nanoseconds: 50_000_000)
    if cancel { model.cancelInstallation() }
    store.selectWeb("newer")
    try await waitForAnimationAction(model)
    #expect(store.kind == .web && store.webProjectID == "newer")
    #expect(try await library.load().isEmpty)
    #expect(model.errorMessage == nil)
    if !cancel { #expect(installer.resolve(TerminalWallpaperPreset.all[4].item) != nil) }
}

@Test @MainActor
func animationMissingExecutablesRetainSavedCardsAndOfflineSearchIsIndependent() async throws {
    let library = TerminalAnimationLibraryStore()
    _ = try await library.add("nyancat")
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(),
        resolveExecutable: { _ in nil }, libraryStore: library, packageProvider: OfflineAnimationPackages()
    )
    model.prepareCatalogIfNeeded()
    model.setCatalogSearch("бонсай")
    model.setCatalogSearch("аквариум")
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(model.catalogItems.first?.id == "asciiquarium")
    #expect(model.libraryPresets.map(\.id) == ["asciiquarium", "lavat", "cmatrix", "pipes", "nyancat"])
    #expect(model.cachedExecutablePath(for: TerminalWallpaperPreset.all[5].item) == nil)
    guard case .failed = model.availability["asciiquarium"] else { Issue.record("Expected network error on the missing package"); return }
    #expect(!model.isBusy && !model.status.running)
}

@Test @MainActor
func animationDisabledPackageCannotReachInstaller() async throws {
    let installer = DelayedAnimationInstaller()
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(), installer: installer,
        resolveExecutable: { _ in nil }, packageProvider: ReviewedTestPackages(disabled: true)
    )
    model.use(TerminalWallpaperPreset.all[4].item)
    try await waitForAnimationAction(model)
    #expect(model.errorMessage != nil)
    #expect(installer.resolve(TerminalWallpaperPreset.all[4].item) == nil)
}

@Suite(.serialized) @MainActor
struct AnimationPanelLayoutTests {
    @Test(arguments: [NSSize(width: 712, height: 432), NSSize(width: 1200, height: 800)])
    func scrollingOccupiesRemainingPanelWithoutFooter(size: NSSize) async throws {
        let model = TerminalWallpaperViewModel(controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(),
            resolveExecutable: { _ in nil }, packageProvider: OfflineAnimationPackages())
        let hosting = NSHostingView(rootView: TerminalWallpaperSettingsView(viewModel: model, onClose: {}))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        hosting.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scroll = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
        let frame = scroll.convert(scroll.bounds, to: hosting)
        #expect(frame.height >= size.height - 75)
        #expect(frame.minX >= 0 && frame.maxX <= size.width + 1)
        #expect(frame.minY >= 0 && frame.maxY <= size.height + 1)
        #expect(model.libraryPresets.count == 4)
    }
}

@Test @MainActor
func animationCatalogPTYHonorsVerifiedCustomPackageLocation() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("nyancat")
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
    let store = WallpaperPreviewSelectionStore(selectionURL: directory.appendingPathComponent("selection.json"))
    let runtime = TerminalWallpaperRuntimeStore(appSupportURL: directory.appendingPathComponent("runtime"))
    let preview = TerminalWallpaperPreviewModel(selectionStore: store, runtimeStore: runtime, windowIsVisible: { true })
    var config = TerminalWallpaperConfig.defaultConfig
    config.command = TerminalCommandConfiguration(catalogItemID: "nyancat", executable: executable.path,
        arguments: ["-c", "i=0; while [ $i -lt 30 ]; do printf '\\033[Hverified path %s' \"$i\"; i=$((i+1)); sleep 0.1; done"])
    let id = UUID()
    store.beginTemporaryTerminal(config, operationID: id)
    defer { store.rollbackTemporaryTerminal(operationID: id) }
    try await preview.waitUntilReady(configuration: config, operationID: id, timeout: 2)
    let text = preview.snapshot?.cells.map(\.text).joined() ?? ""
    #expect(text.contains("verified path"))
}

@Test @MainActor
func animationSelectionWriteFailureRollsBackNewLibraryEntry() async throws {
    let directory = try animationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let selectionURL = directory.appendingPathComponent("directory-not-file")
    try FileManager.default.createDirectory(at: selectionURL, withIntermediateDirectories: true)
    let store = WallpaperPreviewSelectionStore(selectionURL: selectionURL)
    let library = TerminalAnimationLibraryStore()
    let model = TerminalWallpaperViewModel(
        controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(), previewSelectionStore: store,
        resolveExecutable: { _ in "/usr/bin/true" }, libraryStore: library,
        packageProvider: OfflineAnimationPackages(), previewReady: { _, _ in }
    )
    model.use(TerminalWallpaperPreset.all[4].item)
    try await waitForAnimationAction(model)
    #expect(store.kind == .video)
    #expect(model.errorMessage != nil)
    #expect(try await library.load().isEmpty)
    #expect(model.libraryPresets.count == 4)
}

@Test @MainActor
func animationReopeningDetectsRemovedExecutableAndOffersReinstall() async throws {
    let installer = DelayedAnimationInstaller()
    try await installer.install(preset: TerminalWallpaperPreset.all[5]) { _ in }
    let library = TerminalAnimationLibraryStore()
    _ = try await library.add("nyancat")
    let model = TerminalWallpaperViewModel(controller: AnimationTestController(), catalogProvider: EmptyAnimationDiscovery(),
        resolveExecutable: { installer.resolve($0) }, libraryStore: library, packageProvider: ReviewedTestPackages())
    model.prepareCatalogIfNeeded()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.cachedExecutablePath(for: TerminalWallpaperPreset.all[5].item) != nil)
    installer.removeExecutable()
    model.prepareCatalogIfNeeded()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.cachedExecutablePath(for: TerminalWallpaperPreset.all[5].item) == nil)
    #expect(model.availability["nyancat"]?.canInstall == true)
    #expect(model.libraryPresets.last?.id == "nyancat")
}
