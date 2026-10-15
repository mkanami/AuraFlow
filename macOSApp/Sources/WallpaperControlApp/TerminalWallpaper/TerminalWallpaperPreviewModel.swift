import AppKit
import AuraTerminalWallpaperCore
import AuraTerminalRendering
import Combine
import Foundation
import IOSurface

enum WallpaperPreviewKind: String, Codable {
    case video
    case terminal
    case web
}

enum WallpaperMenuRuntimeTarget: Equatable {
    case video
    case terminal
    case web
    case none
}

enum WallpaperMenuActionPolicy {
    static func canStart(
        previewKind: WallpaperPreviewKind,
        terminalRuntimeActive: Bool,
        videoRuntimeActive: Bool,
        terminalReady: Bool,
        videoReady: Bool,
        isBusy: Bool,
        webRuntimeActive: Bool = false,
        webReady: Bool = false
    ) -> Bool {
        guard !isBusy else { return false }
        switch previewKind {
        case .terminal:
            return terminalReady && !videoRuntimeActive && !webRuntimeActive
        case .video:
            return videoReady && !terminalRuntimeActive && !webRuntimeActive
        case .web:
            return webReady && !terminalRuntimeActive && !videoRuntimeActive
        }
    }

    static func removeTarget(terminalRuntimeActive: Bool, videoRuntimeActive: Bool, webRuntimeActive: Bool = false) -> WallpaperMenuRuntimeTarget {
        if webRuntimeActive { return .web }
        if terminalRuntimeActive { return .terminal }
        if videoRuntimeActive { return .video }
        return .none
    }
}

enum TerminalWallpaperPreviewRuntimePolicy {
    static func canReuseActiveFrames(
        selectedConfiguration: TerminalWallpaperConfig,
        runtimeStatus: TerminalWallpaperStatus,
        descriptor: TerminalSharedFrameDescriptor?,
        surfaceAvailable: Bool = true
    ) -> Bool {
        guard runtimeStatus.running,
              let descriptor,
              surfaceAvailable,
              runtimeStatus.pid == descriptor.agentPID else { return false }
        var sourceRender = runtimeStatus.config.render
        sourceRender.scaleMode = selectedConfiguration.render.scaleMode
        return runtimeStatus.config.command == selectedConfiguration.command
            && sourceRender == selectedConfiguration.render
    }
}

private struct WallpaperPreviewSelectionRecord: Codable {
    var kind: WallpaperPreviewKind
    var terminalConfiguration: TerminalWallpaperConfig?
    var webProjectID: String?
}

@MainActor
final class WallpaperPreviewSelectionStore: ObservableObject {
    @Published private(set) var kind: WallpaperPreviewKind = .video
    @Published private(set) var terminalConfiguration: TerminalWallpaperConfig?
    @Published private(set) var webProjectID: String?
    @Published private(set) var isAdjustingTerminalSpeed = false
    private(set) var hasSavedSelection = false
    private(set) var selectionRevision: UInt64 = 0
    private(set) var pendingOperationID: UUID?
    private var previousSelection: WallpaperPreviewSelectionRecord?

    private let selectionURL: URL

    init(selectionURL: URL = TerminalWallpaperRuntimeStore.defaultAppSupportURL()
        .appendingPathComponent("preview-selection.json")) {
        self.selectionURL = selectionURL
        guard let data = try? Data(contentsOf: selectionURL),
              let record = try? JSONDecoder().decode(WallpaperPreviewSelectionRecord.self, from: data)
        else { return }
        hasSavedSelection = true
        kind = record.kind
        terminalConfiguration = record.kind == .terminal ? record.terminalConfiguration?.normalized() : nil
        webProjectID = record.kind == .web ? record.webProjectID : nil
    }

    func selectVideo() {
        invalidateTemporarySelection()
        guard kind != .video || terminalConfiguration != nil || !hasSavedSelection else { return }
        kind = .video
        isAdjustingTerminalSpeed = false
        terminalConfiguration = nil
        webProjectID = nil
        persist()
    }

    func selectTerminal(_ configuration: TerminalWallpaperConfig) {
        invalidateTemporarySelection()
        let normalized = configuration.normalized()
        guard kind != .terminal || terminalConfiguration != normalized else { return }
        kind = .terminal
        isAdjustingTerminalSpeed = false
        terminalConfiguration = normalized
        webProjectID = nil
        persist()
    }

