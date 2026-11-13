import Foundation

public struct SourceSearchOutcome: Sendable {
    public var sourceID: String
    public var books: [SearchBook]
    public var diagnostics: [RuleDiagnostic]

    public init(sourceID: String, books: [SearchBook], diagnostics: [RuleDiagnostic]) {
        self.sourceID = sourceID
        self.books = books
        self.diagnostics = diagnostics
    }
}

public struct BookSearchReport: Sendable {
    public var books: [SearchBook]
    public var outcomes: [SourceSearchOutcome]

    public init(books: [SearchBook], outcomes: [SourceSearchOutcome]) {
        self.books = books
        self.outcomes = outcomes
    }
}

public actor BookSearchHistory {
    public static let shared = BookSearchHistory(defaults: .standard)
    private struct Entry: Codable, Sendable {
        var success: Date?
        var failure: Date?
        var failures = 0
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults?
    private static let key = "legado.searchSourceHistory.v1"
    private var saveTask: Task<Void, Never>?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    public func ordered(_ sources: [BookSource], preferred: Set<String>, now: Date = Date()) -> [BookSource] {
        func rank(_ source: BookSource) -> Int {
            if preferred.contains(source.id) { return 0 }
            guard let entry = entries[source.id] else { return 2 }
            if let failure = entry.failure, now.timeIntervalSince(failure) < 300, entry.failures > 0 { return 3 }
            if let success = entry.success, now.timeIntervalSince(success) < 7 * 86_400 { return 1 }
            return 2
        }
        return sources.enumerated().sorted {
            let lhs = rank($0.element), rhs = rank($1.element)
            if lhs != rhs { return lhs < rhs }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    public func record(_ outcome: SourceSearchOutcome, now: Date = Date()) {
        guard !outcome.diagnostics.contains(where: { $0.code == "search.cancelled" }) else { return }
        var entry = entries[outcome.sourceID] ?? Entry()
        if !outcome.books.isEmpty {
            entry.success = now
            entry.failures = 0
        } else if outcome.diagnostics.contains(where: { $0.severity == .error }) {
            entry.failure = now
            entry.failures += 1
        } else { return }
        entries[outcome.sourceID] = entry
        guard defaults != nil, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let defaults else { return }
        let retained = entries.sorted {
            if ($0.value.success != nil) != ($1.value.success != nil) { return $0.value.success != nil }
            return ($0.value.success ?? $0.value.failure ?? .distantPast) > ($1.value.success ?? $1.value.failure ?? .distantPast)
        }.prefix(512)
        entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

public struct BookSearchAccumulator: Sendable {
    private var books: [SearchBook] = []
    private var indices: [String: Int] = [:]
    public init() {}

    public mutating func add(_ incoming: [SearchBook], replacingExisting: Bool = false) {
        for book in incoming {
            let identity = BookSearchService.mergeIdentity(for: book)
            if let index = indices[identity] {
                let origins = books[index].origins.union(book.origins)
                if replacingExisting { books[index] = book }
                books[index].origins = origins
            } else {
                indices[identity] = books.count
                books.append(book)
            }
        }
    }

    public func results(keyword: String) -> [SearchBook] {
        var buckets = Array(repeating: [SearchBook](), count: 4)
        for book in books {
            let rank: Int
            if book.name == keyword || book.author == keyword { rank = 0 }
            else if book.kind?.contains(keyword) == true { rank = 1 }
            else if book.name.contains(keyword) || book.author.contains(keyword) { rank = 2 }
            else { rank = 3 }
            buckets[rank].append(book)
        }
        // Android ranks matching books by the number of available sources,
        // retaining arrival order for ties and for unrelated results.
        for index in 0..<3 {
            buckets[index] = buckets[index].enumerated().sorted {
                if $0.element.origins.count != $1.element.origins.count {
                    return $0.element.origins.count > $1.element.origins.count
                }
                return $0.offset < $1.offset
            }.map(\.element)
        }
        return buckets.flatMap { $0 }
    }
}

public struct BookSearchService: Sendable {
    private let transport: any HTTPTransport
    private let urlBuilder: LegadoURLBuilder
    private let engine: RuleEngine
    private let networkPolicy: SourceNetworkPolicy
    private let webViewExecutor: (any SourceWebViewRequestExecuting)?
    private let snapshotRecorder: (any DifferentialSnapshotRecording)?
    private let history: BookSearchHistory

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        urlBuilder: LegadoURLBuilder = .init(),
        engine: RuleEngine = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil,
        snapshotRecorder: (any DifferentialSnapshotRecording)? = nil,
        history: BookSearchHistory = .shared
    ) {
        self.transport = transport
        self.urlBuilder = urlBuilder
        self.engine = engine
        self.networkPolicy = networkPolicy
        self.webViewExecutor = webViewExecutor
        self.snapshotRecorder = snapshotRecorder
        self.history = history
    }

    public func search(
        keyword: String,
        page: Int = 1,
        sources: [BookSource]
    ) async -> BookSearchReport {
        let enabled = sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }
        let sourceOrder = Dictionary(enabled.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [SourceSearchOutcome] = []
        for await outcome in searchOutcomes(keyword: keyword, page: page, sources: enabled) {
            outcomes.append(outcome)
        }
        outcomes.sort { (sourceOrder[$0.sourceID] ?? .max) < (sourceOrder[$1.sourceID] ?? .max) }
        return .init(books: merge(outcomes: outcomes, keyword: keyword), outcomes: outcomes)
    }

    public func searchOutcomes(
        keyword: String,
        page: Int = 1,
        sources: [BookSource],
        maximumConcurrentSources: Int = ApplicationSettingsStore.shared.settings.concurrentSources,
        includeDisabled: Bool = false,
        preferredSourceIDs: Set<String> = []
    ) -> AsyncStream<SourceSearchOutcome> {
        var seen = Set<String>()
        let enabled = sources.filter { (includeDisabled || $0.enabled) && $0.searchUrl?.isEmpty == false && seen.insert($0.id).inserted }
        let concurrency = min(max(maximumConcurrentSources, 1), enabled.count)
        guard concurrency > 0 else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let task = Task {
                let ordered = await history.ordered(enabled, preferred: preferredSourceIDs)
                await withTaskGroup(of: SourceSearchOutcome.self) { group in
                    var complexRunning = 0
                    let complexLimit = min(concurrency, 4)
                    func isComplex(_ source: BookSource) -> Bool {
                        let template = (source.searchUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return template.hasPrefix("@js:") || template.hasPrefix("<js>") || template.contains("webview") || template.contains("webjs")
                    }
                    let complexIDs = Set(ordered.filter(isComplex).map(\.id))
                    let normal = ordered.enumerated().filter { !complexIDs.contains($0.element.id) }.map(\.offset)
                    let complex = ordered.enumerated().filter { complexIDs.contains($0.element.id) }.map(\.offset)
                    var normalIndex = 0
                    var complexIndex = 0
                    func enqueue() -> Bool {
                        guard !Task.isCancelled else { return false }
                        let nextNormal = normalIndex < normal.count ? normal[normalIndex] : Int.max
                        let nextComplex = complexIndex < complex.count && complexRunning < complexLimit ? complex[complexIndex] : Int.max
                        guard min(nextNormal, nextComplex) != Int.max else { return false }
                        let source: BookSource
                        if nextComplex < nextNormal {
                            source = ordered[nextComplex]
                            complexIndex += 1
                            complexRunning += 1
                        } else {
                            source = ordered[nextNormal]
                            normalIndex += 1
                        }
                        group.addTask {
                            await search(keyword: keyword, page: page, source: source,
                                         timeoutLimit: enabled.count > 1 ? 8 : 30)
                        }
                        return true
                    }
                    for _ in 0..<concurrency { if !enqueue() { break } }
                    while let outcome = await group.next() {
                        if complexIDs.contains(outcome.sourceID) { complexRunning -= 1 }
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        await history.record(outcome)
                        continuation.yield(outcome)
                        _ = enqueue()
                    }
                }
                await history.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await history.flush() }
            }
        }
    }

    public func search(keyword: String, page: Int, source: BookSource) async -> SourceSearchOutcome {
        await search(keyword: keyword, page: page, source: source, timeoutLimit: 30)
    }

    private func search(keyword: String, page: Int, source: BookSource, timeoutLimit: TimeInterval) async -> SourceSearchOutcome {
        guard let template = source.searchUrl else {
            return failure(source, code: "search.configuration", message: "书源缺少搜索地址或规则")
        }
        let rules = source.ruleSearch ?? .init()
        do {
            var prepared = try await RuleExecutionWorker.run {
                let headers = try BookSourceHeaderResolver().resolve(source)
                return try urlBuilder.prepare(template, context: .init(key: keyword, page: page, source: source),
                                              baseURL: URL(string: source.bookSourceUrl), defaultHeaders: headers)
            }
            if timeoutLimit < 30 { prepared.retry = min(prepared.retry, 1) }
            // respondTime is the last measured source-check duration used for
            // sorting. A previously fast response is not a request deadline.
            let timeout = timeoutLimit
            let response = try await networkPolicy.execute(
                prepared,
                source: source,
                transport: transport,
                timeout: timeout,
                webViewExecutor: webViewExecutor,
                snapshotRecorder: snapshotRecorder,
                snapshotStage: .search
            )
            let detailService = NetworkBookService(engine: engine)
            let detailURL = response.finalURL == prepared.url ? prepared.resolvedRuleURL : response.finalURL.absoluteString
            func detailOutcome(variables: [String: String]) async -> SourceSearchOutcome {
                await detailService.analyzeSearchDetail(
                    response: response, bookURL: detailURL, source: source,
                    context: .init(variables: variables, key: keyword, page: page)
                )
            }
            if let pattern = source.bookUrlPattern, !pattern.isEmpty {
                let matches = try await RuleExecutionWorker.run {
                    try RegexEvaluator().captureGroups(pattern: "\\A(?:" + pattern + ")\\z", input: response.finalURL.absoluteString)
                }
                if !matches.isEmpty { return await detailOutcome(variables: response.requestVariables) }
            }
            let listRule = rules.bookList ?? ""
            let root = response.decodedJSON
            let body = response.decodedText
            let listEvaluation = if listRule.isEmpty {
                RuleEvaluation(variables: response.requestVariables)
            } else if let root {
                await engine.evaluate(
                    listRule.trimmingListPrefix,
                    in: root,
                    listMode: true,
                    context: .init(variables: response.requestVariables, baseURL: response.finalURL.absoluteString, key: keyword, page: page, source: source)
                )
            } else {
                await engine.evaluate(
                    listRule.trimmingListPrefix,
                    inText: body,
                    baseURL: response.finalURL.absoluteString,
                    listMode: true,
                    context: .init(variables: response.requestVariables, key: keyword, page: page, source: source)
                )
            }
            var diagnostics = listEvaluation.diagnostics
            let items = listEvaluation.listItems(rule: listRule.trimmingListPrefix)
            if items.isEmpty, source.bookUrlPattern?.isEmpty != false,
               !diagnostics.contains(where: { $0.severity == .error }) {
                var outcome = await detailOutcome(variables: listEvaluation.variables)
                outcome.diagnostics = diagnostics + outcome.diagnostics
                return outcome
            }
            var books: [SearchBook] = []
            for item in items {
                try Task.checkCancellation()
                let fields = await evaluateFields(
                    rules,
                    item: item,
                    isHTML: root == nil,
                    baseURL: response.finalURL.absoluteString,
                    source: source,
                    variables: listEvaluation.variables,
                    keyword: keyword,
                    page: page
                )
                diagnostics += fields.diagnostics
                guard let name = fields.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                let bookURLValue = fields.bookURL?.nilIfEmpty ?? response.finalURL.absoluteString
                let bookURL = resolve(bookURLValue, against: response.finalURL)
                var book = SearchBook(
                    bookURL: bookURL,
                    origin: source.bookSourceUrl,
                    originName: source.bookSourceName,
                    type: source.bookSourceType,
                    name: name,
                    author: fields.author ?? ""
                )
                book.kind = fields.kind
                book.coverURL = fields.coverURL.map { resolve($0, against: response.finalURL) }
                book.intro = MetadataTextSanitizer().clean(fields.intro)
                book.wordCount = fields.wordCount
                book.latestChapterTitle = fields.lastChapter
                book.originOrder = source.customOrder
                book.variables = fields.variables
                books.append(book)
            }
            if listRule.hasPrefix("-") { books.reverse() }
            var seenURLs = Set<String>()
            let unique = books.filter { seenURLs.insert($0.bookURL).inserted }
            return .init(sourceID: source.id, books: unique, diagnostics: diagnostics)
        } catch is CancellationError {
            return failure(source, code: "search.cancelled", message: "搜索已取消")
        } catch let error as RuleEngineError {
            return .init(sourceID: source.id, books: [], diagnostics: [error.diagnostic])
        } catch {
            return failure(source, code: "search.request", message: error.localizedDescription)
        }
    }

    private func evaluateFields(
        _ rules: SearchRule,
        item: JSONValue,
        isHTML: Bool,
        baseURL: String,
        source: BookSource,
        variables: [String: String],
        keyword: String,
        page: Int
    ) async -> FieldEvaluation {
        var result = FieldEvaluation()
        var currentBook = Book(bookUrl: baseURL, name: "", origin: source.bookSourceUrl)
        currentBook.originName = source.bookSourceName
        currentBook.originOrder = source.customOrder
        currentBook.type = source.bookSourceType
        var context = RuleExecutionContext(variables: variables, baseURL: baseURL, key: keyword, page: page, source: source, book: currentBook, isHTMLFragment: true)
        let name = await evaluate(rules.name, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = name.variables
        context.book?.name = name.joinedString ?? ""
        let author = await evaluate(rules.author, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = author.variables
        context.book?.author = author.joinedString ?? ""
        let kind = await evaluate(rules.kind, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = kind.variables
        context.book?.kind = kind.strings.filter { !$0.isEmpty }.joined(separator: ",").nilIfEmpty
        // Match BookList.getSearchItem: metadata and variables produced by an
        // earlier field are visible to the rules evaluated after it.
        let wordCount = await evaluate(rules.wordCount, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = wordCount.variables
        context.book?.wordCount = wordCount.joinedString
        let lastChapter = await evaluate(rules.lastChapter, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = lastChapter.variables
        context.book?.latestChapterTitle = lastChapter.joinedString
        let intro = await evaluate(rules.intro, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = intro.variables
        context.book?.intro = MetadataTextSanitizer().clean(intro.joinedString)
        let coverURL = await evaluate(rules.coverUrl, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = coverURL.variables
        context.book?.coverUrl = coverURL.joinedString.flatMap { value in
            URL(string: baseURL).map { resolve(value, against: $0) }
        }
        let bookURL = await evaluate(rules.bookUrl, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = bookURL.variables
        let values = (name, author, kind, bookURL, coverURL, intro, wordCount, lastChapter)
        result.name = values.0.joinedString
        result.author = values.1.joinedString
        result.kind = values.2.strings.filter { !$0.isEmpty }.joined(separator: ",").nilIfEmpty
        result.bookURL = isHTML ? values.3.leadingString : values.3.joinedString
        result.coverURL = values.4.joinedString
        result.intro = MetadataTextSanitizer().clean(values.5.joinedString)
        result.wordCount = values.6.joinedString
        result.lastChapter = values.7.joinedString
        result.diagnostics = [values.0, values.1, values.2, values.3, values.4, values.5, values.6, values.7]
            .flatMap(\.diagnostics)
        result.variables = context.variables
        return result
    }

    private func evaluate(
        _ rule: String?,
        item: JSONValue,
        isHTML: Bool,
        baseURL: String,
        context: RuleExecutionContext = .init()
    ) async -> RuleEvaluation {
        guard let rule, !rule.isEmpty else { return .init(variables: context.variables) }
        if case .string(let text) = item {
            return await engine.evaluate(rule, inText: text, baseURL: baseURL, context: context)
        }
        return await engine.evaluate(rule, in: item, context: context)
    }

    private func resolve(_ value: String, against baseURL: URL) -> String {
        LegadoURLBuilder.resolve(value, against: baseURL)
    }

    private func failure(_ source: BookSource, code: String, message: String) -> SourceSearchOutcome {
        .init(
            sourceID: source.id,
            books: [],
            diagnostics: [.init(severity: .error, code: code, message: message, rule: source.searchUrl ?? "")]
        )
    }

    public func merge(outcomes: [SourceSearchOutcome], keyword: String) -> [SearchBook] {
        merge(outcomes.flatMap(\.books), keyword: keyword)
    }

    private func merge(_ books: [SearchBook], keyword: String) -> [SearchBook] {
        var accumulator = BookSearchAccumulator()
        accumulator.add(books)
        return accumulator.results(keyword: keyword)
    }

    public static func mergeIdentity(for book: SearchBook) -> String {
        "\(normalizedIdentityText(book.name))\u{0}\(normalizedAuthor(book.author))"
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        var normalized = String(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }).lowercased()
        // Preserve punctuation and symbols inside names: they can distinguish
        // different books/authors. Only remove sentence-edge decoration and
        // balanced title quotation marks, retaining the existing source cleanup.
        let decoration = CharacterSet(charactersIn: "！!？?。．.，,；;：:、…")
        let wrappers: [(Character, Character)] = [
            ("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』"),
            ("“", "”"), ("‘", "’"), ("\"", "\""), ("'", "'")
        ]
        while true {
            let trimmed = normalized.trimmingCharacters(in: decoration)
            if !trimmed.isEmpty { normalized = trimmed }
            guard normalized.count > 2,
                  wrappers.contains(where: { normalized.first == $0.0 && normalized.last == $0.1 }) else { break }
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }

    private static func normalizedAuthor(_ value: String) -> String {
        var value = normalizedIdentityText(value)
        for prefix in ["作者", "author", "著者"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        for suffix in ["著", "撰"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return normalizedIdentityText(value)
    }

    private struct FieldEvaluation {
        var name: String?
        var author: String?
        var kind: String?
        var bookURL: String?
        var coverURL: String?
        var intro: String?
        var wordCount: String?
        var lastChapter: String?
        var diagnostics: [RuleDiagnostic] = []
        var variables: [String: String] = [:]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
