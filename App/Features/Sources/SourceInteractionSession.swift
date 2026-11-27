import SwiftUI
@preconcurrency import WebKit

extension Notification.Name {
    static let sourceLoginUpdated = Notification.Name("Legado.sourceLoginUpdated")
}

enum SourceBrowserCookies {
    static func store(_ cookies: [HTTPCookie], for origin: URL) {
        guard let host = origin.host?.lowercased() else { return }
        for cookie in cookies {
            let domain = cookie.domain.lowercased()
            let matches = domain == host || (domain.hasPrefix(".") &&
                (String(domain.dropFirst()) == host || host.hasSuffix(domain)))
            if matches { HTTPCookieStorage.shared.setCookie(cookie) }
        }
    }
}

/// A synchronous script can wait on its own worker. The view completes this
/// ticket on dismissal, including cancellation when its owning reader closes.
private final class BrowserTicket: @unchecked Sendable {
    private let condition = NSCondition()
    private var reply: [String: String]?

    func finish(_ value: [String: String]) {
        condition.lock()
        defer { condition.unlock() }
        guard reply == nil else { return }
        reply = value
        condition.broadcast()
    }

    func result() -> [String: String] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 300)
        while reply == nil {
            if !condition.wait(until: deadline) { break }
        }
        return reply ?? [:]
    }
}

@MainActor
final class SourceInteractionSession: ObservableObject, SourceScriptInteraction {
    fileprivate struct Page: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let source: BookSource
    }
    @Published fileprivate var page: Page?
    @Published var message: String?
    fileprivate var source: BookSource?
    private var ticket: BrowserTicket?
    private var pageResult: [String: String] = [:]

    var isPresenting: Bool { page != nil || message != nil }

    var evaluator: JavaScriptRuleEvaluator {
        var evaluator = JavaScriptRuleEvaluator()
        evaluator.interaction = self
        return evaluator
    }

    nonisolated func browse(_ address: String, title: String, waitsForDismissal: Bool) -> [String: String] {
        guard !Thread.isMainThread else { return [:] }
        let request = BrowserTicket()
        Task { @MainActor in
            guard ticket == nil, let source,
                  let url = Self.destination(address, relativeTo: source.bookSourceUrl) else {
                request.finish([:])
                return
            }
            ticket = request
            page = Page(url: url, title: title, source: source)
        }
        return waitsForDismissal ? request.result() : [:]
    }

    private static func destination(_ address: String, relativeTo source: String) -> URL? {
        if address.prefix(15).lowercased().hasPrefix("data:text/html"), let comma = address.firstIndex(of: ",") {
            let meta = address[..<comma].lowercased()
            let body = String(address[address.index(after: comma)...])
            let data = meta.contains(";base64") ? Data(base64Encoded: body, options: .ignoreUnknownCharacters)
                                                : Data((body.removingPercentEncoding ?? body).utf8)
            return data.flatMap { URL(string: "data:text/html;base64," + $0.base64EncodedString()) }
        }
        guard let url = URL(string: address, relativeTo: URL(string: source))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    nonisolated func refreshDiscovery() {
        Task { @MainActor in
            guard let source else { return }
            NotificationCenter.default.post(name: .sourceLoginUpdated, object: source.id)
        }
    }

    nonisolated func showMessage(_ message: String) {
        Task { @MainActor in self.message = message }
    }

    fileprivate func accept(_ result: [String: String], from id: UUID) {
        guard page?.id == id else { return }
        pageResult = result
        page = nil
    }

    fileprivate func close() {
        let completed = ticket
        ticket = nil
        completed?.finish(pageResult)
        pageResult = [:]
        page = nil
    }
}

extension View {
    func sourceInteraction(_ session: SourceInteractionSession, source: BookSource) -> some View {
        modifier(SourceInteractionPresentation(session: session, source: source))
    }
}

private struct SourceInteractionPresentation: ViewModifier {
    @ObservedObject var session: SourceInteractionSession
    let source: BookSource

    func body(content: Content) -> some View {
        content
            .onAppear { session.source = source }
            .onChange(of: source.id) { _ in session.close(); session.source = source }
            .onDisappear { session.source = nil; session.close() }
            .sheet(item: $session.page, onDismiss: session.close) { page in
                ScriptBrowser(page: page) { session.accept($0, from: page.id) }
                    .readingPresentationDetents([.medium, .large])
            }
            .alert("书源提示", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
                Button("好") { session.message = nil }
            } message: { Text(session.message ?? "") }
    }
}

private struct ScriptBrowser: UIViewControllerRepresentable {
    let page: SourceInteractionSession.Page
    let close: ([String: String]) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = BrowserController(page: page, close: close)
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class BrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
        private let page: SourceInteractionSession.Page
        private let close: ([String: String]) -> Void
        private let browser: WKWebView
        private var response: HTTPURLResponse?

        init(page: SourceInteractionSession.Page, close: @escaping ([String: String]) -> Void) {
            self.page = page
            self.close = close
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            browser = WKWebView(frame: .zero, configuration: config)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func loadView() { view = browser }
        override func viewDidLoad() {
            super.viewDidLoad()
            title = page.title
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                                action: #selector(done))
            browser.isOpaque = false
            browser.backgroundColor = ReadingTheme.canvasColor
            browser.scrollView.backgroundColor = ReadingTheme.canvasColor
            browser.navigationDelegate = self
            browser.uiDelegate = self
            Task {
                if page.source.enabledCookieJar != false {
                    for cookie in HTTPCookieStorage.shared.cookies(for: page.url) ?? [] {
                        await browser.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                }
                browser.load(URLRequest(url: page.url))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame { response = navigationResponse.response as? HTTPURLResponse }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            navigationItem.prompt = error.localizedDescription
            response = nil
        }

        @objc private func done() {
            navigationItem.rightBarButtonItem?.isEnabled = false
            Task {
                let body = (try? await browser.evaluateJavaScript("document.documentElement.outerHTML")) as? String
                if page.source.enabledCookieJar != false, let origin = URL(string: page.source.bookSourceUrl) {
                    let jar = browser.configuration.websiteDataStore.httpCookieStore
                    let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                        jar.getAllCookies { continuation.resume(returning: $0) }
                    }
                    SourceBrowserCookies.store(cookies, for: origin)
                    let scoped = HTTPCookieStorage.shared.cookies(for: origin) ?? []
                    await SourceNetworkPolicy.shared.setCookieHeader(HTTPCookie.requestHeaderFields(with: scoped)["Cookie"] ?? "",
                                                                     sourceID: page.source.id, url: origin)
                }
                let headers = response?.allHeaderFields as? [String: String] ?? [:]
                let encoded = (try? JSONEncoder().encode(headers)) ?? Data()
                close(["body": body ?? "", "url": browser.url?.absoluteString ?? "",
                                    "status": String(response?.statusCode ?? (browser.url?.scheme == "data" ? 200 : 0)),
                                    "headers": String(decoding: encoded, as: UTF8.self)])
            }
        }
    }
}