    func selectWeb(_ projectID: String) {
        invalidateTemporarySelection()
        kind = .web; terminalConfiguration = nil; webProjectID = projectID
        isAdjustingTerminalSpeed = false; persist()
    }

    func setTerminalNativeSpeed(_ speed: Double) {
        guard kind == .terminal, var config = terminalConfiguration,
              TerminalNativeSpeed.profile(for: config.command) != nil else { return }
        config.nativeSpeed = speed
        let normalized = config.normalized()
        if terminalConfiguration != normalized { terminalConfiguration = normalized }
    }

    func setAdjustingTerminalSpeed(_ editing: Bool) {
        isAdjustingTerminalSpeed = editing
        if !editing { persist() }
    }

    private func persist() {
        guard pendingOperationID == nil else { return }
        hasSavedSelection = true
        let record = WallpaperPreviewSelectionRecord(
            kind: kind,
            terminalConfiguration: terminalConfiguration,
            webProjectID: webProjectID
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: selectionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: selectionURL, options: .atomic)
    }

    private func invalidateTemporarySelection() {
        selectionRevision &+= 1
        pendingOperationID = nil
        previousSelection = nil
    }

    func beginTemporaryTerminal(_ configuration: TerminalWallpaperConfig, operationID: UUID) {
        previousSelection = WallpaperPreviewSelectionRecord(kind: kind, terminalConfiguration: terminalConfiguration, webProjectID: webProjectID)
        pendingOperationID = operationID
        kind = .terminal
        terminalConfiguration = configuration.normalized()
        webProjectID = nil
        isAdjustingTerminalSpeed = false
    }

    func replaceTemporaryTerminal(_ configuration: TerminalWallpaperConfig, operationID: UUID) throws {
        guard pendingOperationID == operationID else { throw CancellationError() }
        // Retry a discovered option without losing the original rollback source.
        terminalConfiguration = configuration.normalized()
    }

    func commitTemporaryTerminal(operationID: UUID) throws {
        guard pendingOperationID == operationID else { throw CancellationError() }
        let record = WallpaperPreviewSelectionRecord(kind: kind, terminalConfiguration: terminalConfiguration, webProjectID: webProjectID)
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: selectionURL, options: .atomic)
        hasSavedSelection = true
        invalidateTemporarySelection()
    }

    func rollbackTemporaryTerminal(operationID: UUID) {
        guard pendingOperationID == operationID, let previousSelection else { return }
        kind = previousSelection.kind
        terminalConfiguration = previousSelection.terminalConfiguration
        webProjectID = previousSelection.webProjectID
        isAdjustingTerminalSpeed = false
        invalidateTemporarySelection()
    }
}

@MainActor
final class TerminalWallpaperPreviewModel: ObservableObject {
    @Published private(set) var snapshot: TerminalGridSnapshot?
    @Published private(set) var configuration: TerminalWallpaperConfig?
    @Published private(set) var sharedFrame: TerminalSharedFrameDescriptor?
    @Published private(set) var frameSequence: UInt64 = 0
    @Published private(set) var previewError: String?

    private let selectionStore: WallpaperPreviewSelectionStore
    private let runtimeStore: TerminalWallpaperRuntimeStore
    private let windowIsVisible: @MainActor () -> Bool
    private var previewSession: TerminalWallpaperPreviewPTY?
    private var selectedCommand: TerminalCommandConfiguration?
    private var selectedGrid: (columns: Int, rows: Int)?
    private var viewportSize: CGSize?

