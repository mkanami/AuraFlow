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
        var lastAccess = Date()

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

        func prewarm() {
            lastAccess = Date()
            webView.evaluateJavaScript("document.getElementById('preview')?.load()")
        }

        func play() {
            lastAccess = Date()
            webView.evaluateJavaScript("document.getElementById('preview')?.play()")
        }

        func stop() {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: MessageHandler.messageName
            )
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
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
                const send = (value) => window.webkit.messageHandlers.\(MessageHandler.messageName).postMessage(value);
                const reportStarted = () => {
                  if (started || video.currentTime <= 0.03 || video.readyState < 2) return;
                  started = true;
                  requestAnimationFrame(() => requestAnimationFrame(() => send('started')));
                };
                const reportFailed = () => {
                  if (failed || started) return;
                  failed = true;
                  send('failed');
                };
                video.addEventListener('playing', reportStarted);
                video.addEventListener('timeupdate', reportStarted);
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
        var onStarted: (() -> Void)?
        var onFailed: (() -> Void)?

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
    private let maximumSessionCount = 8

    func prewarm(url: URL, referer: URL?, prioritize: Bool) {
        if sessions[url] == nil,
           sessions.count >= maximumSessionCount,
           !prioritize {
            return
        }
        session(for: url, referer: referer).prewarm()
        pruneIfNeeded(keeping: url)
    }

    func attach(
        url: URL,
        referer: URL?,
        to hostView: CatalogStreamingVideoHostView,
        onStarted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        let session = session(for: url, referer: referer)
        session.messageHandler.onStarted = onStarted
        session.messageHandler.onFailed = onFailed

        if session.webView.superview !== hostView {
            session.webView.removeFromSuperview()
            hostView.install(session.webView, url: url)
        }
        session.play()

        session.messageHandler.deliverCurrentState()
        pruneIfNeeded(keeping: url)
    }

    func detach(from hostView: CatalogStreamingVideoHostView) {
        guard let url = hostView.url,
              let session = sessions[url],
              session.webView.superview === hostView else {
            return
        }
        session.messageHandler.onStarted = nil
        session.messageHandler.onFailed = nil
        session.webView.removeFromSuperview()
        hostView.url = nil
        session.webView.evaluateJavaScript("document.getElementById('preview')?.pause()")
    }

    private func session(for url: URL, referer: URL?) -> Session {
        if let existing = sessions[url] {
            existing.lastAccess = Date()
            return existing
        }
        let session = Session(url: url, referer: referer)
        sessions[url] = session
        return session
    }

    private func pruneIfNeeded(keeping protectedURL: URL) {
        guard sessions.count > maximumSessionCount else { return }
        let removable = sessions.values
            .filter { $0.url != protectedURL && $0.webView.superview == nil }
            .sorted { $0.lastAccess < $1.lastAccess }
        for session in removable where sessions.count > maximumSessionCount {
            sessions[session.url] = nil
            session.stop()
        }
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
