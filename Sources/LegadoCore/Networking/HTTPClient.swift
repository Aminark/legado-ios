import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL
    public var requestedCharset: String?
    public var requestVariables: [String: String]
    public var rssArticle: RssArticle?

    public init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL, requestedCharset: String? = nil, requestVariables: [String: String] = [:], rssArticle: RssArticle? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
        self.requestedCharset = requestedCharset
        self.requestVariables = requestVariables
        self.rssArticle = rssArticle
    }

    public var decodedText: String {
        let encoding = requestedCharset.flatMap(HTTPTextDecoder.encoding(named:))
            ?? contentTypeCharset.flatMap(HTTPTextDecoder.encoding(named:))
            ?? HTTPTextDecoder.bomEncoding(data)
            ?? HTTPTextDecoder.htmlEncoding(data)
            ?? .utf8
        if let value = String(data: HTTPTextDecoder.removingBOM(data), encoding: encoding) { return value }
        if encoding != .utf8, let value = String(data: HTTPTextDecoder.removingBOM(data), encoding: .utf8) { return value }
        return String(decoding: data, as: UTF8.self)
    }

    public var decodedJSON: JSONValue? {
        try? JSONValue.decode(data: Data(decodedText.utf8))
    }

    private var contentTypeCharset: String? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value,
              let expression = try? NSRegularExpression(pattern: #"charset\s*=\s*[\"']?([^;\"'\s]+)"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

public enum HTTPTextDecoder {
    public static func htmlEncoding(_ data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(16_384), as: UTF8.self)
        guard let meta = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive),
              let charset = try? NSRegularExpression(pattern: #"charset\s*=\s*["']?\s*([a-zA-Z0-9_-]+)"#, options: .caseInsensitive) else { return nil }
        for tag in meta.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let match = charset.firstMatch(in: head, range: tag.range),
                  let range = Range(match.range(at: 1), in: head),
                  let encoding = encoding(named: String(head[range])) else { continue }
            return encoding
        }
        return nil
    }

    public static func encoding(named rawValue: String) -> String.Encoding? {
        let value = rawValue.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le", "utf16le": return .utf16LittleEndian
        case "utf-16be", "utf16be": return .utf16BigEndian
        case "utf-32", "utf32": return .utf32
        case "utf-32le", "utf32le": return .utf32LittleEndian
        case "utf-32be", "utf32be": return .utf32BigEndian
        case "gbk", "gb2312", "gb-2312", "gb18030", "gb-18030":
            return foundationEncoding(.GB_18030_2000)
        case "big5", "big-5": return foundationEncoding(.big5)
        case "shift-jis", "shiftjis", "sjis": return .shiftJIS
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return nil
        }
    }

    private static func foundationEncoding(_ value: CFStringEncodings) -> String.Encoding {
        .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    public static func bomEncoding(_ data: Data) -> String.Encoding? {
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if prefix.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if prefix.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return nil
    }

    public static func removingBOM(_ data: Data) -> Data {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return data.dropFirst(3) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return data.dropFirst(4) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return data.dropFirst(2) }
        return data
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

public final class LegadoUnsafeTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = LegadoUnsafeTrustDelegate()
    private let settingsStore: ApplicationSettingsStore
    private let interceptHostsRedirects: Bool

    public init(settingsStore: ApplicationSettingsStore = .shared, interceptHostsRedirects: Bool = true) {
        self.settingsStore = settingsStore
        self.interceptHostsRedirects = interceptHostsRedirects
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.resolution(for: challenge, ignoreCertificateErrors: settingsStore.settings.ignoreCertificateErrors)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let settings = settingsStore.settings
        let address = try? ApplicationSettings.parseHosts(settings.hosts)[request.url?.host?.lowercased() ?? ""]
        completionHandler(interceptHostsRedirects && settings.proxy.isEmpty && address != nil ? nil : request)
    }

    public static func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let result = resolution(for: challenge)
        completionHandler(result.0, result.1)
    }

    static func resolution(
        for challenge: URLAuthenticationChallenge,
        ignoreCertificateErrors: Bool = ApplicationSettingsStore.shared.settings.ignoreCertificateErrors
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let disposition: URLSession.AuthChallengeDisposition
        let credential: URLCredential?
        if ignoreCertificateErrors,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            disposition = .useCredential
            credential = URLCredential(trust: trust)
        } else {
            disposition = .performDefaultHandling
            credential = nil
        }
        return (disposition, credential)
    }
}

