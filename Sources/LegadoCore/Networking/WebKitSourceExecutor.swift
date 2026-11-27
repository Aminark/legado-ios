#if canImport(WebKit)
import Foundation
@preconcurrency import WebKit

/// Background `WKWebView` request executor living inside `LegadoCore`.
///
/// Key guarantees compared to naive `didFinish` snapshots:
/// - Tracks HTTP status/headers exclusively on the main frame so third-party
///   captcha/ad iframes cannot poison the page status.
/// - Waits through anti-bot challenge pages (202/403/429/503, Cloudflare,
///   Qidian probe, meta-refresh) until the real document commits and settles.
/// - Observes `DOMContentLoaded` and applies a bounded subresource grace
///   period so slow embeds or analytics scripts do not stall an already-parsed page.
/// - Evaluates scripts via callback bridge with `undefined` normalization so
///   `WKError.javaScriptResultTypeIsUnsupported` never aborts a valid script.
public final class WebKitSourceExecutor: NSObject, SourceWebViewRequestExecuting, @unchecked Sendable {
    public override init() {
        super.init()
    }

    @MainActor
    public func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        let settings = ApplicationSettingsStore.shared.settings
        let effectiveTimeout = settings.timeoutSeconds > 0 ? Double(settings.timeoutSeconds) : timeout
        let resolvedUA = WebViewChallengePolicy.resolveUserAgent(
            requestHeaders: prepared.headers,
            applicationDefault: settings.userAgent
        )
        return try await WebKitRequestSession(
            prepared: prepared,
            source: source,
            timeout: effectiveTimeout,
            userAgent: resolvedUA
        ).run()
    }
}

public typealias WKSourceWebViewExecutor = WebKitSourceExecutor

