import SwiftUI

struct WallpaperAudioBadge: View {
    var body: some View {
        Label("Audio", systemImage: "music.note")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityLabel("Wallpaper includes sound")
            .help("Sound was detected in this wallpaper. Use Volume to hear it.")
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
