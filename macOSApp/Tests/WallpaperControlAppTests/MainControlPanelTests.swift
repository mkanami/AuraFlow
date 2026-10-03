import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct MainControlPanelTests {
    @Test(arguments: [676.0, 899, 900, 901, 1036, 1396])
    func rowFramesStayInsideAvailableWidth(width: Double) {
        for row in [MainControlRowLayout.Row.playback, .library] {
            let frames = MainControlRowLayout(row: row).frames(width: width, idealWidths: [88, 82, 103, 76, 161])
            #expect(frames.count == 5)
            #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width && $0.height == 22 })
            for pair in zip(frames, frames.dropFirst()) {
                #expect(pair.0.maxX + 8 <= pair.1.minX + 0.01)
            }
            if row == .library {
                #expect(frames[0].width == frames[1].width)
                #expect(frames[1].width == frames[2].width)
                #expect(frames[3].size == CGSize(width: 32, height: 22))
                #expect(frames[4].size == CGSize(width: 32, height: 22))
                // Vertical compaction must not change any horizontal allocation.
                #expect(abs(frames[0].width - (width - 96) / 3) < 0.01)
                #expect(abs(frames[3].minX - (width - 72)) < 0.01)
                #expect(abs(frames[4].minX - (width - 32)) < 0.01)
            }
        }
        #expect(MainControlRowLayout.usesCompactTitles(contentWidth: width) == (width < 900))
    }

    @Test
    func measuredResumeWidthIsRespectedInsteadOfShrinkingText() {
        let frames = MainControlRowLayout(row: .playback).frames(width: 676, idealWidths: [88, 90, 118, 72, 86])
        #expect(frames.prefix(4).allSatisfy { $0.width == 118 })
        #expect(frames[4].width >= 86)
        #expect(frames[4].maxX == 676)
    }

    @Test
    func hostedGlassButtonsStayInTwoRowsAndMatchLayoutDuringResize() async throws {
        let state = PanelState()
        let hosting = NSHostingView(rootView: RowsFixture(state: state))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }

        for width in [676.0, 899, 900, 901, 1036, 1396, 676] {
            window.setContentSize(NSSize(width: width, height: 52))
            try await settle(hosting)
            #expect(state.frames.count == 10)
            for row in 0..<2 {
                let frames = try (0..<5).map { try #require(state.frames["\(row)-\($0)"]) }
                #expect(frames.allSatisfy { $0.minX >= -0.1 && $0.maxX <= width + 0.1 })
                #expect(frames.allSatisfy { abs($0.height - 22) < 0.1 && abs($0.minY - frames[0].minY) < 0.1 })
                for pair in zip(frames, frames.dropFirst()) { #expect(pair.0.maxX < pair.1.minX) }
                if row == 1 {
                    #expect(abs(frames[0].width - frames[2].width) < 0.1)
                    #expect(abs(frames[3].width - 32) < 0.1)
                    #expect(abs(frames[4].width - 32) < 0.1)
                }
            }
            #expect(abs(try #require(state.frames["0-0"]).minY) < 0.1)
            #expect(abs(try #require(state.frames["1-0"]).minY - 30) < 0.1)
        }
    }

    @Test(arguments: [false, true])
    func entireGlassSurfaceIsClickableAndDisabledActionsDoNotFire(iconOnly: Bool) async throws {
        var count = 0
        let width: CGFloat = iconOnly ? 32 : 160
        let makeButton = { (enabled: Bool) in
            MainPanelActionButton("Settings", icon: "slider.horizontal.3", id: "settings",
                                  help: "Playback Settings", enabled: enabled, iconOnly: iconOnly) { count += 1 }
                .frame(width: width, height: 22)
        }
        let hosting = NSHostingView(rootView: makeButton(true))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: width, height: 22))
        try await settle(hosting)
        for (index, point) in [NSPoint(x: 4, y: 11), NSPoint(x: width / 2, y: 3),
                               NSPoint(x: width - 4, y: 11), NSPoint(x: width / 2, y: 19)].enumerated() {
            try click(point, window: window, eventNumber: index * 2)
            #expect(count == index + 1)
        }
        hosting.rootView = makeButton(false)
        try await settle(hosting)
        try click(NSPoint(x: width / 2, y: 11), window: window, eventNumber: 20)
        #expect(count == 4)
    }

    @Test
    func minimumPanelKeepsSourceAndUtilityActionsAndDisabledStates() async throws {
        let controller = MockNativeWallpaperController()
        let model = AppViewModel(controller: controller, catalogProvider: MockCatalogProvider(wallpapers: []))
        let state = PanelState()
        let hosting = NSHostingView(rootView: PanelFixture(model: model, state: state))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 760, height: 480))
        try await settle(hosting)

        // Actual panel buttons at the minimum window size, in window coordinates.
        try click(NSPoint(x: 600, y: 75), window: window, eventNumber: 0)
        #expect(state.showsSourcePicker)
        try click(NSPoint(x: 662, y: 45), window: window, eventNumber: 2)
        #expect(model.isSettingsOpen)
        model.closeSettings()
        try click(NSPoint(x: 702, y: 45), window: window, eventNumber: 4)
        #expect(model.isMonitoringOpen)
        model.closeMonitoring()
        try click(NSPoint(x: 130, y: 45), window: window, eventNumber: 6)
        #expect(model.isTerminalWallpaperOpen)
        model.closeTerminalWallpaper()
        try click(NSPoint(x: 540, y: 45), window: window, eventNumber: 8)
        #expect(model.isCatalogOpen)
        model.navigateBackFromCatalog()
        try click(NSPoint(x: 335, y: 45), window: window, eventNumber: 10)
        #expect(model.isDownloadedWallpapersOpen)
        model.closeDownloadedWallpapers()
        #expect(controller.startCallCount == 0)
        #expect(controller.clearCallCount == 0)

        model.isBusy = true
        model.isPlaybackPaused = true
        try await settle(hosting)
        try click(NSPoint(x: 662, y: 45), window: window, eventNumber: 12)
        #expect(!model.isSettingsOpen)
        #expect(!model.canTogglePlayback)
        #expect(try #require(state.frames["panel"]).height == 72)

        model.isBusy = false
        model.statusMessage = String(repeating: "Status ", count: 100)
        model.optimizationInProgress = true
        model.optimizationLabel = String(repeating: "Progress ", count: 100)
        try await settle(hosting)
        #expect(try #require(state.frames["panel"]).height == 72)
    }

    @Test
    func sourceMenuStaysAnchoredAndInsideSmallAndWideWindows() {
        for size in [CGSize(width: 760, height: 480), CGSize(width: 900, height: 600),
                     CGSize(width: 984, height: 620), CGSize(width: 1440, height: 900)] {
            let button = CGRect(x: size.width - 270, y: size.height - 86, width: 228, height: 22)
            let menu = WallpaperSourceMenuLayout.frame(button: button, container: size)
            #expect(menu.minX >= 12 && menu.maxX <= size.width - 12)
            #expect(menu.minY >= 12 && menu.maxY <= size.height - 12)
            #expect(menu.midX == button.midX)
            #expect(menu.width == 288)
            #expect(menu.maxY == button.minY - 10)
        }
    }

    @Test
    func sourceMenuCentersWithoutShiftingAtEitherWindowEdge() {
        let size = CGSize(width: 760, height: 480)
        for button in [CGRect(x: 42, y: 394, width: 228, height: 22),
                       CGRect(x: 266, y: 394, width: 228, height: 22),
                       CGRect(x: 490, y: 394, width: 228, height: 22)] {
            let menu = WallpaperSourceMenuLayout.frame(button: button, container: size)
            #expect(menu.midX == button.midX)
            #expect(menu.minX >= 12 && menu.maxX <= size.width - 12)
            #expect(menu.width == (button.midX == size.width / 2 ? 300 : 288))
            #expect(menu.height == 116)
            #expect(menu.maxY == button.minY - 10)
        }
    }

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        hosting.layoutSubtreeIfNeeded()
    }

    private func click(_ point: NSPoint, window: NSWindow, eventNumber: Int) throws {
        for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber + offset,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}

