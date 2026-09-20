import AuraTerminalWallpaperCore
import SwiftUI

struct TerminalWallpaperSettingsView: View {
    @ObservedObject var viewModel: TerminalWallpaperViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                commandSection
                renderSection
                behaviorSection
                statusSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 600)
        .task {
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

    private var commandSection: some View {
        GroupBox("Child TUI") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Executable, e.g. /usr/bin/top", text: $viewModel.executable)
                    .textFieldStyle(.roundedBorder)
                Text("Arguments — one argument per line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.argumentsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                TextField("Working directory (optional)", text: $viewModel.workingDirectory)
                    .textFieldStyle(.roundedBorder)
                Text("Environment — KEY=VALUE per line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.environmentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            .padding(.top, 4)
        }
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
