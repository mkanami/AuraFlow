import AuraWallpaperCore
import SwiftUI

/// Hosts only the wallpaper background; controls and desktop clicks remain outside the effect layers.
struct WallpaperEffectsPreview<Content: View>: NSViewRepresentable {
    let settings: WallpaperEffectsSettings
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WallpaperEffectsView {
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = []
        let view = WallpaperEffectsView(content: hosting, store: nil, isPreview: true)
        view.update(settings: settings)
        return view
    }

    func updateNSView(_ view: WallpaperEffectsView, context: Context) {
        (view.wallpaperContent as? NSHostingView<Content>)?.rootView = content()
        view.update(settings: settings)
    }
}
