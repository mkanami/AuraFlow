import AuraWallpaperCore
import SwiftUI
import Combine

/// Hosts only the wallpaper background; controls and desktop clicks remain outside the effect layers.
struct WallpaperEffectsPreview<Content: View>: NSViewRepresentable {
    let settings: WallpaperEffectsSettings
    let renderingActivity: PreviewRenderingActivity
    var imageURL: URL? = nil
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
        view.rainLightingImageURL = imageURL
        view.update(settings: settings)
        context.coordinator.attach(view, activity: renderingActivity)
        return view
    }

    func updateNSView(_ view: WallpaperEffectsView, context: Context) {
        (view.wallpaperContent as? NSHostingView<WallpaperEffectsPreviewContent<Content>>)?.rootView =
            WallpaperEffectsPreviewContent(content: content())
        view.rainLightingImageURL = imageURL
        view.update(settings: settings)
        context.coordinator.attach(view, activity: renderingActivity)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private weak var activity: PreviewRenderingActivity?
        private var subscription: AnyCancellable?

        func attach(_ view: WallpaperEffectsView, activity: PreviewRenderingActivity) {
            guard self.activity !== activity else { return }
            self.activity = activity
            view.setPreviewInteractionActive(activity.isSuspended)
            subscription = activity.changes.sink { [weak view] active in
                view?.setPreviewInteractionActive(active)
            }
        }
    }
}

private struct WallpaperEffectsPreviewContent<Content: View>: View {
    let content: Content

    var body: some View {
        content.ignoresSafeArea() // Also covers macOS 13.0–13.2, before safeAreaRegions is available.
    }
}
