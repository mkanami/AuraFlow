import SwiftUI
import AVKit
import AppKit
import ImageIO
import QuartzCore

private struct AdaptiveGlassAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = AdaptiveGlassAppearance.default
}

extension EnvironmentValues {
    var adaptiveGlassAppearance: AdaptiveGlassAppearance {
        get { self[AdaptiveGlassAppearanceEnvironmentKey.self] }
        set { self[AdaptiveGlassAppearanceEnvironmentKey.self] = newValue }
    }
}

private func speedOverlayPillWidth(for availableWidth: CGFloat) -> CGFloat {
    min(max(availableWidth * 0.46, 420), 720)
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isAdjustingSpeed: Bool = false
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var window: NSWindow?
    @State private var lastActivityRefreshAt: Date = .distantPast
    @State private var isHoveringTopOverlay: Bool = false
    @State private var isHoveringBottomOverlay: Bool = false

    private var aspectRatio: CGFloat { mainScreenAspectRatio() }
    private let hideDelay: TimeInterval = 4.0
    private let activityRefreshThrottle: TimeInterval = 0.18
    private let topOverlayTopPadding: CGFloat = 18
    private let zoomedTopOverlayPadding: CGFloat = 48
    private let dragTitlebarTopOffset: CGFloat = -40
    private var dragTitlebarHeight: CGFloat {
        topOverlayTopPadding - dragTitlebarTopOffset
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 24
            let availableWidth = max(proxy.size.width - (horizontalPadding * 2), 0)
            let availableHeight = max(proxy.size.height - 48, 0)
            let controlPanelMaxWidth: CGFloat = 1440
            let controlPanelWidth = min(availableWidth, controlPanelMaxWidth)
            let catalogMaxWidth: CGFloat = 1040
            let overlayWidth = viewModel.isCatalogOpen ? min(availableWidth, catalogMaxWidth) : controlPanelWidth
            let isCompactBySize = controlPanelWidth < 1080 || availableHeight < 620
            let isVeryCompactByHeight = availableHeight < 560
            let topOverlayPadding = resolvedTopOverlayPadding()
            let bottomOverlayPadding = resolvedBottomOverlayPadding()

            ZStack {
                mainContent(
                    proxy: proxy,
                    availableWidth: availableWidth,
                    overlayWidth: overlayWidth,
                    controlPanelWidth: controlPanelWidth,
                    horizontalPadding: horizontalPadding,
                    topOverlayPadding: topOverlayPadding,
                    bottomOverlayPadding: bottomOverlayPadding,
                    isCompactBySize: isCompactBySize,
                    isVeryCompactByHeight: isVeryCompactByHeight
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .overlay {
                if viewModel.isSettingsOpen {
                    SettingsPopupOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                if viewModel.isMonitoringOpen {
                    MonitoringPopupOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                if viewModel.isDownloadedWallpapersOpen {
                    DownloadedWallpapersOverlay(viewModel: viewModel)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color.clear)
        .overlay(
            WindowAccessor(
                window: $window,
                onInteractionStart: beginWindowDrag,
                onInteractionEnd: endWindowDrag
            )
            .allowsHitTesting(false)
        )
        .task {
            await viewModel.loadStatus()
        }
        .onAppear {
            setupActivityMonitoring()
            handleUserActivity()
        }
        .onDisappear {
            teardownActivityMonitoring()
        }
        .environment(\.adaptiveGlassAppearance, viewModel.adaptiveGlassAppearance)
    }

    @ViewBuilder
    private func mainContent(
        proxy: GeometryProxy,
        availableWidth: CGFloat,
        overlayWidth: CGFloat,
        controlPanelWidth: CGFloat,
        horizontalPadding: CGFloat,
        topOverlayPadding: CGFloat,
        bottomOverlayPadding: CGFloat,
        isCompactBySize: Bool,
        isVeryCompactByHeight: Bool
    ) -> some View {
        ZStack(alignment: .top) {
            Color.clear

            PreviewLayer(
                player: viewModel.previewPlayer,
                aspectRatio: aspectRatio,
                scaleMode: viewModel.scaleMode
            )
            .ignoresSafeArea()

            TitlebarInteractionOverlay(
                window: window,
                protectedCenterWidth: viewModel.isCatalogOpen
                    ? nil
                    : speedOverlayPillWidth(for: availableWidth),
                onDragStateChange: { dragging in
                    if dragging {
                        beginWindowDrag()
                    } else {
                        endWindowDrag()
                    }
                }
            )
            .frame(height: dragTitlebarHeight)
            .padding(.top, dragTitlebarTopOffset)

            optimizedGlassControls(
                availableWidth: availableWidth,
                overlayWidth: overlayWidth,
                controlPanelWidth: controlPanelWidth,
                horizontalPadding: horizontalPadding,
                topOverlayPadding: topOverlayPadding,
                bottomOverlayPadding: bottomOverlayPadding,
                isCompactBySize: isCompactBySize,
                isVeryCompactByHeight: isVeryCompactByHeight
            )
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    @ViewBuilder
    private func optimizedGlassControls(
        availableWidth: CGFloat,
        overlayWidth: CGFloat,
        controlPanelWidth: CGFloat,
        horizontalPadding: CGFloat,
        topOverlayPadding: CGFloat,
        bottomOverlayPadding: CGFloat,
        isCompactBySize: Bool,
        isVeryCompactByHeight: Bool
    ) -> some View {
        // The two glass surfaces are far apart and do not morph into one another.
        // A full-window GlassEffectContainer reorders their background passes above
        // the controls on macOS 27, washing out labels without reducing useful work.
        glassControlContents(
            availableWidth: availableWidth,
            overlayWidth: overlayWidth,
            controlPanelWidth: controlPanelWidth,
            horizontalPadding: horizontalPadding,
            topOverlayPadding: topOverlayPadding,
            bottomOverlayPadding: bottomOverlayPadding,
            isCompactBySize: isCompactBySize,
            isVeryCompactByHeight: isVeryCompactByHeight
        )
    }

    private func glassControlContents(
        availableWidth: CGFloat,
        overlayWidth: CGFloat,
        controlPanelWidth: CGFloat,
        horizontalPadding: CGFloat,
        topOverlayPadding: CGFloat,
        bottomOverlayPadding: CGFloat,
        isCompactBySize: Bool,
        isVeryCompactByHeight: Bool
    ) -> some View {
        VStack(spacing: 0) {
            if !viewModel.isCatalogOpen {
                SpeedOverlay(
                    viewModel: viewModel,
                    isAdjustingSpeed: $isAdjustingSpeed,
                    availableWidth: availableWidth,
                    onHoverChanged: { hovering in
                        isHoveringTopOverlay = hovering
                        handleInterfaceHoverChange()
                    }
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topOverlayPadding)
                .auraControlsVisibility(controlsVisible)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                if let alert = viewModel.alertMessage {
                    ErrorBanner(text: alert)
                }

                if viewModel.isCatalogOpen {
                    WallpaperCatalogView(viewModel: viewModel)
                } else {
                    ControlPanel(
                        viewModel: viewModel,
                        isAdjustingSpeed: $isAdjustingSpeed,
                        panelWidth: controlPanelWidth,
                        isCompactBySize: isCompactBySize,
                        isVeryCompactByHeight: isVeryCompactByHeight
                    )
                    .disabled(!viewModel.isControllerAvailable)
                    .overlay(
                        Group {
                            if !viewModel.isControllerAvailable {
                                DisabledOverlay()
                            }
                        }
                    )
                }
            }
            .frame(width: overlayWidth, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomOverlayPadding)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringBottomOverlay = hovering
                handleInterfaceHoverChange()
            }
            .auraControlsVisibility(controlsVisible)
        }
    }
}

private extension View {
    @ViewBuilder
    func auraControlsVisibility(_ isVisible: Bool) -> some View {
        if #available(macOS 26.0, *) {
            // Native glass is rendered in a separate compositor pass and can remain
            // visible even when an ancestor reaches opacity zero. Remove the entire
            // subtree so hidden controls cannot leave an empty glass shell behind.
            if isVisible {
                self
            }
        } else {
            opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
        }
    }
}

struct TitlebarInteractionOverlay: View {
    let window: NSWindow?
    let protectedCenterWidth: CGFloat?
    let onDragStateChange: (Bool) -> Void

    var body: some View {
        TitlebarInteractionView(
            window: window,
            protectedCenterWidth: protectedCenterWidth,
            onDragStateChange: onDragStateChange
        )
    }
}

struct TitlebarInteractionView: NSViewRepresentable {
    let window: NSWindow?
    let protectedCenterWidth: CGFloat?
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> TitlebarInteractionNSView {
        let view = TitlebarInteractionNSView()
        view.windowReference = window
        view.protectedCenterWidth = protectedCenterWidth
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: TitlebarInteractionNSView, context: Context) {
        nsView.windowReference = window
        nsView.protectedCenterWidth = protectedCenterWidth
        nsView.onDragStateChange = onDragStateChange
    }
}

struct HoverTrackingArea: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

final class TitlebarInteractionNSView: NSView {
    weak var windowReference: NSWindow?
    var protectedCenterWidth: CGFloat?
    var onDragStateChange: ((Bool) -> Void)?

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let protectedCenterWidth {
            let protectedRect = NSRect(
                x: bounds.midX - (protectedCenterWidth * 0.5),
                y: bounds.minY,
                width: protectedCenterWidth,
                height: bounds.height
            )
            if protectedRect.contains(point) {
                return nil
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let targetWindow = windowReference ?? window else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            toggleFastWindowZoom(targetWindow)
            return
        }

        onDragStateChange?(true)
        targetWindow.performDrag(with: event)
        onDragStateChange?(false)
    }
}

struct PreviewLayer: View {
    let player: AVPlayer?
    let aspectRatio: CGFloat
    let scaleMode: WallpaperScaleMode

    var body: some View {
        VideoPreview(player: player, videoGravity: scaleMode.previewGravity)
            .aspectRatio(aspectRatio, contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

struct ControlPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isAdjustingSpeed: Bool
    let panelWidth: CGFloat
    let isCompactBySize: Bool
    let isVeryCompactByHeight: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    private var widthScale: CGFloat {
        max(0.82, min(1.0, panelWidth / 1180))
    }

    private var panelHorizontalInset: CGFloat {
        isCompactBySize ? 18 : 22
    }

    private var panelVerticalInset: CGFloat {
        if isVeryCompactByHeight {
            return 10
        }
        return isCompactBySize ? 12 : 14
    }

    private var rowSpacing: CGFloat {
        if isVeryCompactByHeight {
            return 8
        }
        return isCompactBySize ? 10 : 12
    }

    private var primarySpacing: CGFloat {
        if isVeryCompactByHeight {
            return 6
        }
        return isCompactBySize ? 8 : 12
    }

    private var secondarySpacing: CGFloat {
        if isVeryCompactByHeight {
            return 6
        }
        return isCompactBySize ? 8 : 12
    }

    private var controlSize: ControlSize {
        if isVeryCompactByHeight {
            return .mini
        }
        return isCompactBySize ? .small : .regular
    }

    private var primaryButtonWidth: CGFloat {
        scaledWidth(104, min: 92)
    }

    private var removeButtonWidth: CGFloat {
        scaledWidth(178, min: 154)
    }

    private var catalogButtonWidth: CGFloat {
        scaledWidth(184, min: 160)
    }

    private var downloadedButtonWidth: CGFloat {
        scaledWidth(226, min: 198)
    }

    private var changeWallpaperButtonWidth: CGFloat {
        scaledWidth(228, min: 196)
    }

    private var settingsButtonWidth: CGFloat {
        scaledWidth(126, min: 112)
    }

    private var monitoringButtonWidth: CGFloat {
        scaledWidth(154, min: 136)
    }

    private var rowContentWidth: CGFloat {
        max(panelWidth - (panelHorizontalInset * 2), 0)
    }

    private var controlButtonsRowWidth: CGFloat {
        (primaryButtonWidth * 2) + removeButtonWidth + (primarySpacing * 2)
    }

    private var actionButtonsRowWidth: CGFloat {
        controlButtonsRowWidth + changeWallpaperButtonWidth
    }

    private var libraryButtonsRowWidth: CGFloat {
        catalogButtonWidth + downloadedButtonWidth + primarySpacing
    }

    private var secondaryButtonsRowWidth: CGFloat {
        settingsButtonWidth + monitoringButtonWidth + secondarySpacing
    }

    private var actionRowGap: CGFloat {
        max(primarySpacing, rowContentWidth - actionButtonsRowWidth)
    }

    private var bottomRowGap: CGFloat {
        max(secondarySpacing, rowContentWidth - secondaryButtonsRowWidth - libraryButtonsRowWidth)
    }

    private var showsStatusMessage: Bool {
        !isVeryCompactByHeight && panelWidth >= 860
    }

    private var showsOptimizationProgress: Bool {
        !isVeryCompactByHeight && panelWidth >= 820
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if !isVeryCompactByHeight {
                HStack(alignment: .top, spacing: 0) {
                    videoInfo
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 0) {
                ControlButtons(
                    viewModel: viewModel,
                    spacing: primarySpacing,
                    primaryButtonWidth: primaryButtonWidth,
                    removeButtonWidth: removeButtonWidth
                )
                .frame(width: controlButtonsRowWidth, alignment: .leading)

                Color.clear
                    .frame(width: actionRowGap, height: 1)

                changeWallpaperButton
                    .frame(width: changeWallpaperButtonWidth)
                    .layoutPriority(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: secondarySpacing) {
                    settingsButton
                        .frame(width: settingsButtonWidth)

                    monitoringButton
                        .frame(width: monitoringButtonWidth)
                }
                .frame(width: secondaryButtonsRowWidth, alignment: .leading)

                Color.clear
                    .frame(width: bottomRowGap, height: 1)

                HStack(alignment: .center, spacing: primarySpacing) {
                    catalogButton
                        .frame(width: catalogButtonWidth)
                        .layoutPriority(2)

                    downloadedWallpapersButton
                        .frame(width: downloadedButtonWidth)
                        .layoutPriority(2)
                }
                .frame(width: libraryButtonsRowWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsStatusMessage, let message = viewModel.statusMessage {
                Text(message)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.optimizationInProgress && showsOptimizationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = viewModel.optimizationLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    ProgressView(value: viewModel.optimizationProgress)
                        .progressViewStyle(.linear)
                }
            }
        }
        .controlSize(controlSize)
        .padding(.vertical, panelVerticalInset)
        .padding(.horizontal, panelHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 14,
                material: .clear,
                alphaMultiplier: adaptiveGlassAppearance.bottomGlassAlpha,
                protectionOverlayOpacity: adaptiveGlassAppearance.bottomProtectionOverlayOpacity
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
        .environment(\.colorScheme, .dark)
    }

    private var catalogButton: some View {
        Button {
            viewModel.openCatalog()
        } label: {
            Text("Wallpaper Catalog")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canClearWallpaper)
    }

    private var downloadedWallpapersButton: some View {
        Button {
            viewModel.openDownloadedWallpapers()
        } label: {
            Text("Downloaded Wallpapers")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canClearWallpaper)
    }

    private var changeWallpaperButton: some View {
        Button {
            viewModel.chooseVideo()
        } label: {
            Text("Change Wallpaper…")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canClearWallpaper)
    }

    private var settingsButton: some View {
        Button {
            viewModel.openSettings()
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3.circle.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(viewModel.isBusy)
    }

    private var monitoringButton: some View {
        Button {
            viewModel.openMonitoring()
        } label: {
            Label("Monitoring", systemImage: "gauge.with.dots.needle.67percent")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canOpenMonitoring)
    }

    private func scaledWidth(_ base: CGFloat, min minWidth: CGFloat) -> CGFloat {
        max(minWidth, base * widthScale)
    }

    private var videoInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.96))
            Text(viewModel.selectedVideoName)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .layoutPriority(0)
    }
}

struct SettingsPopupOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.42 : 0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.closeSettings()
                }

            SettingsPopupCard(viewModel: viewModel)
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: viewModel.isSettingsOpen)
        .zIndex(50)
    }
}

struct SettingsPopupCard: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Playback Settings", systemImage: "gearshape.2.fill")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.closeSettings()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(AuraPlainPressButtonStyle())
            }

            Divider()

            Toggle(isOn: Binding(
                get: { viewModel.autostartEnabled },
                set: { newValue in viewModel.toggleAutostart(newValue) }
            )) {
                Label("Launch at Login", systemImage: "power")
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.canToggleAutostart)

            Toggle(isOn: Binding(
                get: { viewModel.pauseOnFullscreenEnabled },
                set: { newValue in viewModel.togglePauseOnFullscreen(newValue) }
            )) {
                Label("Auto-Pause on Fullscreen Apps", systemImage: "display")
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.canTogglePauseOnFullscreen)

            Toggle(isOn: Binding(
                get: { viewModel.blendInterpolationEnabled },
                set: { newValue in viewModel.toggleBlendInterpolation(newValue) }
            )) {
                Label("Blend Interpolation", systemImage: "sparkles.tv")
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.canToggleBlendInterpolation)

            Picker(
                "Scale Algorithm",
                selection: Binding(
                    get: { viewModel.scaleMode },
                    set: { viewModel.setScaleMode($0) }
                )
            ) {
                ForEach(WallpaperScaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.canToggleScaleMode)

            Divider().padding(.vertical, 4)

            Text("Video Optimization")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            Toggle(isOn: Binding(
                get: { viewModel.optimizationEnabled },
                set: { viewModel.setOptimizationEnabled($0) }
            )) {
                Text("Enable Auto Optimization")
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.canChangeOptimizationSettings)

            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { viewModel.optimizationTranscodeH264ToHEVC },
                    set: { viewModel.setOptimizationTranscodeH264ToHEVC($0) }
                )) {
                    Text("H.264 → HEVC")
                }
                .toggleStyle(.checkbox)
                .disabled(!viewModel.optimizationEnabled || !viewModel.canChangeOptimizationSettings)

                Toggle(isOn: Binding(
                    get: { viewModel.optimizationAllowAV1Passthrough },
                    set: { viewModel.setOptimizationAllowAV1Passthrough($0) }
                )) {
                    Text("Keep AV1 (HW Decode)")
                }
                .toggleStyle(.checkbox)
                .disabled(!viewModel.optimizationEnabled || !viewModel.canChangeOptimizationSettings)
            }

            Toggle(isOn: Binding(
                get: { viewModel.optimizationForceSoftwareAV1Encode },
                set: { viewModel.setOptimizationForceSoftwareAV1Encode($0) }
            )) {
                Text("Force AV1 Encode (Software)")
            }
            .toggleStyle(.checkbox)
            .disabled(
                !viewModel.optimizationEnabled
                    || !viewModel.canChangeOptimizationSettings
                    || !viewModel.optimizationHardwareAV1DecodeAvailable
            )

            Picker(
                "Optimization Profile",
                selection: Binding(
                    get: { viewModel.optimizationProfile },
                    set: { viewModel.setOptimizationProfile($0) }
                )
            ) {
                ForEach(OptimizationProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.optimizationEnabled || !viewModel.canChangeOptimizationSettings)

            if viewModel.optimizationHardwareAV1DecodeAvailable {
                Text("AV1 hardware encode is unavailable on Mac. Force AV1 uses software ffmpeg and can be CPU intensive.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Force AV1 encode is disabled because this Mac has no hardware AV1 decode.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)

            Button {
                viewModel.clearCache()
            } label: {
                Label("Clear Cache", systemImage: "trash")
            }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            .disabled(!viewModel.canClearCache)

            if viewModel.optimizationInProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = viewModel.optimizationLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: viewModel.optimizationProgress)
                        .progressViewStyle(.linear)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 18,
                material: .clear
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

struct MonitoringPopupOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.42 : 0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.closeMonitoring()
                }

            MonitoringPopupCard(viewModel: viewModel)
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: viewModel.isMonitoringOpen)
        .zIndex(60)
    }
}

