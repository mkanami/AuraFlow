import SwiftUI
import WebKit

struct CatalogStreamingVideoPreview: NSViewRepresentable {
    let url: URL
    let referer: URL?
    let onStarted: () -> Void
    let onFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.document(for: url), baseURL: referer)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        context.coordinator.hasReportedStart = false
        context.coordinator.hasReportedFailure = false
        webView.loadHTMLString(Self.document(for: url), baseURL: referer)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
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
          <video id="preview" src=\(encodedURL) autoplay muted loop playsinline preload="auto"></video>
          <script>
            const video = document.getElementById('preview');
            let started = false;
            let failed = false;
            const send = (value) => window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(value);
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
            video.play().catch(() => setTimeout(() => video.play().catch(reportFailed), 120));
          </script>
        </body>
        </html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let result = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "auraCatalogPreview"

        var parent: CatalogStreamingVideoPreview
        var loadedURL: URL?
        var hasReportedStart = false
        var hasReportedFailure = false

        init(parent: CatalogStreamingVideoPreview) {
            self.parent = parent
            self.loadedURL = parent.url
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName,
                  let value = message.body as? String else {
                return
            }
            switch value {
            case "started" where !hasReportedStart:
                hasReportedStart = true
                parent.onStarted()
            case "failed" where !hasReportedFailure:
                hasReportedFailure = true
                parent.onFailed()
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailureIfNeeded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailureIfNeeded()
        }

        private func reportFailureIfNeeded() {
            guard !hasReportedFailure, !hasReportedStart else { return }
            hasReportedFailure = true
            parent.onFailed()
        }
    }
}
