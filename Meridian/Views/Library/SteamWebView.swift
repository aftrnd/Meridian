import SwiftUI
import WebKit

struct SteamWebView: View {
    let url: URL

    @State private var isLoading = true
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var webViewStore = WebViewStore()

    var body: some View {
        WebViewRepresentable(
            url: url,
            store: webViewStore,
            isLoading: $isLoading,
            canGoBack: $canGoBack,
            canGoForward: $canGoForward
        )
        // Same corner radius as the library's cards.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if canGoBack {
                Button { webViewStore.webView?.goBack() } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Back")
            }
        }
        // The library grid's one margin all round, measured from the window
        // edges top and bottom so the page runs up under the toolbar.
        .padding(CardLayoutMetrics.spacing)
        .ignoresSafeArea(edges: [.top, .bottom])
    }
}

/// Holds a reference to the live WKWebView so SwiftUI views can call goBack/goForward.
@MainActor
final class WebViewStore {
    var webView: WKWebView?
}

private struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    let store: WebViewStore
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let hideScrollbars = WKUserScript(
            source: "document.addEventListener('DOMContentLoaded', function() { var s = document.createElement('style'); s.textContent = '::-webkit-scrollbar { display: none !important; } html, body { scrollbar-width: none !important; }'; document.head.appendChild(s); });",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(hideScrollbars)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        store.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable

        init(parent: WebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = true
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated,
               let host = url.host,
               !host.contains("steampowered.com"),
               !host.contains("steamcommunity.com"),
               !host.contains("steamstatic.com") {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
