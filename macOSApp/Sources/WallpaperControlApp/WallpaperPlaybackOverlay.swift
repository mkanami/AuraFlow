import SwiftUI

enum WallpaperPlaybackOverlayLayout {
    static func width(available: CGFloat, includesVolume: Bool) -> CGFloat {
        includesVolume ? min(1000, max(0, available - 8)) : min(max(available * 0.46, 420), min(720, available))
    }
}

struct WallpaperPlaybackOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isAdjustingSpeed: Bool
    let availableWidth: CGFloat

    private var contents: some View {
        let volume = viewModel.showsWallpaperVolumeControl
        let width = WallpaperPlaybackOverlayLayout.width(available: availableWidth, includesVolume: volume)
        let controlsWidth = max(0, width - 12)
        return HStack(spacing: 12) {
            SpeedOverlay(viewModel: viewModel, isAdjustingSpeed: $isAdjustingSpeed,
                availableWidth: availableWidth, widthOverride: volume ? controlsWidth * 0.57 : width)
            if volume { WallpaperVolumeOverlay(viewModel: viewModel).frame(width: controlsWidth * 0.43) }
        }
        .frame(width: width)
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { contents }
        } else { contents }
        #else
        contents
        #endif
    }
}

private struct WallpaperVolumeOverlay: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var lastAudibleVolume = 0.3
    @State private var audioContent: WallpaperAudioContent = .unknown
    @Environment(\.adaptiveGlassAppearance) private var appearance

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if viewModel.wallpaperVolume > 0 {
                    lastAudibleVolume = viewModel.wallpaperVolume
                    viewModel.updateVolume(0, immediately: true)
                } else { viewModel.updateVolume(lastAudibleVolume, immediately: true) }
            } label: {
                Image(systemName: viewModel.wallpaperVolume == 0 || audioContent.isSilent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(audioContent.isSilent)
            .accessibilityLabel(audioContent.isSilent ? "No audio in this wallpaper" : (viewModel.wallpaperVolume == 0 ? "Unmute wallpaper audio" : "Mute wallpaper audio"))
            .accessibilityIdentifier("wallpaper.audio.mute")

            Text("Volume").font(.body.weight(.semibold)).lineLimit(1).fixedSize()
            if audioContent.isSilent {
                Spacer(minLength: 0)
                Text("No audio").font(.callout).lineLimit(1)
                    .accessibilityIdentifier("wallpaper.audio.silent")
            } else {
                AuraLegacySpeedSlider(value: viewModel.wallpaperVolume, range: 0...1, step: 0.01,
                    onValueChanged: { viewModel.updateVolume($0) },
                    onEditingChanged: { editing in
                        viewModel.setVolumeEditing(editing)
                        if !editing { viewModel.updateVolume(viewModel.wallpaperVolume, immediately: true) }
                    })
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Wallpaper volume")
                    .accessibilityValue("\(Int((viewModel.wallpaperVolume * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.05 : -0.05
                        viewModel.updateVolume(viewModel.wallpaperVolume + delta, immediately: true)
                    }
                    .accessibilityIdentifier("wallpaper.audio.volume")
                Text("\(Int((viewModel.wallpaperVolume * 100).rounded()))%")
                    .font(.body.weight(.semibold)).monospacedDigit().lineLimit(1)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
        .foregroundStyle(appearance.topTextTone.primaryTextColor)
        .frame(minHeight: 24)
        .padding(.vertical, 10).padding(.horizontal, 16)
        .modifier(WallpaperPlaybackPillGlass())
        .help(audioContent.explanation)
        .task(id: viewModel.currentVideoURL) {
            audioContent = .unknown
            guard let url = viewModel.currentVideoURL?.standardizedFileURL else { return }
            await viewModel.catalogAudioMetadata.inspectLocal(url: url)
            guard !Task.isCancelled else { return }
            audioContent = viewModel.catalogAudioMetadata.localContent[url] ?? .unknown
        }
    }
}

/// Glass belongs to the complete control. A glass-only background is hoisted
/// above sibling labels by GlassEffectContainer on current macOS releases.
struct WallpaperPlaybackPillGlass: ViewModifier {
    @Environment(\.adaptiveGlassAppearance) private var appearance
    func body(content: Content) -> some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .background(Capsule().fill(appearance.topTextTone.contrastSurfaceColor.opacity(appearance.topProtectionOverlayOpacity)))
                    .glassEffect(.clear, in: Capsule())
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
            #else
            content.background(.ultraThinMaterial, in: Capsule())
            #endif
        }
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 2)
        .environment(\.colorScheme, .dark)
    }
}
