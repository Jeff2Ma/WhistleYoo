import AppKit
import SwiftUI
import WebKit
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class WhistleConsoleSession: NSObject, ObservableObject, WKNavigationDelegate {
    enum Workspace: String, Hashable {
        case network
        case plugins

        var loadingMessageKey: LocalizationKey {
            switch self {
            case .network: return .consoleLoadingTheWhistleConsole
            case .plugins: return .pluginsLoadingWhistlePlugins
            }
        }

        var failureMessageKey: LocalizationKey {
            switch self {
            case .network: return .consoleFailedToLoadTheWhistleConsole
            case .plugins: return .pluginsFailedToLoadWhistlePlugins
            }
        }

        var engineUnavailableMessageKey: LocalizationKey {
            switch self {
            case .network: return .settingsStartTheProxyEngineToUseTheWhistleConsole
            case .plugins: return .pluginsStartTheProxyEngineToUseWhistlePlugins
            }
        }
    }

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .loading
    private(set) var baseURL: URL?
    private(set) var workspace: Workspace = .network
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

    /// Starts the selected workspace as soon as Whistle becomes ready. The same
    /// WKWebView is later mounted in the visible tab so its live session and
    /// accumulated requests are preserved when switching workspaces.
    func loadForEngineStart(baseURL: URL) {
        load(baseURL: baseURL, workspace: workspace)
    }

    func ensureLoaded(baseURL: URL, workspace: Workspace) {
        let baseURLChanged = self.baseURL != baseURL
        self.baseURL = baseURL
        self.workspace = workspace
        guard baseURLChanged || !isShowing(workspace: workspace, at: baseURL) else { return }
        if !baseURLChanged, canNavigateWithinDocument(at: baseURL) {
            navigateWithinDocument(to: workspace)
        } else {
            load(baseURL: baseURL, workspace: workspace)
        }
    }

    func reload() {
        guard let baseURL else { return }
        load(baseURL: baseURL, workspace: workspace)
    }

    func pageURL(for baseURL: URL, workspace: Workspace) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.fragment = workspace.rawValue
        return components?.url ?? baseURL
    }

    private func load(baseURL: URL, workspace: Workspace) {
        self.baseURL = baseURL
        self.workspace = workspace
        loadState = .loading
        webView.load(URLRequest(url: pageURL(for: baseURL, workspace: workspace)))
    }

    private func isShowing(workspace: Workspace, at baseURL: URL) -> Bool {
        guard let currentURL = webView.url,
              currentURL.host == baseURL.host,
              currentURL.port == baseURL.port,
              let fragment = currentURL.fragment else { return false }
        return fragment == workspace.rawValue
            || fragment.hasPrefix("\(workspace.rawValue)?")
    }

    private func canNavigateWithinDocument(at baseURL: URL) -> Bool {
        guard let currentURL = webView.url else { return false }
        return currentURL.scheme == baseURL.scheme
            && currentURL.host == baseURL.host
            && currentURL.port == baseURL.port
    }

    private func navigateWithinDocument(to workspace: Workspace) {
        loadState = .loading
        webView.evaluateJavaScript("window.location.hash = '#\(workspace.rawValue)'") {
            [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.loadState = .failed(error.localizedDescription)
                } else {
                    self.loadState = .ready
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadState = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadState = .ready
    }

    func webView(_ webView: WKWebView, didSameDocumentNavigation navigation: WKNavigation!) {
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

struct WhistleWorkspaceView: View {
    @ObservedObject var session: WhistleConsoleSession
    let baseURL: URL
    let workspace: WhistleConsoleSession.Workspace

    var body: some View {
        ZStack {
            WhistleWebViewRepresentable(session: session)

            switch session.loadState {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(Localization.string(workspace.loadingMessageKey))
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
                    Text(Localization.string(workspace.failureMessageKey))
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
                            NSWorkspace.shared.open(
                                session.pageURL(for: baseURL, workspace: workspace)
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            session.ensureLoaded(baseURL: baseURL, workspace: workspace)
        }
        .onChange(of: baseURL) { newURL in
            session.ensureLoaded(baseURL: newURL, workspace: workspace)
        }
        .onChange(of: workspace) { newWorkspace in
            session.ensureLoaded(baseURL: baseURL, workspace: newWorkspace)
        }
    }
}

private struct WhistleWebViewRepresentable: NSViewRepresentable {
    let session: WhistleConsoleSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
