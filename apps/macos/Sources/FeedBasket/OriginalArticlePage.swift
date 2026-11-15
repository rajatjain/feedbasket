import SwiftUI
import WebKit

struct ArticleReaderPresentation {
    enum Mode: Equatable {
        case reader, original
    }

    let mode: Mode
    let canSwitch: Bool

    init(hasReader: Bool, status: String, backendOnline: Bool, loadFinished: Bool,
         hasOriginal: Bool, preference: Mode) {
        let waitingForReader = backendOnline && (status == "pending" || (status == "ready" && !loadFinished))
        let readerUnavailable = !hasReader && !waitingForReader
        canSwitch = hasOriginal && !readerUnavailable
        mode = hasOriginal && (readerUnavailable || preference == .original) ? .original : .reader
    }
}

struct OriginalArticlePage: View {
    @Environment(\.basketStyle) private var style
    let url: URL
    @BasketState private var failed = false
    @BasketState private var attempt = 0

    var body: some View {
        OriginalArticleWebView(url: url, setFailed: { failed = $0 })
            .id(attempt)
            .opacity(failed ? 0 : 1)
            .accessibilityHidden(failed)
            .overlay {
                if failed {
                    VStack(spacing: BasketTokens.spacing) {
                        Text("Couldn’t load the original page.")
                        Button("Reload Page") {
                            failed = false
                            attempt += 1
                        }
                        .buttonStyle(BasketButton())
                    }
                    .foregroundStyle(style.color(BasketTokens.text))
                }
            }
    }

    static func webURL(_ url: URL?) -> URL? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return url
    }
}

private struct OriginalArticleWebView: NSViewRepresentable {
    let url: URL
    let setFailed: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.setFailed = setFailed
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.setFailed = setFailed
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var setFailed: ((Bool) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.targetFrame?.isMainFrame == false { return .allow }
            guard action.targetFrame != nil, !action.shouldPerformDownload,
                  OriginalArticlePage.webURL(action.request.url) != nil else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            setFailed?(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            setFailed?(true)
        }

        private func showFailure(_ error: Error) {
            let failure = error as NSError
            if failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled {
                setFailed?(true)
            }
        }
    }
}
