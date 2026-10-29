import Foundation

public struct RSSRuleParseReport: Sendable {
    public var result: RSSParseResult
    public var diagnostics: [RuleDiagnostic]
    public init(result: RSSParseResult, diagnostics: [RuleDiagnostic] = []) {
        self.result = result
        self.diagnostics = diagnostics
    }
}

public struct RSSRuleParser: Sendable {
    private let engine: RuleEngine
    public init(engine: RuleEngine = .init()) { self.engine = engine }

    public func parse(
        sortName: String,
        sortURL: String,
        redirectURL: String,
        body: String,
        source: RssSource,
        variables: [String: String] = [:]
    ) async throws -> RSSRuleParseReport {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RSSParserError.emptyBody(source.sourceUrl)
        }
        guard var listRule = source.ruleArticles, !listRule.isEmpty else {
            return .init(result: try RSSDefaultParser.parse(sortName: sortName, xml: body, sourceURL: source.sourceUrl))
        }
        let reverse = listRule.hasPrefix("-")
        if reverse { listRule.removeFirst() }
        let adapter = source.bookSourceAdapter
        // sortURL can contain request options, templates or a relative path.
        // Extracted resources belong to the document actually returned.
        let baseURL = redirectURL
        let baseContext = RuleExecutionContext(variables: variables, baseURL: baseURL, source: adapter)
        let list = await engine.evaluate(listRule, inText: body, baseURL: baseURL, listMode: true, context: baseContext)
        var diagnostics = list.diagnostics
        var nextURL: String?
        if let nextRule = source.ruleNextPage, !nextRule.isEmpty {
            if nextRule.uppercased() == "PAGE" {
                nextURL = sortURL
            } else {
                let next = await engine.evaluate(nextRule, inText: body, baseURL: baseURL, context: .init(variables: list.variables, baseURL: baseURL, source: adapter))
                diagnostics += next.diagnostics
                if let value = next.joinedString, !value.isEmpty {
                    nextURL = URL(string: value, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? value
                }
            }
        }
        var articles: [RssArticle] = []
        for item in flatten(list.values) {
            var context = RuleExecutionContext(variables: list.variables, baseURL: baseURL, source: adapter)
            let title = await evaluate(source.ruleTitle, item: item, context: context); context.variables = title.variables
            let pubDate = await evaluate(source.rulePubDate, item: item, context: context); context.variables = pubDate.variables
            let description = await evaluate(source.ruleDescription, item: item, context: context); context.variables = description.variables
            let image = await evaluate(source.ruleImage, item: item, context: context); context.variables = image.variables
            let link = await evaluate(source.ruleLink, item: item, context: context)
            diagnostics += [title, pubDate, description, image, link].flatMap(\.diagnostics)
            guard let titleValue = title.joinedString?.trimmingCharacters(in: .whitespacesAndNewlines), !titleValue.isEmpty else { continue }
            let rawLink = link.leadingString ?? ""
            let resolvedLink = URL(string: rawLink, relativeTo: URL(string: baseURL))?
                .absoluteURL.absoluteString ?? rawLink
            var article = RssArticle(origin: source.sourceUrl, sort: sortName, title: titleValue, link: resolvedLink)
            article.pubDate = pubDate.joinedString
            article.description = source.ruleDescription?.isEmpty == false ? description.joinedString : nil
            if let imageValue = image.joinedString, !imageValue.isEmpty {
                article.image = URL(string: imageValue, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? imageValue
            }
            article.variable = encodeVariables(link.variables)
            article.type = source.type
            articles.append(article)
        }
        if reverse { articles.reverse() }
        return .init(result: .init(articles: articles, nextURL: nextURL), diagnostics: diagnostics)
    }

    private func evaluate(_ rule: String?, item: JSONValue, context: RuleExecutionContext) async -> RuleEvaluation {
        guard let rule, !rule.isEmpty else { return .init(variables: context.variables) }
        if case .string(let text) = item {
            return await engine.evaluate(rule, inText: text, baseURL: context.baseURL, context: context)
        }
        return await engine.evaluate(rule, in: item, context: context)
    }
    private func flatten(_ values: [JSONValue]) -> [JSONValue] {
        values.flatMap { value in
            if case .array(let items) = value { return items }
            // Text rules serialize selected JSON arrays. Expand them before
            // evaluating article fields, just as for an already parsed array.
            if case .string(let text) = value,
               text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
               let items = try? JSONDecoder().decode([JSONValue].self, from: Data(text.utf8)) {
                return items
            }
            return [value]
        }
    }
    private func encodeVariables(_ values: [String: String]) -> String? {
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RssSource {
    var bookSourceAdapter: BookSource {
        var value = BookSource(bookSourceUrl: sourceUrl, bookSourceName: sourceName)
        value.bookSourceGroup = sourceGroup; value.bookSourceType = type; value.customOrder = customOrder
        value.enabled = enabled; value.jsLib = jsLib; value.enabledCookieJar = enabledCookieJar
        value.concurrentRate = concurrentRate; value.header = header; value.loginUrl = loginUrl
        value.loginUi = loginUi; value.loginCheckJs = loginCheckJs; value.coverDecodeJs = coverDecodeJs
        value.bookSourceComment = sourceComment; value.variableComment = variableComment
        value.lastUpdateTime = lastUpdateTime; value.searchUrl = searchUrl
        return value
    }
}
