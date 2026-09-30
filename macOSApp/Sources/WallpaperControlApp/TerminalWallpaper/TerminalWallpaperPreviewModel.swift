import AppKit
import AuraTerminalWallpaperCore
import Combine
import Foundation
import IOSurface

enum WallpaperPreviewKind: String, Codable {
    case video
    case terminal
}

enum WallpaperMenuRuntimeTarget: Equatable {
    case video
    case terminal
    case none
}

enum WallpaperMenuActionPolicy {
    static func canStart(
        previewKind: WallpaperPreviewKind,
        terminalRuntimeActive: Bool,
        videoRuntimeActive: Bool,
        terminalReady: Bool,
        videoReady: Bool,
        isBusy: Bool
    ) -> Bool {
        guard !isBusy else { return false }
        switch previewKind {
        case .terminal:
            return terminalReady && !videoRuntimeActive
        case .video:
            return videoReady && !terminalRuntimeActive
        }
    }

    static func removeTarget(terminalRuntimeActive: Bool, videoRuntimeActive: Bool) -> WallpaperMenuRuntimeTarget {
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
        return runtimeStatus.config.command == selectedConfiguration.command
    }
}

private struct WallpaperPreviewSelectionRecord: Codable {
    var kind: WallpaperPreviewKind
    var terminalConfiguration: TerminalWallpaperConfig?
}