struct MonitoringPopupCard: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wallpaper Monitoring", systemImage: "chart.bar.xaxis")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.closeMonitoring()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(AuraPlainPressButtonStyle())
            }

            Divider()

            if let metrics = viewModel.monitoringSnapshot {
                let cpu = metrics.cpu_percent ?? 0
                let memory = metrics.memory_mb ?? 0
                let virtualMemory = metrics.virtual_memory_mb ?? 0
                let threads = metrics.thread_count ?? 0
                let processCount = metrics.process_count ?? metrics.daemon_pids?.count ?? (metrics.pid == nil ? 0 : 1)
                let screens = metrics.health?.screens ?? 0
                let windows = metrics.health?.windows ?? 0
                let rate = metrics.health?.player_rate ?? 0

                MonitoringRow(label: "Daemon PID", value: metrics.pid.map(String.init) ?? "n/a")
                MonitoringRow(label: "Daemon Processes", value: "\(processCount)")
                MonitoringRow(label: "Running", value: metrics.running ? "Yes" : "No")
                MonitoringRow(label: "CPU", value: String(format: "%.1f%%", cpu))
                MonitoringRow(label: "Memory", value: String(format: "%.1f MB", memory))
                MonitoringRow(label: "Virtual Memory", value: String(format: "%.1f MB", virtualMemory))
                MonitoringRow(label: "Threads", value: "\(threads)")
                MonitoringRow(label: "Screens/Windows", value: "\(screens)/\(windows)")
                MonitoringRow(label: "Player Rate", value: String(format: "%.2fx", rate))

                if let pids = metrics.daemon_pids, !pids.isEmpty {
                    let rendered = pids.prefix(4).map(String.init).joined(separator: ", ")
                    let suffix = pids.count > 4 ? ", ..." : ""
                    Text("PIDs: \(rendered)\(suffix)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let reason = metrics.health?.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Health: \(reason)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            } else {
                Text("Collecting daemon metrics...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = viewModel.monitoringErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button {
                    viewModel.refreshMonitoring()
                } label: {
                    if viewModel.isMonitoringRefreshing {
                        Label("Refreshing…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(viewModel.isMonitoringRefreshing)

                Spacer()
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 18,
                material: .clear
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

struct MonitoringRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}

struct DownloadedWallpapersOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.42 : 0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.closeDownloadedWallpapers()
                }

            DownloadedWallpapersCard(viewModel: viewModel)
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: viewModel.isDownloadedWallpapersOpen)
        .zIndex(70)
    }
}

struct DownloadedWallpapersCard: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Downloaded Wallpapers", systemImage: "arrow.down.circle.fill")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(viewModel.downloadedCatalogWallpapers.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    viewModel.closeDownloadedWallpapers()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(AuraPlainPressButtonStyle())
            }

            Divider()

            if viewModel.downloadedCatalogWallpapers.isEmpty {
                Text("No downloaded wallpapers yet. Use Download & Apply in the catalog.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.downloadedCatalogWallpapers) { wallpaper in
                            HStack(spacing: 12) {
                                CatalogPreviewImage(
                                    url: wallpaper.effectivePreviewURL,
                                    title: wallpaper.title,
                                    referer: wallpaper.sourcePageURL
                                )
                                .frame(width: 140, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(wallpaper.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(wallpaper.category) • \(wallpaper.attribution)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(wallpaper.localURL.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer(minLength: 10)

                                Button {
                                    viewModel.applyDownloadedCatalogWallpaper(wallpaper)
                                } label: {
                                    Label("Apply", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                            }
                            .padding(8)
                            .background(AuraGlassInsetCard())
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 18,
                material: .clear
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

struct ControlButtons: View {
    @ObservedObject var viewModel: AppViewModel
    let spacing: CGFloat
    let primaryButtonWidth: CGFloat
    let removeButtonWidth: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            startButton
                .frame(width: primaryButtonWidth)
            stopButton
                .frame(width: primaryButtonWidth)
            clearButton
                .frame(width: removeButtonWidth)
        }
    }

    private var startButton: some View {
        Button {
            viewModel.start()
        } label: {
            Label("Start", systemImage: "desktopcomputer")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canStart)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            viewModel.stop()
        } label: {
            Label("Stop", systemImage: "stop.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canStop)
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            viewModel.clearWallpaper()
        } label: {
            Text("Remove")
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle())
        .disabled(!viewModel.canClearWallpaper)
    }
}

struct WallpaperCatalogView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var isDetailOpened: Bool {
        viewModel.selectedCatalogWallpaper != nil
    }

    private var catalogCountText: String {
        let filteredCount = viewModel.filteredCatalogWallpapers.count
        if let selectedGroup = viewModel.selectedCatalogGroup {
            let groupCount = viewModel.catalogWallpaperCount(in: selectedGroup)
            guard filteredCount != groupCount else { return "\(groupCount) \(selectedGroup.title)" }
            return "\(filteredCount)/\(groupCount) \(selectedGroup.title)"
        }

        let totalCount = viewModel.catalogWallpapers.count
        guard filteredCount != totalCount else { return "\(totalCount)" }
        return "\(filteredCount)/\(totalCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    viewModel.navigateBackFromCatalog()
                } label: {
                    Label(
                        isDetailOpened ? "Back" : "Close",
                        systemImage: isDetailOpened ? "chevron.left" : "xmark"
                    )
                }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .keyboardShortcut(.escape, modifiers: [])

                Text(viewModel.selectedCatalogWallpaper?.title ?? "Wallpaper Catalog")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.86))

                Spacer()

                if viewModel.selectedCatalogWallpaper == nil {
                    if viewModel.catalogIsRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(catalogCountText)
                        .font(.caption2)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.64))
                }
            }
            .zIndex(10)

            if viewModel.selectedCatalogWallpaper == nil {
                HStack(spacing: 10) {
                    ForEach(CatalogWallpaperGroup.allCases) { group in
                        CatalogGroupFilterButton(
                            group: group,
                            count: viewModel.catalogWallpaperCount(in: group),
                            isSelected: viewModel.selectedCatalogGroup == group
                        ) {
                            viewModel.toggleCatalogGroup(group)
                        }
                    }

                    Spacer(minLength: 8)

                    TextField("Search catalog", text: $viewModel.catalogSearchText)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.94) : Color.black.opacity(0.84))
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(AuraGlassInsetCard(emphasized: true))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.9)
                        )
                        .frame(maxWidth: 260)
                }
                .zIndex(9)
            }

            if let wallpaper = viewModel.selectedCatalogWallpaper {
                WallpaperCatalogDetailView(viewModel: viewModel, wallpaper: wallpaper)
                    .zIndex(0)
            } else {
                WallpaperCatalogGridView(viewModel: viewModel)
                    .zIndex(0)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: 320, alignment: .topLeading)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 14,
                material: .clear
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.26), radius: 12, x: 0, y: 7)
        .environment(\.colorScheme, .dark)
    }
}

