import Foundation
import CryptoKit

public enum HttpTTSServiceError: Error, LocalizedError, Sendable {
    case emptyText
    case invalidContentType(expected: String, actual: String, body: String)
    case textResponse(contentType: String, body: String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "朗读文本为空"
        case .invalidContentType(let expected, let actual, let body):
            "TTS 返回类型不匹配（期望 \(expected)，实际 \(actual)）：\(body)"
        case .textResponse(_, let body):
            body
        }
    }
}

public struct HttpTTSAudio: Sendable {
    public var data: Data
    public var contentType: String?
    public var finalURL: URL

    public init(data: Data, contentType: String?, finalURL: URL) {
        self.data = data
        self.contentType = contentType
        self.finalURL = finalURL
    }
}

public struct HttpTTSAudioStream: Sendable {
    public var contentType: String?
    public var finalURL: URL
    public var expectedContentLength: Int64?
    public var chunks: AsyncThrowingStream<Data, Error>
    public var isIncremental: Bool

    public init(
        contentType: String?,
        finalURL: URL,
        expectedContentLength: Int64?,
        chunks: AsyncThrowingStream<Data, Error>,
        isIncremental: Bool
    ) {
        self.contentType = contentType
        self.finalURL = finalURL
        self.expectedContentLength = expectedContentLength
        self.chunks = chunks
        self.isIncremental = isIncremental
    }
}

