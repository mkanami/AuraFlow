import AppKit
import AuraWallpaperEngineCore
import Darwin
import Foundation
#if canImport(Wallpaper)
@preconcurrency import Wallpaper
#endif

@main
struct WebWallpaperAgentMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = WebWallpaperAgent()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class WebWallpaperAgent: NSObject, NSApplicationDelegate {
    private var config: WebWallpaperConfiguration?
    private var state: WebWallpaperStatus?
    private var windows: [String: NSWindow] = [:]
    private var views: [String: WebWallpaperView] = [:]
    private var timer: Timer?
    private var paused = false
    private var locked = false
    private var pausePending = false
    private var pidLock: Int32 = -1
    private var ownsLock = false
    private var routeGeneration: String?
    private var displayErrors: [String: String] = [:]
    private var renderEpoch = UUID()
    private var screenObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var presentation = WebLockPresentation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentation.onError = { [weak self] error in self?.displayErrors["Lock Screen"] = error; self?.publish() }
        presentation.onReady = { [weak self] in self?.displayErrors.removeValue(forKey: "Lock Screen"); self?.publish() }
        do {
            try FileManager.default.createDirectory(at: WebWallpaperRuntime.root, withIntermediateDirectories: true)
            pidLock = open(WebWallpaperRuntime.url("agent.lock").path, O_CREAT | O_RDWR, 0o600)
            guard pidLock >= 0, flock(pidLock, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
            ownsLock = true
            try String(getpid()).write(to: WebWallpaperRuntime.url("agent.pid"), atomically: true, encoding: .utf8)
        } catch { NSApp.terminate(nil); return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        let center = DistributedNotificationCenter.default()
        for (name, lock) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false), ("com.apple.shieldWindowRaised", true)] {
            sessionObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.transitionLock(lock) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in sessionObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for view in views.values { view.unload() }
        if ownsLock {
            try? FileManager.default.removeItem(at: WebWallpaperRuntime.url("agent.pid"))
            try? FileManager.default.removeItem(at: WebWallpaperRuntime.url("status.json"))
        }
        if pidLock >= 0 { close(pidLock) }
    }
    private func tick() {
        if FileManager.default.fileExists(atPath: WebWallpaperRuntime.url("stop").path) { NSApp.terminate(nil); return }
        guard let next = WebWallpaperRuntime.read(WebWallpaperConfiguration.self, from: "config.json") else { return }
        if config?.generation != next.generation || config?.project.id != next.project.id {
            config = next
            state = .init(pid: getpid(), generation: next.generation, projectID: next.project.id)
            paused = false; pausePending = false; rebuild()
        } else if config != next {
            config = next
            for view in views.values { view.update(values: next.values, fps: next.fps) }
        }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], let actual = session["CGSSessionScreenIsLocked"] as? Bool, actual != locked {
            transitionLock(actual)
        }
        guard let config else { return }
        let route = try? String(contentsOf: WebWallpaperRuntime.url("route-active"))
        if route == config.generation, routeGeneration != route {
            routeGeneration = route
            presentation.update(locked: locked)
        }
        let shouldPause = WebWallpaperPausePolicy.shouldUnload(visible: true, locked: locked, fullscreen: Self.fullscreen(), pauseOnFullscreen: config.pauseOnFullscreen)
        if shouldPause && !paused && !pausePending { freeze() }
        if !shouldPause && paused {
            paused = false; state?.paused = false
            for view in views.values { view.load(config) }
        }
        publish()
    }
    private func rebuild() {
        guard let config else { return }
        renderEpoch = UUID(); let epoch = renderEpoch
        for view in views.values { view.unload() }
        for window in windows.values { window.orderOut(nil); window.close() }
        windows.removeAll(); views.removeAll()
        state?.frames = [:]
        state?.expectedDisplays = []; displayErrors = [:]; state?.error = nil
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.stringValue
            state?.expectedDisplays.append(id)
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true; window.backgroundColor = .black
            window.isOpaque = true; window.hasShadow = false
            let view = WebWallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let generation = config.generation
            view.onReady = { [weak self, weak view] in
                guard let self, let view, self.config?.generation == generation, self.renderEpoch == epoch else { return }
                self.capture(view, display: id, generation: generation)
            }
            view.onError = { [weak self] error in
                guard self?.config?.generation == generation, self?.renderEpoch == epoch else { return }
                self?.displayErrors[id] = error; self?.publish()
            }
            view.onWarning = { message in NSLog("AuraFlow web: %@", message) }
            window.contentView = view
            windows[id] = window; views[id] = view
            window.orderFrontRegardless(); view.load(config)
        }
        publish()
        if routeGeneration == config.generation { presentation.update(locked: locked) }
    }
    private func transitionLock(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value { freeze() }
        if let config, routeGeneration == config.generation { presentation.update(locked: value) }
    }
    private func freeze() {
        guard !pausePending, state?.ready == true, let config else { return }
        pausePending = true
        let generation = config.generation
        let epoch = renderEpoch
        let group = DispatchGroup()
        for (id, view) in views {
            group.enter()
            view.freeze { [weak self] result in
                defer { group.leave() }
                guard let self, self.config?.generation == generation, self.renderEpoch == epoch else { return }
                self.store(result, display: id, generation: generation)
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.config?.generation == generation, self.renderEpoch == epoch else { return }
            self.pausePending = false; self.paused = true; self.state?.paused = true; self.publish()
        }
    }
    private func capture(_ view: WebWallpaperView, display: String, generation: String) {
        let epoch = renderEpoch
        view.capture { [weak self] result in
            guard let self, self.renderEpoch == epoch else { return }
            self.store(result, display: display, generation: generation)
        }
    }
    private func store(_ result: Result<NSImage, Error>, display: String, generation: String) {
        guard config?.generation == generation else { return }
        do {
            let image = try result.get()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw WallpaperEngineError.invalid("Cannot encode the web Lock Screen frame.")
            }
            guard Self.hasVisiblePixels(bitmap) else { throw WallpaperEngineError.invalid("WebKit produced a black frame. This project may not support WebKit snapshots.") }
            let url = WebWallpaperRuntime.url("\(generation)-\(display).png")
            try png.write(to: url, options: .atomic)
            state?.frames[display] = url.path
            displayErrors.removeValue(forKey: "Frame " + display)
        } catch is CancellationError { return }
        catch { displayErrors["Frame " + display] = error.localizedDescription }
        publish()
    }
    private static func hasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
        // Do not miss a sparse Canvas drawing between sampling points. Inspect
        // the existing snapshot bytes, skipping alpha (black is usually opaque).
        if !bitmap.isPlanar, bitmap.bitsPerSample == 8, let bytes = bitmap.bitmapData {
            let components = bitmap.samplesPerPixel
            let alpha = bitmap.hasAlpha ? (bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : components - 1) : -1
            for y in 0..<bitmap.pixelsHigh {
                let row = bytes.advanced(by: y * bitmap.bytesPerRow)
                for x in 0..<bitmap.pixelsWide {
                    for component in 0..<components where component != alpha {
                        if row[x * components + component] > 5 { return true }
                    }
                }
            }
            return false
        }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(color.redComponent, color.greenComponent, color.blueComponent) > 0.02 { return true }
            }
        }
        return false
    }
    private func publish() {
        state?.error = displayErrors.sorted { $0.key < $1.key }.first?.value
        if let state { try? WebWallpaperRuntime.write(state, to: "status.json") }
    }
    private static func fullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return false }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            return NSScreen.screens.contains { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                let screenFrame = CGDisplayBounds(number.uint32Value)
                return abs(frame.minX - screenFrame.minX) < 3 && abs(frame.minY - screenFrame.minY) < 3 && abs(frame.width - screenFrame.width) < 3 && abs(frame.height - screenFrame.height) < 3
            }
        }
    }
}