    func updateViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1,
              viewportSize != size else { return }
        viewportSize = size
        reconcile()
    }

    private func resolvedGrid(_ render: TerminalRenderConfiguration) -> (columns: Int, rows: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let metrics = TerminalFontMetrics.cellMetrics(for: render)
        return TerminalRenderGeometry.viewportGrid(configuration: render,
            logicalWidth: Double(screen?.frame.width ?? 1920), logicalHeight: Double(screen?.frame.height ?? 1080),
            cellWidth: metrics.width, lineHeight: metrics.height)
    }
    private var selectionObservation: AnyCancellable?
    private var observationLifetime: TerminalPreviewObservationLifetime?
    private var rateUpdateTask: Task<Void, Never>?
    private var previewRateUpdateTask: Task<Void, Never>?
    private var speedRestartInFlight = false
    private let rateUpdateQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.preview-speed", qos: .userInitiated)
    @Published private(set) var previewGeneration: UInt64 = 0

    // A separate, deduplicated subscription for panel appearance. Consumers
    // displaying frames still observe this model directly at the leaves.
    lazy var appearanceSourcePublisher = TerminalPreviewAppearanceSource.publisher(
        configuration: $configuration, generation: $previewGeneration, sharedFrame: $sharedFrame
    )

    init(
        selectionStore: WallpaperPreviewSelectionStore,
        runtimeStore: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        windowIsVisible: @escaping @MainActor () -> Bool = {
            WallpaperPreviewVisibility.isVisible
        }
    ) {
        self.selectionStore = selectionStore
        self.runtimeStore = runtimeStore
        self.windowIsVisible = windowIsVisible
        selectionObservation = selectionStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        let frameObserver = DistributedNotificationCenter.default().addObserver(
            forName: TerminalWallpaperRuntimeNotifications.sharedFrameDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let surfaceID = info["surface_id"] as? UInt32,
                  let width = info["width"] as? Int, let height = info["height"] as? Int,
                  let agentPID = info["agent_pid"] as? Int,
                  let generation = info["generation"] as? String,
                  let sequence = info["sequence"] as? UInt64 else { return }
            let descriptor = TerminalSharedFrameDescriptor(surfaceID: surfaceID, width: width,
                height: height, agentPID: agentPID, generation: generation)
            Task { @MainActor [weak self] in self?.receiveSharedFrame(descriptor, sequence: sequence) }
        }
        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopPreviewSession(waitForExit: true) }
        }
        let refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        observationLifetime = TerminalPreviewObservationLifetime(frameObserver: frameObserver,
            terminationObserver: terminationObserver, timer: refreshTimer)
        reconcile()
    }

    private func reconcile() {
        guard selectionStore.kind == .terminal,
              let selected = selectionStore.terminalConfiguration?.normalized()
        else {
            rateUpdateTask?.cancel()
            previewRateUpdateTask?.cancel()
            if previewSession != nil { stopPreviewSession() }
            if configuration != nil { configuration = nil }
            if snapshot != nil { snapshot = nil }
            if sharedFrame != nil { sharedFrame = nil }
            if previewError != nil { previewError = nil }
            return
        }

        if configuration != selected { configuration = selected }
        let runtimeStatus = runtimeStore.status()
        synchronizeRuntimeSpeed(selected, status: runtimeStatus)
        let descriptor = runtimeStore.loadSharedFrameDescriptor()
        let runtimeMatches = selectionStore.pendingOperationID == nil && TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
            selectedConfiguration: selected,
            runtimeStatus: runtimeStatus,
            descriptor: descriptor,
            surfaceAvailable: descriptor.map { IOSurfaceLookup($0.surfaceID) != nil } ?? false
        )

        if runtimeMatches, let descriptor {
            if sharedFrame != descriptor { sharedFrame = descriptor }
            if previewSession != nil { stopPreviewSession() }
            return
        }

        if sharedFrame != nil { sharedFrame = nil }
        let requestedGrid = resolvedGrid(selected.render)
        if selectedCommand != selected.command {
            stopPreviewSession()
            if snapshot != nil { snapshot = nil }
            selectedCommand = selected.command
        }
        if selectedGrid?.columns != requestedGrid.columns || selectedGrid?.rows != requestedGrid.rows {
            previewSession?.resize(columns: requestedGrid.columns, rows: requestedGrid.rows)
            selectedGrid = requestedGrid
        }

        // An install may finish while the user minimizes the window. Allow its
        // bounded readiness check to obtain a frame, then pause after commit.
        guard windowIsVisible() || selectionStore.pendingOperationID != nil else {
            previewSession?.setPaused(true)
            return
        }
        if previewSession == nil, !speedRestartInFlight {
            startPreviewSession(for: selected)
        } else {
            previewSession?.setPaused(false)
            synchronizePreviewSpeed(selected)
        }
    }

    func previewVisibilityDidChange() {
        reconcile()
        // The IOSurface continues updating while the preview is hidden. Ask
        // its view to present the current frame immediately on return.
        if windowIsVisible(), sharedFrame != nil { frameSequence &+= 1 }
    }

    private func synchronizePreviewSpeed(_ selected: TerminalWallpaperConfig) {
        guard !selectionStore.isAdjustingTerminalSpeed, let session = previewSession,
              let previous = session.configuration,
              TerminalNativeSpeed.changed(from: previous, to: selected) else { return }
        scheduleSpeedUpdate(selected, forPreview: true) { [weak self, weak session] in
            guard let self, let session, self.previewSession === session else { return }
            do {
                if let input = TerminalNativeSpeed.profile(for: selected.command)?.input(for: selected) {
                    try session.writeInput(input)
                    session.configuration = selected
                } else {
                    // Keep the last image while the old child exits; never
                    // overlap two preview children during a speed restart.
                    self.speedRestartInFlight = true
                    self.stopPreviewSession()
                    session.afterStopped { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.speedRestartInFlight = false
                            self?.reconcile()
                        }
                    }
                }
            } catch { self.previewError = error.localizedDescription }
        }
    }

    private func scheduleSpeedUpdate(_ selected: TerminalWallpaperConfig, forPreview: Bool = false, action: @escaping @MainActor () async -> Void) {
        if forPreview { previewRateUpdateTask?.cancel() } else { rateUpdateTask?.cancel() }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self,
                  forPreview || self.selectionStore.pendingOperationID == nil,
                  !self.selectionStore.isAdjustingTerminalSpeed,
                  self.selectionStore.kind == .terminal,
                  self.selectionStore.terminalConfiguration == selected else { return }
            await action()
        }
        if forPreview { previewRateUpdateTask = task } else { rateUpdateTask = task }
    }

    private func receiveSharedFrame(_ descriptor: TerminalSharedFrameDescriptor, sequence: UInt64) {
        guard windowIsVisible() else { return }
        let agentPID = descriptor.agentPID
        let runtimeStatus = runtimeStore.status()
        guard selectionStore.kind == .terminal,
              selectionStore.pendingOperationID == nil,
              let selected = selectionStore.terminalConfiguration,
              runtimeStatus.pid == agentPID,
              TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
                selectedConfiguration: selected,
                runtimeStatus: runtimeStatus,
                descriptor: descriptor,
                surfaceAvailable: IOSurfaceLookup(descriptor.surfaceID) != nil
        ) else { return }
        if sharedFrame != descriptor { sharedFrame = descriptor }
        if frameSequence != sequence { frameSequence = sequence }
        if previewSession != nil { stopPreviewSession() }
    }

    private func synchronizeRuntimeSpeed(_ selected: TerminalWallpaperConfig, status: TerminalWallpaperStatus) {
        guard selectionStore.pendingOperationID == nil, !selectionStore.isAdjustingTerminalSpeed, status.running,
              status.config.command == selected.command,
              TerminalNativeSpeed.changed(from: status.config, to: selected),
              let profile = TerminalNativeSpeed.profile(for: selected.command) else { return }
        let store = runtimeStore
        scheduleSpeedUpdate(selected) { [weak self] in
            guard let self else { return }
            do {
                // Save only native speed; preserve the active runtime's render
                // and behavior settings and never start/change its command.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.rateUpdateQueue.async {
                        do {
                            let controller = try NativeTerminalWallpaperController(store: store)
                            _ = try controller.updateNativeSpeed(profile.value(for: selected), matching: selected.command)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                self.previewError = "Could not update animation speed: \(error.localizedDescription)"
            }
        }
    }

    private func startPreviewSession(for config: TerminalWallpaperConfig) {
        if selectionStore.pendingOperationID != nil { snapshot = nil }
        previewGeneration &+= 1
        let generation = previewGeneration
        let session = TerminalWallpaperPreviewPTY()
        previewSession = session
        previewError = nil
        do {
            let grid = resolvedGrid(config.render)
            var launchConfiguration = config
            launchConfiguration.render.columns = grid.columns
            launchConfiguration.render.rows = grid.rows
            try session.start(configuration: launchConfiguration, initialRevision: (snapshot?.revision ?? 0) &+ 1) { [weak self] newSnapshot in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewGeneration == generation,
                          self.previewSession === session,
                          self.selectionStore.kind == .terminal,
                          self.selectedCommand == config.command else { return }
                    guard self.snapshot.map({ newSnapshot.revision >= $0.revision }) ?? true else { return }
                    self.snapshot = newSnapshot
                }
            }
        } catch {
            previewSession = nil
            previewError = error.localizedDescription
        }
    }

    private func stopPreviewSession(waitForExit: Bool = false) {
        previewGeneration &+= 1
        let session = previewSession
        previewSession = nil
        guard let session else { return }
        if waitForExit {
            session.stop(waitForExit: true)
        } else {
            session.stop(waitForExit: false)
        }
    }

    var previewProcessIsRunning: Bool { previewSession?.isRunning == true }
    var previewProcessExitCode: Int32? { previewSession?.exitCode }

    func waitUntilReady(configuration: TerminalWallpaperConfig, operationID: UUID, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var firstVisibleFrame: Date?
        reconcile()
        while Date() < deadline {
            try Task.checkCancellation()
            guard selectionStore.pendingOperationID == operationID,
                  selectionStore.terminalConfiguration == configuration.normalized() else { throw CancellationError() }
            if let previewError { throw TerminalWallpaperControllerError.unavailable(previewError) }
            if let code = previewSession?.exitCode, code != 0 {
                let details = previewSession?.exitDetails ?? ""
                let reason = details.isEmpty ? "" : " \(details)"
                throw TerminalWallpaperControllerError.unavailable("The program exited with status \(code).\(reason) The previous preview was kept.")
            }
            if (previewSession?.isRunning == true || previewSession?.exitCode == 0),
               snapshot?.hasVisibleContent == true {
                if previewSession?.exitCode == 0 {
                    snapshot = previewSession?.deliverLatestSnapshot() ?? snapshot
                    return
                }
                if firstVisibleFrame == nil { firstVisibleFrame = Date() }
                // Give a one-shot command time to report its true exit code;
                // a quick error with printed diagnostics is not a good preview.
                if Date().timeIntervalSince(firstVisibleFrame!) >= 0.15 { return }
            }
            if sharedFrame != nil, frameSequence > 0, runtimeStore.status().health?.running == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TerminalWallpaperControllerError.unavailable(
            "The program did not produce visible output within \(Int(timeout)) seconds. It may be waiting for input. Set arguments or an input file in Add a custom command."
        )
    }

}

