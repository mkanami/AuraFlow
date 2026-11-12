import SwiftUI

struct WallpaperAudioBadge: View {
    var body: some View {
        Label("Audio", systemImage: "music.note")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityLabel("Wallpaper includes an audio track")
            .help("This wallpaper includes an audio track. Use Volume to hear it.")
    }
}
