import SwiftUI

struct WallpaperAudioBadge: View {
    var body: some View {
        glassBadge
            .accessibilityLabel("Wallpaper includes sound")
            .help("Sound was detected in this wallpaper. Use Volume to hear it.")
    }

    private var label: some View {
        Label("Audio", systemImage: "music.note")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7).padding(.vertical, 4)
    }

    @ViewBuilder private var glassBadge: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        label.background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}

/// Observes audio independently of the downloaded row's Equatable boundary.
struct CatalogWallpaperAudioBadge: View {
    let id: String
    @ObservedObject var metadata: CatalogAudioMetadata
    var body: some View {
        if metadata.audio[id] == true { WallpaperAudioBadge() }
    }
}