// Parser data is confined to parserQueue; published snapshots and completion
// state use snapshotLock. UI delivery and timers remain on the main queue.
private final class TerminalWallpaperPreviewPTY: @unchecked Sendable {
    var isRunning: Bool { session.childPID != nil }
    var exitCode: Int32? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return finishedExitCode
    }
    var diagnosticText: String {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return String(decoding: diagnosticOutput, as: UTF8.self)
    }
    var exitDetails: String { TerminalProgramDiagnostics.summary(diagnosticText) }
    var configuration: TerminalWallpaperConfig?
    private let session = TerminalPTYSession()
    private let parserQueue = DispatchQueue(
        label: "com.andrijvergeles.auraflow.terminal-preview-parser",
        qos: .userInitiated
    )
    private let snapshotLock = NSLock()
    private var parser: VTParser?
    private var latestSnapshot: TerminalGridSnapshot?
    private var finishedExitCode: Int32?
    private var diagnosticOutput = Data()
    private var lastDeliveredRevision: UInt64?
    private var snapshotHandler: ((TerminalGridSnapshot) -> Void)?
    private var frameTimer: DispatchSourceTimer?
    private var isPaused = false
    private var hasFinishedOutput = false
    private let shutdownQueue = DispatchQueue(
        label: "com.andrijvergeles.auraflow.terminal-preview-shutdown",
        qos: .utility
    )

    deinit {
        frameTimer?.cancel()
        session.stop()
    }

    func start(
        configuration: TerminalWallpaperConfig,
        initialRevision: UInt64,
        onSnapshot: @escaping (TerminalGridSnapshot) -> Void
    ) throws {
        let config = configuration.normalized()
        self.configuration = config
        let columns = config.render.columns ?? 153
        let rows = config.render.rows ?? 48
        parser = VTParser(columns: columns, rows: rows, initialRevision: initialRevision)
        snapshotHandler = onSnapshot
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = 1.0 / Double(min(max(config.render.maxFPS, 1), 60))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.snapshotLock.lock()
            let newest = self.latestSnapshot
            let finished = self.hasFinishedOutput
            self.snapshotLock.unlock()
            if finished { self.frameTimer?.schedule(deadline: .distantFuture, repeating: .never) }
            guard let newest, newest.revision != self.lastDeliveredRevision else { return }
            self.lastDeliveredRevision = newest.revision
            self.snapshotHandler?(newest)
        }
        frameTimer = timer
        timer.resume()
        _ = try session.start(
            command: TerminalNativeSpeed.launchCommand(for: config),
            columns: columns,
            rows: rows,
            onData: { [weak self] data in
                guard let self else { return }
                self.parserQueue.async { [weak self] in
                    guard let self, var parser = self.parser else { return }
                    parser.feed(data)
                    self.parser = parser
                    let newest = parser.grid.snapshot()
                    self.snapshotLock.lock()
                    if self.diagnosticOutput.count < 65_536 {
                        self.diagnosticOutput.append(data.prefix(65_536 - self.diagnosticOutput.count))
                    }
                    self.latestSnapshot = newest
                    self.snapshotLock.unlock()
                }
            },
            onExit: { [weak self] code in
                self?.parserQueue.async { [weak self] in
                    guard let self else { return }
                    // Data and exit are serialized behind the parser queue so
                    // even a one-shot program keeps its complete final image.
                    self.snapshotLock.lock()
                    self.finishedExitCode = code
                    self.hasFinishedOutput = true
                    self.snapshotLock.unlock()
                    self.parser = nil
                }
            }
        )
    }

    func deliverLatestSnapshot() -> TerminalGridSnapshot? {
        snapshotLock.lock()
        let newest = latestSnapshot
        snapshotLock.unlock()
        guard let newest else { return nil }
        lastDeliveredRevision = newest.revision
        return newest
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            frameTimer?.schedule(deadline: .distantFuture, repeating: .never)
        } else if let config = configuration {
            let interval = 1.0 / Double(min(max(config.render.maxFPS, 1), 60))
            frameTimer?.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        }
        guard session.childPID != nil else { return }
        try? session.setPaused(paused)
    }

    func writeInput(_ input: Data) throws { try session.writeInput(input) }

    func resize(columns: Int, rows: Int) {
        // SIGWINCH reflows the existing program; resizing never relaunches it
        // or reruns a static command with potential side effects.
        parserQueue.async { [weak self] in
            guard let self, self.session.childPID != nil, var parser = self.parser else { return }
            parser.resize(columns: columns, rows: rows)
            self.parser = parser
            self.snapshotLock.lock()
            self.latestSnapshot = parser.grid.snapshot()
            self.snapshotLock.unlock()
            try? self.session.resize(columns: columns, rows: rows)
        }
    }

    func afterStopped(_ completion: @escaping @Sendable () -> Void) {
        shutdownQueue.async(execute: completion)
    }

    func stop(waitForExit: Bool = false) {
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        frameTimer = nil
        snapshotHandler = nil
        snapshotLock.lock()
        latestSnapshot = nil
        snapshotLock.unlock()
        guard waitForExit else {
            let session = self.session
            let parserQueue = self.parserQueue
            shutdownQueue.async { [self] in
                session.stop()
                parserQueue.async { [weak self] in self?.parser = nil }
            }
            return
        }
        session.stop()
        parserQueue.async { [weak self] in self?.parser = nil }
    }
}

// Foundation permits observer removal and timer invalidation during teardown.
// This immutable owner makes that lifetime explicit across a MainActor deinit.
private final class TerminalPreviewObservationLifetime: @unchecked Sendable {
    let frameObserver: NSObjectProtocol
    let terminationObserver: NSObjectProtocol
    let timer: Timer
    init(frameObserver: NSObjectProtocol, terminationObserver: NSObjectProtocol, timer: Timer) {
        self.frameObserver = frameObserver
        self.terminationObserver = terminationObserver
        self.timer = timer
    }
    deinit {
        timer.invalidate()
        DistributedNotificationCenter.default().removeObserver(frameObserver)
        NotificationCenter.default.removeObserver(terminationObserver)
    }
}