struct CatalogGroupFilterButton: View {
    let group: CatalogWallpaperGroup
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: group.systemImage)
                    .font(.caption2.weight(.semibold))
                Text(group.title)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.82))
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(AuraGlassInsetCard(cornerRadius: 9, emphasized: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.10),
                        lineWidth: isSelected ? 1.1 : 0.9
                    )
            )
        }
        .buttonStyle(AuraPlainPressButtonStyle())
        .accessibilityLabel("\(group.title) wallpapers")
        .accessibilityValue(isSelected ? "Selected, \(count)" : "\(count)")
    }
}

struct WallpaperCatalogGridView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    private func restoreCatalogScrollPosition(using proxy: ScrollViewProxy) {
        guard viewModel.selectedCatalogWallpaper == nil,
              let targetID = viewModel.catalogScrollTargetID else {
            return
        }

        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.filteredCatalogWallpapers) { wallpaper in
                        Button {
                            viewModel.openCatalogWallpaper(wallpaper)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CatalogPreviewImage(
                                    url: wallpaper.previewImageURL,
                                    title: wallpaper.title,
                                    referer: wallpaper.sourcePageURL
                                )
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                Text(wallpaper.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.86))
                                    .lineLimit(1)
                                Text(wallpaper.category)
                                    .font(.caption)
                                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.64))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(AuraGlassInsetCard())
                        }
                        .buttonStyle(AuraPlainPressButtonStyle())
                        .id(wallpaper.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                restoreCatalogScrollPosition(using: proxy)
            }
            .onChange(of: viewModel.catalogScrollTargetID) { _ in
                restoreCatalogScrollPosition(using: proxy)
            }
        }
    }
}

