import Foundation

public struct RSSFetchResult: Sendable {
    public var requestURL: String
    public var finalURL: String
    public var statusCode: Int
    public var body: String
    public var report: RSSRuleParseReport
}

public struct RSSContentFetchResult: Sendable {
    public var requestURL: String
    public var finalURL: String
    public var statusCode: Int
    public var body: String
    public var content: String
    public var diagnostics: [RuleDiagnostic]
}

public struct RSSService: Sendable {
    private let transport: any HTTPTransport
    private let urlBuilder: LegadoURLBuilder
    private let engine: RuleEngine
    private let parser: RSSRuleParser
    private let networkPolicy: SourceNetworkPolicy
    private let webViewExecutor: (any SourceWebViewRequestExecuting)?

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        urlBuilder: LegadoURLBuilder = .init(),
        engine: RuleEngine = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil
    ) {
        self.transport = transport
        self.urlBuilder = urlBuilder
        self.engine = engine
        self.parser = RSSRuleParser(engine: engine)
        self.networkPolicy = networkPolicy
        self.webViewExecutor = webViewExecutor
    }

    public func articles(
        sortName: String,
        sortURL: String,
        source: RssSource,
        page: Int,
        key: String? = nil
    ) async throws -> RSSRuleParseReport {
        try await articlesDetailed(sortName: sortName, sortURL: sortURL, source: source, page: page, key: key).report
    }

    public func articlesDetailed(
        sortName: String,
        sortURL: String,
        source: RssSource,
        page: Int,
        key: String? = nil
    ) async throws -> RSSFetchResult {
        let adapter = source.bookSourceAdapter
        let headers = try BookSourceHeaderResolver().resolve(adapter)
        let prepared = try urlBuilder.prepare(
            sortURL,
            context: .init(key: key, page: page, source: adapter),
            baseURL: URL(string: source.sourceUrl),
            defaultHeaders: headers
        )
        let response = try await networkPolicy.execute(
            prepared,
            source: adapter,
            transport: transport,
            timeout: 180,
            webViewExecutor: webViewExecutor,
            snapshotStage: .debug
        )
        let report = try await parser.parse(
            sortName: sortName,
            sortURL: sortURL,
            redirectURL: response.finalURL.absoluteString,
            body: response.decodedText,
            source: source,
            variables: response.requestVariables
        )
        if let error = report.diagnostics.first(where: { $0.severity == .error }) {
            throw RuleEngineError.malformedRule(rule: source.ruleArticles ?? "", detail: error.message)
        }
        return .init(
            requestURL: prepared.url.absoluteString,
            finalURL: response.finalURL.absoluteString,
            statusCode: response.statusCode,
            body: response.decodedText,
            report: report
        )
    }

    public func content(article: RssArticle, rule: String, source: RssSource) async throws -> String {
        try await contentDetailed(article: article, rule: rule, source: source).content
    }

    public func contentDetailed(article: RssArticle, rule: String, source: RssSource) async throws -> RSSContentFetchResult {
        let adapter = source.bookSourceAdapter
        let headers = try BookSourceHeaderResolver().resolve(adapter)
        let prepared = try urlBuilder.prepare(
            article.link,
            context: .init(variables: article.variableMap, source: adapter),
            baseURL: URL(string: article.origin),
            defaultHeaders: headers
        )
        let response = try await networkPolicy.execute(
            prepared,
            source: adapter,
            transport: transport,
            timeout: 180,
            webViewExecutor: webViewExecutor,
            snapshotStage: .content
        )
        let result = await engine.evaluate(
            rule,
            inText: response.decodedText,
            baseURL: URL(string: article.link, relativeTo: URL(string: article.origin))?.absoluteURL.absoluteString ?? article.link,
            context: .init(variables: article.variableMap, baseURL: response.finalURL.absoluteString, source: adapter)
        )
        if let error = result.diagnostics.first(where: { $0.severity == .error }) {
            throw RuleEngineError.malformedRule(rule: rule, detail: error.message)
        }
        return .init(
            requestURL: prepared.url.absoluteString,
            finalURL: response.finalURL.absoluteString,
            statusCode: response.statusCode,
            body: response.decodedText,
            content: result.joinedString ?? "",
            diagnostics: result.diagnostics
        )
    }
}
