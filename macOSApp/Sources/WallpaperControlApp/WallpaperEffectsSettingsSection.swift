import AuraWallpaperCore
import SwiftUI

struct WallpaperEffectsSettingsSection: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @State private var isExpanded: Bool

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _isExpanded = State(initialValue: viewModel.wallpaperEffects.enabled)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            effectControls
        } label: {
            HStack {
                Label("Wallpaper Effects", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(viewModel.wallpaperEffects.enabled ? "On" : "Off")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("wallpaper-effects-settings")
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable wallpaper effects", isOn: binding(\.enabled))
                .toggleStyle(.switch)
            Text("Applies immediately to the Desktop and this preview, for photos, videos, terminal and web wallpapers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.wallpaperEffects.enabled {
                AuraGlassContentGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(WallpaperEffectsPreset.allCases) { preset in
                            Button(preset.title) { viewModel.applyWallpaperEffectsPreset(preset) }
                                .help("Apply the \(preset.title) effect preset")
                        }
                        Spacer(minLength: 0)
                    }
                    .modifier(WallpaperEffectsGlassButtons())
                    .controlSize(.small)
                }

                Toggle("React to cursor", isOn: binding(\.reactsToCursor))
                    .help("Follow the cursor on its display. Turn off for gentle automatic motion.")
                effectSlider("Smoothing", value: \.smoothing)
                effectSlider("Ambient speed", value: \.ambientSpeed)
                lightColorMenu

                Divider()
                Toggle("Parallax", isOn: binding(\.parallaxEnabled))
                if viewModel.wallpaperEffects.parallaxEnabled {
                    effectSlider("Depth", value: \.parallaxAmount)
                    Text("Adds a slight crop so movement keeps the edges covered.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Toggle("Soft glow", isOn: binding(\.glowEnabled))
                if viewModel.wallpaperEffects.glowEnabled {
                    effectSlider("Glow intensity", value: \.glowIntensity)
                    effectSlider("Glow size", value: \.glowSize)
                }

                Toggle("Lens flare", isOn: binding(\.flareEnabled))
                if viewModel.wallpaperEffects.flareEnabled {
                    effectSlider("Flare intensity", value: \.flareIntensity)
                }

                Toggle("Light reflections", isOn: binding(\.reflectionEnabled))
                if viewModel.wallpaperEffects.reflectionEnabled {
                    effectSlider("Reflection", value: \.reflectionIntensity)
                }

                Toggle("Bloom", isOn: binding(\.bloomEnabled))
                if viewModel.wallpaperEffects.bloomEnabled {
                    effectSlider("Bloom intensity", value: \.bloomIntensity)
                    effectSlider("Bloom radius", value: \.bloomRadius)
                }

                Toggle("Blur", isOn: binding(\.blurEnabled))
                if viewModel.wallpaperEffects.blurEnabled {
                    effectSlider("Blur amount", value: \.blurAmount)
                }

                Toggle("Sparkles", isOn: binding(\.sparkleEnabled))
                if viewModel.wallpaperEffects.sparkleEnabled {
                    effectSlider("Sparkle density", value: \.sparkleAmount)
                }

                Toggle("Rain", isOn: binding(\.rainEnabled))
                if viewModel.wallpaperEffects.rainEnabled {
                    rainColorMenu
                    effectSlider("Rain density", value: \.rainAmount)
                    effectSlider("Rain speed", value: \.rainSpeed)
                    effectSlider("Wind direction", value: \.rainAngle)
                    Text("Three depth layers, gentle wind gusts and lighting sampled from the wallpaper. Cursor movement adds a small parallax.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Text("Parallax moves the wallpaper, distant light and foreground particles at different depths. Flat media uses simulated depth.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Effects rest during playback pauses, sleep and Reduce Motion. Low Power Mode reduces effects to 30 fps. Lock Screen keeps the original wallpaper.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset effects") { viewModel.resetWallpaperEffects() }
                    .modifier(WallpaperEffectsGlassButtons())
                    .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.top, 8)
        .padding(.leading, 4)
    }

    private var lightColorMenu: some View {
        colorMenu("Light color", selection: binding(\.tint), options: WallpaperEffectsTint.allCases, name: { $0.title })
    }

    private var rainColorMenu: some View {
        let rgb = viewModel.wallpaperEffects.rainColor.rgb
        return colorMenu("Rain color", selection: binding(\.rainColor), options: WallpaperRainColor.allCases,
            name: { $0.title }, swatch: Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
    }

    private func colorMenu<Value: Identifiable & Hashable>(_ title: String, selection: Binding<Value>,
        options: [Value], name: @escaping (Value) -> String, swatch: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Text(title)
            if let swatch {
                Circle().fill(swatch).frame(width: 9, height: 9).accessibilityHidden(true)
            }
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options) { option in Text(name(option)).tag(option) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(name(selection.wrappedValue))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .modifier(AuraGlassInsetCardModifier(cornerRadius: 9))
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(name(selection.wrappedValue))
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<WallpaperEffectsSettings, Value>) -> Binding<Value> {
        Binding(get: { viewModel.wallpaperEffects[keyPath: key] },
                set: { viewModel.setWallpaperEffect(key, $0) })
    }

    private func effectSlider(_ title: String, value key: WritableKeyPath<WallpaperEffectsSettings, Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).frame(width: 100, alignment: .leading)
            AuraLegacySpeedSlider(value: viewModel.wallpaperEffects[keyPath: key], range: 0...1, step: 0.01,
                onValueChanged: { viewModel.setWallpaperEffect(key, $0) }, onEditingChanged: { _ in },
                textTone: adaptiveGlassAppearance.centerTextTone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(Text(viewModel.wallpaperEffects[keyPath: key], format: .percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(key, by: 0.01)
                    case .decrement: adjust(key, by: -0.01)
                    @unknown default: break
                    }
                }
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .right, .up: adjust(key, by: 0.01)
                    case .left, .down: adjust(key, by: -0.01)
                    default: break
                    }
                }
            Text(viewModel.wallpaperEffects[keyPath: key], format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func adjust(_ key: WritableKeyPath<WallpaperEffectsSettings, Double>, by amount: Double) {
        viewModel.setWallpaperEffect(key, min(1, max(0, viewModel.wallpaperEffects[keyPath: key] + amount)))
    }
}

private struct WallpaperEffectsGlassButtons: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2.3)
        if #available(macOS 26.1, *) {
            content.buttonStyle(.glass(.clear))
        } else {
            compatibleButtons(content)
        }
        #else
        compatibleButtons(content)
        #endif
    }

    @ViewBuilder
    private func compatibleButtons(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
        }
        #else
        content.buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
        #endif
    }
}