@MainActor
private final class WebKitRequestSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let resourceMessageName = "legadoResource"
    private static let domReadyMessageName = "legadoDOMReady"
    private static let defaultSubresourceGraceSeconds: TimeInterval = 8

    private let prepared: PreparedRequest
    private let source: BookSource
    private let timeout: TimeInterval
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var mainFrameStatus = 200
    private var mainFrameHeaders: [String: String] = [:]
    private var navigationEpoch = 0
    private var completed = false
    private var collectingResponse = false
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var domGraceTask: Task<Void, Never>?
    private var sourcePattern: NSRegularExpression?

    init(prepared: PreparedRequest, source: BookSource, timeout: TimeInterval, userAgent: String) {
        self.prepared = prepared
        self.source = source
        self.timeout = min(max(timeout, 3), 300)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.domReadyObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        if prepared.sourceRegex != nil {
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.resourceObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.customUserAgent = userAgent
        self.webView = view
        super.init()
        view.navigationDelegate = self
    }

    func run() async throws -> HTTPResponse {
        try Task.checkCancellation()
        if let pattern = prepared.sourceRegex {
            sourcePattern = try NSRegularExpression(pattern: pattern)
            webView.configuration.userContentController.add(self, name: Self.resourceMessageName)
        }
        webView.configuration.userContentController.add(self, name: Self.domReadyMessageName)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installRequestCookies { [weak self] in
                    self?.beginLoading()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func beginLoading() {
        guard !completed else { return }
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            guard !Task.isCancelled, !self.completed else { return }
            if let pattern = self.prepared.sourceRegex {
                self.finish(.failure(RuleEngineError.invalidInput(
                    rule: pattern,
                    expected: "WebView 在超时前未找到匹配的可观察资源地址"
                )))
            } else {
                self.finish(.failure(URLError(.timedOut)))
            }
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        navigationEpoch &+= 1
        settleTask?.cancel()
        domGraceTask?.cancel()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        if prepared.webViewHTML == nil, let address = webView.url?.absoluteString {
            observeResource(address)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            mainFrameStatus = response.statusCode
            mainFrameHeaders = response.allHeaderFields.reduce(into: [:]) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        domGraceTask?.cancel()
        scheduleCapture(epoch: navigationEpoch, triggeredByDOMGrace: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        // Ignore superseded navigations caused by challenge/meta/JS redirects.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        finish(.failure(error))
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.resourceMessageName {
            if let address = message.body as? String {
                observeResource(address)
            }
            return
        }
        if message.name == Self.domReadyMessageName {
            armDOMSubresourceGraceTimer(epoch: navigationEpoch)
        }
    }

    private func armDOMSubresourceGraceTimer(epoch: Int) {
        domGraceTask?.cancel()
        let grace = min(Self.defaultSubresourceGraceSeconds, max(timeout * 0.45, 2.5))
        domGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.completed, self.navigationEpoch == epoch else { return }
            self.scheduleCapture(epoch: epoch, triggeredByDOMGrace: true)
        }
    }

    // MARK: - Capture & Challenge Handling

    private func scheduleCapture(epoch: Int, triggeredByDOMGrace: Bool) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !triggeredByDOMGrace {
                    let defaultDelay = prepared.webJavaScript == nil ? 650 : 0
                    let delay = 100 + min(max(prepared.webViewDelayMilliseconds, defaultDelay), 300_000)
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
                guard !Task.isCancelled, !completed, navigationEpoch == epoch else { return }

                // Check whether the current main-frame page is an anti-bot challenge
                // interstitial; if so, stay alive and wait for its JS redirect / DOM swap.
                if await waitIfChallengePage(epoch: epoch) {
                    return
                }
                guard !Task.isCancelled, !completed, navigationEpoch == epoch else { return }

                if sourcePattern != nil {
                    if let script = prepared.webJavaScript, !script.isEmpty {
                        _ = await evaluateScriptSafely(WebViewChallengePolicy.wrappedEvaluationScript(script))
                    }
                    return
                }

                let wrapped = WebViewChallengePolicy.wrappedEvaluationScript(prepared.webJavaScript ?? "")
                for attempt in 0..<24 {
                    try Task.checkCancellation()
                    guard !completed, navigationEpoch == epoch else { return }
                    let outcome = await evaluateScriptSafely(wrapped)
                    if let body = outcome.value {
                        await deliver(body)
                        return
                    }
                    if let scriptError = outcome.error, prepared.webJavaScript?.isEmpty == false {
                        throw scriptError
                    }
                    let waitMs = min(attempt + 1, 5) * 200
                    try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                }
                throw URLError(.timedOut)
            } catch {
                guard !Task.isCancelled else { return }
                finish(.failure(error))
            }
        }
    }

    /// Returns `true` when the page is still a challenge interstitial and we have
    /// yielded control to wait for a navigation or in-place challenge resolution.
    private func waitIfChallengePage(epoch: Int) async -> Bool {
        let title = (await evaluateScriptSafely("document.title || ''")).value ?? ""
        let html = (await evaluateScriptSafely("document.documentElement ? document.documentElement.outerHTML : ''")).value ?? ""
        guard WebViewChallengePolicy.looksLikeChallengeDocument(
            statusCode: mainFrameStatus,
            title: title,
            html: html
        ) else {
            return false
        }
        // Poll gently in case the challenge updates the DOM without triggering a
        // full provisional navigation; a full navigation will cancel this task.
        for _ in 0..<18 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, !completed, navigationEpoch == epoch else { return true }
            let nextTitle = (await evaluateScriptSafely("document.title || ''")).value ?? ""
            let nextHTML = (await evaluateScriptSafely("document.documentElement ? document.documentElement.outerHTML : ''")).value ?? ""
            let cleared = !WebViewChallengePolicy.looksLikeChallengeDocument(
                statusCode: 200,
                title: nextTitle,
                html: nextHTML
            )
            if cleared && !WebViewChallengePolicy.isChallengeStatus(mainFrameStatus) {
                return false
            }
        }
        return true
    }

    private func evaluateScriptSafely(_ script: String) async -> (value: String?, error: Error?) {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == WKError.errorDomain,
                       nsError.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                        continuation.resume(returning: (nil, nil))
                        return
                    }
                    continuation.resume(returning: (nil, error))
                    return
                }
                guard let result, !(result is NSNull) else {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                if let string = result as? String {
                    continuation.resume(returning: (string, nil))
                } else if JSONSerialization.isValidJSONObject(result),
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    continuation.resume(returning: (String(decoding: data, as: UTF8.self), nil))
                } else {
                    continuation.resume(returning: (String(describing: result), nil))
                }
            }
        }
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
        let cookies = await allWebViewCookies()
        guard !completed else { return }
        let targetURL = webView.url ?? prepared.url
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        var headers = mainFrameHeaders
        if source.enabledCookieJar == true, !cookieHeader.isEmpty {
            await SourceNetworkPolicy.shared.setCookieHeader(cookieHeader, sourceID: source.id, url: targetURL)
            LegadoCookieStore.shared.setCookie(cookieHeader, for: targetURL.absoluteString)
            headers["Set-Cookie"] = cookieHeader
        }
        finish(.success(HTTPResponse(
            data: Data(body.utf8),
            statusCode: mainFrameStatus,
            headers: headers,
            finalURL: targetURL,
            requestedCharset: "utf-8"
        )))
    }

    private func allWebViewCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        domGraceTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.domReadyMessageName)
        if sourcePattern != nil {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.resourceMessageName)
        }
        webView.navigationDelegate = nil
        webView.stopLoading()
        continuation?.resume(with: result)
        continuation = nil
    }

    private static let domReadyObserverScript = #"""
    (() => {
        const notify = () => {
            try { window.webkit.messageHandlers.legadoDOMReady.postMessage(document.readyState); } catch (_) {}
        };
        if (document.readyState === 'interactive' || document.readyState === 'complete') {
            notify();
        } else {
            document.addEventListener('DOMContentLoaded', notify, { once: true });
        }
    })();
    """#

    private static let resourceObserverScript = #"""
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
}
#endif