struct WallpaperCatalogDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let wallpaper: CatalogWallpaper
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CatalogPreviewImage(
                url: wallpaper.previewImageURL,
                title: wallpaper.title,
                referer: wallpaper.sourcePageURL
            )
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(wallpaper.title)
                .font(.headline)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.86))

            Text("Category: \(wallpaper.category) • Source: \(wallpaper.attribution)")
                .font(.caption)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.80) : Color.black.opacity(0.66))

            HStack(spacing: 10) {
                Button {
                    viewModel.applyCatalogWallpaper(wallpaper)
                } label: {
                    if viewModel.isDownloading(wallpaper) {
                        Label("Downloading…", systemImage: "arrow.down.circle")
                    } else {
                        Label("Download & Apply", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(!viewModel.canApplyCatalogWallpaper)

                if let sourceURL = wallpaper.sourcePageURL {
                    Button {
                        NSWorkspace.shared.open(sourceURL)
                    } label: {
                        Label("Open Source", systemImage: "link")
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                }

                Spacer()
            }
        }
    }
}

struct CatalogPreviewImage: View {
    let url: URL?
    let title: String
    let referer: URL?
    @StateObject private var loader = CatalogPreviewImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                previewFallback
            }
        }
        .task(id: cacheKey) {
            loader.load(url: url, referer: referer)
        }
        .onDisappear {
            loader.cancel()
        }
    }

    private var cacheKey: String {
        [
            url?.absoluteString ?? "nil",
            referer?.absoluteString ?? "nil",
        ].joined(separator: "|")
    }

    private var previewFallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.55), Color.cyan.opacity(0.35), Color.indigo.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(8)
                .lineLimit(2)
        }
    }
}

