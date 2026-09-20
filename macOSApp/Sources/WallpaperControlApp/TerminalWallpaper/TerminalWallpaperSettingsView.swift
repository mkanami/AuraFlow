import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel
    @State private var showAdvancedCommand = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                catalogSection
                renderSection
                behaviorSection
                statusSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 680)
        .task {
            viewModel.refreshCatalog()
            while !Task.isCancelled {
                viewModel.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Terminal Wallpaper", systemImage: "terminal")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(viewModel.statusTitle)
                .foregroundStyle(viewModel.status.running ? .green : .secondary)
        }
    }

    private var catalogSection: some View {
        GroupBox("Choose what to render") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select a terminal app or system utility. AuraFlow will find its executable automatically.")
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

                HStack {
                    Button("Refresh catalog") { viewModel.refreshCatalog() }
                    Button("Choose executable…") {
                        guard let url = TerminalExecutablePicker.choose() else { return }
                        if viewModel.selectCustomExecutable(url) {
                            showAdvancedCommand = true
                        }
                    }
                    Text("For custom scripts or terminal programs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced command settings", isExpanded: $showAdvancedCommand) {
                    advancedCommandFields
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func catalogCategory(_ category: TerminalWallpaperCatalogCategory) -> some View {
        let items = viewModel.availableCatalogItems(for: category)
        if !items.isEmpty {
            Label(category.title, systemImage: category.systemImage)
                .font(.headline)
                .padding(.top, 6)
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
                    Spacer()
                    if viewModel.selectedCatalogItemID == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("Start") { viewModel.start(item) }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.status.running)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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
        GroupBox("Render") {
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
            .padding(.top, 4)
        }
    }

    private var behaviorSection: some View {
        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Render on all displays", isOn: $viewModel.allDisplays)
                Toggle(
                    "Launch Terminal Wallpaper at login",
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
                HStack {
                    Button("Apply") { viewModel.apply() }
                        .disabled(viewModel.isBusy)
                    Button("Start") { viewModel.start() }
                        .disabled(!viewModel.canStart || viewModel.status.running)
                    Button("Restart") { viewModel.restart() }
                        .disabled(!viewModel.canStart)
                    Button("Stop") { viewModel.stop() }
                        .disabled(viewModel.isBusy || !viewModel.status.running)
                    Spacer()
                    Button("Refresh") { viewModel.refresh() }
                }
            }
            .padding(.top, 4)
        }
    }

    private var statusSection: some View {
        GroupBox("Runtime health") {
            VStack(alignment: .leading, spacing: 6) {
                if let health = viewModel.status.health {
                    Text("PID: \(health.childPID.map(String.init) ?? "—")")
                    Text("PTY/grid: \(health.columns.map(String.init) ?? "—") × \(health.rows.map(String.init) ?? "—")")
                    Text("Screens: \(health.screens)   Frames: \(health.frames)   Rendered: \(health.renderedFrames)")
                    if let error = health.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                } else {
                    Text("No runtime health report yet.")
                        .foregroundStyle(.secondary)
                }
                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage).foregroundStyle(.secondary)
                }
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.top, 4)
        }
    }
}
