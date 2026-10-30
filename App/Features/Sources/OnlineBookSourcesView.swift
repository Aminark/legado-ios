@preconcurrency import WebKit
import SwiftUI
import UIKit

struct OnlineBookSourcesView: View {
    static let yuqueURL = URL(string: "https://www.yuque.com/legado/pd/rp3gdumplxqc3oo2")!
    static let catalogURL = URL(string: "https://gedoor.github.io/blog/book-source-2022-9-2213")!
    static let miaogongziURL = URL(string: "https://yuedu.miaogongzi.net/gx.html")!

    var body: some View {
        List {
            Section {
                catalogLink("⭐ 开源阅读 · 书源站", subtitle: "语雀 · 书源与字体资源", url: Self.yuqueURL)
                catalogLink("喵公子书源", subtitle: "书源合集与在线更新", url: Self.miaogongziURL)
                catalogLink("开源阅读 · 九月书源更新", subtitle: "gedoor.github.io · 2022 年 9 月", url: Self.catalogURL)
            } footer: {
                Text("在网页中点击「一键导入」或「点击此处导入」，即可预览并选择书源。")
            }
        }
        .listStyle(.insetGrouped)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.groupedCanvas)
        .navigationTitle("在线书源")
    }

    private func catalogLink(_ title: String, subtitle: String, url: URL) -> some View {
        NavigationLink {
            OnlineSourceBrowserView(url: url)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } icon: {
                Image(systemName: "globe")
                    .foregroundStyle(ReadingTheme.accent)
            }
        }
    }
}

private struct OnlineSourceBrowserView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @StateObject private var browser: OnlineSourceBrowser

    init(url: URL) {
        _browser = StateObject(wrappedValue: OnlineSourceBrowser(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("上一页", systemImage: "chevron.backward") { browser.webView.goBack() }
                    .disabled(!browser.canGoBack || browser.isImporting)
                Button("下一页", systemImage: "chevron.forward") { browser.webView.goForward() }
                    .disabled(!browser.canGoForward || browser.isImporting)
                Text(browser.webView.url?.host ?? browser.initialURL.host ?? "")
                    .lineLimit(1)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button("重新载入", systemImage: "arrow.clockwise") { browser.reload() }
                    .disabled(browser.isImporting)
            }
            .font(.caption)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if let error = browser.errorMessage {
                ReadingUnavailableView {
                    Label("网页加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重新载入") { browser.reload() }
                        .readingProminentButtonStyle()
                }
            } else {
                OnlineSourceWebView(browser: browser)
                    .allowsHitTesting(!browser.isImporting)
                    .overlay {
                        if browser.isImporting {
                            ProgressView("正在获取书源…")
                                .padding(24)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
            }
        }
        .navigationTitle("阅读书源分享")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            browser.onImport = { url in
                guard !library.isWorking, library.pendingImport == nil else { return }
                await library.handleDeepLink(url)
            }
            browser.start()
        }
    }
}

private struct OnlineSourceWebView: UIViewRepresentable {
    let browser: OnlineSourceBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Void) {
        webView.stopLoading()
    }
}

@MainActor
final class OnlineSourceBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let initialURL: URL
    let webView: WKWebView
    var onImport: ((URL) async -> Void)?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?
    private var hasStarted = false

    init(url: URL) {
        initialURL = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        webView.load(URLRequest(url: initialURL))
    }

    func reload() {
        errorMessage = nil
        if webView.url == nil { webView.load(URLRequest(url: initialURL)) }
        else { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if routeImport(url) { decisionHandler(.cancel); return }
        decisionHandler(isWebURL(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        // The catalog's import links open a new window. Keep both import links
        // and ordinary target="_blank" links inside this browser.
        if !routeImport(url), isWebURL(url) { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "网页暂时无法显示，请重新载入。"
    }

    private func routeImport(_ url: URL) -> Bool {
        guard RuleImportInput.isDeepLink(url) else { return false }
        guard let onImport, !isImporting else { return true }
        isImporting = true
        Task {
            await onImport(url)
            isImporting = false
        }
        return true
    }

    private func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank"
    }

    private func report(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        errorMessage = error.localizedDescription
    }
}
