import Foundation

public struct BookExploreService: Sendable {
    private let transport: any HTTPTransport
    private let urlBuilder: LegadoURLBuilder
    private let engine: RuleEngine
    private let networkPolicy: SourceNetworkPolicy
    private let webViewExecutor: (any SourceWebViewRequestExecuting)?

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport.shared,
        urlBuilder: LegadoURLBuilder = .init(),
        engine: RuleEngine = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil
    ) {
        self.transport = transport
        self.urlBuilder = urlBuilder
        self.engine = engine
        self.networkPolicy = networkPolicy
        self.webViewExecutor = webViewExecutor
    }

    public func kinds(for source: BookSource) async -> ExploreKindsReport {
        guard let rule = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rule.isEmpty else { return .init() }
        var diagnostics: [RuleDiagnostic] = []
        let rendered: String
        if rule.lowercased().hasPrefix("@js:") || rule.lowercased().hasPrefix("<js>") {
            var context = RuleExecutionContext(baseURL: source.bookSourceUrl, source: source)
            context.isGeneratingExploreKinds = true
            let result = await engine.evaluate(rule, in: .null, context: context)
            diagnostics = result.diagnostics
            rendered = result.values.first?.stringValue ?? ""
        } else {
            rendered = rule
        }
        do {
            return .init(kinds: try parseKinds(rendered), diagnostics: diagnostics)
        } catch let error as RuleEngineError {
            return .init(diagnostics: diagnostics + [error.diagnostic])
        } catch {
            return .init(diagnostics: diagnostics + [.init(
                severity: .error,
                code: "explore.kinds",
                message: error.localizedDescription,
                rule: rule
            )])
        }
    }

    public func explore(
        source: BookSource,
        kind: ExploreKind,
        page: Int = 1
    ) async -> SourceSearchOutcome {
        guard let template = kind.navigableURL else {
            return failure(source, code: "explore.url", message: "发现分类缺少 URL", rule: kind.title)
        }
        let rules = resolvedRules(source) ?? .init()
        let listRule = rules.bookList ?? ""
        do {
            let prepared = try await RuleExecutionWorker.run {
                try urlBuilder.prepare(
                    template,
                    context: .init(page: page, source: source),
                    baseURL: URL(string: source.bookSourceUrl),
                    defaultHeaders: BookSourceHeaderResolver().resolve(source)
                )
            }
            let timeout = min(max(Double(source.respondTime) / 1_000, 5), 180)
            let response = try await networkPolicy.execute(
                prepared,
                source: source,
                transport: transport,
                timeout: timeout,
                webViewExecutor: webViewExecutor
            )
            let (body, root) = response.decodeTextAndJSON()
            var context = RuleExecutionContext(
                variables: response.requestVariables,
                baseURL: response.finalURL.absoluteString,
                page: page,
                source: source
            )
            let list = if listRule.isEmpty {
                RuleEvaluation(variables: context.variables)
            } else if let root {
                await engine.evaluate(listRule.trimmingListPrefix, in: root, listMode: true, context: context)
            } else {
                await engine.evaluate(
                    listRule.trimmingListPrefix,
                    inText: body,
                    baseURL: response.finalURL.absoluteString,
                    listMode: true,
                    context: context
                )
            }
            context.variables = list.variables
            var diagnostics = list.diagnostics
            let items = list.listItems(rule: listRule.trimmingListPrefix)
            if items.isEmpty, source.bookUrlPattern?.isEmpty != false,
               !diagnostics.contains(where: { $0.severity == .error }) {
                var outcome = await NetworkBookService(engine: engine).analyzeSearchDetail(
                    response: response, bookURL: prepared.resolvedRuleURL, source: source, context: context
                )
                outcome.diagnostics = diagnostics + outcome.diagnostics
                return outcome
            }
            var books: [SearchBook] = []
            if !items.isEmpty {
                let cancellation = RuleExecutionCancellation()
                let baseURLString = response.finalURL.absoluteString
                let finalURL = response.finalURL
                let isHTML = root == nil
                let listVariables = context.variables
                let evaluated = try await withTaskCancellationHandler {
                    try await RuleExecutionWorker.runRule {
                        var parsed: [SearchBook] = []
                        var itemDiagnostics: [RuleDiagnostic] = []
                        parsed.reserveCapacity(items.count)
                        let sanitizer = MetadataTextSanitizer()
                        for item in items {
                            try cancellation.check()
                            let fields = evaluateFieldsSynchronously(
                                rules,
                                item: item,
                                isHTML: isHTML,
                                baseURL: baseURLString,
                                source: source,
                                variables: listVariables,
                                page: page,
                                cancellation: cancellation,
                                sanitizer: sanitizer
                            )
                            itemDiagnostics += fields.diagnostics
                            guard let name = fields.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                            let bookURL = resolve(fields.bookURL?.nilIfEmpty ?? baseURLString, against: finalURL)
                            var book = SearchBook(
                                bookURL: bookURL,
                                origin: source.bookSourceUrl,
                                originName: source.bookSourceName,
                                type: source.bookSourceType,
                                name: name,
                                author: fields.author ?? ""
                            )
                            book.kind = fields.kind
                            book.coverURL = fields.coverURL.map { resolve($0, against: finalURL) }
                            book.intro = fields.intro
                            book.wordCount = fields.wordCount
                            book.latestChapterTitle = fields.lastChapter
                            book.originOrder = source.customOrder
                            book.variables = fields.variables
                            parsed.append(book)
                        }
                        return (parsed, itemDiagnostics)
                    }
                } onCancel: {
                    cancellation.cancel()
                }
                books = evaluated.0
                diagnostics += evaluated.1
            }
            if listRule.hasPrefix("-") { books.reverse() }
            var unique = Set<String>()
            books = books.filter { unique.insert($0.bookURL).inserted }
            return .init(sourceID: source.id, books: books, diagnostics: diagnostics)
        } catch is CancellationError {
            return failure(source, code: "explore.cancelled", message: "发现加载已取消", rule: template)
        } catch let error as RuleEngineError {
            return .init(sourceID: source.id, books: [], diagnostics: [error.diagnostic])
        } catch {
            return failure(source, code: "explore.request", message: error.localizedDescription, rule: template)
        }
    }

    private func parseKinds(_ value: String) throws -> [ExploreKind] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") {
            do {
                return try JSONDecoder().decode([ExploreKind].self, from: Data(trimmed.utf8))
            } catch let strictError {
                do {
                    let object = try JSONSerialization.jsonObject(
                        with: Data(trimmed.utf8),
                        options: [.fragmentsAllowed, .json5Allowed]
                    )
                    let normalized = try JSONEncoder().encode(JSONValue.bridge(object))
                    return try JSONDecoder().decode([ExploreKind].self, from: normalized)
                } catch {
                    throw RuleEngineError.malformedRule(
                        rule: value,
                        detail: "发现分类 JSON 无效：\(strictError.localizedDescription)"
                    )
                }
            }
        }
        return trimmed
            .replacingOccurrences(of: "&&", with: "\n")
            .split(whereSeparator: { $0.isNewline })
            .compactMap { line in
                let line = String(line)
                let range = line.range(of: "::")
                let title = String(range.map { line[..<$0.lowerBound] } ?? line[...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let url = range.map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                return ExploreKind(title: title, url: url?.isEmpty == true ? nil : url)
            }
    }

    private func resolvedRules(_ source: BookSource) -> BookListRule? {
        if let rules = source.ruleExplore, rules.bookList?.isEmpty == false { return rules }
        guard let search = source.ruleSearch else { return source.ruleExplore }
        return .init(
            bookList: search.bookList,
            name: search.name,
            author: search.author,
            intro: search.intro,
            kind: search.kind,
            lastChapter: search.lastChapter,
            updateTime: search.updateTime,
            bookUrl: search.bookUrl,
            coverUrl: search.coverUrl,
            wordCount: search.wordCount
        )
    }

    private func evaluateFieldsSynchronously(
        _ rules: BookListRule,
        item: JSONValue,
        isHTML: Bool,
        baseURL: String,
        source: BookSource,
        variables: [String: String],
        page: Int,
        cancellation: RuleExecutionCancellation,
        sanitizer: MetadataTextSanitizer
    ) -> Fields {
        var book = Book(bookUrl: baseURL, name: "", origin: source.bookSourceUrl)
        book.originName = source.bookSourceName
        book.originOrder = source.customOrder
        book.type = source.bookSourceType
        var context = RuleExecutionContext(
            variables: variables,
            baseURL: baseURL,
            page: page,
            source: source,
            book: book,
            isHTMLFragment: true
        )
        context.cancellation = cancellation
        var result = Fields()
        let name = evaluateSynchronously(rules.name, item: item, baseURL: baseURL, context: context)
        context.variables = name.variables
        context.book?.name = name.joinedString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = evaluateSynchronously(rules.author, item: item, baseURL: baseURL, context: context)
        context.variables = author.variables
        context.book?.author = author.joinedString ?? ""
        let kind = evaluateSynchronously(rules.kind, item: item, baseURL: baseURL, context: context)
        context.variables = kind.variables
        let joinedKind = kind.strings.filter { !$0.isEmpty }.joined(separator: ",").nilIfEmpty
        context.book?.kind = joinedKind
        // Keep Android's field order: later rules can read earlier metadata
        // and java.put values through the current book's rule context.
        let wordCount = evaluateSynchronously(rules.wordCount, item: item, baseURL: baseURL, context: context)
        context.variables = wordCount.variables
        context.book?.wordCount = wordCount.joinedString
        let lastChapter = evaluateSynchronously(rules.lastChapter, item: item, baseURL: baseURL, context: context)
        context.variables = lastChapter.variables
        context.book?.latestChapterTitle = lastChapter.joinedString
        let intro = evaluateSynchronously(rules.intro, item: item, baseURL: baseURL, context: context)
        context.variables = intro.variables
        let cleanedIntro = sanitizer.clean(intro.joinedString)
        context.book?.intro = cleanedIntro
        let cover = evaluateSynchronously(rules.coverUrl, item: item, baseURL: baseURL, context: context)
        context.variables = cover.variables
        context.book?.coverUrl = cover.joinedString.flatMap { value in
            URL(string: baseURL).map { resolve(value, against: $0) }
        }
        let bookURL = evaluateSynchronously(rules.bookUrl, item: item, baseURL: baseURL, context: context)
        context.variables = bookURL.variables
        result.name = name.joinedString
        result.author = author.joinedString
        result.kind = joinedKind
        result.bookURL = isHTML ? bookURL.leadingString : bookURL.joinedString
        result.coverURL = cover.joinedString
        result.intro = cleanedIntro
        result.wordCount = wordCount.joinedString
        result.lastChapter = lastChapter.joinedString
        result.variables = context.variables
        result.diagnostics = [name, author, kind, bookURL, cover, intro, wordCount, lastChapter].flatMap(\.diagnostics)
        return result
    }

    private func evaluateSynchronously(
        _ rule: String?,
        item: JSONValue,
        baseURL: String,
        context: RuleExecutionContext
    ) -> RuleEvaluation {
        guard let rule, !rule.isEmpty else { return .init(variables: context.variables) }
        if case .string(let text) = item {
            return engine.evaluateSynchronously(rule, inText: text, baseURL: baseURL, context: context)
        }
        return engine.evaluateSynchronously(rule, in: item, context: context)
    }

    private func resolve(_ value: String, against base: URL) -> String {
        LegadoURLBuilder.resolve(value, against: base)
    }

    private func failure(_ source: BookSource, code: String, message: String, rule: String) -> SourceSearchOutcome {
        .init(sourceID: source.id, books: [], diagnostics: [
            .init(severity: .error, code: code, message: message, rule: rule)
        ])
    }

    private struct Fields {
        var name: String?
        var author: String?
        var kind: String?
        var bookURL: String?
        var coverURL: String?
        var intro: String?
        var wordCount: String?
        var lastChapter: String?
        var variables: [String: String] = [:]
        var diagnostics: [RuleDiagnostic] = []
    }
}

extension String {
    var trimmingListPrefix: String {
        guard hasPrefix("-") || hasPrefix("+") else { return self }
        return String(dropFirst())
    }

    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
