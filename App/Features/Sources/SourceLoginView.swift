@preconcurrency import WebKit
import SwiftUI
import UIKit

struct SourceLoginView: View {
    let source: BookSource
    @State private var reloadID = UUID()
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(ReadingTheme.accent)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if let request = loginRequest {
                SourceLoginWebView(
                    request: request,
                    sourceURL: source.bookSourceUrl,
                    sourceID: source.id,
                    loginCheckJavaScript: source.loginCheckJs,
                    reloadID: reloadID,
                    status: $status,
                    isChecking: $isChecking
                )
            } else {
                ReadingUnavailableView("登录地址无效", systemImage: "link.badge.plus", description: Text(source.loginUrl ?? "书源没有配置登录地址"))
            }
        }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新载入", systemImage: "arrow.clockwise") { reloadID = UUID() }
            }
        }
    }

    private var loginRequest: URLRequest? {
        guard let value = source.loginUrl,
              let prepared = try? LegadoURLBuilder().prepare(
                value,
                baseURL: URL(string: source.bookSourceUrl),
                defaultHeaders: sourceHeaders
              ) else { return nil }
        return prepared.urlRequest(handleCookies: source.enabledCookieJar ?? true)
    }

    private var sourceHeaders: [String: String] {
        guard let value = source.header,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let request: URLRequest
    let sourceURL: String
    let sourceID: String
    let loginCheckJavaScript: String?
    let reloadID: UUID
    @Binding var status: String
    @Binding var isChecking: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.navigationDelegate = context.coordinator
        context.coordinator.installExistingCookies(in: webView) { webView.load(request) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadID != reloadID else { return }
        context.coordinator.lastReloadID = reloadID
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SourceLoginWebView
        var lastReloadID: UUID

        init(parent: SourceLoginWebView) {
            self.parent = parent
            lastReloadID = parent.reloadID
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.status = "正在打开登录页…"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            syncCookies(from: webView)
            guard let script = parent.loginCheckJavaScript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !script.isEmpty else {
                parent.status = "页面已载入；登录后 Cookie 会自动同步。"
                return
            }
            parent.isChecking = true
            webView.evaluateJavaScript(script) { [weak self] value, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.parent.isChecking = false
                    if let error {
                        self.parent.status = "登录检测脚本失败：\(error.localizedDescription)"
                    } else {
                        self.parent.status = Self.truthy(value) ? "书源登录检测已通过" : "页面已载入，尚未检测到登录状态"
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func installExistingCookies(in webView: WKWebView, completion: @escaping () -> Void) {
            guard let url = URL(string: parent.sourceURL) else {
                completion()
                return
            }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            guard !cookies.isEmpty else {
                completion()
                return
            }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }

        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                guard let url = URL(string: self.parent.sourceURL) else { return }
                let matching = HTTPCookieStorage.shared.cookies(for: url) ?? []
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                Task {
                    await SourceNetworkPolicy.shared.setCookieHeader(
                        header,
                        sourceID: self.parent.sourceID,
                        url: url
                    )
                }
            }
        }

        private static func truthy(_ value: Any?) -> Bool {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            guard let text = value.map(String.init(describing:))?.lowercased() else { return false }
            return !text.isEmpty && !["false", "0", "null", "undefined"].contains(text)
        }
    }
}

final class WKSourceWebViewExecutor: NSObject, SourceWebViewRequestExecuting, @unchecked Sendable {
    @MainActor
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        let override = ApplicationSettingsStore.shared.settings.timeoutSeconds
        return try await BackgroundWebViewRequest(prepared: prepared, source: source, timeout: override > 0 ? Double(override) : timeout).run()
    }
}

