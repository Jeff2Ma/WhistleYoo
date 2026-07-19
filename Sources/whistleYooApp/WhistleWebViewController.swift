import AppKit
import SwiftUI
import WebKit
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class WhistleConsoleSession: NSObject, ObservableObject, WKNavigationDelegate {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .loading
    private(set) var baseURL: URL?
    let webView: WKWebView

    private static let customCSS = """
    /* Keep Whistle in its main workspace and hide the alternate left navigation. */
    .w-switch-layout,
    .w-left-menu {
        display: none !important;
    }
    """

    private static var customStyleUserScript: WKUserScript {
        let escapedCSS = customCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        let source = """
        (() => {
            const styleID = 'whistleyoo-custom-style';
            if (document.getElementById(styleID)) {
                return;
            }
            const style = document.createElement('style');
            style.id = styleID;
            style.textContent = `\(escapedCSS)`;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(Self.customStyleUserScript)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Starts the Network workspace as soon as Whistle becomes ready. The same
    /// WKWebView is later mounted in the visible console so its live session and
    /// accumulated requests are preserved.
    func loadForEngineStart(baseURL: URL) {
        self.baseURL = baseURL
        loadState = .loading
        webView.load(URLRequest(url: networkURL(for: baseURL)))
    }

    func ensureLoaded(baseURL: URL) {
        guard self.baseURL != baseURL || webView.url == nil else { return }
        loadForEngineStart(baseURL: baseURL)
    }

    func reload() {
        guard let baseURL else { return }
        loadForEngineStart(baseURL: baseURL)
    }

    private func networkURL(for baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.fragment = "network"
        return components?.url ?? baseURL
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadState = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadState = .ready
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        loadState = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadState = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.host == baseURL?.host && url.port == baseURL?.port {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

struct WhistleConsoleView: View {
    @ObservedObject var session: WhistleConsoleSession
    let baseURL: URL

    var body: some View {
        ZStack {
            WhistleWebView(session: session)

            switch session.loadState {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(Localization.string(.consoleLoadingTheWhistleConsole))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            case .ready:
                EmptyView()
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(Localization.string(.consoleFailedToLoadTheWhistleConsole))
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 420)
                    HStack(spacing: 10) {
                        Button(Localization.string(.consoleReload)) {
                            session.reload()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(Localization.string(.consoleOpenInBrowser)) {
                            NSWorkspace.shared.open(baseURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            session.ensureLoaded(baseURL: baseURL)
        }
        .onChange(of: baseURL) { newURL in
            session.ensureLoaded(baseURL: newURL)
        }
    }
}

private struct WhistleWebView: NSViewRepresentable {
    let session: WhistleConsoleSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
