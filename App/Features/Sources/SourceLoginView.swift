import SafariServices
@preconcurrency import WebKit
import SwiftUI
import UIKit

struct ReadingWebBrowser: UIViewControllerRepresentable {
    let url: URL
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { close() }
    }
}

struct SourceLoginView: View {
    let source: BookSource
    @State private var reloadID = UUID()
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false

    @ViewBuilder var body: some View {
        if source.loginUi?.isEmpty == false || source.loginScript != nil {
            SourceCredentialsForm(source: source) { _ in
                NotificationCenter.default.post(name: .sourceLoginUpdated, object: source.id)
            }
        } else {
            webLogin.onDisappear {
                NotificationCenter.default.post(name: .sourceLoginUpdated, object: source.id)
            }
        }
    }

    private var webLogin: some View {
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
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if let explicitUA = request.value(forHTTPHeaderField: "User-Agent"), !explicitUA.isEmpty {
            webView.customUserAgent = explicitUA
        }
        webView.isOpaque = false
        webView.backgroundColor = ReadingTheme.canvasColor
        webView.scrollView.backgroundColor = ReadingTheme.canvasColor
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
                guard let url = URL(string: self.parent.sourceURL) else { return }
                SourceBrowserCookies.store(cookies, for: url)
                let matching = HTTPCookieStorage.shared.cookies(for: url) ?? []
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                Task {
                    await SourceNetworkPolicy.shared.setCookieHeader(
                        header,
                        sourceID: self.parent.sourceID,
                        url: url
                    )
                    if !header.isEmpty {
                        LegadoCookieStore.shared.setCookie(header, for: url.absoluteString)
                    }
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