public struct HTTPStreamResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL
    public var expectedContentLength: Int64?
    public var chunks: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String],
        finalURL: URL,
        expectedContentLength: Int64? = nil,
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
        self.expectedContentLength = expectedContentLength
        self.chunks = chunks
    }
}

public protocol StreamingHTTPTransport: HTTPTransport {
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse
}

public protocol ProxyHTTPTransport: HTTPTransport {
    func data(for request: URLRequest, proxy: String) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, LocalizedError, Sendable {
    case nonHTTPResponse
    case statusCode(Int)
    case statusResponse(HTTPResponse)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse: "服务器没有返回 HTTP 响应"
        case .statusCode(let code): "服务器返回 HTTP \(code)"
        case .statusResponse(let response): "服务器返回 HTTP \(response.statusCode)"
        }
    }
}

public final class URLSessionHTTPTransport: ProxyHTTPTransport, StreamingHTTPTransport, @unchecked Sendable {
    public static let shared = URLSessionHTTPTransport()
    private let configuration: URLSessionConfiguration
    private let settingsStore: ApplicationSettingsStore
    private let lock = NSLock()
    private var cachedSettings: ApplicationSettings?
    private var cachedSession: URLSession?

    public init(configuration: URLSessionConfiguration = .ephemeral, settingsStore: ApplicationSettingsStore = .shared) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.settingsStore = settingsStore
        self.configuration.httpCookieAcceptPolicy = .always
        self.configuration.httpShouldSetCookies = true
        self.configuration.httpCookieStorage = HTTPCookieStorage.shared
        self.configuration.requestCachePolicy = .reloadRevalidatingCacheData
    }

    deinit { cachedSession?.finishTasksAndInvalidate() }

    private func configuredSession(settings: ApplicationSettings) throws -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if settings == cachedSettings, let cachedSession { return cachedSession }
        let config = configuration.copy() as! URLSessionConfiguration
        try settings.configure(config)
        let session = URLSession(configuration: config, delegate: LegadoUnsafeTrustDelegate(settingsStore: settingsStore), delegateQueue: nil)
        cachedSession?.finishTasksAndInvalidate()
        cachedSession = session
        cachedSettings = settings
        return session
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        try await load(request, redirectsRemaining: 10)
    }

    private func load(_ original: URLRequest, redirectsRemaining: Int) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let settings = settingsStore.settings
        let request = settings.configure(original)
        let started = Date()
        do {
            let response: HTTPResponse
            if settings.proxy.isEmpty,
               let address = try ApplicationSettings.parseHosts(settings.hosts)[request.url?.host?.lowercased() ?? ""] {
                response = try await HostsHTTPTransport.data(for: request, address: address, ignoreCertificateErrors: settings.ignoreCertificateErrors)
            } else {
                let session = try configuredSession(settings: settings)
                response = try await rawData(for: request, session: session)
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.headers.first(where: { $0.key.lowercased() == "location" })?.value,
               let target = URL(string: location, relativeTo: response.finalURL)?.absoluteURL {
                guard redirectsRemaining > 0 else { throw URLError(.httpTooManyRedirects) }
                var next = request
                next.url = target
                if response.statusCode == 303 || ([301, 302].contains(response.statusCode) && next.httpMethod == "POST") {
                    next.httpMethod = "GET"; next.httpBody = nil
                    next.setValue(nil, forHTTPHeaderField: "Content-Length")
                    next.setValue(nil, forHTTPHeaderField: "Content-Type")
                }
                if target.host?.lowercased() != request.url?.host?.lowercased()
                    || target.scheme?.lowercased() != request.url?.scheme?.lowercased()
                    || target.port != request.url?.port {
                    next.setValue(nil, forHTTPHeaderField: "Authorization")
                    next.setValue(nil, forHTTPHeaderField: "Cookie")
                }
                next.setValue(nil, forHTTPHeaderField: "Host")
                DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
                return try await load(next, redirectsRemaining: redirectsRemaining - 1)
            }
            guard (200...299).contains(response.statusCode) else { throw HTTPClientError.statusResponse(response) }
            DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
            return response
        } catch {
            DiagnosticLog.shared.network(request, error: error, startedAt: started)
            throw error
        }
    }

    public func download(for request: URLRequest) async throws -> (Data, URLResponse) {
        let value = try await data(for: request)
        guard let response = HTTPURLResponse(url: value.finalURL, statusCode: value.statusCode, httpVersion: nil, headerFields: value.headers) else {
            throw HTTPClientError.nonHTTPResponse
        }
        return (value.data, response)
    }

    public func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let settings = settingsStore.settings
        let request = settings.configure(request)
        if !settings.hosts.isEmpty, settings.proxy.isEmpty {
            let response = try await data(for: request)
            return .init(statusCode: response.statusCode, headers: response.headers, finalURL: response.finalURL,
                         expectedContentLength: Int64(response.data.count), chunks: AsyncThrowingStream { continuation in
                continuation.yield(response.data)
                continuation.finish()
            })
        }
        let session = try configuredSession(settings: settings)
        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            DiagnosticLog.shared.network(request, error: error, startedAt: started)
            throw error
        }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw HTTPClientError.nonHTTPResponse
        }
        let headers = Self.headers(from: http)
        DiagnosticLog.shared.network(request, status: http.statusCode, startedAt: started)
        guard (200 ... 299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw HTTPClientError.statusResponse(.init(
                data: body,
                statusCode: http.statusCode,
                headers: headers,
                finalURL: finalURL
            ))
        }
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(32 * 1_024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= 32 * 1_024 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(
            statusCode: http.statusCode,
            headers: headers,
            finalURL: finalURL,
            expectedContentLength: http.expectedContentLength >= 0 ? http.expectedContentLength : nil,
            chunks: chunks
        )
    }

    public func data(for original: URLRequest, proxy: String) async throws -> HTTPResponse {
        let settings = settingsStore.settings
        let config = configuration.copy() as! URLSessionConfiguration
        try settings.configure(config, proxyOverride: proxy)
        let session = URLSession(configuration: config, delegate: LegadoUnsafeTrustDelegate(settingsStore: settingsStore, interceptHostsRedirects: false), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let request = settings.configure(original)
        let started = Date()
        do {
            let response = try await rawData(for: request, session: session)
            guard (200...299).contains(response.statusCode) else { throw HTTPClientError.statusResponse(response) }
            DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
            return response
        } catch {
            DiagnosticLog.shared.network(request, error: error, startedAt: started)
            throw error
        }
    }

    private func rawData(for request: URLRequest, session: URLSession) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw HTTPClientError.nonHTTPResponse }
        return .init(data: data, statusCode: http.statusCode, headers: Self.headers(from: http), finalURL: url)
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
    }
}