@MainActor
private final class BackgroundWebViewRequest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let prepared: PreparedRequest
    private let source: BookSource
    private let timeout: TimeInterval
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var responseStatus = 200
    private var responseHeaders: [String: String] = [:]
    private var completed = false
    private var timeoutTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var sourcePattern: NSRegularExpression?
    private var collectingResponse = false

    init(prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) {
        self.prepared = prepared
        self.source = source
        self.timeout = timeout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = prepared.headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        super.init()
        webView.navigationDelegate = self
        if prepared.sourceRegex != nil {
            configuration.userContentController.addUserScript(.init(source: Self.resourceObserver,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func run() async throws -> HTTPResponse {
        try Task.checkCancellation()
        if let pattern = prepared.sourceRegex { sourcePattern = try NSRegularExpression(pattern: pattern) }
        if sourcePattern != nil { webView.configuration.userContentController.add(self, name: "legadoResource") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installRequestCookies { [weak self] in self?.startLoading() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func startLoading() {
        guard !completed else { return }
        timeoutTask = Task { [weak self] in
            let seconds = min(max(self?.timeout ?? 30, 1), 300)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let error: Error
            if let pattern = prepared.sourceRegex {
                error = RuleEngineError.invalidInput(rule: pattern, expected: "WebView 在超时前未找到匹配的可观察资源地址")
            } else { error = URLError(.timedOut) }
            finish(.failure(error))
        }
        if let html = prepared.webViewHTML {
            webView.loadHTMLString(html, baseURL: prepared.url)
        } else {
            webView.load(prepared.urlRequest(timeout: timeout, handleCookies: true))
        }
    }

    private func installRequestCookies(completion: @escaping () -> Void) {
        guard let header = prepared.headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value,
              let host = prepared.url.host, !header.isEmpty else {
            completion()
            return
        }
        let cookies = header.split(separator: ";").compactMap { part -> HTTPCookie? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return HTTPCookie(properties: [
                .name: pair[0].trimmingCharacters(in: .whitespaces),
                .value: pair[1],
                .domain: host,
                .path: "/",
                .secure: prepared.url.scheme == "https" ? "TRUE" : "FALSE"
            ])
        }
        guard !cookies.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            responseStatus = response.statusCode
            responseHeaders = response.allHeaderFields.reduce(into: [:]) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let defaultDelay = prepared.webJavaScript == nil ? 900 : 0
                let delay = 100 + min(max(prepared.webViewDelayMilliseconds, defaultDelay), 300_000)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !completed else { return }
                if sourcePattern != nil {
                    // Resource sniffing has priority over script output; the
                    // script may start a media/fetch request after load.
                    if let script = prepared.webJavaScript, !script.isEmpty {
                        _ = try await webView.evaluateJavaScript(script)
                    }
                    return
                }
                let script = prepared.webJavaScript.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "document.documentElement.outerHTML"
                for attempt in 0...31 {
                    try Task.checkCancellation()
                    guard !completed else { return }
                    let value = try await webView.evaluateJavaScript(script)
                    if let value, !(value is NSNull) {
                        let body: String
                        if let string = value as? String { body = string }
                        else {
                            body = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
                        }
                        await deliver(body)
                        return
                    }
                    guard attempt < 31 else { throw URLError(.timedOut) }
                    try await Task.sleep(nanoseconds: UInt64(min(attempt + 1, 5) * 200) * 1_000_000)
                }
            } catch {
                guard !Task.isCancelled else { return }
                finish(.failure(error))
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        observeResource(address)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        if prepared.webViewHTML == nil, let address = webView.url?.absoluteString { observeResource(address) }
    }

    private func observeResource(_ address: String) {
        guard !completed, !collectingResponse, let pattern = sourcePattern else { return }
        let range = NSRange(address.startIndex..., in: address)
        guard pattern.firstMatch(in: address, range: range)?.range == range else { return }
        collectingResponse = true
        Task { [weak self] in await self?.deliver(address) }
    }

    private func deliver(_ body: String) async {
        guard !completed else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard !completed else { return }
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        var headers = responseHeaders
        if source.enabledCookieJar == true, !cookieHeader.isEmpty {
            await SourceNetworkPolicy.shared.setCookieHeader(cookieHeader, sourceID: source.id, url: prepared.url)
            headers["Set-Cookie"] = cookieHeader
        }
        finish(.success(.init(data: Data(body.utf8), statusCode: responseStatus, headers: headers,
                              finalURL: webView.url ?? prepared.url, requestedCharset: "utf-8")))
    }

    // Public WK APIs do not expose every network request. Observe browser
    // resource timing, dispatched fetch/XHR, and media load events, including
    // frames. Native HLS segments, service-worker internals and DRM traffic
    // cannot be promised; a missing match fails explicitly at the deadline.
    private static let resourceObserver = #"""
    (() => {
        const send = value => {
            try { if (value) window.webkit.messageHandlers.legadoResource.postMessage(new URL(String(value), document.baseURI).href); } catch (_) {}
        };
        try {
            new PerformanceObserver(list => list.getEntries().forEach(entry => send(entry.name))).observe({type:'resource', buffered:true});
        } catch (_) {}
        const originalFetch = window.fetch;
        if (originalFetch) window.fetch = function(input, init) {
            const result = originalFetch.apply(this, arguments);
            send(typeof input === 'string' || input instanceof URL ? input : input.url);
            return result;
        };
        const open = XMLHttpRequest.prototype.open, transmit = XMLHttpRequest.prototype.send;
        const addresses = new WeakMap();
        XMLHttpRequest.prototype.open = function(method, url) { const result = open.apply(this, arguments); addresses.set(this, url); return result; };
        XMLHttpRequest.prototype.send = function() { const result = transmit.apply(this, arguments); send(addresses.get(this)); return result; };
        document.addEventListener('loadstart', event => {
            if (event.target instanceof HTMLMediaElement) send(event.target.currentSrc || event.target.src);
        }, true);
        window.addEventListener('load', () => performance.getEntriesByType('resource').forEach(entry => send(entry.name)));
    })();
    """#

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        evaluationTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "legadoResource")
        webView.navigationDelegate = nil
        webView.stopLoading()
        continuation?.resume(with: result)
        continuation = nil
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