@MainActor
private final class PanelState: ObservableObject {
    @Published var showsSourcePicker = false
    var frames: [String: CGRect] = [:]
}

private struct ButtonFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct RowsFixture: View {
    let state: PanelState

    var body: some View {
        GeometryReader { proxy in
            let compact = MainControlRowLayout.usesCompactTitles(contentWidth: proxy.size.width)
            VStack(spacing: 8) {
                MainControlRowLayout(row: .playback) {
                    recordedButton("Start", icon: "desktopcomputer", id: "0-0")
                    recordedButton("Lock", icon: "lock.display", id: "0-1")
                    recordedButton("Resume", icon: "play.fill", id: "0-2")
                    recordedButton("Remove", icon: "trash", id: "0-3")
                    recordedButton(compact ? "Change…" : "Change Wallpaper…", icon: "photo.on.rectangle", id: "0-4")
                }
                MainControlRowLayout(row: .library) {
                    recordedButton(compact ? "Terminal" : "Terminal Wallpaper", icon: "terminal", id: "1-0")
                    recordedButton(compact ? "Downloaded" : "Downloaded Wallpapers", icon: "arrow.down.circle", id: "1-1")
                    recordedButton(compact ? "Catalog" : "Wallpaper Catalog", icon: "square.grid.2x2", id: "1-2")
                    recordedButton("Settings", icon: "slider.horizontal.3", id: "1-3", iconOnly: true)
                    recordedButton("Monitoring", icon: "gauge.with.dots.needle.67percent", id: "1-4", iconOnly: true)
                }
            }
            .coordinateSpace(name: "controls")
            .onPreferenceChange(ButtonFramesKey.self) { state.frames = $0 }
        }
    }

    private func recordedButton(_ title: String, icon: String? = nil, id: String, iconOnly: Bool = false) -> some View {
        MainPanelActionButton(title, icon: icon, id: id, help: title, iconOnly: iconOnly) {}
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ButtonFramesKey.self,
                                       value: [id: proxy.frame(in: .named("controls"))])
            })
    }
}

private struct PanelFixture: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var state: PanelState

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 48, 1440)
            let height = proxy.size.height - 48
            ControlPanel(viewModel: model, isAdjustingSpeed: .constant(false),
                         showsWallpaperSourcePicker: $state.showsSourcePicker,
                         panelWidth: width, isCompactBySize: width < 1080 || height < 620,
                         isVeryCompactByHeight: height < 560)
                .frame(width: width)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ButtonFramesKey.self,
                                           value: ["panel": proxy.frame(in: .local)])
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
                .onPreferenceChange(ButtonFramesKey.self) { state.frames = $0 }
        }
    }
}