public final class LegadoCookieStore: @unchecked Sendable {
    public static let shared = LegadoCookieStore()

    private let storage: HTTPCookieStorage
    private let lock = NSLock()
    private let persistent = PersistentRuntimeCache.shared

    public init(storage: HTTPCookieStorage = .shared) {
        self.storage = storage
    }

    public func cookieHeader(for value: String) -> String {
        guard let url = normalizedURL(value) else { return "" }
        lock.lock()
        let cookies = storage.cookies(for: url) ?? []
        lock.unlock()
        let session = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        let saved = persistent.cookie(for: persistenceKey(url)) ?? ""
        return mergeCookieHeaders(saved, session)
    }

    public func cookie(for value: String, key: String) -> String {
        guard let url = normalizedURL(value) else { return "" }
        lock.lock()
        let result = storage.cookies(for: url)?.first(where: { $0.name == key })?.value
        lock.unlock()
        if let result { return result }
        return cookieMap(persistent.cookie(for: persistenceKey(url)) ?? "")[key] ?? ""
    }

    public func setCookie(_ cookie: String, for value: String) {
        guard let url = normalizedURL(value), !cookie.isEmpty else { return }
        var cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookie], for: url)
        if cookies.isEmpty,
           let host = url.host,
           let first = cookie.split(separator: ";").first {
            let pair = first.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, let fallback = HTTPCookie(properties: [
                .name: pair[0].trimmingCharacters(in: .whitespaces),
                .value: pair[1],
                .domain: host,
                .path: "/",
                .secure: url.scheme == "https" ? "TRUE" : "FALSE"
            ]) {
                cookies = [fallback]
            }
        }
        lock.lock()
        cookies.forEach(storage.setCookie)
        lock.unlock()
        let old = persistent.cookie(for: persistenceKey(url)) ?? ""
        persistent.putCookie(
            key: persistenceKey(url),
            value: mergeCookieHeaders(old, persistentCookieHeader(cookie))
        )
    }

    public func removeCookies(for value: String) {
        guard let url = normalizedURL(value) else { return }
        lock.lock()
        storage.cookies(for: url)?.forEach(storage.deleteCookie)
        lock.unlock()
        persistent.deleteCookie(key: persistenceKey(url))
    }

    private func normalizedURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(string: "https://\(value)")
    }

    private func persistenceKey(_ url: URL) -> String {
        guard let host = url.host?.lowercased() else { return url.absoluteString }
        return Self.persistenceDomain(for: host)
    }

    static func persistenceDomain(for host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isIPAddress(host) else { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let publicSecondLevels: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
            "com.hk", "net.hk", "org.hk", "com.tw", "net.tw", "org.tw",
            "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk",
            "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
            "com.au", "net.au", "org.au", "edu.au", "gov.au",
            "co.nz", "net.nz", "org.nz", "co.kr", "or.kr", "ne.kr",
            "co.in", "firm.in", "net.in", "org.in", "gen.in", "ind.in",
            "com.sg", "net.sg", "org.sg", "com.br", "net.br", "org.br"
        ]
        return publicSecondLevels.contains(lastTwo)
            ? labels.suffix(3).joined(separator: ".")
            : lastTwo
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private func cookieMap(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func mergeCookieHeaders(_ headers: String...) -> String {
        var values: [String: String] = [:]
        var order: [String] = []
        for header in headers {
            for part in header.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                if values[name] == nil { order.append(name) }
                values[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return order.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }

    private func persistentCookieHeader(_ header: String) -> String {
        let attributes = Set(["path", "domain", "expires", "max-age", "samesite"])
        return header.split(separator: ";").compactMap { part -> String? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            guard !attributes.contains(name.lowercased()) else { return nil }
            return "\(name)=\(pair[1].trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "; ")
    }
}

public protocol SourceWebViewRequestExecuting: Sendable {
    @MainActor
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse
}

public final class SourceWebViewExecutorRegistry: @unchecked Sendable {
    public static let shared = SourceWebViewExecutorRegistry()

    private let lock = NSLock()
    private var storedExecutor: (any SourceWebViewRequestExecuting)?

    public init() {}

    public func register(_ executor: any SourceWebViewRequestExecuting) {
        lock.lock()
        storedExecutor = executor
        lock.unlock()
    }

    public func executor() -> (any SourceWebViewRequestExecuting)? {
        lock.lock()
        let value = storedExecutor
        lock.unlock()
        return value
    }
}

public struct SourceRateLimit: Sendable, Equatable {
    public var accessLimit: Int
    public var intervalMilliseconds: Int64

    public init?(rawValue: String?) {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "0" else { return nil }
        if let slash = value.firstIndex(of: "/"),
           let count = Int(value[..<slash]),
           let interval = Int64(value[value.index(after: slash)...]),
           count > 0, interval > 0 {
            accessLimit = count
            intervalMilliseconds = interval
        } else if let interval = Int64(value), interval > 0 {
            accessLimit = 1
            intervalMilliseconds = interval
        } else {
            return nil
        }
    }
}

public struct SourceRateWindow: Sendable, Equatable {
    public var startedAt: Int64
    public var frequency: Int

    public init(startedAt: Int64 = 0, frequency: Int = 0) {
        self.startedAt = startedAt
        self.frequency = frequency
    }

    public mutating func reserve(now: Int64, limit: SourceRateLimit) -> Int64 {
        if frequency == 0 || now >= startedAt + limit.intervalMilliseconds {
            startedAt = now
            frequency = 1
            return 0
        }
        if frequency < limit.accessLimit {
            frequency += 1
            return 0
        }
        return max(startedAt + limit.intervalMilliseconds - now, 0)
    }
}

public actor SourceNetworkPolicy {
    public static let shared = SourceNetworkPolicy()

    private struct StoredCookie: Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expiresAt: Date?
        var secure: Bool
    }

    private var windows: [String: SourceRateWindow] = [:]
    private var cookies: [String: [StoredCookie]] = [:]
    private let javaScript: JavaScriptRuleEvaluator

    public init(javaScript: JavaScriptRuleEvaluator = .init()) { self.javaScript = javaScript }

    public func execute(
        _ prepared: PreparedRequest,
        source: BookSource,
        transport: any HTTPTransport,
        timeout: TimeInterval,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil,
        snapshotRecorder: (any DifferentialSnapshotRecording)? = nil,
        snapshotStage: DifferentialStage = .debug
    ) async throws -> HTTPResponse {
        try await acquire(source: source)
        if prepared.url.scheme?.lowercased() == "data", !prepared.useWebView {
            do {
                let response = try dataURIResponse(for: prepared)
                let transformed = try await transformBodyIfNeeded(response, prepared: prepared, source: source)
                await snapshotRecorder?.record(
                    stage: snapshotStage,
                    sourceID: source.id,
                    prepared: prepared,
                    rawResponse: response,
                    response: transformed,
                    timeout: timeout
                )
                return transformed
            } catch {
                await snapshotRecorder?.recordFailure(
                    stage: snapshotStage,
                    sourceID: source.id,
                    prepared: prepared,
                    response: nil,
                    error: error,
                    timeout: timeout
                )
                throw error
            }
        }
        if prepared.useWebView {
            guard let executor = webViewExecutor ?? SourceWebViewExecutorRegistry.shared.executor() else {
                throw RuleEngineError.unsupportedRule(rule: prepared.ruleURL, feature: "后台 WKWebView 请求")
            }
            return try await executeWebView(
                prepared,
                source: source,
                executor: executor,
                transport: transport,
                timeout: timeout,
                snapshotRecorder: snapshotRecorder,
                snapshotStage: snapshotStage
            )
        }
        var request = prepared.urlRequest(timeout: timeout, handleCookies: false)
        if source.enabledCookieJar == true {
            let stored = cookieHeader(sourceID: source.id, url: prepared.url)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }

        let retryCount = max(prepared.retry, 0)
        let attempts = retryCount == Int.max ? Int.max : retryCount + 1
        var lastError: Error = HTTPClientError.nonHTTPResponse
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                var response: HTTPResponse
                if let proxy = prepared.proxy {
                    guard let proxyTransport = transport as? any ProxyHTTPTransport else {
                        throw RuleEngineError.unsupportedRule(rule: prepared.ruleURL, feature: "当前传输层不支持代理")
                    }
                    response = try await proxyTransport.data(for: request, proxy: proxy)
                } else {
                    response = try await transport.data(for: request)
                }
                response.requestedCharset = prepared.charset
                guard (200...299).contains(response.statusCode) else {
                    throw HTTPClientError.statusResponse(response)
                }
                if source.enabledCookieJar == true { captureCookies(response: response, sourceID: source.id) }
                let transformed = try await transformBodyIfNeeded(response, prepared: prepared, source: source)
                await snapshotRecorder?.record(stage: snapshotStage, sourceID: source.id, prepared: prepared, rawResponse: response, response: transformed, timeout: timeout)
                return transformed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case HTTPClientError.statusResponse(let response) = error,
                   source.enabledCookieJar == true {
                    captureCookies(response: response, sourceID: source.id)
                }
                guard case HTTPClientError.statusResponse = error, attempt + 1 < attempts else { break }
            }
        }
        let failedResponse: HTTPResponse? = if case HTTPClientError.statusResponse(let response) = lastError { response } else { nil }
        await snapshotRecorder?.recordFailure(stage: snapshotStage, sourceID: source.id, prepared: prepared, response: failedResponse, error: lastError, timeout: timeout)
        throw lastError
    }

    public func executeStream(
        _ prepared: PreparedRequest,
        source: BookSource,
        transport: any StreamingHTTPTransport,
        timeout: TimeInterval
    ) async throws -> HTTPStreamResponse {
        guard prepared.url.scheme?.lowercased() != "data",
              !prepared.useWebView,
              prepared.bodyJavaScript == nil,
              prepared.responseType == nil else {
            throw RuleEngineError.unsupportedRule(rule: prepared.ruleURL, feature: "流式响应转换")
        }
        guard prepared.proxy == nil else {
            throw RuleEngineError.unsupportedRule(rule: prepared.ruleURL, feature: "流式代理请求")
        }
        try await acquire(source: source)
        var request = prepared.urlRequest(timeout: timeout, handleCookies: false)
        if source.enabledCookieJar == true {
            let stored = cookieHeader(sourceID: source.id, url: prepared.url)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }
        let response = try await transport.stream(for: request)
        if source.enabledCookieJar == true {
            captureCookies(
                response: .init(
                    data: Data(),
                    statusCode: response.statusCode,
                    headers: response.headers,
                    finalURL: response.finalURL
                ),
                sourceID: source.id
            )
        }
        return response
    }

    private func executeWebView(
        _ prepared: PreparedRequest,
        source: BookSource,
        executor: any SourceWebViewRequestExecuting,
        transport: any HTTPTransport,
        timeout: TimeInterval,
        snapshotRecorder: (any DifferentialSnapshotRecording)?,
        snapshotStage: DifferentialStage
    ) async throws -> HTTPResponse {
        let started = Date()
        var webPrepared = prepared
        var request = prepared.urlRequest(timeout: timeout, handleCookies: false)
        if source.enabledCookieJar == true {
            let stored = cookieHeader(sourceID: source.id, url: prepared.url)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty {
                request.setValue(merged, forHTTPHeaderField: "Cookie")
                webPrepared.headers["Cookie"] = merged
            }
        }
        let retryCount = max(prepared.retry, 0)
        let attempts = retryCount == Int.max ? Int.max : retryCount + 1
        var lastError: Error = HTTPClientError.nonHTTPResponse
        for attempt in 0..<attempts {
            do {
                try Task.checkCancellation()
                if prepared.method == .post, prepared.webViewHTML == nil {
                    let page: HTTPResponse
                    if let proxy = prepared.proxy {
                        guard let proxyTransport = transport as? any ProxyHTTPTransport else {
                            throw RuleEngineError.unsupportedRule(rule: prepared.ruleURL, feature: "当前传输层不支持代理")
                        }
                        page = try await proxyTransport.data(for: request, proxy: proxy)
                    } else { page = try await transport.data(for: request) }
                    guard (200...299).contains(page.statusCode) else { throw HTTPClientError.statusResponse(page) }
                    if source.enabledCookieJar == true {
                        captureCookies(response: page, sourceID: source.id)
                        let cookies = cookieHeader(sourceID: source.id, url: page.finalURL)
                        let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
                        webPrepared.headers["Cookie"] = mergeCookieHeaders(cookies, explicit)
                    }
                    var decoded = page
                    decoded.requestedCharset = prepared.charset ?? page.requestedCharset
                    webPrepared.webViewHTML = decoded.decodedText
                    webPrepared.url = page.finalURL
                }
                try Task.checkCancellation()
                var response = try await executor.execute(webPrepared, source: source, timeout: timeout)
                try Task.checkCancellation()
                // WKWebView serializes JavaScript results as UTF-8 even when
                // the original document used a legacy encoding.
                response.requestedCharset = response.requestedCharset ?? prepared.charset
                guard (200...299).contains(response.statusCode) else {
                    throw HTTPClientError.statusResponse(response)
                }
                if source.enabledCookieJar == true { captureCookies(response: response, sourceID: source.id) }
                let transformed = try await transformBodyIfNeeded(response, prepared: prepared, source: source)
                await snapshotRecorder?.record(stage: snapshotStage, sourceID: source.id, prepared: prepared, rawResponse: response, response: transformed, timeout: timeout)
                DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
                return transformed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case HTTPClientError.statusResponse(let response) = error,
                   source.enabledCookieJar == true {
                    captureCookies(response: response, sourceID: source.id)
                }
                guard case HTTPClientError.statusResponse = error, attempt + 1 < attempts else { break }
            }
        }
        let failedResponse: HTTPResponse? = if case HTTPClientError.statusResponse(let response) = lastError { response } else { nil }
        await snapshotRecorder?.recordFailure(stage: snapshotStage, sourceID: source.id, prepared: prepared, response: failedResponse, error: lastError, timeout: timeout)
        DiagnosticLog.shared.network(request, error: lastError, startedAt: started)
        throw lastError
    }

    private nonisolated func transformBodyIfNeeded(
        _ original: HTTPResponse,
        prepared: PreparedRequest,
        source: BookSource
    ) async throws -> HTTPResponse {
        var response = original
        response.requestVariables = prepared.variables
        response.rssArticle = prepared.rssArticle
        if prepared.responseType != nil {
            response.data = Data(original.data.map { String(format: "%02x", $0) }.joined().utf8)
            response.requestedCharset = "utf-8"
            return response
        }
        guard let script = prepared.bodyJavaScript else { return response }
        let transformed = try await javaScript.evaluateAsync(
            script: script,
            result: .string(response.decodedText),
            executionContext: .init(
                variables: response.requestVariables,
                baseURL: response.finalURL.absoluteString,
                key: prepared.key,
                page: prepared.page,
                source: source,
                book: prepared.book,
                chapter: prepared.chapter,
                rssArticle: prepared.rssArticle
            )
        )
        response.data = Data(transformed.value.stringValue.utf8)
        response.requestedCharset = "utf-8"
        response.requestVariables = transformed.variables
        response.rssArticle = transformed.rssArticle ?? response.rssArticle
        return response
    }

    public func cookieHeader(sourceID: String, url: URL) -> String {
        let now = Date()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let values = (cookies[sourceID] ?? []).filter { cookie in
            (cookie.expiresAt == nil || cookie.expiresAt! > now)
                && domainMatches(host: host, domain: cookie.domain)
                && path.hasPrefix(cookie.path)
                && (!cookie.secure || url.scheme?.lowercased() == "https")
        }
        return values.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func setCookieHeader(_ header: String, sourceID: String, url: URL) {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            upsert(.init(name: pair[0].trimmingCharacters(in: .whitespaces), value: pair[1], domain: url.host ?? "", path: "/", expiresAt: nil, secure: url.scheme == "https"), sourceID: sourceID)
        }
    }

    public func removeCookies(sourceID: String) { cookies[sourceID] = nil }

    private func acquire(source: BookSource) async throws {
        guard let limit = SourceRateLimit(rawValue: source.concurrentRate) else { return }
        while true {
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            var window = windows[source.id] ?? .init()
            let wait = window.reserve(now: now, limit: limit)
            windows[source.id] = window
            guard wait > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        }
    }

    private func captureCookies(response: HTTPResponse, sourceID: String) {
        guard let header = response.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value else { return }
        LegadoCookieStore.shared.setCookie(header, for: response.finalURL.absoluteString)
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: response.finalURL) {
            upsert(.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expiresAt: cookie.expiresDate, secure: cookie.isSecure), sourceID: sourceID)
        }
    }

    private func dataURIResponse(for prepared: PreparedRequest) throws -> HTTPResponse {
        let value = prepared.url.absoluteString
        guard value.lowercased().hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else {
            throw RuleEngineError.malformedRule(rule: prepared.ruleURL, detail: "data URI 无效")
        }
        let metadata = String(value[value.index(value.startIndex, offsetBy: 5)..<comma])
        let payload = String(value[value.index(after: comma)...])
        let isBase64 = metadata.split(separator: ";").contains { $0.caseInsensitiveCompare("base64") == .orderedSame }
        let data: Data?
        if isBase64 {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
        } else {
            data = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let data else {
            throw RuleEngineError.malformedRule(rule: prepared.ruleURL, detail: "data URI 内容无法解码")
        }
        let mediaType = metadata.split(separator: ";", maxSplits: 1).first.map(String.init)
        let headers = mediaType.flatMap { $0.isEmpty ? nil : ["Content-Type": $0] } ?? [:]
        return HTTPResponse(data: data, statusCode: 200, headers: headers, finalURL: prepared.url)
    }

    private func upsert(_ cookie: StoredCookie, sourceID: String) {
        var values = cookies[sourceID] ?? []
        values.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        values.append(cookie)
        cookies[sourceID] = values
    }

    private func domainMatches(host: String, domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == normalized || host.hasSuffix(".\(normalized)")
    }

    private func mergeCookieHeaders(_ headers: String...) -> String {
        var values: [String: String] = [:]
        var order: [String] = []
        for header in headers {
            for part in header.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                if values[name] == nil { order.append(name) }
                values[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return order.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }
}