@MainActor
final class WallpaperPreviewSelectionStore: ObservableObject {
    @Published private(set) var kind: WallpaperPreviewKind = .video
    @Published private(set) var terminalConfiguration: TerminalWallpaperConfig?
    private(set) var hasSavedSelection = false

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
    }

    func selectVideo() {
        guard kind != .video || terminalConfiguration != nil || !hasSavedSelection else { return }
        kind = .video
        terminalConfiguration = nil
        persist()
    }

    func selectTerminal(_ configuration: TerminalWallpaperConfig) {
        let normalized = configuration.normalized()
        guard kind != .terminal || terminalConfiguration != normalized else { return }
        kind = .terminal
        terminalConfiguration = normalized
        persist()
    }

    private func persist() {
        hasSavedSelection = true
        let record = WallpaperPreviewSelectionRecord(
            kind: kind,
            terminalConfiguration: terminalConfiguration
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: selectionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: selectionURL, options: .atomic)
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
    private var selectionObservation: AnyCancellable?
    private var frameObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    @Published private(set) var previewGeneration: UInt64 = 0

    init(
        selectionStore: WallpaperPreviewSelectionStore,
        runtimeStore: TerminalWallpaperRuntimeStore = TerminalWallpaperRuntimeStore(),
        windowIsVisible: @escaping @MainActor () -> Bool = {
            NSApp.windows.contains { $0.title == "AuraFlow" && $0.isVisible }
        }
    ) {
        self.selectionStore = selectionStore
        self.runtimeStore = runtimeStore
        self.windowIsVisible = windowIsVisible
        selectionObservation = selectionStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        frameObserver = DistributedNotificationCenter.default().addObserver(
            forName: TerminalWallpaperRuntimeNotifications.sharedFrameDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.receiveSharedFrame(notification) }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopPreviewSession(waitForExit: true) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcile()
    }

    deinit {
        refreshTimer?.invalidate()
        if let frameObserver {
            DistributedNotificationCenter.default().removeObserver(frameObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func reconcile() {
        guard selectionStore.kind == .terminal,
              let selected = selectionStore.terminalConfiguration?.normalized()
        else {
            if previewSession != nil { stopPreviewSession() }
            if configuration != nil { configuration = nil }
            if snapshot != nil { snapshot = nil }
            if sharedFrame != nil { sharedFrame = nil }
            if previewError != nil { previewError = nil }
            return
        }

        if configuration != selected { configuration = selected }
        let runtimeStatus = runtimeStore.status()
        let descriptor = runtimeStore.loadSharedFrameDescriptor()
        let runtimeMatches = TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
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
        let requestedGrid = (
            columns: selected.render.columns ?? 153,
            rows: selected.render.rows ?? 48
        )
        if selectedCommand != selected.command
            || selectedGrid?.columns != requestedGrid.columns
            || selectedGrid?.rows != requestedGrid.rows {
            stopPreviewSession()
            if snapshot != nil { snapshot = nil }
            selectedCommand = selected.command
            selectedGrid = requestedGrid
        }

        guard windowIsVisible() else {
            previewSession?.setPaused(true)
            return
        }
        if previewSession == nil {
            startPreviewSession(for: selected)
        } else {
            previewSession?.setPaused(false)
        }
    }

    private func receiveSharedFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let surfaceID = userInfo["surface_id"] as? UInt32,
              let width = userInfo["width"] as? Int,
              let height = userInfo["height"] as? Int,
              let agentPID = userInfo["agent_pid"] as? Int,
              let generation = userInfo["generation"] as? String,
              let sequence = userInfo["sequence"] as? UInt64
        else { return }
        let descriptor = TerminalSharedFrameDescriptor(
            surfaceID: surfaceID,
            width: width,
            height: height,
            agentPID: agentPID,
            generation: generation
        )
        let runtimeStatus = runtimeStore.status()
        guard selectionStore.kind == .terminal,
              let selected = selectionStore.terminalConfiguration,
              runtimeStatus.pid == agentPID,
              TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
                selectedConfiguration: selected,
                runtimeStatus: runtimeStatus,
                descriptor: descriptor,
                surfaceAvailable: IOSurfaceLookup(descriptor.surfaceID) != nil
        ) else { return }
        sharedFrame = descriptor
        frameSequence = sequence
        if previewSession != nil { stopPreviewSession() }
    }

    private func startPreviewSession(for config: TerminalWallpaperConfig) {
        previewGeneration &+= 1
        let generation = previewGeneration
        let session = TerminalWallpaperPreviewPTY()
        previewSession = session
        previewError = nil
        do {
            try session.start(configuration: config) { [weak self] newSnapshot in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewGeneration == generation,
                          self.previewSession === session,
                          self.selectionStore.kind == .terminal,
                          self.selectedCommand == config.command else { return }
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

}

private final class TerminalWallpaperPreviewPTY {
    private let session = TerminalPTYSession()
    private let parserQueue = DispatchQueue(
        label: "com.andrijvergeles.auraflow.terminal-preview-parser",
        qos: .userInitiated
    )
    private let snapshotLock = NSLock()
    private var parser: VTParser?
    private var latestSnapshot: TerminalGridSnapshot?
    private var lastDeliveredRevision: UInt64?
    private var snapshotHandler: ((TerminalGridSnapshot) -> Void)?
    private var frameTimer: DispatchSourceTimer?
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
        onSnapshot: @escaping (TerminalGridSnapshot) -> Void
    ) throws {
        let config = configuration.normalized()
        let columns = config.render.columns ?? 153
        let rows = config.render.rows ?? 48
        parser = VTParser(columns: columns, rows: rows)
        snapshotHandler = onSnapshot
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = 1.0 / Double(min(max(config.render.maxFPS, 1), 60))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.snapshotLock.lock()
            let newest = self.latestSnapshot
            self.snapshotLock.unlock()
            guard let newest, newest.revision != self.lastDeliveredRevision else { return }
            self.lastDeliveredRevision = newest.revision
            self.snapshotHandler?(newest)
        }
        frameTimer = timer
        timer.resume()
        _ = try session.start(
            command: config.command,
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
                    self.latestSnapshot = newest
                    self.snapshotLock.unlock()
                }
            },
            onExit: { [weak self] _ in
                self?.parserQueue.async { [weak self] in
                    self?.parser = nil
                }
            }
        )
    }

    func setPaused(_ paused: Bool) {
        guard session.childPID != nil else { return }
        try? session.setPaused(paused)
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