public actor HttpTTSAudioCache {
    public static let shared = HttpTTSAudioCache()
    private let directory: URL
    private let maximumBytes: Int64

    public init(directory: URL? = nil, maximumBytes: Int64 = 128 * 1_024 * 1_024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/httpTTS_cache", isDirectory: true)
        self.maximumBytes = maximumBytes
    }

    public func data(for key: String) -> Data? {
        let url = directory.appendingPathComponent(key + ".audio")
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func store(_ data: Data, for key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".audio"), options: .atomic)
            trimIfNeeded()
        } catch { }
    }

    public func clear() { try? FileManager.default.removeItem(at: directory) }

    private func trimIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(URL, Int64, Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maximumBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > maximumBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

public actor HttpTTSService {
    private let urlBuilder: LegadoURLBuilder
    private let networkPolicy: SourceNetworkPolicy
    private let transport: any HTTPTransport
    private let cache: HttpTTSAudioCache

    public init(
        urlBuilder: LegadoURLBuilder = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        cache: HttpTTSAudioCache = .shared
    ) {
        self.urlBuilder = urlBuilder
        self.networkPolicy = networkPolicy
        self.transport = transport
        self.cache = cache
    }

    public func audio(engine: HttpTTS, text: String, speechRate: Int) async throws -> HttpTTSAudio {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HttpTTSServiceError.emptyText }
        let source = engine.bookSourceAdapter
        let cacheKey = try Self.cacheKey(engine: engine, text: text, speechRate: speechRate)
        if let data = await cache.data(for: cacheKey) {
            return .init(data: data, contentType: engine.contentType, finalURL: cacheURL(engine: engine))
        }
        let context = URLTemplateContext(
            key: text,
            variables: [
                "speakText": text,
                "speakSpeed": String(speechRate)
            ],
            source: source
        )
        var lastError: Error = HttpTTSServiceError.emptyText
        for attempt in 0..<6 {
            try Task.checkCancellation()
            do {
                let prepared = try urlBuilder.prepare(
                    engine.url,
                    context: context,
                    defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                )
                var response = try await networkPolicy.execute(
                    prepared,
                    source: source,
                    transport: transport,
                    timeout: 300
                )
                if try evaluateLoginCheckIfNeeded(engine: engine, source: source, response: response) {
                    let rebuilt = try urlBuilder.prepare(
                        engine.url,
                        context: context,
                        defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                    )
                    response = try await networkPolicy.execute(
                        rebuilt,
                        source: source,
                        transport: transport,
                        timeout: 300
                    )
                }
                let contentType = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
                }?.value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                try validateContentType(engine: engine, response: response, contentType: contentType)
                await cache.store(response.data, for: cacheKey)
                return .init(data: response.data, contentType: contentType, finalURL: response.finalURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch HTTPClientError.statusResponse(let response) {
                if try evaluateLoginCheckIfNeeded(engine: engine, source: source, response: response) {
                    let rebuilt = try urlBuilder.prepare(
                        engine.url,
                        context: context,
                        defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                    )
                    let recovered = try await networkPolicy.execute(
                        rebuilt,
                        source: source,
                        transport: transport,
                        timeout: 300
                    )
                    let contentType = Self.contentType(from: recovered.headers)
                    try validateContentType(engine: engine, response: recovered, contentType: contentType)
                    await cache.store(recovered.data, for: cacheKey)
                    return .init(data: recovered.data, contentType: contentType, finalURL: recovered.finalURL)
                }
                lastError = HTTPClientError.statusResponse(response)
                if attempt == 5 { throw lastError }
            } catch let error as RuleEngineError {
                throw error
            } catch {
                lastError = error
                if attempt == 5 { throw error }
            }
        }
        throw lastError
    }

    public func audioStream(engine: HttpTTS, text: String, speechRate: Int) async throws -> HttpTTSAudioStream {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HttpTTSServiceError.emptyText }
        let cacheKey = try Self.cacheKey(engine: engine, text: text, speechRate: speechRate)
        if let data = await cache.data(for: cacheKey) {
            return Self.bufferedStream(
                data: data,
                contentType: engine.contentType,
                finalURL: cacheURL(engine: engine)
            )
        }
        let requiresBufferedValidation = engine.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !requiresBufferedValidation,
              let streamingTransport = transport as? any StreamingHTTPTransport else {
            let value = try await audio(engine: engine, text: text, speechRate: speechRate)
            return Self.bufferedStream(data: value.data, contentType: value.contentType, finalURL: value.finalURL)
        }
        let source = engine.bookSourceAdapter
        let context = URLTemplateContext(
            key: text,
            variables: ["speakText": text, "speakSpeed": String(speechRate)],
            source: source
        )
        let prepared = try urlBuilder.prepare(
            engine.url,
            context: context,
            defaultHeaders: try BookSourceHeaderResolver().resolve(source)
        )
        if prepared.bodyJavaScript != nil || prepared.responseType != nil || prepared.proxy != nil || prepared.useWebView {
            let value = try await audio(engine: engine, text: text, speechRate: speechRate)
            return Self.bufferedStream(data: value.data, contentType: value.contentType, finalURL: value.finalURL)
        }
        let response = try await networkPolicy.executeStream(
            prepared,
            source: source,
            transport: streamingTransport,
            timeout: 300
        )
        let contentType = Self.contentType(from: response.headers)
        try validateStreamContentType(engine: engine, contentType: contentType)
        let upstream = response.chunks
        let cache = self.cache
        let cachedChunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var complete = Data()
                if let length = response.expectedContentLength, length > 0, length <= Int64(Int.max) {
                    complete.reserveCapacity(Int(length))
                }
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        complete.append(chunk)
                        continuation.yield(chunk)
                    }
                    await cache.store(complete, for: cacheKey)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(
            contentType: contentType,
            finalURL: response.finalURL,
            expectedContentLength: response.expectedContentLength,
            chunks: cachedChunks,
            isIncremental: true
        )
    }

    private static func cacheKey(engine: HttpTTS, text: String, speechRate: Int) throws -> String {
        struct CacheInput: Encodable {
            let engine: HttpTTS
            let text: String
            let speechRate: Int
        }
        // Voices can share an endpoint and select their speaker through headers
        // or JavaScript. Include the complete configuration and source identity.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(CacheInput(engine: engine, text: text, speechRate: speechRate))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bufferedStream(data: Data, contentType: String?, finalURL: URL) -> HttpTTSAudioStream {
        .init(
            contentType: contentType,
            finalURL: finalURL,
            expectedContentLength: Int64(data.count),
            chunks: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            },
            isIncremental: false
        )
    }

    private static func contentType(from headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cacheURL(engine: HttpTTS) -> URL {
        URL(string: engine.url.components(separatedBy: ",").first ?? "")
            ?? URL(fileURLWithPath: "/httpTTS-cache")
    }

    private func evaluateLoginCheckIfNeeded(engine: HttpTTS, source: BookSource, response: HTTPResponse) throws -> Bool {
        guard let script = engine.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else { return false }
        let headers = response.headers.mapValues(JSONValue.string)
        let input = JSONValue.object([
            "code": .number(Double(response.statusCode)),
            "body": .string(response.decodedText),
            "headers": .object(headers),
            "url": .string(response.finalURL.absoluteString)
        ])
        let wrapped = """
            (function () {
              var raw = result;
              var rebuildRequest = false;
              function header(name) {
                var wanted = String(name).toLowerCase();
                for (var key in raw.headers) if (key.toLowerCase() === wanted) return raw.headers[key];
                return null;
              }
              result = {
                code: function () { return raw.code; },
                statusCode: function () { return raw.code; },
                body: function () { return { string: function () { return raw.body; } }; },
                header: header,
                headers: function () { return { get: header }; },
                url: function () { return { toString: function () { return raw.url; } }; }
              };
              java.getHeaderMap = function () {
                return { putAll: function () {}, put: function () {} };
              };
              java.getResponse = function () { rebuildRequest = true; return result; };
              java.initUrl = function () { rebuildRequest = true; return result; };
              java.ruleUrl = raw.url;
              (function () {
                \(script)
              })();
              return { rebuildRequest: rebuildRequest };
            })()
            """
        let result = try JavaScriptRuleEvaluator().evaluate(
            script: wrapped,
            result: input,
            executionContext: .init(
                variables: ["speakSpeed": "", "speakText": ""],
                baseURL: response.finalURL.absoluteString,
                source: source
            )
        )
        if case .object(let object) = result.value,
           case .bool(let requested)? = object["rebuildRequest"] {
            return requested
        }
        return false
    }

    private func validateContentType(engine: HttpTTS, response: HTTPResponse, contentType: String?) throws {
        guard let contentType, !contentType.isEmpty else { return }
        if contentType == "application/json" || contentType.hasPrefix("text/") {
            throw HttpTTSServiceError.textResponse(contentType: contentType, body: response.decodedText)
        }
        guard let expected = engine.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return }
        let expression = try NSRegularExpression(pattern: expected)
        let range = NSRange(contentType.startIndex..., in: contentType)
        guard expression.firstMatch(in: contentType, range: range) != nil else {
            throw HttpTTSServiceError.invalidContentType(
                expected: expected,
                actual: contentType,
                body: response.decodedText
            )
        }
    }

    private func validateStreamContentType(engine: HttpTTS, contentType: String?) throws {
        guard let contentType, !contentType.isEmpty else { return }
        if contentType == "application/json" || contentType.hasPrefix("text/") {
            throw HttpTTSServiceError.textResponse(contentType: contentType, body: "TTS 返回了文本响应")
        }
        guard let expected = engine.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return }
        let expression = try NSRegularExpression(pattern: expected)
        let range = NSRange(contentType.startIndex..., in: contentType)
        guard expression.firstMatch(in: contentType, range: range) != nil else {
            throw HttpTTSServiceError.invalidContentType(expected: expected, actual: contentType, body: "")
        }
    }
}

public extension HttpTTS {
    var sourceKey: String { "httpTts:\(id)" }

    var bookSourceAdapter: BookSource {
        var source = BookSource(bookSourceUrl: sourceKey, bookSourceName: name)
        source.concurrentRate = concurrentRate
        source.loginUrl = loginUrl
        source.loginUi = loginUi
        source.header = header
        source.jsLib = jsLib
        source.enabledCookieJar = enabledCookieJar
        source.loginCheckJs = loginCheckJs
        source.lastUpdateTime = lastUpdateTime
        return source
    }
}
