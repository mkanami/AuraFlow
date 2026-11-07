import AuraWallpaperCore
import SwiftUI

struct WallpaperEffectsSettingsSection: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isExpanded: Bool

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _isExpanded = State(initialValue: viewModel.wallpaperEffects.enabled)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable wallpaper effects", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                Text("Applies immediately to the Desktop and this preview, for photos, videos, terminal and web wallpapers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.wallpaperEffects.enabled {
                    HStack {
                        ForEach(WallpaperEffectsPreset.allCases) { preset in
                            Button(preset.title) { viewModel.applyWallpaperEffectsPreset(preset) }
                                .help("Apply the \(preset.title) effect preset")
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Toggle("React to cursor", isOn: binding(\.reactsToCursor))
                        .help("Follow the cursor on its display. Turn off for gentle automatic motion.")
                    effectSlider("Smoothing", value: \.smoothing)
                    effectSlider("Ambient speed", value: \.ambientSpeed)
                    Picker("Light color", selection: binding(\.tint)) {
                        ForEach(WallpaperEffectsTint.allCases) { tint in Text(tint.title).tag(tint) }
                    }

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
                        effectSlider("Rain density", value: \.rainAmount)
                        effectSlider("Rain speed", value: \.rainSpeed)
                        effectSlider("Wind direction", value: \.rainAngle)
                    }

                    Text("Parallax moves the wallpaper, distant light and foreground particles at different depths. Flat media uses simulated depth.")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("Effects rest during playback pauses, sleep and Reduce Motion. Low Power Mode reduces effects to 30 fps. Lock Screen keeps the original wallpaper.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset effects") { viewModel.resetWallpaperEffects() }
                        .controlSize(.small)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 8)
            .padding(.leading, 4)
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

    private func binding<Value>(_ key: WritableKeyPath<WallpaperEffectsSettings, Value>) -> Binding<Value> {
        Binding(get: { viewModel.wallpaperEffects[keyPath: key] },
                set: { viewModel.setWallpaperEffect(key, $0) })
    }

    private func effectSlider(_ title: String, value key: WritableKeyPath<WallpaperEffectsSettings, Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).frame(width: 100, alignment: .leading)
            Slider(value: binding(key), in: 0...1)
                .accessibilityLabel(title)
            Text(viewModel.wallpaperEffects[keyPath: key], format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