@MainActor
final class CatalogPreviewImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private struct DecodedPreview: @unchecked Sendable {
        let image: NSImage
        let cost: Int
    }

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var task: Task<Void, Never>?

    static func clearCache() {
        cache.removeAllObjects()
    }

    func load(url: URL?, referer: URL?) {
        task?.cancel()
        task = nil
        image = nil

        guard let url else {
            return
        }

        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        task = Task { [weak self] in
            guard let self else { return }

            if url.isFileURL {
                let decoded: DecodedPreview? = await Task.detached(priority: .utility) {
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                        return nil
                    }
                    return Self.decodePreviewImage(data: data)
                }.value
                guard !Task.isCancelled, let decoded else { return }
                Self.cache.setObject(decoded.image, forKey: url as NSURL, cost: decoded.cost)
                self.image = decoded.image
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("AuraFlow/1.1", forHTTPHeaderField: "User-Agent")
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    return
                }
                let decoded = await Task.detached(priority: .utility) {
                    Self.decodePreviewImage(data: data)
                }.value
                guard !Task.isCancelled, let decoded else { return }
                Self.cache.setObject(decoded.image, forKey: url as NSURL, cost: decoded.cost)
                self.image = decoded.image
            } catch {
                // Keep fallback preview on failures.
            }
        }
    }

    nonisolated private static func decodePreviewImage(data: Data) -> DecodedPreview? {
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary

        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            let thumbnailOptions: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
            ] as CFDictionary

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
                let image = NSImage(cgImage: cgImage, size: .zero)
                let cost = max(cgImage.width * cgImage.height * 4, 1)
                return DecodedPreview(image: image, cost: cost)
            }
        }

        guard let image = NSImage(data: data) else {
            return nil
        }
        return DecodedPreview(image: image, cost: 4 * 1024 * 1024)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

