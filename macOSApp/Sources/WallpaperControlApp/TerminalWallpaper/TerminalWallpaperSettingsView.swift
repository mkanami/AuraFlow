import AuraTerminalWallpaperCore
import SwiftUI

func terminalWallpaperPopupAppearance(
    from appearance: AdaptiveGlassAppearance
) -> AdaptiveGlassAppearance {
    guard appearance.centerTextTone == .dark else { return appearance }

    var adjusted = appearance
    // The shared glass surface is already bounded at render time. Keep this
    // popup's large light-backed surface a little quieter without changing the
    // adaptive tone or the appearance of any other AuraFlow panel.
    adjusted.centerProtectionOverlayOpacity = min(
        appearance.centerProtectionOverlayOpacity,
        0.22
    )
    return adjusted
}

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel
    var onClose: (() -> Void)? = nil
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @State private var showAdvancedCommand = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header

                if let errorMessage = viewModel.errorMessage {
                    terminalMessage(
                        errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red
                    )
                    if let url = viewModel.installHelpURL {
                        Link("Homebrew installation guide", destination: url)
                            .font(.callout)
                            .padding(.horizontal, 14)
                    }
                }

                if let statusMessage = viewModel.statusMessage {
                    terminalMessage(
                        statusMessage,
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                }

                catalogSection
                Divider()
                renderSection
                Divider()
                behaviorSection
                if viewModel.status.health != nil {
                    Divider()
                    statusSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 0, minHeight: 0)
        .foregroundStyle(adaptiveGlassAppearance.centerTextTone.primaryTextColor)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 18,
                material: .clear,
                alphaMultiplier: adaptiveGlassAppearance.centerGlassAlpha,
                protectionOverlayOpacity: adaptiveGlassAppearance.centerProtectionOverlayOpacity,
                protectionOverlayColor: adaptiveGlassAppearance.centerTextTone.contrastSurfaceColor
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 8)
        .environment(\.colorScheme, .dark)
        .task {
            viewModel.prepareCatalogIfNeeded()
            while !Task.isCancelled {
                viewModel.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal")
                .font(.title2.weight(.semibold))

            Text("Terminal Wallpaper")
                .font(.title2.weight(.semibold))

            Spacer()

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(AuraPlainPressButtonStyle())
                .accessibilityLabel("Close Terminal Wallpaper")
            }
        }
        .padding(.horizontal, 4)
    }

    private func terminalMessage(_ message: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AuraGlassInsetCard(cornerRadius: 12, emphasized: false))
    }

    private var catalogSection: some View {
        TerminalWallpaperSection(title: "Choose a wallpaper", systemImage: "rectangle.grid.2x2") {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AuraCatalogSearchField(
                        text: Binding(
                            get: { viewModel.catalogSearch },
                            set: { viewModel.setCatalogSearch($0) }
                        ),
                        placeholder: "Search wallpapers or exact command",
                        accessibilityLabel: "Search wallpapers or exact command"
                    )
                    Button {
                        viewModel.refreshCatalog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
                    .accessibilityLabel("Refresh wallpaper choices")
                }

                if viewModel.catalogSearch.isEmpty {
                    if let active = viewModel.activeUnfeaturedTitle {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Current: \(active)")
                                .font(.callout.weight(.medium))
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(viewModel.featuredPresets) { preset in
                            presetCard(preset)
                        }
                    }
                } else {
                    ForEach(viewModel.catalogItems) { item in
                        if let preset = TerminalWallpaperPreset.preset(id: item.id) {
                            presetCard(preset)
                        } else {
                            catalogRow(item)
                        }
                    }
                    if viewModel.catalogItems.isEmpty && !viewModel.catalogIsLoading {
                        Label("No match. Try an exact command name or choose a file.", systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    }
                    if viewModel.catalogIsLoading {
                        ProgressView("Looking for an exact executable…")
                            .controlSize(.small)
                    }
                }

                if let stage = viewModel.installStage {
                    ProgressView(stage)
                        .controlSize(.small)
                        .padding(.vertical, 4)
                }

                DisclosureGroup("Add a custom command", isExpanded: $showAdvancedCommand) {
                    Button {
                        guard let url = TerminalExecutablePicker.choose() else { return }
                        _ = viewModel.selectCustomExecutable(url)
                    } label: {
                        Label("Choose file…", systemImage: "folder")
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                    advancedCommandFields
                }
            }
        }
    }

    private func presetCard(_ preset: TerminalWallpaperPreset) -> some View {
        let item = preset.item
        let installed = viewModel.cachedExecutablePath(for: item) != nil
        let active = viewModel.isActive(item)
        return HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.semibold))
                Text(preset.description)
                    .font(.callout)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(active ? "Current" : installed ? "Set wallpaper" : "Install & set") {
                viewModel.use(item)
            }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
            .disabled(viewModel.isBusy || active)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(catalogRowBackground)
    }

    private func catalogRow(_ item: TerminalWallpaperCatalogItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold))
                Text("Unverified command · may not draw a wallpaper")
                    .font(.caption)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            }
            Spacer(minLength: 4)
            Button(viewModel.isActive(item) ? "Current" : "Set wallpaper") { viewModel.use(item) }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
                .disabled(viewModel.isBusy || viewModel.isActive(item) || viewModel.cachedExecutablePath(for: item) == nil)
        }
        .padding(12)
        .background(catalogRowBackground)
    }

    private var catalogRowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(
                adaptiveGlassAppearance.centerTextTone == .dark
                    ? Color.white.opacity(0.12)
                    : Color.black.opacity(0.24)
            )
            .overlay {
                shape.stroke(
                    adaptiveGlassAppearance.centerTextTone.primaryTextColor.opacity(0.10),
                    lineWidth: 0.8
                )
            }
    }

    private var advancedCommandFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuraTerminalTextField(
                text: Binding(
                    get: { viewModel.executable },
                    set: { viewModel.setExecutable($0) }
                ),
                placeholder: "Executable",
                monospaced: true
            )

            AuraTerminalTextEditor(
                text: $viewModel.argumentsText,
                placeholder: "Arguments — one per line"
            )

            AuraTerminalTextField(
                text: $viewModel.workingDirectory,
                placeholder: "Working directory (optional)",
                monospaced: true
            )

            AuraTerminalTextEditor(
                text: $viewModel.environmentText,
                placeholder: "Environment — KEY=VALUE per line"
            )
        }
        .padding(.top, 8)
    }

    private var renderSection: some View {
        TerminalWallpaperSection(title: "Render", systemImage: "paintbrush.pointed") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Pixel resolution", selection: $viewModel.pixelMode) {
                    ForEach(TerminalPixelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.pixelMode == .fixed {
                    HStack {
                        Stepper("Width: \(viewModel.fixedWidth)", value: $viewModel.fixedWidth, in: 320...16_384, step: 16)
                        Stepper("Height: \(viewModel.fixedHeight)", value: $viewModel.fixedHeight, in: 240...16_384, step: 16)
                    }
                }

                Toggle("Automatic terminal grid", isOn: $viewModel.useAutomaticGrid)
                if !viewModel.useAutomaticGrid {
                    HStack {
                        Stepper("Columns: \(viewModel.columns)", value: $viewModel.columns, in: 1...1000)
                        Stepper("Rows: \(viewModel.rows)", value: $viewModel.rows, in: 1...500)
                    }
                }

                HStack {
                    AuraTerminalTextField(
                        text: $viewModel.fontFamily,
                        placeholder: "Font"
                    )
                    Stepper("Size: \(viewModel.fontSize, specifier: "%.1f")", value: $viewModel.fontSize, in: 6...96, step: 1)
                }

                HStack {
                    Stepper("Cell spacing: \(viewModel.cellSpacing, specifier: "%.1f")", value: $viewModel.cellSpacing, in: 0...8, step: 0.5)
                    Stepper("FPS: \(viewModel.maxFPS)", value: $viewModel.maxFPS, in: 1...60, step: 1)
                }

                HStack(spacing: 12) {
                    Text("Text scale")
                        .frame(width: 90, alignment: .leading)
                    AuraLegacySpeedSlider(
                        value: viewModel.textScale,
                        range: 0.5...3,
                        step: 0.05,
                        onValueChanged: { viewModel.textScale = $0 },
                        onEditingChanged: { _ in }
                    )
                    Text("\(viewModel.textScale * 100, specifier: "%.0f")%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                    Button("Reset") { viewModel.textScale = 1.5 }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
                }

                Picker("Scale", selection: $viewModel.scaleMode) {
                    ForEach(TerminalScaleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    AuraTerminalTextField(
                        text: $viewModel.backgroundHex,
                        placeholder: "Background hex",
                        monospaced: true
                    )
                    AuraLegacySpeedSlider(
                        value: viewModel.backgroundOpacity,
                        range: 0...1,
                        step: 0.01,
                        onValueChanged: { viewModel.backgroundOpacity = $0 },
                        onEditingChanged: { _ in }
                    )
                    Text("Opacity \(viewModel.backgroundOpacity * 100, specifier: "%.0f%%")")
                        .frame(width: 110, alignment: .trailing)
                }
            }
        }
    }

    private var behaviorSection: some View {
        TerminalWallpaperSection(title: "Behavior", systemImage: "gearshape.2") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Render on all displays", isOn: $viewModel.allDisplays)
                Toggle("Pause when another app is fullscreen", isOn: $viewModel.pauseOnFullscreen)
                Toggle(
                    "Launch Terminal Wallpaper at login",
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )

                HStack(spacing: 10) {
                    Button("Apply") { viewModel.apply() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(viewModel.isBusy)
                    Button("Start") { viewModel.start() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(!viewModel.canStart || viewModel.status.running)
                    Button("Restart") { viewModel.restart() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(!viewModel.canStart)
                    Button("Stop") { viewModel.stop() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(viewModel.isBusy || !viewModel.status.running)
                    Spacer()
                    Button("Refresh") { viewModel.refresh() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                }
            }
        }
    }

    private var statusSection: some View {
        TerminalWallpaperSection(title: "Runtime", systemImage: "heart.text.square") {
            VStack(alignment: .leading, spacing: 8) {
                if let health = viewModel.status.health {
                    terminalStatusRow(label: "PID", value: health.childPID.map(String.init) ?? "—")
                    terminalStatusRow(
                        label: "Grid",
                        value: "\(health.columns.map(String.init) ?? "—") × \(health.rows.map(String.init) ?? "—")"
                    )
                    if let error = health.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                    }

                    DisclosureGroup("Diagnostics") {
                        VStack(alignment: .leading, spacing: 6) {
                            terminalStatusRow(label: "Displays", value: "\(health.screens)")
                            terminalStatusRow(label: "Frames", value: "\(health.frames)")
                            terminalStatusRow(label: "Rendered", value: "\(health.renderedFrames)")
                        }
                        .padding(.top, 6)
                    }
                } else {
                    Text("Waiting for status…")
                        .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    private func terminalStatusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            Spacer()
            Text(value)
        }
    }
}

struct TerminalWallpaperOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var terminalWallpaperViewModel: TerminalWallpaperViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    var body: some View {
        GeometryReader { proxy in
            let popupHeight = min(820, max(proxy.size.height - 48, 1))
            let popupWidth = min(920, max(proxy.size.width - 48, 1))

            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.42 : 0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.closeTerminalWallpaper()
                    }

                TerminalWallpaperSettingsView(
                    viewModel: terminalWallpaperViewModel,
                    onClose: viewModel.closeTerminalWallpaper
                )
                    .environment(
                        \.adaptiveGlassAppearance,
                        terminalWallpaperPopupAppearance(from: adaptiveGlassAppearance)
                    )
                    .frame(width: popupWidth, height: popupHeight)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: viewModel.isTerminalWallpaperOpen)
        .zIndex(80)
    }
}

private struct TerminalWallpaperSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
