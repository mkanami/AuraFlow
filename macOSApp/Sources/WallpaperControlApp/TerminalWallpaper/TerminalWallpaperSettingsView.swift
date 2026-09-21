import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel
    var onClose: (() -> Void)? = nil
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @State private var showAdvancedCommand = false

    private var terminalAppearance: AdaptiveGlassAppearance {
        var appearance = adaptiveGlassAppearance
        // Terminal settings need a stable dark canvas. Reusing the wallpaper's
        // adaptive light tone makes every glass surface turn into a white slab
        // over bright artwork and leaves secondary buttons without contrast.
        appearance.textTone = .light
        appearance.centerGlassAlpha = 0.94
        appearance.topGlassAlpha = 0.94
        appearance.bottomGlassAlpha = 0.94
        appearance.centerProtectionOverlayOpacity = 0.42
        appearance.topProtectionOverlayOpacity = 0.42
        appearance.bottomProtectionOverlayOpacity = 0.42
        appearance.bottomButtonProtectionOpacity = 0.36
        appearance.bottomButtonHighlightOpacity = 0.04
        return appearance
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                if let errorMessage = viewModel.errorMessage {
                    terminalMessage(
                        errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red
                    )
                }

                if let statusMessage = viewModel.statusMessage {
                    terminalMessage(
                        statusMessage,
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                }

                catalogSection
                renderSection
                behaviorSection
                statusSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .environment(\.adaptiveGlassAppearance, terminalAppearance)
        .frame(minWidth: 0, minHeight: 0)
        .foregroundStyle(terminalAppearance.centerTextTone.primaryTextColor)
        .background(
            AuraGlassRoundedSurface(
                cornerRadius: 18,
                material: .clear,
                alphaMultiplier: terminalAppearance.centerGlassAlpha,
                protectionOverlayOpacity: terminalAppearance.centerProtectionOverlayOpacity,
                protectionOverlayColor: terminalAppearance.centerTextTone.contrastSurfaceColor
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(terminalDimmingOpacity))
                .allowsHitTesting(false)
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

    private var terminalDimmingOpacity: CGFloat {
        0.18
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal Wallpaper")
                    .font(.title2.weight(.semibold))
                Text("Run a terminal app as a live desktop wallpaper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(viewModel.status.running ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(viewModel.statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.status.running ? .green : .secondary)
            }

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
        TerminalWallpaperSection(title: "Choose what to render", systemImage: "rectangle.grid.2x2") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select a terminal app or system utility. AuraFlow finds its executable automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("GUI .app bundles are excluded. A command that writes no terminal output will be reported as blank.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                AuraCatalogSearchField(
                    text: Binding(
                        get: { viewModel.catalogSearch },
                        set: { viewModel.setCatalogSearch($0) }
                    ),
                    placeholder: "Search installed executables",
                    accessibilityLabel: "Search installed executables"
                )

                catalogCategory(.applications)
                catalogCategory(.utilities)

                if viewModel.catalogItems.isEmpty && !viewModel.catalogIsLoading {
                    Text("No executable terminal programs were found in PATH or the standard bin folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.catalogIsLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning installed command-line programs…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button("Refresh catalog") { viewModel.refreshCatalog() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))

                    Button("Choose executable…") {
                        guard let url = TerminalExecutablePicker.choose() else { return }
                        if viewModel.selectCustomExecutable(url) {
                            showAdvancedCommand = true
                        }
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))

                    Text("For custom scripts or terminal programs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced command settings", isExpanded: $showAdvancedCommand) {
                    advancedCommandFields
                }
                .tint(.secondary)
            }
        }
    }

    @ViewBuilder
    private func catalogCategory(_ category: TerminalWallpaperCatalogCategory) -> some View {
        let items = viewModel.availableCatalogItems(for: category)
        if !items.isEmpty {
            Label(category.title, systemImage: category.systemImage)
                .font(.headline.weight(.semibold))
                .padding(.top, 5)

            ForEach(items) { item in
                catalogRow(item)
                    .onAppear {
                        guard item.id == viewModel.catalogItems.last?.id else { return }
                        viewModel.loadMoreCatalogItems()
                    }
            }
        }
    }

    private func catalogRow(_ item: TerminalWallpaperCatalogItem) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.select(item)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.title3)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let executable = viewModel.cachedExecutablePath(for: item) {
                            Text(executable)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if viewModel.selectedCatalogItemID == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(AuraPlainPressButtonStyle())

            Button("Start") { viewModel.start(item) }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(
                        viewModel.isBusy
                        || viewModel.status.running
                        || viewModel.cachedExecutablePath(for: item) == nil
                )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
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

            Text("Arguments — one argument per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            AuraTerminalTextEditor(
                text: $viewModel.argumentsText,
                placeholder: "--argument\nvalue"
            )

            AuraTerminalTextField(
                text: $viewModel.workingDirectory,
                placeholder: "Working directory (optional)",
                monospaced: true
            )

            Text("Environment — KEY=VALUE per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            AuraTerminalTextEditor(
                text: $viewModel.environmentText,
                placeholder: "KEY=VALUE"
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
                    Stepper("FPS: \(viewModel.maxFPS)", value: $viewModel.maxFPS, in: 1...120, step: 1)
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
                        .buttonStyle(.borderless)
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
        TerminalWallpaperSection(title: "Runtime health", systemImage: "heart.text.square") {
            VStack(alignment: .leading, spacing: 6) {
                if let health = viewModel.status.health {
                    terminalStatusRow(label: "PID", value: health.childPID.map(String.init) ?? "—")
                    terminalStatusRow(
                        label: "PTY/grid",
                        value: "\(health.columns.map(String.init) ?? "—") × \(health.rows.map(String.init) ?? "—")"
                    )
                    terminalStatusRow(label: "Screens", value: "\(health.screens)")
                    terminalStatusRow(label: "Frames", value: "\(health.frames)")
                    terminalStatusRow(label: "Rendered", value: "\(health.renderedFrames)")
                    if let error = health.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }
                } else {
                    Text("No runtime health report yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func terminalStatusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

struct TerminalWallpaperOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var terminalWallpaperViewModel: TerminalWallpaperViewModel
    @Environment(\.colorScheme) private var colorScheme

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
        .padding(16)
        .background(AuraGlassInsetCard(cornerRadius: 16, emphasized: false))
    }
}
