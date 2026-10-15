import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor
func terminalPreviewSelectionPersistsIndependentlyFromRuntimeConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-terminal-preview-\(UUID().uuidString)", isDirectory: true)
    let selectionURL = root.appendingPathComponent("selection.json")
    let selected = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(
            catalogItemID: "lavat",
            executable: "/opt/homebrew/bin/lavat",
            arguments: ["--small"]
        )
    )

    let store = WallpaperPreviewSelectionStore(selectionURL: selectionURL)
    store.selectTerminal(selected)

    let restored = WallpaperPreviewSelectionStore(selectionURL: selectionURL)
    #expect(restored.hasSavedSelection)
    #expect(restored.kind == .terminal)
    #expect(restored.terminalConfiguration == selected)

    restored.selectVideo()
    let videoSelection = WallpaperPreviewSelectionStore(selectionURL: selectionURL)
    #expect(videoSelection.kind == .video)
    #expect(videoSelection.terminalConfiguration == nil)
}

@Test
func topMenuStartBlocksCrossTypeConflictAndRemoveTargetsOnlyInstalledRuntime() {
    #expect(WallpaperMenuActionPolicy.canStart(
        previewKind: .terminal,
        terminalRuntimeActive: false,
        videoRuntimeActive: true,
        terminalReady: true,
        videoReady: true,
        isBusy: false
    ) == false)
    #expect(WallpaperMenuActionPolicy.canStart(
        previewKind: .terminal,
        terminalRuntimeActive: false,
        videoRuntimeActive: false,
        terminalReady: true,
        videoReady: true,
        isBusy: false
    ))
    #expect(WallpaperMenuActionPolicy.canStart(
        previewKind: .video,
        terminalRuntimeActive: true,
        videoRuntimeActive: false,
        terminalReady: true,
        videoReady: true,
        isBusy: false
    ) == false)
    #expect(WallpaperMenuActionPolicy.removeTarget(
        terminalRuntimeActive: false,
        videoRuntimeActive: false
    ) == .none)
    #expect(WallpaperMenuActionPolicy.removeTarget(
        terminalRuntimeActive: true,
        videoRuntimeActive: false
    ) == .terminal)
    #expect(WallpaperMenuActionPolicy.removeTarget(
        terminalRuntimeActive: false,
        videoRuntimeActive: true
    ) == .video)
}

@Test
func terminalSharedFrameDescriptorIsVersionedAndRemovedWithRuntime() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-shared-frame-\(UUID().uuidString)", isDirectory: true)
    let store = TerminalWallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("runtime", isDirectory: true),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/terminal.plist")
    )
    let descriptor = TerminalSharedFrameDescriptor(
        surfaceID: 17,
        width: 1920,
        height: 1080,
        agentPID: 4242,
        generation: "frame-generation"
    )

    try store.saveSharedFrameDescriptor(descriptor)
    #expect(store.loadSharedFrameDescriptor() == descriptor)
    store.removeSharedFrameDescriptor()
    #expect(store.loadSharedFrameDescriptor() == nil)
}

@Test
func matchingTerminalSelectionReusesOnlyTheCurrentAgentsSharedSurface() {
    let config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(
            catalogItemID: "asciiquarium",
            executable: "/opt/homebrew/bin/asciiquarium"
        )
    )
    let status = TerminalWallpaperStatus(running: true, pid: 301, config: config)
    let matchingDescriptor = TerminalSharedFrameDescriptor(
        surfaceID: 19,
        width: 1920,
        height: 1080,
        agentPID: 301,
        generation: "current-agent"
    )
    let staleDescriptor = TerminalSharedFrameDescriptor(
        surfaceID: 20,
        width: 1920,
        height: 1080,
        agentPID: 300,
        generation: "previous-agent"
    )

    #expect(TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
        selectedConfiguration: config,
        runtimeStatus: status,
        descriptor: matchingDescriptor
    ))
    #expect(!TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
        selectedConfiguration: config,
        runtimeStatus: status,
        descriptor: matchingDescriptor,
        surfaceAvailable: false
    ))
    let differentSelection = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(catalogItemID: "lavat", executable: "/opt/homebrew/bin/lavat")
    )
    #expect(!TerminalWallpaperPreviewRuntimePolicy.canReuseActiveFrames(
        selectedConfiguration: differentSelection,
        runtimeStatus: status,
        descriptor: matchingDescriptor
    ))
}