struct SpeedOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isAdjustingSpeed: Bool
    let availableWidth: CGFloat
    var onHoverChanged: ((Bool) -> Void)? = nil
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    private var pillWidth: CGFloat {
        speedOverlayPillWidth(for: availableWidth)
    }

    private var compactControlSize: ControlSize {
        availableWidth < 900 ? .small : .regular
    }

    var body: some View {
        HStack(spacing: 14) {
            Label("Speed", systemImage: "speedometer")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            AuraLegacySpeedSlider(
                value: viewModel.playbackSpeed,
                range: 0.25...2.0,
                step: 0.05,
                onValueChanged: { newValue in
                    viewModel.setPreviewPlaybackSpeed(newValue)
                },
                onEditingChanged: { editing in
                    isAdjustingSpeed = editing
                    if !editing {
                        viewModel.updateSpeed(viewModel.playbackSpeed)
                    }
                }
            )
            .frame(maxWidth: .infinity)

            Text(String(format: "%.2fx", viewModel.playbackSpeed))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .controlSize(compactControlSize)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(width: pillWidth)
        .background(
            AuraGlassCapsuleSurface(
                material: .clear,
                alphaMultiplier: adaptiveGlassAppearance.topGlassAlpha,
                protectionOverlayOpacity: adaptiveGlassAppearance.topProtectionOverlayOpacity
            )
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1.0)
        )
        .overlay(HoverTrackingArea(onHoverChanged: { hovering in
            onHoverChanged?(hovering)
        }))
        .shadow(color: Color.black.opacity(0.16), radius: 4, x: 0, y: 2)
        .environment(\.colorScheme, .dark)
    }
}

private struct AuraLegacySpeedSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChanged: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    private var normalizedValue: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(CGFloat(fraction), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 4
            let knobSize = CGSize(width: 10, height: 24)
            let usableWidth = max(proxy.size.width - knobSize.width, 1)
            let knobX = normalizedValue * usableWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: trackHeight)

                AuraLegacySliderDashes()
                    .mask(
                        Capsule()
                            .frame(height: trackHeight)
                    )
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: knobSize.width * 0.5, style: .continuous)
                    .fill(Color.white.opacity(0.78))
                    .frame(width: knobSize.width, height: knobSize.height)
                    .shadow(color: Color.black.opacity(0.20), radius: 2, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: knobSize.width * 0.5, style: .continuous)
                            .stroke(Color.white.opacity(0.26), lineWidth: 0.8)
                    )
                    .offset(x: knobX, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let position = min(max(gesture.location.x - (knobSize.width * 0.5), 0), usableWidth)
                        let fraction = position / usableWidth
                        let rawValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                        onValueChanged(snapped(rawValue))
                    }
                    .onEnded { gesture in
                        let position = min(max(gesture.location.x - (knobSize.width * 0.5), 0), usableWidth)
                        let fraction = position / usableWidth
                        let rawValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                        onValueChanged(snapped(rawValue))
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
    }

    private func snapped(_ value: Double) -> Double {
        guard step > 0 else { return value }
        let snappedValue = (value / step).rounded() * step
        return min(max(snappedValue, range.lowerBound), range.upperBound)
    }
}

private struct AuraLegacySliderDashes: View {
    private let dashCount = 38

    var body: some View {
        GeometryReader { proxy in
            let dashWidth: CGFloat = 1
            let dashHeight = max(proxy.size.height + 4, 8)
            let spacing = max((proxy.size.width - (CGFloat(dashCount) * dashWidth)) / CGFloat(max(dashCount - 1, 1)), 1)

            HStack(spacing: spacing) {
                ForEach(0..<dashCount, id: \.self) { _ in
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: dashWidth, height: dashHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
    }
}

struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer?
    let videoGravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> AuraPreviewPlayerView {
        let view = AuraPreviewPlayerView()
        view.update(player: player, videoGravity: videoGravity)
        return view
    }

    func updateNSView(_ nsView: AuraPreviewPlayerView, context: Context) {
        nsView.update(player: player, videoGravity: videoGravity)
    }
}

final class AuraPreviewPlayerView: NSView {
    override var isOpaque: Bool {
        true
    }

    private var playerLayer: AVPlayerLayer {
        guard let layer = self.layer as? AVPlayerLayer else {
            let fallback = AVPlayerLayer()
            self.layer = fallback
            return fallback
        }
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.needsDisplayOnBoundsChange = false
    }

    func update(player: AVPlayer?, videoGravity: AVLayerVideoGravity) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if playerLayer.videoGravity != videoGravity {
            playerLayer.videoGravity = videoGravity
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct DisabledOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.black.opacity(0.5))
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3.weight(.semibold))
                    Text("Native wallpaper runtime unavailable")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.92))
                }
                .padding(14)
            )
    }
}

struct AuraPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AuraPanelButton(configuration: configuration)
    }
}

