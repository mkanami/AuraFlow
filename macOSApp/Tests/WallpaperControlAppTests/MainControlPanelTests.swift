import AppKit
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct MainControlPanelTests {
    @Test func repeatedMovementAndLiveResizeHaveOneInteractionLifetime() async throws {
        let activity = WindowInteractionActivity()
        var starts = 0
        var ends = 0
        activity.onStart = { starts += 1 }
        activity.onEnd = { ends += 1 }
        activity.begin()
        for _ in 0..<500 {
            activity.begin()
            activity.moved()
        }
        #expect(starts == 1 && ends == 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!activity.isActive && ends == 1)
        activity.begin(resizing: true)
        activity.moved()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(activity.isActive && starts == 2 && ends == 1)
        activity.end()
        activity.end()
        #expect(!activity.isActive && ends == 2)
    }

    @Test func interactionTimerDoesNotRetainClosedWindowActivity() async throws {
        var activity: WindowInteractionActivity? = WindowInteractionActivity()
        weak var released = activity
        var ends = 0
        activity?.onEnd = { ends += 1 }
        activity?.begin()
        activity?.moved()
        activity = nil
        #expect(released == nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(ends == 0)
    }

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
                #expect(frames[2].width == frames[3].width)
                #expect(frames[3].width == frames[4].width)
                #expect(frames[0].size == CGSize(width: 32, height: 22))
                #expect(frames[1].size == CGSize(width: 32, height: 22))
                // Vertical compaction must not change any horizontal allocation.
                #expect(abs(frames[2].width - (width - 96) / 3) < 0.01)
                #expect(frames[0].minX == 0)
                #expect(frames[1].minX == 40)
                #expect(frames[2].minX == 80)
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

    @Test(arguments: [22.0, 23, 24])
    func hostedGlassButtonsStayInTwoRowsAndMatchLayoutDuringResize(height: Double) async throws {
        let state = PanelState()
        let hosting = NSHostingView(rootView: RowsFixture(state: state, height: height))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }

        for width in [676.0, 899, 900, 901, 1036, 1396, 676] {
            window.setContentSize(NSSize(width: width, height: height * 2 + 8))
            try await settle(hosting)
            #expect(state.frames.count == 10)
            for row in 0..<2 {
                let frames = try (0..<5).map { try #require(state.frames["\(row)-\($0)"]) }
                #expect(frames.allSatisfy { $0.minX >= -0.1 && $0.maxX <= width + 0.1 })
                #expect(frames.allSatisfy { abs($0.height - height) < 0.1 && abs($0.minY - frames[0].minY) < 0.1 })
                for pair in zip(frames, frames.dropFirst()) { #expect(pair.0.maxX < pair.1.minX) }
                if row == 1 {
                    #expect(abs(frames[2].width - frames[4].width) < 0.1)
                    #expect(abs(frames[0].width - 32) < 0.1)
                    #expect(abs(frames[1].width - 32) < 0.1)
                }
            }
            #expect(abs(try #require(state.frames["0-0"]).minY) < 0.1)
            #expect(abs(try #require(state.frames["1-0"]).minY - (height + 8)) < 0.1)
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
        try click(NSPoint(x: 58, y: 45), window: window, eventNumber: 2)
        #expect(model.isSettingsOpen)
        model.closeSettings()
        try click(NSPoint(x: 98, y: 45), window: window, eventNumber: 4)
        #expect(model.isMonitoringOpen)
        model.closeMonitoring()
        try click(NSPoint(x: 218, y: 45), window: window, eventNumber: 6)
        #expect(model.isTerminalWallpaperOpen)
        model.closeTerminalWallpaper()
        try click(NSPoint(x: 610, y: 45), window: window, eventNumber: 8)
        #expect(model.isCatalogOpen)
        model.navigateBackFromCatalog()
        try click(NSPoint(x: 420, y: 45), window: window, eventNumber: 10)
        #expect(model.isDownloadedWallpapersOpen)
        model.closeDownloadedWallpapers()
        #expect(controller.startCallCount == 0)
        #expect(controller.clearCallCount == 0)

        model.isBusy = true
        model.isPlaybackPaused = true
        try await settle(hosting)
        try click(NSPoint(x: 58, y: 45), window: window, eventNumber: 12)
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
    func panelGrowthTapersSmoothlyWithoutFlatteningTallWindows() {
        #expect(MainControlPanelMetrics.width(availableWidth: 712) == 712)
        #expect(MainControlPanelMetrics.width(availableWidth: 900) == 900)
        #expect(MainControlPanelMetrics.width(availableWidth: 1180) == 1040)
        #expect(MainControlPanelMetrics.buttonHeight(panelWidth: 900, isVeryCompactByHeight: false) == 22)
        #expect(MainControlPanelMetrics.buttonHeight(panelWidth: 1000, isVeryCompactByHeight: false) == 23)
        #expect(MainControlPanelMetrics.buttonHeight(panelWidth: 1100, isVeryCompactByHeight: false) == 24)
        for width in [1180.0, 1920, 2560, 3840, 7680] {
            #expect(MainControlPanelMetrics.buttonHeight(panelWidth: width, isVeryCompactByHeight: false) == 24)
            #expect(MainControlPanelMetrics.buttonHeight(panelWidth: width, isVeryCompactByHeight: true) == 22)
        }
        #expect(MainControlPanelMetrics.buttonHeight(panelWidth: 1180, isVeryCompactByHeight: true) == 22)
        var previousWidth: CGFloat = 900
        var previousGrowth: CGFloat = 1
        var previousHeight: CGFloat = 22
        for available in stride(from: CGFloat(901), through: 4000, by: 1) {
            let width = MainControlPanelMetrics.width(availableWidth: available)
            let growth = width - previousWidth
            let height = MainControlPanelMetrics.buttonHeight(panelWidth: width, isVeryCompactByHeight: false)
            #expect(width <= available && width < 1180)
            #expect(growth > 0 && growth <= previousGrowth + 0.00001)
            #expect(height >= previousHeight && height <= 24)
            previousWidth = width
            previousGrowth = growth
            previousHeight = height
        }
    }

    @Test
    func resizingPanelDoesNotIntroduceWallpaperTitleRow() async throws {
        let model = AppViewModel(controller: MockNativeWallpaperController(),
                                 catalogProvider: MockCatalogProvider(wallpapers: []))
        model.statusMessage = nil
        let state = PanelState()
        let hosting = NSHostingView(rootView: PanelFixture(model: model, state: state)
            .environment(\.terminalPreviewTitle, String(repeating: "Wallpaper title ", count: 30)))
        let window = makeWindow(hosting)
        defer { window.orderOut(nil); window.close() }

        for size in [
            CGSize(width: 760, height: 480),
            CGSize(width: 984, height: 620),
            CGSize(width: 1440, height: 900),
            CGSize(width: 2000, height: 1200),
            CGSize(width: 2000, height: 480),
            CGSize(width: 760, height: 480),
        ] {
            window.setContentSize(size)
            try await settle(hosting)
            let panel = try #require(state.frames["panel"])
            let width = MainControlPanelMetrics.width(availableWidth: size.width - 48)
            let short = size.height - 48 < 560
            let compact = width < 1080 || size.height - 48 < 620
            let buttonHeight = MainControlPanelMetrics.buttonHeight(panelWidth: width, isVeryCompactByHeight: short)
            let expectedHeight = buttonHeight * 2 + (short ? 8 : (compact ? 10 : 12))
                + (short ? 20 : (compact ? 24 : 28))
            // Only the two button rows and existing insets/spacing remain.
            #expect(abs(panel.height - expectedHeight) < 0.1)
            #expect(abs(panel.width - width) < 0.1)
        }
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
    var height: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let compact = MainControlRowLayout.usesCompactTitles(contentWidth: proxy.size.width)
            VStack(spacing: 8) {
                MainControlRowLayout(row: .playback, height: height) {
                    recordedButton("Start", icon: "desktopcomputer", id: "0-0")
                    recordedButton("Lock", icon: "lock.display", id: "0-1")
                    recordedButton("Resume", icon: "play.fill", id: "0-2")
                    recordedButton("Remove", icon: "trash", id: "0-3")
                    recordedButton(compact ? "Change…" : "Change Wallpaper…", icon: "photo.on.rectangle", id: "0-4")
                }
                MainControlRowLayout(row: .library, height: height) {
                    recordedButton("Settings", icon: "slider.horizontal.3", id: "1-0", iconOnly: true)
                    recordedButton("Monitoring", icon: "gauge.with.dots.needle.67percent", id: "1-1", iconOnly: true)
                    recordedButton(compact ? "Terminal" : "Terminal Wallpaper", icon: "terminal", id: "1-2")
                    recordedButton(compact ? "Downloaded" : "Downloaded Wallpapers", icon: "arrow.down.circle", id: "1-3")
                    recordedButton(compact ? "Catalog" : "Wallpaper Catalog", icon: "square.grid.2x2", id: "1-4")
                }
            }
            .environment(\.mainControlButtonHeight, height)
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
            let width = MainControlPanelMetrics.width(availableWidth: proxy.size.width - 48)
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
