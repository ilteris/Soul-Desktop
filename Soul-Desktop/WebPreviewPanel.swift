import AppKit
import SwiftUI
import WebKit

private struct OpenWebPreviewKey: EnvironmentKey {
    static let defaultValue: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
}

extension EnvironmentValues {
    var openWebPreview: (URL) -> Void {
        get { self[OpenWebPreviewKey.self] }
        set { self[OpenWebPreviewKey.self] = newValue }
    }
}

enum WebPreviewRouting {
    static func shouldOpenInSoul(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return false }
        if shouldOpenInSoul(url) { return false }
        if scheme == "about" || scheme == "data" || scheme == "blob" { return false }
        return true
    }
}

struct WebPreviewPanel: View {
    enum Source: Equatable {
        case file(URL)
        case web(URL)

        var externalURL: URL {
            switch self {
            case .file(let url), .web(let url): return url
            }
        }
    }

    let source: Source

    var body: some View {
        WebPreviewRepresentable(source: source)
            .background(Color.white)
    }
}

private struct WebPreviewRepresentable: NSViewRepresentable {
    let source: WebPreviewPanel.Source

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentSource != source else { return }
        context.coordinator.currentSource = source
        switch source {
        case .file(let url):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case .web(let url):
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentSource: WebPreviewPanel.Source?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if WebPreviewRouting.isExternal(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
