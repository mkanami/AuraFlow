import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperCardPresentation: Equatable, Sendable {
    let installed: Bool
    let selectedForPreview: Bool
    let applied: Bool
    let busy: Bool

    var actionTitle: String {
        if !installed { return "Install & show in preview" }
        return selectedForPreview ? "In preview" : "Show in preview"
    }

    var actionDisabled: Bool { busy || (installed && selectedForPreview) }
    var availabilityTitle: String? { installed ? nil : "Installation required" }
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
struct TerminalWallpaperDisclosureStyle: DisclosureGroupStyle {
    var usesCard = true

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
                .padding(.horizontal, usesCard ? 16 : 0)
                .padding(.vertical, usesCard ? 8 : 4)
                .frame(maxWidth: .infinity, minHeight: usesCard ? 48 : 0, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(AuraPlainPressButtonStyle())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                if usesCard {
                    Divider().padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 12) {
                    configuration.content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, usesCard ? 16 : 0)
                .padding(.leading, usesCard ? 0 : 16)
                .padding(.vertical, usesCard ? 16 : 0)
                // Diagnostics inside a section stay lightweight, not another
                // nested glass card. Only the four top-level sections get one.
                .disclosureGroupStyle(TerminalWallpaperDisclosureStyle(usesCard: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AuraGlassInsetCardModifier(cornerRadius: 12, enabled: usesCard))
    }
}

/// Match Settings' compact glass segments instead of AppKit's opaque,
/// full-width gray segmented picker. One shared surface, not glass per button.
private struct TerminalWallpaperSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Environment(\.adaptiveGlassAppearance) private var appearance

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.callout.weight(selection == option ? .semibold : .medium))
                        .foregroundStyle(selection == option ? Color.white : appearance.centerTextTone.primaryTextColor)
                        .frame(width: 72, height: 26)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.accentColor)
                                    .padding(2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(AuraPlainPressButtonStyle())
                .accessibilityValue(selection == option ? "Selected" : "")
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
        .background(AuraGlassInsetCard(cornerRadius: 12).allowsHitTesting(false))
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
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    customCommandSection
                    settingsDisclosure(
                        "Appearance & performance", subtitle: "Font, size, background and frame rate",
                        systemImage: "paintbrush.pointed", isExpanded: $showAppearance
                    ) {
                        renderSection
                        applySettingsAction
                    }
                    settingsDisclosure(
                        "Behavior", subtitle: "Displays and fullscreen pause",
                        systemImage: "gearshape.2", isExpanded: $showBehavior
                    ) {
                        behaviorSection
                        applySettingsAction
                    }
                    settingsDisclosure(
                        "Runtime & troubleshooting", subtitle: "Status and diagnostics",
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
        .onAppear { searchText = viewModel.catalogSearch }
        .onChange(of: searchText) { viewModel.setCatalogSearch($0) }
        .onChange(of: viewModel.catalogSearch) { if searchText != $0 { searchText = $0 } }
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

    private func settingsDisclosure<Content: View>(
        _ title: String, subtitle: String, systemImage: String,
        isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12, content: content)
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
        .modifier(AuraGlassInsetCardModifier(cornerRadius: 12))
    }

    private var catalogSection: some View {
        TerminalWallpaperSection(title: "Terminal programs", systemImage: "rectangle.grid.2x2") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AuraCatalogSearchField(
                        text: $searchText,
                        placeholder: "Search terminal programs…",
                        accessibilityLabel: "Search terminal programs",
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
                .id("terminal-program-search")

                if !viewModel.catalogSearch.isEmpty {
                    // Search can return hundreds of programs. Instantiate glass
                    // only near the viewport, just like the saved library grid.
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.catalogItems) { item in
                            if let preset = viewModel.preset(for: item) {
                                presetCard(preset, compact: true)
                            }
                        }
                    }
                    if viewModel.catalogItems.isEmpty && !viewModel.catalogIsLoading {
                        Label("No terminal programs found.", systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    }
                    if viewModel.catalogIsLoading {
                        ProgressView("Searching programs…")
                            .controlSize(.small)
                    }
                    if let error = viewModel.searchError {
                        Text(error).font(.caption)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.libraryPresets) { preset in
                        presetCard(preset)
                    }
                }

                if viewModel.needsHomebrew {
                    Button("Set up Homebrew…") { viewModel.prepareHomebrew() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(viewModel.isBusy)
                }
                if viewModel.isBusy, viewModel.installingAnimationID == nil, let stage = viewModel.installStage {
                    ProgressView(stage).controlSize(.small)
                    Button("Cancel") { viewModel.cancelInstallation() }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                }
            }
        }
    }

    private var customCommandSection: some View {
        DisclosureGroup(isExpanded: $showAdvancedCommand) {
            Text("Only run commands you trust. Custom commands may be incompatible.")
                .font(.caption)
                .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                .padding(.vertical, 8)
            Button {
                guard let url = TerminalExecutablePicker.choose() else { return }
                _ = viewModel.selectCustomExecutable(url)
            } label: {
                Label("Choose executable…", systemImage: "folder")
            }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            .disabled(viewModel.isBusy)
            advancedCommandFields
            Button("Show command in preview") {
                viewModel.showCurrentCommandInPreview()
            }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            .disabled(viewModel.isBusy || viewModel.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } label: {
            Text("Add a custom command").font(.headline)
        }
        .tint(adaptiveGlassAppearance.centerTextTone.primaryTextColor)
    }

    private func presetCard(_ preset: TerminalWallpaperPreset, compact: Bool = false) -> some View {
        let item = preset.item
        let installing = viewModel.installingAnimationID == item.id
        let availability = viewModel.availability[item.id] ?? .checking
        let presentation = TerminalWallpaperCardPresentation(
            installed: viewModel.cachedExecutablePath(for: item) != nil,
            selectedForPreview: viewModel.isPreviewSelected(item),
            applied: viewModel.isActive(item),
            busy: viewModel.isBusy
        )
        return TerminalWallpaperPresetCard(preset: preset, compact: compact,
            availability: availability, presentation: presentation,
            installing: installing,
            installStage: installing ? viewModel.installStage : nil, viewModel: viewModel)
            .equatable()
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
            HStack(spacing: 8) {
                Text("Pixel resolution")
                TerminalWallpaperSegmentedControl(options: TerminalPixelMode.allCases, selection: $viewModel.pixelMode) {
                    $0.title
                }
                .accessibilityLabel("Pixel resolution")
            }

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
            Toggle("Pause when another app is fullscreen", isOn: Binding(
                get: { viewModel.controlsPauseOnFullscreen }, set: { viewModel.setPauseOnFullscreen($0) }))
                .disabled(viewModel.isBusy)
                .help("Also pauses when the foreground window fills the working area between the menu bar and Dock.")
        }
    }

    private var applySettingsAction: some View {
        Button("Apply settings") { viewModel.apply() }
            .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            .disabled(viewModel.isBusy)
            .help("Scale is in Playback Settings and updates automatically. Apply settings updates the remaining settings.")
    }

    private var runtimeActions: some View {
        HStack(spacing: 10) {
            Button("Refresh status") { viewModel.refresh() }
            Spacer()
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
                Text(viewModel.status.running ? "Waiting for runtime diagnostics…" : "No terminal wallpaper applied.")
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

struct TerminalWallpaperPresetCard: View, Equatable {
    let preset: TerminalWallpaperPreset
    let compact: Bool
    let availability: TerminalAnimationAvailability
    let presentation: TerminalWallpaperCardPresentation
    let installing: Bool
    let installStage: String?
    let viewModel: TerminalWallpaperViewModel
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preset == rhs.preset && lhs.compact == rhs.compact
            && lhs.availability == rhs.availability && lhs.presentation == rhs.presentation
            && lhs.installing == rhs.installing && lhs.installStage == rhs.installStage
            && lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        let item = preset.item
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline)
                    if !preset.isReviewedAnimation {
                        Text(item.subtitle)
                            .font(.caption).lineLimit(2)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    }
                    if !presentation.installed {
                        Text(availability.message)
                            .font(.caption)
                            .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if presentation.applied {
                        Label("Applied", systemImage: "desktopcomputer")
                    }
                }
                .font(.caption.weight(.medium))
            }
            if !compact {
                Text(preset.description)
                    .font(.callout)
                    .foregroundStyle(adaptiveGlassAppearance.centerTextTone.secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installing {
                ProgressView(installStage ?? "Checking animation…").controlSize(.small)
                Button("Cancel") { viewModel.cancelInstallation() }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            } else {
                Button {
                    viewModel.use(item)
                } label: {
                    Label(presentation.actionTitle, systemImage: presentation.installed ? "play.rectangle" : "arrow.down.circle")
                }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(presentation.actionDisabled || (!presentation.installed && !availability.canInstall))
                .accessibilityLabel("\(presentation.actionTitle): \(item.title)")
                .accessibilityHint(presentation.installed
                                   ? "Changes only the AuraFlow preview, not your applied wallpaper."
                                   : "Installs this program with Homebrew, then opens it only in preview.")
                if case .failed = availability {
                    Button("Retry package check") { viewModel.checkAvailability(preset) }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                        .disabled(presentation.busy)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AuraGlassInsetCardModifier(cornerRadius: 14))
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
        .padding(.top, 6)
    }
}
