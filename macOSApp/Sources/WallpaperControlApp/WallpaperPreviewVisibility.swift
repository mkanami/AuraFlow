import AppKit

@MainActor
enum WallpaperPreviewVisibility {
    static var isVisible: Bool {
        !NSApp.isHidden && NSApp.windows.contains {
            $0.title == "AuraFlow" && $0.isVisible && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
        }
    }
}

/// Watches visibility, not keyboard focus: a visible background window still
/// animates. The installed wallpaper agents are deliberately outside this policy.
@MainActor
final class WallpaperPreviewVisibilityMonitor {
    private var observers: [NSObjectProtocol] = []
    private var lastVisible: Bool?
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.willCloseNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        let visible = WallpaperPreviewVisibility.isVisible
        guard lastVisible != visible else { return }
        lastVisible = visible
        onChange(visible)
    }
}