private struct AuraPanelButton: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var usesNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private var baseSurfaceOpacity: CGFloat {
        guard isEnabled else { return 0.028 }
        if configuration.isPressed {
            return usesNativeLiquidGlass ? 0.12 : 0.10
        }
        if isHovering {
            return usesNativeLiquidGlass ? 0.095 : 0.085
        }
        return usesNativeLiquidGlass ? 0.055 : 0.05
    }

    private var protectionOpacity: CGFloat {
        let adaptive = adaptiveGlassAppearance.bottomButtonProtectionOpacity
        return (usesNativeLiquidGlass ? 0.035 : 0.10) + adaptive
    }

    private var topHighlightOpacity: CGFloat {
        guard isEnabled else { return 0.035 }
        let adaptive = adaptiveGlassAppearance.bottomButtonHighlightOpacity
        return min(0.22, (usesNativeLiquidGlass ? 0.105 : 0.075) + adaptive)
    }

    private var labelColor: Color {
        guard isEnabled else { return Color.white.opacity(0.50) }
        return Color.white.opacity(configuration.isPressed ? 0.90 : 0.97)
    }

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(labelColor)
            .shadow(color: Color.black.opacity(isEnabled ? 0.18 : 0.06), radius: 1, x: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .padding(.horizontal, 12)
            .background {
                ZStack {
                    shape.fill(Color.black.opacity(protectionOpacity))
                    shape.fill(Color.white.opacity(baseSurfaceOpacity))
                    LinearGradient(
                        colors: [
                            Color.white.opacity(topHighlightOpacity),
                            Color.white.opacity(isEnabled ? 0.045 : 0.018),
                            Color.black.opacity(isEnabled ? 0.035 : 0.06),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isEnabled ? (isHovering ? 0.34 : 0.26) : 0.10),
                            Color.white.opacity(isEnabled ? 0.10 : 0.055),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .overlay {
                shape
                    .inset(by: 1.1)
                    .stroke(Color.white.opacity(isEnabled ? 0.055 : 0.02), lineWidth: 0.5)
            }
            .contentShape(shape)
            .clipShape(shape)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct AuraGlassButtonStyle: ButtonStyle {
    enum Tone {
        case secondary
        case accent
        case destructive
    }

    var tone: Tone = .secondary
    var fillWidth = true

    func makeBody(configuration: Configuration) -> some View {
        // A separate live glass surface for every button multiplies the number of
        // compositor passes over the video. This lightweight treatment keeps the
        // same visual language while reserving real glass for the containing panel.
        AuraGlassButton(configuration: configuration, tone: tone, fillWidth: fillWidth)
    }
}

struct AuraPlainPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AuraPlainPressButton(configuration: configuration)
    }
}

private struct AuraGlassButton: View {
    let configuration: ButtonStyle.Configuration
    let tone: AuraGlassButtonStyle.Tone
    let fillWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var baseTint: Color {
        switch tone {
        case .secondary:
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.white.opacity(0.06)
        case .accent:
            return Color(red: 0.67, green: 0.28, blue: 0.78)
        case .destructive:
            return Color(red: 0.82, green: 0.28, blue: 0.40)
        }
    }

    private var tintOpacity: CGFloat {
        switch tone {
        case .secondary:
            return 0.22
        case .accent:
            return 0.66
        case .destructive:
            return 0.52
        }
    }

    private var borderOpacity: CGFloat {
        switch tone {
        case .secondary:
            return 0.16
        case .accent:
            return 0.40
        case .destructive:
            return 0.34
        }
    }

    private var backdropColor: Color {
        switch tone {
        case .secondary:
            return colorScheme == .dark
                ? Color.black.opacity(0.24)
                : Color.black.opacity(0.20)
        case .accent:
            return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.14)
        case .destructive:
            return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.14)
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .secondary:
            return Color.white.opacity(0.94)
        case .accent, .destructive:
            return .white.opacity(isEnabled ? 0.96 : 0.82)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var pressedOverlayColor: Color {
        Color.white.opacity(configuration.isPressed ? 0.10 : 0.0)
    }

    @ViewBuilder
    private var labelContent: some View {
        if fillWidth {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            configuration.label
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    var body: some View {
        labelContent
            .font(.body.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .shadow(color: Color.black.opacity(tone == .secondary ? 0.10 : 0.18), radius: 1, x: 0, y: 1)
            .padding(.vertical, 3)
            .padding(.horizontal, 12)
            .background {
                ZStack {
                    shape.fill(backdropColor)
                    shape.fill(baseTint.opacity(tintOpacity))
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.04),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                    shape.fill(pressedOverlayColor)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.stroke(Color.white.opacity(borderOpacity), lineWidth: 1.0)
            }
            .clipShape(shape)
            .opacity(isEnabled ? 1.0 : 0.62)
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AuraPlainPressButton: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1.0) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.18 : 0.0),
                radius: configuration.isPressed ? 2 : 0,
                x: 0,
                y: configuration.isPressed ? 1 : 0
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum AuraSurfaceMaterial: Equatable {
    case regular
    case clear
}

private struct AuraGlassRoundedSurface: View {
    let cornerRadius: CGFloat
    var material: AuraSurfaceMaterial = .clear
    var washColor: Color = .clear
    var alphaMultiplier: CGFloat = 1.0
    var protectionOverlayOpacity: CGFloat = 0.0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        let strength = min(max(Double(alphaMultiplier), 0), 1)

        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(material.systemGlass, in: shape)
            } else {
                // SwiftUI Material maps to the efficient system visual-effect blur
                // used by macOS 13–15; no custom Core Image filters are involved.
                shape
                    .fill(material.legacyMaterial)
                    .opacity(strength)
            }
        }
        .overlay {
            if washColor != .clear {
                shape.fill(washColor)
            }
        }
        .overlay {
            if protectionOverlayOpacity > 0.001 {
                shape.fill(Color.black.opacity(protectionOverlayOpacity))
            }
        }
        .clipShape(shape)
    }
}

private struct AuraGlassCapsuleSurface: View {
    var material: AuraSurfaceMaterial = .clear
    var washColor: Color = .clear
    var alphaMultiplier: CGFloat = 1.0
    var protectionOverlayOpacity: CGFloat = 0.0

    var body: some View {
        let shape = Capsule()
        let strength = min(max(Double(alphaMultiplier), 0), 1)

        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(material.systemGlass, in: shape)
            } else {
                shape
                    .fill(material.legacyMaterial)
                    .opacity(strength)
            }
        }
        .overlay {
            if washColor != .clear {
                shape.fill(washColor)
            }
        }
        .overlay {
            if protectionOverlayOpacity > 0.001 {
                shape.fill(Color.black.opacity(protectionOverlayOpacity))
            }
        }
        .clipShape(shape)
    }
}

private extension AuraSurfaceMaterial {
    var legacyMaterial: Material {
        switch self {
        case .regular:
            return .regularMaterial
        case .clear:
            return .ultraThinMaterial
        }
    }
}

@available(macOS 26.0, *)
private extension AuraSurfaceMaterial {
    var systemGlass: Glass {
        switch self {
        case .regular:
            return .regular
        case .clear:
            return .clear
        }
    }
}

struct AuraGlassInsetCard: View {
    var cornerRadius: CGFloat = 10
    var emphasized: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape.fill(
                colorScheme == .dark
                    ? Color.black.opacity(emphasized ? 0.30 : 0.22)
                    : Color.white.opacity(emphasized ? 0.22 : 0.16)
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(emphasized ? 0.10 : 0.065),
                    Color.white.opacity(0.018),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(shape)
        }
        .overlay(
            shape
                .stroke(Color.white.opacity(emphasized ? 0.14 : 0.10), lineWidth: 0.9)
        )
        .clipShape(shape)
    }
}

