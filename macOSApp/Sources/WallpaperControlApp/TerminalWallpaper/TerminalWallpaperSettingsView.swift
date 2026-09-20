import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel
    @State private var showAdvancedCommand = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.84)
                .ignoresSafeArea()

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
        }
        .frame(minWidth: 720, minHeight: 680)
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .dark)
        .task {
            viewModel.refreshCatalog()
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
        .background(AuraGlassInsetCard(cornerRadius: 12, emphasized: true))
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

                TextField(
                    "Search installed executables",
                    text: Binding(
                        get: { viewModel.catalogSearch },
                        set: { viewModel.setCatalogSearch($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)

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
                } else if viewModel.catalogHasMore && viewModel.catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Scroll to load more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onAppear { viewModel.loadMoreCatalogItems() }
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
                        if let executable = item.resolvedExecutable() {
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
            .buttonStyle(AuraGlassButtonStyle(fillWidth: true))

            Button("Start") { viewModel.start(item) }
                .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                .disabled(viewModel.isBusy || viewModel.status.running)
        }
        .padding(8)
        .background(AuraGlassInsetCard(cornerRadius: 10))
    }

    private var advancedCommandFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Executable",
                text: Binding(
                    get: { viewModel.executable },
                    set: { viewModel.setExecutable($0) }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Arguments — one argument per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.argumentsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            TextField("Working directory (optional)", text: $viewModel.workingDirectory)
                .textFieldStyle(.roundedBorder)

            Text("Environment — KEY=VALUE per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.environmentText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
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
                    TextField("Font", text: $viewModel.fontFamily)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Size: \(viewModel.fontSize, specifier: "%.1f")", value: $viewModel.fontSize, in: 6...96, step: 1)
                }

                HStack {
                    Stepper("Cell spacing: \(viewModel.cellSpacing, specifier: "%.1f")", value: $viewModel.cellSpacing, in: 0...8, step: 0.5)
                    Stepper("FPS: \(viewModel.maxFPS)", value: $viewModel.maxFPS, in: 1...120, step: 1)
                }

                HStack(spacing: 12) {
                    Text("Text scale")
                        .frame(width: 90, alignment: .leading)
                    Slider(value: $viewModel.textScale, in: 0.5...3, step: 0.05)
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
                    TextField("Background hex", text: $viewModel.backgroundHex)
                        .textFieldStyle(.roundedBorder)
                    Slider(value: $viewModel.backgroundOpacity, in: 0...1)
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
        .background(AuraGlassInsetCard(cornerRadius: 16, emphasized: true))
    }
}