/// Web-only presentation assertions. The video/terminal implementations and
/// their route journals remain unchanged.
@MainActor
final class WebLockPresentation {
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?
    private var assertions: [AnyObject] = []
    private var generation = 0
    private var task: Task<Void, Never>?
    func update(locked: Bool) {
        generation += 1; let current = generation
        task?.cancel()
        if locked, let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL),
           let symbol = dlsym(handle, "SACScreenSaverStartNow") {
            let start = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
            _ = start()
        }
        task = Task {
            #if canImport(Wallpaper)
            guard #available(macOS 26, *) else { return }
            do {
                var next: [AnyObject] = []
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                    let display = try await makeDisplay(number.uint32Value)
                    let presentation = try await Self.mode(DisplayBox(display), locked: locked)
                    guard !Task.isCancelled, generation == current else { return }
                    next.append(display); next.append(presentation.value)
                }
                assertions = next
                onReady?()
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                onError?("Lock Screen presentation failed: \(error.localizedDescription)")
            }
            #endif
        }
    }
    #if canImport(Wallpaper)
    @_optimize(none) private func makeDisplay(_ id: UInt32) async throws -> WallpaperDisplayAssertion {
        try await WallpaperDisplayAssertion(displayID: id, attributes: .screenSaver)
    }
    private final class DisplayBox: @unchecked Sendable {
        let value: WallpaperDisplayAssertion
        init(_ value: WallpaperDisplayAssertion) { self.value = value }
    }
    private final class ModeBox: @unchecked Sendable {
        let value: WallpaperPresentationModeAssertion
        init(_ value: WallpaperPresentationModeAssertion) { self.value = value }
    }
    private nonisolated static func mode(_ display: DisplayBox, locked: Bool) async throws -> ModeBox {
        if locked { return ModeBox(try await WallpaperPresentationModeAssertion.takeLockedAssertion(displayAssertion: display.value)) }
        return ModeBox(try await WallpaperPresentationModeAssertion.takeIdleAssertion(displayAssertion: display.value))
    }
    #endif
}
