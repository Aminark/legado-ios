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
        var sharedVariables = list.variables
        var nextURL: String?
        if let nextRule = source.ruleNextPage, !nextRule.isEmpty {
            if nextRule.uppercased() == "PAGE" {
                nextURL = sortURL
            } else {
                let next = await engine.evaluate(nextRule, inText: body, baseURL: baseURL, context: .init(variables: list.variables, baseURL: baseURL, source: adapter))
                diagnostics += next.diagnostics
                sharedVariables = next.variables
                if let value = next.joinedString, !value.isEmpty {
                    nextURL = URL(string: value, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? value
                }
            }
        }
        var articles: [RssArticle] = []
        for item in flatten(list.values, rule: listRule) {
            try Task.checkCancellation()
            var context = RuleExecutionContext(variables: sharedVariables, baseURL: baseURL, source: adapter, rssArticle: RssArticle())
            let title = await evaluate(source.ruleTitle, item: item, context: context)
            apply(title, to: &context)
            context.rssArticle?.title = title.joinedString ?? ""
            let pubDate = await evaluate(source.rulePubDate, item: item, context: context)
            apply(pubDate, to: &context)
            context.rssArticle?.pubDate = pubDate.joinedString
            let description = await evaluate(source.ruleDescription, item: item, context: context)
            apply(description, to: &context)
            context.rssArticle?.description = source.ruleDescription?.isEmpty == false ? description.joinedString : nil
            let image = await evaluate(source.ruleImage, item: item, context: context)
            apply(image, to: &context)
            if let imageValue = image.joinedString, !imageValue.isEmpty {
                context.rssArticle?.image = URL(string: imageValue, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? imageValue
            }
            let link = await evaluate(source.ruleLink, item: item, context: context)
            apply(link, to: &context)
            diagnostics += [title, pubDate, description, image, link].flatMap(\.diagnostics)
            guard var article = context.rssArticle else { continue }
            article.title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !article.title.isEmpty else { continue }
            let rawLink = link.leadingString ?? ""
            let resolvedLink = URL(string: rawLink, relativeTo: URL(string: baseURL))?
                .absoluteURL.absoluteString ?? rawLink
            article.origin = source.sourceUrl
            article.sort = sortName
            article.link = resolvedLink
            article.variable = encodeVariables(link.variables)
            article.type = source.type
            if var state = article.ruleVariableState {
                try Task.checkCancellation()
                state.identity = (origin: article.origin, link: article.link)
                try state.commit()
                article.ruleVariableState = state
            }
            articles.append(article)
        }
        if reverse { articles.reverse() }
        return .init(result: .init(articles: articles, nextURL: nextURL), diagnostics: diagnostics)
    }

    private func evaluate(_ rule: String?, item: JSONValue, context: RuleExecutionContext) async -> RuleEvaluation {
        guard let rule, !rule.isEmpty else { return .init(variables: context.variables, rssArticle: context.rssArticle) }
        if case .string(let text) = item {
            return await engine.evaluate(rule, inText: text, baseURL: context.baseURL, context: context)
        }
        return await engine.evaluate(rule, in: item, context: context)
    }
    private func apply(_ evaluation: RuleEvaluation, to context: inout RuleExecutionContext) {
        context.variables = evaluation.variables
        context.rssArticle = evaluation.rssArticle ?? context.rssArticle
    }
    private func flatten(_ values: [JSONValue], rule: String) -> [JSONValue] {
        // Each regex result is an array containing $0, $1, ... for one
        // article. Flattening it would turn capture groups into articles.
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":") { return values }
        return values.flatMap { value in
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
