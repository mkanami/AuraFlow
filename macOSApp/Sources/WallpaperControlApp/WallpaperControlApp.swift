import AppKit
import SwiftUI

@MainActor
final class AuraFlowApplication {
    static let shared = AuraFlowApplication()

    let viewModel = AppViewModel()
    private var mainWindow: NSWindow?

    private init() {}

    func showMainWindow() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window

        removeDuplicateMainWindows(keeping: window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        if !window.isVisible {
            ensureWindowIsVisibleOnScreen(window)
            window.orderFrontRegardless()
        }

        ensureWindowIsVisibleOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeMainWindow() -> NSWindow {
        let size = preferredWindowSize()
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: visibleFrame.midX - (size.width * 0.5),
            y: visibleFrame.midY - (size.height * 0.5)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size).integral,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AuraFlow"
        window.contentViewController = NSHostingController(rootView: ContentView(viewModel: self.viewModel))
        configureWindowForClientDecorations(window)
        return window
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        scheduleMainWindowReveal()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !hasVisibleAuraFlowMainWindow() else { return }
        scheduleMainWindowReveal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scheduleMainWindowReveal()
        return false
    }

    private func scheduleMainWindowReveal(attempt: Int = 0) {
        let revealDelay = attempt == 0 ? 0.05 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) {
            if bringMainWindowToFront() {
                return
            }
            AuraFlowApplication.shared.showMainWindow()
            guard attempt < 20 else {
                return
            }
            self.scheduleMainWindowReveal(attempt: attempt + 1)
        }
    }
}

@main
struct WallpaperControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AuraFlowApplication.shared.viewModel

    var body: some Scene {
        MenuBarExtra {
            MenuBarControls(viewModel: viewModel)
        } label: {
            MenuBarIcon()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct MenuBarControls: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var menuOpenedAt: Date = .distantPast

    var body: some View {
        Button("Open AuraFlow") {
            openMainWindow()
        }

        Divider()

        Button("Start") {
            guard allowActionAfterMenuOpen else { return }
            performMenuBarActionAfterDismiss {
                viewModel.start()
            }
        }
        .disabled(!viewModel.canStart)

        Button("Stop") {
            guard allowActionAfterMenuOpen else { return }
            viewModel.stop()
        }
        .disabled(!viewModel.canStop)

        Button("Remove Wallpaper") {
            guard allowActionAfterMenuOpen else { return }
            performMenuBarActionAfterDismiss {
                viewModel.clearWallpaper()
            }
        }
        .disabled(!viewModel.canClearWallpaper)

        Button("Change Wallpaper…") {
            guard allowActionAfterMenuOpen else { return }
            changeWallpaperFromMenuBar()
        }
        .disabled(!viewModel.canClearWallpaper)

        Button("Wallpaper Catalog") {
            guard allowActionAfterMenuOpen else { return }
            openCatalogFromMenuBar()
        }

        Divider()

        Button("Quit AuraFlow") {
            NSApp.terminate(nil)
        }
        .onAppear {
            menuOpenedAt = Date()
        }
    }

    private var allowActionAfterMenuOpen: Bool {
        Date().timeIntervalSince(menuOpenedAt) > 0.35
    }

    private func openMainWindow() {
        AuraFlowApplication.shared.showMainWindow()
    }

    private func changeWallpaperFromMenuBar() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            viewModel.chooseVideoFromMenuBar()
        }
    }

    private func openCatalogFromMenuBar() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            viewModel.openCatalogFromMenuBar()
        }
    }

    private func performMenuBarActionAfterDismiss(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            action()
        }
    }
}

private struct MenuBarIcon: View {
    var body: some View {
        Image(nsImage: Self.menuBarTemplateIcon)
            .renderingMode(.template)
            .accessibilityLabel("AuraFlow")
    }

    private static let menuBarTemplateIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.black.setStroke()

        let framePath = NSBezierPath(roundedRect: NSRect(x: 2.4, y: 7.3, width: 13.2, height: 8.1), xRadius: 2.4, yRadius: 2.4)
        framePath.lineWidth = 1.75
        framePath.lineCapStyle = .round
        framePath.lineJoinStyle = .round
        framePath.stroke()

        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 3.6, y: 11.2))
        wave.curve(
            to: NSPoint(x: 14.4, y: 11.2),
            controlPoint1: NSPoint(x: 5.5, y: 12.9),
            controlPoint2: NSPoint(x: 8.8, y: 9.4)
        )
        wave.lineWidth = 1.65
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        wave.stroke()

        let loop = NSBezierPath()
        loop.appendArc(withCenter: NSPoint(x: 9.0, y: 5.4), radius: 2.7, startAngle: 208, endAngle: 18, clockwise: false)
        loop.lineWidth = 1.65
        loop.lineCapStyle = .round
        loop.lineJoinStyle = .round
        loop.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 7.2, y: 2.95))
        arrow.line(to: NSPoint(x: 6.25, y: 3.95))
        arrow.move(to: NSPoint(x: 7.2, y: 2.95))
        arrow.line(to: NSPoint(x: 8.45, y: 3.15))
        arrow.lineWidth = 1.65
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}
