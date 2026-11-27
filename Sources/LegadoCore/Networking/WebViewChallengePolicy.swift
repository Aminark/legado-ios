import Foundation

/// Pure-Swift decision logic governing background WebView request execution:
/// challenge detection (Cloudflare, Qidian WAF, meta-refresh), User-Agent
/// fallback, and script result normalization. Separated from WebKit so every
/// edge case is directly unit-tested without spinning up a browser.
public enum WebViewChallengePolicy {
    public static let defaultBrowserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    /// HTTP status codes commonly returned by anti-bot challenge interstitials
    /// (Cloudflare, Qidian probe, JS WAF gates) before redirecting to the real page.
    public static let challengeStatusCodes: Set<Int> = [202, 403, 429, 503]

    private static let challengeTitleMarkers = [
        "just a moment",
        "attention required",
        "please wait",
        "checking your browser",
        "ddos-guard",
        "安全验证",
        "正在验证"
    ]

    private static let challengeBodyMarkers = [
        "cdn-cgi/challenge-platform",
        "cf-browser-verification",
        "cf_chl_opt",
        "__cf_chl_",
        "challenge-running",
        "turnstile",
        "jschl_vc",
        "waf_js_challenge",
        "acw_sc__v2"
    ]

    public static func isChallengeStatus(_ statusCode: Int) -> Bool {
        challengeStatusCodes.contains(statusCode)
    }

    public static func looksLikeChallengeDocument(statusCode: Int, title: String, html: String) -> Bool {
        if isChallengeStatus(statusCode) {
            return true
        }
        let loweredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if challengeTitleMarkers.contains(where: { loweredTitle.contains($0) }) {
            return true
        }
        // Only scan the leading 16 KB to keep challenge inspection fast on large pages.
        let sample = String(html.prefix(16_384)).lowercased()
        if challengeBodyMarkers.contains(where: { sample.contains($0) }) {
            return true
        }
        if sample.contains("http-equiv=\"refresh\"") || sample.contains("http-equiv='refresh'") {
            return html.count < 8_192
        }
        return false
    }

    public static func resolveUserAgent(
        requestHeaders: [String: String],
        applicationDefault: String
    ) -> String {
        if let explicit = requestHeaders.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        let configured = applicationDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return defaultBrowserUserAgent
    }

    /// Wraps a source `webJs` expression or statement block so WebKit's bridge
    /// never throws `WKError.javaScriptResultTypeIsUnsupported` on `undefined`,
    /// while preserving full browser `window` and `document` visibility.
    public static func wrappedEvaluationScript(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "document.documentElement ? document.documentElement.outerHTML : ''"
        }
        guard let encoded = try? JSONEncoder().encode(trimmed),
              let literal = String(data: encoded, encoding: .utf8) else {
            return trimmed
        }
        return """
        (() => {
            const __src = \(literal);
            const __value = (0, eval)(__src);
            if (__value === undefined || __value === null) return null;
            if (typeof __value === 'string') return __value;
            try { return JSON.stringify(__value); } catch (_) { return String(__value); }
        })()
        """
    }
}
