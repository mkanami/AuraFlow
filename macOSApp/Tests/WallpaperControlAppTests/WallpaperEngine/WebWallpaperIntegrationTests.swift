import AppKit
import Foundation
import Testing
import WebKit
@testable import AuraWallpaperEngineCore

/// Opt-in real WebKit tests require an unlocked, interactive macOS session.
/// They never change desktop or Screen Saver preferences.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AURAFLOW_WEBKIT_TESTS"] == "1"))
@MainActor struct WebWallpaperIntegrationTests {
    private func loaded(_ script: String, size: NSSize = NSSize(width: 400, height: 240)) async throws -> (URL, NSWindow, WebWallpaperView, WebWallpaperConfiguration) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlow-WebKit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"type\":\"web\",\"file\":\"index.html\",\"title\":\"WebKit test\"}".utf8).write(to: root.appendingPathComponent("project.json"))
        try Data("window.localAsset=123;".utf8).write(to: root.appendingPathComponent("local.js"))
        try Data("<style>html,body{margin:0;background:#123456}canvas{width:100vw;height:100vh}</style><canvas id='c' width='400' height='240'></canvas><script src='local.js'></script><script>\(script)</script>".utf8).write(to: root.appendingPathComponent("index.html"))
        let project = try WallpaperEngineLibrary(rootURL: root.appendingPathComponent("owned")).importProject(at: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WebWallpaperView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view; window.orderFrontRegardless()
        let config = WebWallpaperConfiguration(project: project, values: ["text": .string("safe '\\ string")])
        var failure: String?
        view.onError = { failure = $0 }
        view.load(config)
        let deadline = Date().addingTimeInterval(10)
        while !view.ready && failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard view.ready else {
            view.unload(); window.close(); try? FileManager.default.removeItem(at: root)
            throw WallpaperEngineError.invalid(failure ?? "WebKit timed out")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        return (root, window, view, config)
    }
    private func snapshot(_ view: WebWallpaperView) async throws -> NSBitmapImageRep {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in view.capture { continuation.resume(with: $0) } }
        return try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    }
    @Test(arguments: [false, true])
    func canvasAndWebGLProduceVisibleSnapshots(webGL: Bool) async throws {
        let script = webGL ? "const gl=c.getContext('webgl'); if(!gl) throw Error('No WebGL'); gl.clearColor(0,1,0,1); gl.clear(gl.COLOR_BUFFER_BIT);" : "const g=c.getContext('2d'); g.fillStyle='#00ff00'; g.fillRect(0,0,400,240);"
        let (root, window, view, _) = try await loaded(script, size: webGL ? NSSize(width: 240, height: 400) : NSSize(width: 600, height: 240))
        defer { view.unload(); window.close(); try? FileManager.default.removeItem(at: root) }
        let bitmap = try await snapshot(view)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent > 0.8)
        #expect(color.redComponent < 0.2)
        #expect(view.webView?.configuration.websiteDataStore.isPersistent == false)
    }
    @Test
    func propertiesDeliverOnceAndHiddenViewDestroysJavaScriptThenRestores() async throws {
        let script = "window.calls=0;window.wallpaperPropertyListener={applyUserProperties(p){window.calls++;window.text=p.text.value;},applyGeneralProperties(p){window.fps=p.fps;},setPaused(p){window.paused=p;}};"
        let (root, window, view, config) = try await loaded(script)
        defer { view.unload(); window.close(); try? FileManager.default.removeItem(at: root) }
        let result = try await view.webView?.evaluateJavaScript("[window.calls,window.text,window.fps,window.paused]") as? [Any]
        #expect(result?[0] as? Int == 1)
        #expect(result?[1] as? String == "safe '\\ string")
        #expect(result?[2] as? Int == 30)
        #expect(result?[3] as? Bool == false)
        view.update(values: config.values)
        #expect(try await view.webView?.evaluateJavaScript("window.calls") as? Int == 1)
        let _: NSImage = try await withCheckedThrowingContinuation { c in view.freeze { c.resume(with: $0) } }
        #expect(view.webView == nil)
        #expect(!view.ready)
        view.load(config)
        for _ in 0..<100 where !view.ready { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(view.ready)
    }
    @Test
    func staleLoadCannotReplaceNewSourceAndNetworkAPIsAreBlocked() async throws {
        let (root, window, view, config) = try await loaded("window.localValue=42;")
        defer { view.unload(); window.close(); try? FileManager.default.removeItem(at: root) }
        #expect(try await view.webView?.evaluateJavaScript("(()=>{try{new WebSocket('ws://127.0.0.1:9')}catch(e){return e.message}})()") as? String == "External network access is disabled in AuraFlow")
        #expect(try await view.webView?.evaluateJavaScript("navigator.sendBeacon('https://example.invalid','x')") as? Bool == false)
        #expect(try await view.webView?.evaluateJavaScript("window.localAsset") as? Int == 123)
        #expect(try await view.webView?.evaluateJavaScript("(()=>{try{new Worker('local.js')}catch(e){return e.message}})()") as? String == "Web workers are unavailable in AuraFlow")
        view.load(config)
        view.unload()
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(view.webView == nil)
        #expect(!view.ready)
    }
}
