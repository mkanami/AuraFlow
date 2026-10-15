import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct SettingsPopupLayoutTests {
    @Test(arguments: [520.0, 432, 300, 180])
    func cardFitsItsContentsAndKeepsScrollingWhenSpaceIsLimited(maximumHeight: Double) async throws {
        let model = makeModel()
        let state = SettingsLayoutState()
        let hosting = NSHostingView(rootView: SettingsLayoutFixture(model: model, state: state,
                                                                   maximumHeight: maximumHeight))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }
        try await settle(hosting)

        #expect(state.contentHeight > 300 && state.contentHeight < 520)
        #expect(abs(state.cardHeight - min(state.contentHeight, maximumHeight)) < 1)
        #expect(state.cardHeight <= maximumHeight)
    }

    @Test
    func cardResizesWhenOptimizationProgressAppearsAndDisappears() async throws {
        let model = makeModel()
        let state = SettingsLayoutState()
        let hosting = NSHostingView(rootView: SettingsLayoutFixture(model: model, state: state,
                                                                   maximumHeight: 520))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }
        try await settle(hosting)
        let initialHeight = state.contentHeight

        model.optimizationInProgress = true
        model.optimizationLabel = "Optimizing wallpaper"
        try await settle(hosting)
        #expect(state.contentHeight > initialHeight)
        #expect(abs(state.cardHeight - min(state.contentHeight, 520)) < 1)

        model.optimizationInProgress = false
        try await settle(hosting)
        #expect(abs(state.contentHeight - initialHeight) < 1)
        #expect(abs(state.cardHeight - initialHeight) < 1)
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(controller: MockNativeWallpaperController(),
                     catalogProvider: MockCatalogProvider(wallpapers: []))
    }

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ hosting: NSView) async throws {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class SettingsLayoutState {
    var contentHeight: CGFloat = 0
    var cardHeight: CGFloat = 0
}

private struct SettingsCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SettingsLayoutFixture: View {
    let model: AppViewModel
    let state: SettingsLayoutState
    let maximumHeight: CGFloat

    var body: some View {
        SettingsPopupCard(viewModel: model, maximumHeight: maximumHeight)
            .frame(width: 620)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SettingsCardHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(SettingsCardHeightKey.self) { state.cardHeight = $0 }
            .onPreferenceChange(SettingsPopupContentHeightKey.self) { state.contentHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