struct ErrorBanner: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 14,
                material: .regular,
                washColor: Color.orange.opacity(colorScheme == .dark ? 0.06 : 0.05)
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22), lineWidth: 0.9)
        )
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    var onInteractionStart: () -> Void = {}
    var onInteractionEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAccessorView()
        view.onWindowChange = { currentWindow in
            guard let currentWindow else { return }
            context.coordinator.attachIfNeeded(
                currentWindow,
                onInteractionStart: onInteractionStart,
                onInteractionEnd: onInteractionEnd
            )
            if window !== currentWindow {
                window = currentWindow
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let accessorView = nsView as? WindowAccessorView else { return }
        accessorView.onWindowChange = { currentWindow in
            guard let currentWindow else { return }
            context.coordinator.attachIfNeeded(
                currentWindow,
                onInteractionStart: onInteractionStart,
                onInteractionEnd: onInteractionEnd
            )
            if window !== currentWindow {
                window = currentWindow
            }
        }
        if let currentWindow = nsView.window {
            context.coordinator.attachIfNeeded(
                currentWindow,
                onInteractionStart: onInteractionStart,
                onInteractionEnd: onInteractionEnd
            )
            if window !== currentWindow {
                window = currentWindow
            }
        }
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var interactionEndWorkItem: DispatchWorkItem?
        private var onInteractionStart: () -> Void = {}
        private var onInteractionEnd: () -> Void = {}

        func attachIfNeeded(
            _ window: NSWindow,
            onInteractionStart: @escaping () -> Void,
            onInteractionEnd: @escaping () -> Void
        ) {
            self.onInteractionStart = onInteractionStart
            self.onInteractionEnd = onInteractionEnd
            if configuredWindow !== window {
                detachObservers()
                configuredWindow = window
                let center = NotificationCenter.default
                let names: [Notification.Name] = [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResignKeyNotification,
                    NSWindow.didBecomeMainNotification,
                    NSWindow.didResignMainNotification
                ]
                observers = names.map { name in
                    center.addObserver(forName: name, object: window, queue: .main) { _ in
                        applyStandardWindowButtonAppearance(for: window)
                    }
                }
                observers.append(
                    center.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main) { [weak self] _ in
                        self?.beginWindowInteraction()
                    }
                )
                observers.append(
                    center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                        self?.scheduleWindowInteractionEnd()
                    }
                )
                observers.append(
                    center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                        self?.beginWindowInteraction()
                    }
                )
                observers.append(
                    center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                        self?.scheduleWindowInteractionEnd()
                    }
                )
                configureWindowForClientDecorations(window)
            }
        }

        deinit {
            detachObservers()
        }

        private func detachObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            interactionEndWorkItem?.cancel()
            interactionEndWorkItem = nil
        }

        private func beginWindowInteraction() {
            interactionEndWorkItem?.cancel()
            interactionEndWorkItem = nil
            onInteractionStart()
        }

        private func scheduleWindowInteractionEnd() {
            interactionEndWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.onInteractionEnd()
            }
            interactionEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }
    }
}

private final class WindowAccessorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private extension ContentView {
    func resolvedTopOverlayPadding() -> CGFloat {
        guard let window else { return topOverlayTopPadding }
        if usesZoomedWindowLayout(window) {
            return zoomedTopOverlayPadding
        }
        return topOverlayTopPadding
    }

    func usesZoomedWindowLayout(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen) else {
            return false
        }
        if window.isZoomed {
            return true
        }
        guard let visibleFrame = window.screen?.visibleFrame else {
            return false
        }

        let tolerance: CGFloat = 2
        let frame = window.frame
        return abs(frame.minX - visibleFrame.minX) <= tolerance
            && abs(frame.minY - visibleFrame.minY) <= tolerance
            && abs(frame.maxX - visibleFrame.maxX) <= tolerance
            && abs(frame.maxY - visibleFrame.maxY) <= tolerance
    }

    func resolvedBottomOverlayPadding() -> CGFloat {
        guard let window else { return 24 }
        if window.styleMask.contains(.fullScreen) {
            return 68
        }
        if window.isZoomed {
            return 54
        }
        return 24
    }

    func beginWindowDrag() {
        viewModel.suspendPreviewRenderingForWindowDrag()
    }

    func endWindowDrag() {
        viewModel.resumePreviewRenderingAfterWindowDrag()
    }

    func setupActivityMonitoring() {
        teardownActivityMonitoring()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .mouseMoved, controlsVisible, !viewModel.isCatalogOpen {
                return event
            }
            handleUserActivity()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { _ in
            handleUserActivity()
        }
    }

    func teardownActivityMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        hideTask?.cancel()
        hideTask = nil
    }

    func handleUserActivity() {
        let now = Date()

        if viewModel.isCatalogOpen {
            hideTask?.cancel()
            hideTask = nil
            if !controlsVisible {
                setControlsVisible(true, legacyDuration: 0.2)
            }
            lastActivityRefreshAt = now
            return
        }

        if isHoveringTopOverlay || isHoveringBottomOverlay {
            hideTask?.cancel()
            hideTask = nil
            if !controlsVisible {
                setControlsVisible(true, legacyDuration: 0.2)
            }
            lastActivityRefreshAt = now
            return
        }

        if controlsVisible,
           hideTask != nil,
           now.timeIntervalSince(lastActivityRefreshAt) < activityRefreshThrottle {
            return
        }

        hideTask?.cancel()
        if !controlsVisible {
            setControlsVisible(true, legacyDuration: 0.25)
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(hideDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !isHoveringTopOverlay,
                  !isHoveringBottomOverlay,
                  !isAdjustingSpeed,
                  !viewModel.isCatalogOpen,
                  !viewModel.isSettingsOpen,
                  !viewModel.isMonitoringOpen,
                  !viewModel.isDownloadedWallpapersOpen else {
                return
            }
            setControlsVisible(false, legacyDuration: 0.4)
            hideTask = nil
        }
        lastActivityRefreshAt = now
    }

    func handleInterfaceHoverChange() {
        if isHoveringTopOverlay || isHoveringBottomOverlay {
            handleUserActivity()
            return
        }

        hideTask?.cancel()
        hideTask = nil
        handleUserActivity()
    }

    func setControlsVisible(_ isVisible: Bool, legacyDuration: TimeInterval) {
        if #available(macOS 26.0, *) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                controlsVisible = isVisible
            }
        } else {
            withAnimation(.easeInOut(duration: legacyDuration)) {
                controlsVisible = isVisible
            }
        }
    }
}
