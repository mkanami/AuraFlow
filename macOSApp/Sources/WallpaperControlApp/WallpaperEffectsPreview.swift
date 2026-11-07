import AuraWallpaperCore
import SwiftUI

/// Hosts only the wallpaper background; controls and desktop clicks remain outside the effect layers.
struct WallpaperEffectsPreview<Content: View>: NSViewRepresentable {
    let settings: WallpaperEffectsSettings
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WallpaperEffectsView {
        let hosting = NSHostingView(rootView: WallpaperEffectsPreviewContent(content: content()))
        hosting.sizingOptions = []
        if #available(macOS 13.3, *) {
            // This host renders a background inside an already full-size preview.
            // Inheriting the window's titlebar safe area creates a second top inset.
            hosting.safeAreaRegions = []
        }
        let view = WallpaperEffectsView(content: hosting, store: nil, isPreview: true)
        view.update(settings: settings)
        return view
    }

    func updateNSView(_ view: WallpaperEffectsView, context: Context) {
        (view.wallpaperContent as? NSHostingView<WallpaperEffectsPreviewContent<Content>>)?.rootView =
            WallpaperEffectsPreviewContent(content: content())
        view.update(settings: settings)
    }
}

private struct WallpaperEffectsPreviewContent<Content: View>: View {
    let content: Content

    var body: some View {
        content.ignoresSafeArea() // Also covers macOS 13.0–13.2, before safeAreaRegions is available.
    }
}
