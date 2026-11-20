import Foundation
import CryptoKit

public enum DifferentialStage: String, Codable, Sendable {
    case search, detail, toc, content, review, login, debug
}

public struct DifferentialRequestSnapshot: Codable, Sendable, Equatable {
    public struct Request: Codable, Sendable, Equatable {
        public var ruleURL: String
        public var renderedURL: String
        public var method: String
        public var headers: [String: String]
        public var bodyBase64: String?
        public var charset: String?
        public var cookies: [String: String]
        public var timeoutMilliseconds: Int
        public var retryCount: Int
        public var proxy: String?
        public var dnsIp: String?
        public var serverID: String?
    }

    public struct Response: Codable, Sendable, Equatable {
        public struct ErrorInfo: Codable, Sendable, Equatable {
            public var code: String
            public var legadoCode: Int
            public var message: String
        }

        public var statusCode: Int
        public var finalURL: String
        public var headers: [String: String]
        public var charset: String?
        public var bodySHA256: String
        public var bodyJsSHA256: String?
        public var setCookies: [String: String]
        public var error: ErrorInfo?
    }

    public init(caseID: String, stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, failedResponse: HTTPResponse?, error: Error, timeout: TimeInterval) {
        self.caseID = caseID
        self.stage = stage
        self.sourceID = sourceID
        let response = failedResponse
        request = .init(
            ruleURL: prepared.ruleURL, renderedURL: prepared.url.absoluteString, method: prepared.method.rawValue,
            headers: Self.normalizedHeaders(prepared.headers), bodyBase64: prepared.body?.base64EncodedString(),
            charset: prepared.charset,
            cookies: Self.cookies(from: prepared.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value),
            timeoutMilliseconds: Int(timeout * 1_000), retryCount: prepared.retry,
            proxy: prepared.proxy, dnsIp: prepared.dnsIP, serverID: prepared.serverID.map(String.init)
        )
        let classification = Self.classify(error)
        self.response = .init(
            statusCode: response?.statusCode ?? 0,
            finalURL: response?.finalURL.absoluteString ?? prepared.url.absoluteString,
            headers: Self.normalizedHeaders(response?.headers ?? [:]),
            charset: response?.requestedCharset,
            bodySHA256: Self.sha256(response?.data ?? Data()),
            bodyJsSHA256: nil,
            setCookies: Self.cookies(from: response?.headers.first { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }?.value),
            error: .init(code: classification.code, legadoCode: classification.legadoCode, message: error.localizedDescription)
        )
    }

    public var schemaVersion = 1
    public var caseID: String
    public var platform = "ios"
    public var stage: DifferentialStage
    public var sourceID: String
    public var request: Request
    public var response: Response

    public init(caseID: String, stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, rawResponse: HTTPResponse, response: HTTPResponse, timeout: TimeInterval) {
        self.caseID = caseID
        self.stage = stage
        self.sourceID = sourceID
        let requestCookies = Self.cookies(from: prepared.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value)
        let setCookies = Self.cookies(from: response.headers.first { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }?.value)
        request = .init(
            ruleURL: prepared.ruleURL,
            renderedURL: prepared.url.absoluteString,
            method: prepared.method.rawValue,
            headers: Self.normalizedHeaders(prepared.headers),
            bodyBase64: prepared.body?.base64EncodedString(),
            charset: prepared.charset,
            cookies: requestCookies,
            timeoutMilliseconds: Int(timeout * 1_000),
            retryCount: prepared.retry,
            proxy: prepared.proxy,
            dnsIp: prepared.dnsIP,
            serverID: prepared.serverID.map(String.init)
        )
        self.response = .init(
            statusCode: response.statusCode,
            finalURL: response.finalURL.absoluteString,
            headers: Self.normalizedHeaders(response.headers),
            charset: response.requestedCharset,
            bodySHA256: Self.sha256(rawResponse.data),
            bodyJsSHA256: prepared.bodyJavaScript == nil ? nil : Self.sha256(response.data),
            setCookies: setCookies,
            error: nil
        )
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            let (key, value) = entry
            let normalized = key.lowercased()
            result[normalized] = normalized == "cookie" || normalized == "set-cookie" || normalized == "authorization"
                ? "<redacted:\(sha256(Data(value.utf8)))>" : value
        }
    }

    private static func cookies(from header: String?) -> [String: String] {
        guard let header else { return [:] }
        return header.split(separator: ";").reduce(into: [:]) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = "<redacted:\(sha256(Data(pair[1].utf8)))>"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func classify(_ error: Error) -> (code: String, legadoCode: Int) {
        if case HTTPClientError.statusResponse(let response) = error { return ("http.\(response.statusCode)", -7) }
        guard let urlError = error as? URLError else { return ("other", -7) }
        switch urlError.code {
        case .timedOut: return ("timeout", -2)
        case .cannotFindHost, .dnsLookupFailed: return ("dns", -3)
        case .cannotConnectToHost: return ("connection_refused", -4)
        case .networkConnectionLost, .notConnectedToInternet: return ("socket", -5)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return ("tls", -6)
        default: return ("other", -7)
        }
    }
}

