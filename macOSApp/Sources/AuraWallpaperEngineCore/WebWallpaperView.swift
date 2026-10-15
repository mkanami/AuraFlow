import AppKit
import Foundation
import WebKit

/// Each instance has a project-only file grant and no shared browser session.
/// Destroying the WKWebView, not merely hiding it, stops author timers.
@MainActor
public final class WebWallpaperView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public private(set) var webView: WKWebView?
    public var onReady: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onWarning: ((String) -> Void)?
    public private(set) var ready = false
    private var configuration: WebWallpaperConfiguration?
    private var generation = WebWallpaperGenerationGate()
    private let fallback = NSImageView()
    private var retryCount = 0
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        fallback.imageScaling = .scaleProportionallyUpOrDown
        fallback.frame = bounds; fallback.autoresizingMask = [.width, .height]
        addSubview(fallback)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    public func load(_ config: WebWallpaperConfiguration) {
        let reset = configuration?.project.id != config.project.id || configuration?.generation != config.generation
        if reset { retryCount = 0; fallback.image = nil }
        unload(); configuration = config
        guard config.project.type == .web else { onError?("This is not a Web project."); return }
        let token = generation.generation
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.mediaTypesRequiringUserActionForPlayback = .audio
        let content = webConfiguration.userContentController
        content.add(WeakMessageHandler(self), name: "auraDiagnostic")
        content.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Rules apply to subresources as well as navigation. NavigationDelegate
        // alone does not block fetch/XHR/images/web sockets in an imported page.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AuraFlowOfflineWallpaper-v2", encodedContentRuleList: rules) { [weak self] rule, error in
            Task { @MainActor in
                guard let self, self.generation.accepts(token) else { return }
                guard let rule, error == nil else { self.onError?("Could not establish the offline Web sandbox."); return }
                content.add(rule)
                do {
                    _ = try WallpaperEngineLibrary.relativePath(config.project.entryPath, in: config.project.rootURL)
                    let view = WKWebView(frame: self.bounds, configuration: webConfiguration)
                    view.autoresizingMask = [.width, .height]
                    view.navigationDelegate = self; view.uiDelegate = self
                    self.webView = view; self.addSubview(view)
                    view.loadFileURL(config.project.entryURL, allowingReadAccessTo: config.project.rootURL)
                } catch { self.onError?(error.localizedDescription) }
            }
        }
    }
    public func update(values: [String: ProjectValue], fps: Int = 30) {
        let fps = min(max(fps, 1), 60)
        guard configuration?.values != values || configuration?.fps != fps else { return }
        configuration?.values = values; configuration?.fps = fps
        deliverProperties()
    }
    public func unload() {
        generation.replace(); ready = false
        webView?.evaluateJavaScript("window.wallpaperPropertyListener?.setPaused?.(true)")
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "auraDiagnostic")
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
    }
    public func freeze(completion: @escaping (Result<NSImage, Error>) -> Void) {
        let token = generation.generation
        capture { [weak self] result in
            guard let self, self.generation.accepts(token) else { completion(.failure(CancellationError())); return }
            if case .success(let image) = result { self.fallback.image = image }
            self.unload(); completion(result)
        }
    }
    public func capture(completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard let webView, ready else {
            if let image = fallback.image { completion(.success(image)) }
            else { completion(.failure(WallpaperEngineError.invalid("The web wallpaper has no rendered frame yet."))) }
            return
        }
        let token = generation.generation
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            guard let self, self.generation.accepts(token) else { completion(.failure(CancellationError())); return }
            guard let image, image.size.width > 0, image.size.height > 0 else {
                completion(.failure(error ?? WallpaperEngineError.invalid("WebKit did not produce a Lock Screen frame."))); return
            }
            completion(.success(image))
        }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        ready = true; deliverProperties()
        // Give Canvas/WebGL a paint opportunity before taking the seed frame.
        let token = generation.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation.accepts(token) else { return }
            self.onReady?()
        }
    }
    private func deliverProperties() {
        guard ready, let configuration else { return }
        let wrapped = configuration.values.mapValues { ["value": $0] }
        guard let json = try? JSONEncoder().encode(wrapped), let string = String(data: json, encoding: .utf8) else { return }
        let token = generation.generation
        webView?.evaluateJavaScript("window.wallpaperPropertyListener?.applyUserProperties?.(\(string)); window.wallpaperPropertyListener?.applyGeneralProperties?.({fps:\(min(max(configuration.fps, 1), 60))}); window.wallpaperPropertyListener?.setPaused?.(false);") { [weak self] _, error in
            guard self?.generation.accepts(token) == true else { return }
            if let error { self?.onError?("Wallpaper property callback failed: \(error.localizedDescription)") }
        }
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let config = configuration,
              url.isFileURL, url.resolvingSymlinksInPath().path.hasPrefix(config.project.rootURL.resolvingSymlinksInPath().path + "/"),
              !navigationAction.shouldPerformDownload,
              navigationAction.navigationType != .linkActivated else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === self.webView { onError?(error.localizedDescription) } }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === self.webView { onError?(error.localizedDescription) } }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard retryCount < 1, let configuration else { onError?("The WebKit renderer terminated repeatedly."); unload(); return }
        retryCount += 1; load(configuration)
    }
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard userContentController === webView?.configuration.userContentController,
              message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        if text.hasPrefix("Web error:") { onError?(text) } else { onWarning?(text) }
    }
    private static let bridgeScript = """
    (() => {
      // Content rules block subresource requests. Also deny network APIs which
      // are not consistently covered by WebKit's content blocker (WebSocket).
      function deny() { throw new Error('External network access is disabled in AuraFlow'); }
      for (const name of ['WebSocket', 'EventSource', 'RTCPeerConnection', 'webkitRTCPeerConnection']) {
        Object.defineProperty(window, name, {value: deny, configurable: false, writable: false});
      }
      if (navigator.sendBeacon) navigator.sendBeacon = () => false;
      const warned = new Set();
      const report = name => { if (!warned.has(name)) { warned.add(name); window.webkit.messageHandlers.auraDiagnostic.postMessage(name + ' is unavailable in AuraFlow.'); } };
      // Worker contexts do not receive WKUserScripts. Until a worker-specific
      // offline sandbox exists, do not let them bypass the network restrictions.
      for (const name of ['Worker', 'SharedWorker']) {
        Object.defineProperty(window, name, {value: function() { report('Web workers'); throw new Error('Web workers are unavailable in AuraFlow'); }, configurable: false, writable: false});
      }
      if (navigator.serviceWorker) Object.defineProperty(navigator, 'serviceWorker', {value: undefined});
      if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition = (_, failure) => failure?.({code:1,message:'Permission denied'});
        navigator.geolocation.watchPosition = (_, failure) => { failure?.({code:1,message:'Permission denied'}); return 0; };
      }
      for (const name of ['wallpaperRegisterAudioListener', 'wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener', 'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener', 'wallpaperRegisterMediaTimelineListener', 'wallpaperRegisterRGBListener']) {
        window[name] = () => report(name);
      }
      window.wallpaperRequestRandomFileForProperty = (key, callback) => { report('Directory properties'); if (typeof callback === 'function') callback(key, ''); };
      window.addEventListener('error', event => window.webkit.messageHandlers.auraDiagnostic.postMessage('Web error: ' + (event.message || 'asset load failed')));
    })();
    """
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}
