import AppKit
import SwiftUI
import WebKit

struct CatalogStreamingVideoPreview: NSViewRepresentable {
    let url: URL
    let referer: URL?
    let onStarted: () -> Void
    let onFailed: () -> Void

    func makeNSView(context: Context) -> CatalogStreamingVideoHostView {
        let hostView = CatalogStreamingVideoHostView()
        CatalogStreamingVideoSessionStore.shared.attach(
            url: url,
            referer: referer,
            to: hostView,
            onStarted: onStarted,
            onFailed: onFailed
        )
        return hostView
    }

    func updateNSView(_ hostView: CatalogStreamingVideoHostView, context: Context) {
        CatalogStreamingVideoSessionStore.shared.attach(
            url: url,
            referer: referer,
            to: hostView,
            onStarted: onStarted,
            onFailed: onFailed
        )
    }

    static func dismantleNSView(_ hostView: CatalogStreamingVideoHostView, coordinator: Void) {
        CatalogStreamingVideoSessionStore.shared.detach(from: hostView)
    }
}

@MainActor
final class CatalogStreamingVideoSessionStore {
    static let shared = CatalogStreamingVideoSessionStore()

    @MainActor
    private final class Session {
        let url: URL
        let webView: CatalogStreamingWKWebView
        let messageHandler: MessageHandler

        init(url: URL, referer: URL?) {
            self.url = url
            self.messageHandler = MessageHandler()

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.userContentController.add(
                messageHandler,
                name: MessageHandler.messageName
            )

            let webView = CatalogStreamingWKWebView(frame: .zero, configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            webView.navigationDelegate = messageHandler
            self.webView = webView
            webView.loadHTMLString(Self.document(for: url), baseURL: referer)
        }

        func play() {
            messageHandler.shouldPlay = true
            messageHandler.requestPlayback(in: webView)
        }

        func pause() {
            messageHandler.shouldPlay = false
            webView.evaluateJavaScript("window.auraPausePreview?.()")
        }

        func stop() {
            messageHandler.shouldPlay = false
            webView.evaluateJavaScript(
                "window.auraPausePreview?.(); const v=document.getElementById('preview'); if(v){v.removeAttribute('src');v.load();}"
            )
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: MessageHandler.messageName
            )
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }

        func snapshot() -> NSImage? {
            guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
            let representation = webView.bitmapImageRepForCachingDisplay(in: webView.bounds)
            guard let representation else { return nil }
            webView.cacheDisplay(in: webView.bounds, to: representation)
            let image = NSImage(size: webView.bounds.size)
            image.addRepresentation(representation)
            return image
        }

        private static func document(for url: URL) -> String {
            let encodedURL = jsonString(url.absoluteString)
            return """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <style>
                html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
                video { width: 100%; height: 100%; object-fit: cover; background: transparent; }
              </style>
            </head>
            <body>
              <video id="preview" src=\(encodedURL) muted loop playsinline preload="auto"></video>
              <script>
                const video = document.getElementById('preview');
                let started = false;
                let failed = false;
                let retryTimer = null;
                const send = (value) => window.webkit.messageHandlers.\(MessageHandler.messageName).postMessage(value);
                const reportStarted = () => {
                  if (started || video.currentTime <= 0.03 || video.readyState < 2) return;
                  started = true;
                  clearTimeout(retryTimer);
                  requestAnimationFrame(() => requestAnimationFrame(() => send('started')));
                };
                const reportFailed = () => {
                  if (failed || started) return;
                  failed = true;
                  clearTimeout(retryTimer);
                  send('failed');
                };
                const attemptPlayback = () => {
                  if (!window.auraPreviewShouldPlay || failed) return;
                  video.muted = true;
                  video.play().catch(() => {});
                  clearTimeout(retryTimer);
                  if (!started) retryTimer = setTimeout(attemptPlayback, 250);
                };
                window.auraStartPreview = () => {
                  window.auraPreviewShouldPlay = true;
                  attemptPlayback();
                };
                window.auraPausePreview = () => {
                  window.auraPreviewShouldPlay = false;
                  clearTimeout(retryTimer);
                  video.pause();
                };
                video.addEventListener('playing', reportStarted);
                video.addEventListener('timeupdate', reportStarted);
                video.addEventListener('loadeddata', attemptPlayback);
                video.addEventListener('canplay', attemptPlayback);
                video.addEventListener('error', reportFailed);
              </script>
            </body>
            </html>
            """
        }

        private static func jsonString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: .fragmentsAllowed
            ),
            let result = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return result
        }
    }

    @MainActor
    private final class MessageHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "auraCatalogPreview"

        var hasStarted = false
        var hasFailed = false
        var shouldPlay = false
        var onStarted: (() -> Void)?
        var onFailed: (() -> Void)?

        func requestPlayback(in webView: WKWebView) {
            guard shouldPlay, !hasFailed else { return }
            webView.evaluateJavaScript("window.auraStartPreview?.()")
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageName,
                  let value = message.body as? String else {
                return
            }
            switch value {
            case "started" where !hasStarted:
                hasStarted = true
                onStarted?()
            case "failed" where !hasFailed:
                reportFailureIfNeeded()
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            reportFailureIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportFailureIfNeeded()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            requestPlayback(in: webView)
        }

        private func reportFailureIfNeeded() {
            guard !hasFailed, !hasStarted else { return }
            hasFailed = true
            onFailed?()
        }

        func deliverCurrentState() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                if hasStarted {
                    onStarted?()
                } else if hasFailed {
                    onFailed?()
                }
            }
        }
    }

    private var sessions: [URL: Session] = [:]

    func attach(
        url: URL,
        referer: URL?,
        to hostView: CatalogStreamingVideoHostView,
        onStarted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        let staleURLs = sessions.keys.filter { $0 != url }
        for existingURL in staleURLs {
            sessions.removeValue(forKey: existingURL)?.stop()
        }
        let session = session(for: url, referer: referer)
        session.messageHandler.onStarted = onStarted
        session.messageHandler.onFailed = onFailed

        if session.webView.superview !== hostView {
            session.webView.removeFromSuperview()
            hostView.install(session.webView, url: url)
        }
        session.play()

        session.messageHandler.deliverCurrentState()
    }

    func detach(from hostView: CatalogStreamingVideoHostView) {
        guard let url = hostView.url,
              let session = sessions[url],
              session.webView.superview === hostView else {
            return
        }
        session.messageHandler.onStarted = nil
        session.messageHandler.onFailed = nil
        hostView.url = nil
        sessions[url] = nil
        session.stop()
    }

    func snapshotAndStop(url: URL) -> NSImage? {
        guard let session = sessions.removeValue(forKey: url) else { return nil }
        let image = session.snapshot()
        session.stop()
        return image
    }

    func stop(url: URL) {
        sessions.removeValue(forKey: url)?.stop()
    }

    private func session(for url: URL, referer: URL?) -> Session {
        if let existing = sessions[url] {
            return existing
        }
        let session = Session(url: url, referer: referer)
        sessions[url] = session
        return session
    }

}

final class CatalogStreamingVideoHostView: NSView {
    fileprivate var url: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    fileprivate func install(_ webView: WKWebView, url: URL) {
        self.url = url
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class CatalogStreamingWKWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