public protocol DifferentialSnapshotRecording: Sendable {
    func record(stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, rawResponse: HTTPResponse, response: HTTPResponse, timeout: TimeInterval) async
    func recordFailure(stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, response: HTTPResponse?, error: Error, timeout: TimeInterval) async
}

public actor MemoryDifferentialSnapshotRecorder: DifferentialSnapshotRecording {
    public let caseID: String
    public private(set) var snapshots: [DifferentialRequestSnapshot] = []

    public init(caseID: String) { self.caseID = caseID }

    public func record(stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, rawResponse: HTTPResponse, response: HTTPResponse, timeout: TimeInterval) async {
        snapshots.append(.init(caseID: caseID, stage: stage, sourceID: sourceID, prepared: prepared, rawResponse: rawResponse, response: response, timeout: timeout))
    }

    public func recordFailure(stage: DifferentialStage, sourceID: String, prepared: PreparedRequest, response: HTTPResponse?, error: Error, timeout: TimeInterval) async {
        snapshots.append(.init(caseID: caseID, stage: stage, sourceID: sourceID, prepared: prepared, failedResponse: response, error: error, timeout: timeout))
    }

    public func encodedSnapshots() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshots)
    }
}

public struct DifferentialBusinessSnapshot: Codable, Sendable {
    public struct Content: Codable, Sendable {
        public var title: String?
        public var text: String
        public var supplementalText: String?
        public var pagesVisited: Int
    }

    public struct Result: Codable, Sendable {
        public var books: [SearchBook]?
        public var book: Book?
        public var chapters: [BookChapter]?
        public var content: Content?
        public var variables: [String: String]
        public var cookies: [String: String]
        public var diagnostics: [RuleDiagnostic]
    }

    public var schemaVersion = 1
    public var caseID: String
    public var platform = "ios"
    public var flow: DifferentialStage
    public var result: Result

    public static func search(caseID: String, report: BookSearchReport) -> Self {
        .init(caseID: caseID, flow: .search, result: .init(
            books: report.books, book: nil, chapters: nil, content: nil,
            variables: [:], cookies: [:], diagnostics: report.outcomes.flatMap(\.diagnostics)
        ))
    }

    public static func detail(caseID: String, report: BookDetailReport) -> Self {
        .init(caseID: caseID, flow: .detail, result: .init(
            books: nil, book: report.book, chapters: nil, content: nil,
            variables: decodeVariables(report.book.variable), cookies: [:], diagnostics: report.diagnostics
        ))
    }

    public static func toc(caseID: String, report: ChapterListReport) -> Self {
        .init(caseID: caseID, flow: .toc, result: .init(
            books: nil, book: nil, chapters: report.chapters, content: nil,
            variables: [:], cookies: [:], diagnostics: report.diagnostics
        ))
    }

    public static func content(caseID: String, report: ChapterContentReport) -> Self {
        .init(caseID: caseID, flow: .content, result: .init(
            books: nil, book: nil, chapters: nil,
            content: .init(title: report.title, text: report.content, supplementalText: report.supplementalContent, pagesVisited: report.pagesVisited),
            variables: [:], cookies: [:], diagnostics: report.diagnostics
        ))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func decodeVariables(_ value: String?) -> [String: String] {
        guard let value, let data = value.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
