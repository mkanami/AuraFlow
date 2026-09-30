import AppKit
import AuraTerminalWallpaperCore
import IOSurface
import Metal
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct TerminalPreviewAppearanceTests {
    @Test @MainActor func terminalPaletteNeverInheritsTheLastVideoAndVideoIsUnchanged() {
        let terminal = TerminalPreviewAppearanceModel.fallback(for: TerminalWallpaperConfig())
        let video = AdaptiveGlassAppearance.safeFallback
        #expect(terminal.textTone == .light)
        #expect(video.textTone == .dark)
        #expect(TerminalPreviewAppearanceModel.resolved(kind: .terminal, video: video, terminal: terminal) == terminal)
        #expect(TerminalPreviewAppearanceModel.resolved(kind: .video, video: video, terminal: terminal) == video)
        #expect(EnvironmentValues().terminalPreviewUsesRegularGlass == false)
        #expect(EnvironmentValues().terminalPreviewTitle == nil)
    }

    @Test @MainActor func fallbackUsesTerminalBackgroundAndTitlesUseSelectedCommand() {
        var config = TerminalWallpaperConfig()
        config.render.background = TerminalRGBA(red: 1, green: 1, blue: 1)
        #expect(TerminalPreviewAppearanceModel.fallback(for: config).textTone == .dark)
        config.render.backgroundOpacity = 0
        #expect(TerminalPreviewAppearanceModel.fallback(for: config).textTone == .light)
        #expect(TerminalPreviewAppearanceModel.title(for: TerminalCommandConfiguration(catalogItemID: "cmatrix", executable: "/opt/homebrew/bin/cmatrix")) == "CMatrix")
        #expect(TerminalPreviewAppearanceModel.title(for: TerminalCommandConfiguration(executable: "/Users/test/.local/bin/neo")) == "neo")
    }

    @Test @MainActor func polarityNeedsTwoConsecutiveSamplesAndRejectsOldSource() {
        let model = TerminalPreviewAppearanceModel()
        model.setSource("A", configuration: TerminalWallpaperConfig())
        let bright = AdaptiveGlassAppearance.safeFallback
        let dark = AdaptiveGlassAppearance.emptyState
        model.receive(bright, source: "A")
        #expect(model.appearance.textTone == .light)
        model.receive(dark, source: "A")
        model.receive(bright, source: "A")
        #expect(model.appearance.textTone == .light)
        model.receive(bright, source: "A")
        #expect(model.appearance.textTone == .dark)
        model.setSource("B", configuration: TerminalWallpaperConfig())
        model.receive(bright, source: "A")
        model.receive(bright, source: "A")
        #expect(model.appearance.textTone == .light)
        model.setSource(nil, configuration: nil)
        model.receive(bright, source: "B")
        #expect(model.sourceKey == nil)
        #expect(model.appearance == .emptyState)
    }

    @Test func samplingSkipsHiddenUnchangedThrottledAndInFlightFrames() {
        var budget = TerminalAppearanceSampleBudget()
        let hidden = budget.reserve(frame: "1", visible: false, at: 0)
        #expect(!hidden)
        #expect(budget.lastFrame == nil)
        let first = budget.reserve(frame: "1", visible: true, at: 0)
        #expect(first)
        let inFlight = budget.reserve(frame: "2", visible: true, at: 2)
        #expect(!inFlight)
        budget.complete()
        let unchanged = budget.reserve(frame: "1", visible: true, at: 2)
        #expect(!unchanged)
        let throttled = budget.reserve(frame: "2", visible: true, at: 0.5)
        #expect(!throttled)
        let next = budget.reserve(frame: "2", visible: true, at: 1)
        #expect(next)
        budget.complete()
        let hiddenAgain = budget.reserve(frame: "3", visible: false, at: 3)
        #expect(!hiddenAgain)
        #expect(budget.lastFrame == "2")
        let visibleAgain = budget.reserve(frame: "3", visible: true, at: 3)
        #expect(visibleAgain)
    }

    @Test @MainActor func sourceIdentityIsStableAcrossSpeedAndChangesAcrossSelectionsAndGenerations() {
        var config = TerminalWallpaperConfig()
        let key = TerminalPreviewAppearanceModel.sourceKey(configuration: config, generation: 1, shared: nil)
        for _ in 0..<20 {
            #expect(TerminalPreviewAppearanceModel.sourceKey(configuration: config, generation: 1, shared: nil) == key)
        }
        config.playbackSpeed = 2
        #expect(TerminalPreviewAppearanceModel.sourceKey(configuration: config, generation: 1, shared: nil) == key)
        #expect(TerminalPreviewAppearanceModel.sourceKey(configuration: config, generation: 2, shared: nil) != key)
        config.command.executable = "/opt/homebrew/bin/nyancat"
        #expect(TerminalPreviewAppearanceModel.sourceKey(configuration: config, generation: 1, shared: nil) != key)
        #expect(TerminalPreviewAppearanceModel.sourceKey(configuration: nil, generation: 1, shared: nil) == nil)
    }

    @Test func gpuSamplerReadsOnlyTinyFramesAndAnalyzesRealSurfaceColors() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(TerminalAppearanceGPUSampler.width * TerminalAppearanceGPUSampler.height * 4 == 51_840)
        for white in [false, true] {
            let width = 288, height = 180
            let properties: [String: Any] = [
                kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
                kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: width * 4,
                kIOSurfaceAllocSize as String: width * height * 4
            ]
            let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
            IOSurfaceLock(surface, [], nil)
            let memory = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
            for i in 0..<(width * height) { memory[i] = white ? 0xFFFF_FFFF : 0xFF00_0000 }
            IOSurfaceUnlock(surface, [], nil)
            let descriptor = TerminalSharedFrameDescriptor(surfaceID: IOSurfaceGetID(surface), width: width, height: height, agentPID: 1)
            let sampler = TerminalAppearanceGPUSampler()
            let candidate: AdaptiveGlassAppearance? = await withCheckedContinuation { continuation in
                let accepted = sampler.sample(descriptor: descriptor, viewport: CGSize(width: width, height: height)) {
                    continuation.resume(returning: $0)
                }
                if !accepted { continuation.resume(returning: nil) }
            }
            let appearance = try #require(candidate)
            #expect(appearance.textTone == (white ? .dark : .light))
        }
    }
}
