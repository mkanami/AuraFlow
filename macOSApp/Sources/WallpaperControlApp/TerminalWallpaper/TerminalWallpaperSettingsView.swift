import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperCardPresentation: Equatable {
    let installed: Bool
    let selectedForPreview: Bool
    let applied: Bool
    let busy: Bool

    var actionTitle: String {
        if !installed { return "Install & show in preview" }
        return selectedForPreview ? "In preview" : "Show in preview"
    }

    var actionDisabled: Bool { busy || (installed && selectedForPreview) }
    var availabilityTitle: String { installed ? "Installed" : "Installation required" }
}

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

/// Make only the header a full-width button: fields inside the expanded
/// section must stay interactive without collapsing their parent.
private struct TerminalWallpaperDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 16)
            }
        }
    }
}

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel
    var onClose: (() -> Void)? = nil
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @State private var showAdvancedCommand = false
    @State private var showAppearance = false
    @State private var showBehavior = false
    @State private var showRuntime = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    gettingStarted

                    if let errorMessage = viewModel.errorMessage {
                        terminalMessage(
                            errorMessage,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                        if let url = viewModel.installHelpURL {
                            Link("Homebrew installation guide", destination: url)
                                .font(.callout)
                        }
                    }

                    if viewModel.errorMessage == nil, let runtimeError = viewModel.status.health?.lastError {
                        terminalMessage(runtimeError, systemImage: "exclamationmark.triangle.fill", color: .red)
                    }

                    catalogSection
                    if let statusMessage = viewModel.statusMessage {
                        terminalMessage(
                            statusMessage,
                            systemImage: "checkmark.circle.fill",
                            color: .green
                        )
                    }
                    Divider()
                    settingsDisclosure(
                        "Appearance & performance", subtitle: "Font, size, background and frame rate",
                        systemImage: "paintbrush.pointed", isExpanded: $showAppearance
                    ) {
                        renderSection
                        applySettingsAction
                    }
                    Divider()
                    settingsDisclosure(
                        "Behavior", subtitle: "Displays, fullscreen pause and launch at login",
                        systemImage: "gearshape.2", isExpanded: $showBehavior
                    ) {
                        behaviorSection
                        applySettingsAction
                    }
                    Divider()
                    settingsDisclosure(
                        "Runtime & troubleshooting", subtitle: "Status, restart and diagnostics",
                        systemImage: "heart.text.square", isExpanded: $showRuntime
                    ) {
                        statusSection
                        runtimeActions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            Divider()
            previewFooter
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
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
        .disclosureGroupStyle(TerminalWallpaperDisclosureStyle())
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Terminal Wallpaper")
                    .font(.title2.weight(.semibold))
                Text("Choose an animation. Try it before applying it.")
                    .font(.callout)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            }

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

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                workflowStep("1", title: "Choose an animation")
                workflowStep("2", title: "See live preview")
                workflowStep("3", title: "Use Start to apply")
            }
            Text("Choosing changes only the preview. Use Start for desktop & Lock Screen; Remove first if other wallpaper is running.")
                .font(.caption)
                .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
            if let active = viewModel.activeWallpaperTitle {
                Label("Applied wallpaper: \(active)", systemImage: "desktopcomputer")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func workflowStep(_ number: String, title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.callout.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(adaptiveGlassAppearance.centerTextTone.primaryTextColor.opacity(0.10)))
            Text(title)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var previewFooter: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.previewTitle.map { "Preview: \($0)" } ?? "Choose an animation to begin")
                    .font(.callout.weight(.semibold))
                Text(viewModel.previewTitle == nil
                     ? "Your current wallpaper stays unchanged."
                     : "Close this panel to see it live. Use Start to apply it.")
                    .font(.caption)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Label("Back to preview", systemImage: "play.rectangle")
                }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            }
        }
    }

    private func settingsDisclosure<Content: View>(
        _ title: String, subtitle: String, systemImage: String,
        isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                }
            }
            .padding(.vertical, 5)
        }
        .tint(adaptiveGlassAppearance.centerTextTone.primaryTextColor)
    }

    private func terminalMessage(_ message: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AuraGlassInsetCard(cornerRadius: 12, emphasized: false))
    }

    private var catalogSection: some View {
        TerminalWallpaperSection(title: "Choose a wallpaper", systemImage: "rectangle.grid.2x2") {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AuraCatalogSearchField(
                        text: Binding(
                            get: { viewModel.catalogSearch },
                            set: { viewModel.setCatalogSearch($0) }
                        ),
                        placeholder: "Search animations or exact command",
                        accessibilityLabel: "Search wallpapers or exact command",
                        maxWidth: .infinity
                    )
                    if !viewModel.catalogSearch.isEmpty {
                        Button {
                            viewModel.setCatalogSearch("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(AuraPlainPressButtonStyle())
                        .accessibilityLabel("Clear search")
                    }
                    Button {
                        viewModel.refreshCatalog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                    .accessibilityLabel("Refresh wallpaper choices")
                }

                if viewModel.catalogSearch.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
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

                Text("Looking for something else? Search an exact installed command name, or add a custom command below.")
                    .font(.caption)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let stage = viewModel.installStage {
                    ProgressView(stage)
                        .controlSize(.small)
                        .padding(.vertical, 4)
                }

                DisclosureGroup("Add a custom command", isExpanded: $showAdvancedCommand) {
                    Text("For advanced users: choose a trusted terminal executable, not a macOS app. Custom commands are unverified and may not work as wallpaper.")
                        .font(.callout)
                        .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                        .padding(.vertical, 8)
                    Button {
                        guard let url = TerminalExecutablePicker.choose() else { return }
                        _ = viewModel.selectCustomExecutable(url)
                    } label: {
                        Label("Choose file…", systemImage: "folder")
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                    .disabled(viewModel.isBusy)
                    advancedCommandFields
                    Button("Show command in preview") {
                        viewModel.showCurrentCommandInPreview()
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                    .disabled(viewModel.isBusy || viewModel.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .tint(adaptiveGlassAppearance.centerTextTone.primaryTextColor)
            }
        }
    }

    private func presetCard(_ preset: TerminalWallpaperPreset) -> some View {
        let item = preset.item
        let presentation = TerminalWallpaperCardPresentation(
            installed: viewModel.cachedExecutablePath(for: item) != nil,
            selectedForPreview: viewModel.isPreviewSelected(item),
            applied: viewModel.isActive(item),
            busy: viewModel.isBusy
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline)
                    Text(presentation.availabilityTitle)
                        .font(.caption)
                        .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if presentation.selectedForPreview {
                        Label("In preview", systemImage: "play.rectangle")
                    }
                    if presentation.applied {
                        Label("Applied", systemImage: "desktopcomputer")
                    }
                }
                .font(.caption.weight(.medium))
            }
            Text(preset.description)
                .font(.callout)
                .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                viewModel.use(item)
            } label: {
                Label(presentation.actionTitle, systemImage: presentation.installed ? "play.rectangle" : "arrow.down.circle")
            }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            .disabled(presentation.actionDisabled)
            .accessibilityLabel("\(presentation.actionTitle): \(item.title)")
            .accessibilityHint(presentation.installed
                               ? "Changes only the AuraFlow preview, not your applied wallpaper."
                               : "Installs this program with Homebrew, then opens it only in preview.")
        }
        .padding(14)
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
                    .font(.callout)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            }
            Spacer(minLength: 4)
            Button(viewModel.isPreviewSelected(item) ? "Previewing" : "Show in preview") { viewModel.use(item) }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(viewModel.isBusy || viewModel.isPreviewSelected(item) || viewModel.cachedExecutablePath(for: item) == nil)
        }
        .padding(12)
        .background(catalogRowBackground)
    }

    private var catalogRowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
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

    private var behaviorSection: some View {
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
        }
    }

    private var applySettingsAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The preview updates automatically. Apply also updates the terminal wallpaper runtime with these settings.")
                .font(.caption)
                .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            Button("Apply settings") { viewModel.apply() }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(viewModel.isBusy)
        }
    }

    private var runtimeActions: some View {
        HStack(spacing: 10) {
            Button("Start") { viewModel.start() }
                .disabled(!viewModel.canStart || viewModel.status.running)
            Button("Restart") { viewModel.restart() }
                .disabled(!viewModel.canStart)
            Button("Stop") { viewModel.stop() }
                .disabled(viewModel.isBusy || !viewModel.status.running)
            Spacer()
            Button("Refresh status") { viewModel.refresh() }
        }
        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            terminalStatusRow(label: "Status", value: viewModel.statusTitle)
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
                Text(viewModel.status.running ? "Waiting for runtime diagnostics…" : "No terminal wallpaper is applied. A live preview is not an active wallpaper.")
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
            }
        }
        .font(.system(.callout, design: .monospaced))
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
        .padding(.vertical, 6)
    }
}
