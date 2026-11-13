import Foundation

protocol BookUpdateJavaScriptRefreshing: Sendable {
    func refreshBook(_ book: Book, research: Bool) throws -> Book
}

private struct BookUpdatePreparationError: LocalizedError {
    var diagnostics: [RuleDiagnostic]
    var errorDescription: String? { diagnostics.map(\.message).joined(separator: "\n") }
}

public struct BookDetailReport: Sendable {
    public var book: Book
    public var diagnostics: [RuleDiagnostic]

    public init(book: Book, diagnostics: [RuleDiagnostic] = []) {
        self.book = book
        self.diagnostics = diagnostics
    }
}

/// JavaScript native methods are synchronous. Run their async I/O on detached
/// tasks, and wake the JS worker immediately when its owning update is cancelled.
private final class BookUpdateScriptOperations: JavaScriptNetworkLoading, BookUpdateJavaScriptRefreshing, @unchecked Sendable {
    private let transport: any HTTPTransport
    private let refresh: @Sendable (Book, Bool) async throws -> Book
    private let lock = NSLock()
    private var cancelled = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    init(transport: any HTTPTransport, refresh: @escaping @Sendable (Book, Bool) async throws -> Book) {
        self.transport = transport
        self.refresh = refresh
    }

    func load(_ request: URLRequest) throws -> HTTPResponse {
        try wait(timeout: max(request.timeoutInterval, 1) + 1) { [transport] in
            try await transport.data(for: request)
        }
    }

    func refreshBook(_ book: Book, research: Bool) throws -> Book {
        try wait(timeout: 1_800) { [refresh] in try await refresh(book, research) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = Array(cancellations.values)
        lock.unlock()
        pending.forEach { $0() }
    }

    private func wait<Value: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let result = BookUpdateBlockingResult<Value>()
        let task = Task.detached {
            do { result.complete(.success(try await operation())) }
            catch { result.complete(.failure(error)) }
        }
        let cancel: @Sendable () -> Void = { task.cancel(); result.complete(.failure(CancellationError())) }
        let id = UUID()
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { cancellations[id] = cancel }
        lock.unlock()
        defer {
            lock.lock()
            cancellations[id] = nil
            lock.unlock()
        }
        if wasCancelled { cancel() }
        guard result.semaphore.wait(timeout: .now() + timeout) == .success else {
            cancel()
            throw URLError(.timedOut)
        }
        return try result.value().get()
    }
}

private final class BookUpdateBlockingResult<Value: Sendable>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func complete(_ value: Result<Value, Error>) {
        lock.lock()
        guard stored == nil else { lock.unlock(); return }
        stored = value
        lock.unlock()
        semaphore.signal()
    }

    func value() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(CancellationError())
    }
}

public struct ChapterListReport: Sendable {
    public var chapters: [BookChapter]
    public var diagnostics: [RuleDiagnostic]
    public var pagesVisited: Int

    public init(chapters: [BookChapter], diagnostics: [RuleDiagnostic] = [], pagesVisited: Int = 0) {
        self.chapters = chapters
        self.diagnostics = diagnostics
        self.pagesVisited = pagesVisited
    }
}

public struct ChapterContentReport: Sendable {
    public var title: String?
    public var content: String
    public var supplementalContent: String?
    public var diagnostics: [RuleDiagnostic]
    public var pagesVisited: Int

    public init(
        title: String? = nil,
        content: String = "",
        supplementalContent: String? = nil,
        diagnostics: [RuleDiagnostic] = [],
        pagesVisited: Int = 0
    ) {
        self.title = title
        self.content = content
        self.supplementalContent = supplementalContent
        self.diagnostics = diagnostics
        self.pagesVisited = pagesVisited
    }
}

public struct NetworkBookService: Sendable {
    private let transport: any HTTPTransport
    private let urlBuilder: LegadoURLBuilder
    private let engine: RuleEngine
    private let networkPolicy: SourceNetworkPolicy
    private let webViewExecutor: (any SourceWebViewRequestExecuting)?
    private let snapshotRecorder: (any DifferentialSnapshotRecording)?

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        urlBuilder: LegadoURLBuilder = .init(),
        engine: RuleEngine = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil,
        snapshotRecorder: (any DifferentialSnapshotRecording)? = nil
    ) {
        self.transport = transport
        self.urlBuilder = urlBuilder
        self.engine = engine
        self.networkPolicy = networkPolicy
        self.webViewExecutor = webViewExecutor
        self.snapshotRecorder = snapshotRecorder
    }

    public func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        var book = Book(
            bookUrl: searchBook.bookURL,
            name: searchBook.name,
            author: searchBook.author,
            origin: source.bookSourceUrl
        )
        book.originName = source.bookSourceName
        book.type = searchBook.type
        book.kind = searchBook.kind
        book.coverUrl = searchBook.coverURL
        book.intro = MetadataTextSanitizer().clean(searchBook.intro)
        book.wordCount = searchBook.wordCount
        book.latestChapterTitle = searchBook.latestChapterTitle
        book.tocUrl = searchBook.tocURL
        book.originOrder = searchBook.originOrder
        book.variable = encodeVariables(searchBook.variables)

        guard source.ruleBookInfo != nil else {
            return .init(book: book, diagnostics: [diagnostic(
                code: "detail.configuration", message: "书源缺少详情规则", rule: searchBook.bookURL
            )])
        }
        do {
            let response = try await request(
                searchBook.bookURL, source: source, stage: .detail,
                context: .init(variables: searchBook.variables, source: source, book: book)
            )
            return await analyzeDetail(response: response, book: book, source: source)
        } catch {
            return .init(book: book, diagnostics: [diagnostic(error, stage: "detail", rule: searchBook.bookURL)])
        }
    }

    /// Parse an already fetched page so search/explore redirects use the same
    /// detail rules without issuing a second request or losing request state.
    func analyzeDetail(
        response: HTTPResponse,
        book initialBook: Book,
        source: BookSource,
        context: RuleExecutionContext = .init()
    ) async -> BookDetailReport {
        var book = initialBook
        guard let rules = source.ruleBookInfo else {
            return .init(book: book, diagnostics: [diagnostic(
                code: "detail.configuration", message: "书源缺少详情规则", rule: book.bookUrl
            )])
        }
        var document = PageDocument(response: response)
        var diagnostics: [RuleDiagnostic] = []
        var execution = context
        execution.variables = decodeVariables(book.variable).merging(response.requestVariables) { _, value in value }
            .merging(context.variables) { _, value in value }
        execution.baseURL = response.finalURL.absoluteString
        execution.source = source
        execution.book = book
        if let initialRule = nonempty(rules.`init`) {
            let initial = await evaluate(initialRule, in: document, listMode: true, context: execution)
            diagnostics += initial.diagnostics
            execution.variables = initial.variables
            if let first = initial.values.first {
                document = .init(value: first, baseURL: document.baseURL, isFragment: true)
            }
        }

        // Android treats canReName as an opt-in marker, not a boolean rule.
        // Each field is published before the next rule executes, in Android order.
        let canRename = nonempty(rules.canReName) != nil
        let name = await evaluate(rules.name, in: document, context: execution)
        execution.variables = name.variables
        if canRename || book.name.isEmpty { book.name = nonempty(name.joinedString) ?? book.name }
        execution.book = book
        let author = await evaluate(rules.author, in: document, context: execution)
        execution.variables = author.variables
        if canRename || book.author.isEmpty { book.author = nonempty(author.joinedString) ?? book.author }
        execution.book = book
        let kind = await evaluate(rules.kind, in: document, context: execution)
        execution.variables = kind.variables
        book.kind = nonempty(kind.strings.filter { !$0.isEmpty }.joined(separator: ",")) ?? book.kind
        execution.book = book
        let wordCount = await evaluate(rules.wordCount, in: document, context: execution)
        execution.variables = wordCount.variables
        book.wordCount = nonempty(wordCount.joinedString) ?? book.wordCount
        execution.book = book
        let lastChapter = await evaluate(rules.lastChapter, in: document, context: execution)
        execution.variables = lastChapter.variables
        book.latestChapterTitle = nonempty(lastChapter.joinedString) ?? book.latestChapterTitle
        execution.book = book
        let intro = await evaluate(rules.intro, in: document, context: execution)
        execution.variables = intro.variables
        book.intro = MetadataTextSanitizer().clean(intro.joinedString) ?? book.intro
        execution.book = book
        let cover = await evaluate(rules.coverUrl, in: document, context: execution)
        execution.variables = cover.variables
        if let value = nonempty(cover.joinedString) { book.coverUrl = resolve(value, against: response.finalURL) }
        execution.book = book
        let toc = await evaluate(rules.tocUrl, in: document, context: execution)
        execution.variables = toc.variables
        let tocValue = document.isHTML ? toc.leadingString : toc.joinedString
        let samePageRequest: String? = book.bookUrl.range(of: #",\s*(?=\{)"#, options: .regularExpression).flatMap { range in
            let requestURL = URL(string: String(book.bookUrl[..<range.lowerBound]))
            return requestURL == response.finalURL ? book.bookUrl : nil
        }
        book.tocUrl = nonempty(tocValue).map { resolve($0, against: response.finalURL) }
            ?? nonempty(book.tocUrl)
            ?? samePageRequest
            ?? response.finalURL.absoluteString
        book.variable = encodeVariables(execution.variables)
        diagnostics += [name, author, kind, wordCount, lastChapter, intro, cover, toc].flatMap(\.diagnostics)
        return .init(book: book, diagnostics: diagnostics)
    }

    func analyzeSearchDetail(
        response: HTTPResponse,
        bookURL: String,
        source: BookSource,
        context: RuleExecutionContext
    ) async -> SourceSearchOutcome {
        // An empty list with no detail rules is a legitimate no-result page.
        guard source.ruleBookInfo != nil else { return .init(sourceID: source.id, books: [], diagnostics: []) }
        var seed = Book(bookUrl: bookURL, name: "", origin: source.id)
        seed.originName = source.bookSourceName
        seed.type = source.bookSourceType
        seed.originOrder = source.customOrder
        let detail = await analyzeDetail(response: response, book: seed, source: source, context: context)
        let book = detail.book
        guard !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(sourceID: source.id, books: [], diagnostics: detail.diagnostics)
        }
        var found = SearchBook(bookURL: book.bookUrl, origin: book.origin, originName: book.originName,
                               type: book.type, name: book.name, author: book.author)
        found.kind = book.kind
        found.coverURL = book.coverUrl
        found.intro = book.intro
        found.wordCount = book.wordCount
        found.latestChapterTitle = book.latestChapterTitle
        found.tocURL = book.tocUrl
        found.originOrder = book.originOrder
        found.variable = book.variable
        return .init(sourceID: source.id, books: [found], diagnostics: detail.diagnostics)
    }

    public func prepareUpdate(
        book: Book, source: BookSource, runPreUpdateScript: Bool = true, isFromBookInfo: Bool = false
    ) async -> BookDetailReport {
        do {
            try Task.checkCancellation()
            // Shelf refresh fills a missing TOC from details, and does not run
            // preUpdateJs a second time on that freshly obtained detail page.
            if !isFromBookInfo, nonempty(book.tocUrl) == nil {
                return try await refreshBookDetails(book: book, source: source, canRename: true)
            }
            guard runPreUpdateScript, let script = nonempty(source.ruleToc?.preUpdateJs) else {
                return .init(book: book)
            }
            let operations = BookUpdateScriptOperations(transport: transport) { current, research in
                try Task.checkCancellation()
                if isFromBookInfo && !research { return current }
                var updated = current
                if research {
                    let searcher = BookSearchService(transport: transport, urlBuilder: urlBuilder, engine: engine,
                                                    networkPolicy: networkPolicy, webViewExecutor: webViewExecutor)
                    let found = await searcher.search(keyword: current.name, page: 1, source: source)
                    try Task.checkCancellation()
                    guard let match = found.books.first(where: { $0.name == current.name && $0.author == current.author }) else {
                        throw RuleEngineError.invalidInput(rule: script, expected: "未搜索到 \(current.name)(\(current.author)) 书籍")
                    }
                    updated.bookUrl = match.bookURL
                    updated.variable = encodeVariables(decodeVariables(current.variable).merging(match.variables) { _, value in value })
                }
                return try await refreshBookDetails(book: updated, source: source, canRename: false).book
            }
            let updated = try await withTaskCancellationHandler {
                try await JavaScriptRuleEvaluator(networkLoader: operations).evaluateBookUpdateAsync(
                    script: script, book: book, source: source, refresher: operations
                )
            } onCancel: { operations.cancel() }
            try Task.checkCancellation()
            guard nonempty(updated.bookUrl) != nil else {
                throw RuleEngineError.invalidInput(rule: script, expected: "更新前脚本返回了空书籍地址")
            }
            return .init(book: updated)
        } catch is CancellationError {
            return .init(book: book, diagnostics: [diagnostic(code: "toc.cancelled", message: "目录更新准备已取消", rule: book.bookUrl)])
        } catch let error as BookUpdatePreparationError {
            if Task.isCancelled {
                return .init(book: book, diagnostics: [diagnostic(code: "toc.cancelled", message: "目录更新准备已取消", rule: book.bookUrl)])
            }
            return .init(book: book, diagnostics: error.diagnostics)
        } catch {
            if Task.isCancelled {
                return .init(book: book, diagnostics: [diagnostic(code: "toc.cancelled", message: "目录更新准备已取消", rule: book.bookUrl)])
            }
            return .init(book: book, diagnostics: [diagnostic(code: "toc.pre_update", message: error.localizedDescription,
                                                            rule: source.ruleToc?.preUpdateJs ?? book.bookUrl)])
        }
    }

    private func refreshBookDetails(book: Book, source: BookSource, canRename: Bool) async throws -> BookDetailReport {
        try Task.checkCancellation()
        guard source.ruleBookInfo != nil else {
            var updated = book
            if nonempty(updated.tocUrl) == nil { updated.tocUrl = updated.bookUrl }
            return .init(book: updated)
        }
        let response = try await request(book.bookUrl, source: source, stage: .detail,
                                         context: .init(variables: decodeVariables(book.variable), source: source, book: book))
        try Task.checkCancellation()
        var effectiveSource = source
        if !canRename { effectiveSource.ruleBookInfo?.canReName = nil }
        // An explicit refresh must replace a rotating TOC address, even when
        // the new detail rule falls back to the detail page itself.
        var initial = book
        initial.tocUrl = ""
        let report = await analyzeDetail(response: response, book: initial, source: effectiveSource)
        try Task.checkCancellation()
        if report.diagnostics.contains(where: { $0.severity == .error }) {
            throw BookUpdatePreparationError(diagnostics: report.diagnostics)
        }
        return report
    }

    public func loadChapters(
        book: Book,
        source: BookSource,
        maxPages: Int = 20
    ) async -> ChapterListReport {
        guard let rules = source.ruleToc,
              var listRule = nonempty(rules.chapterList) else {
            return .init(chapters: [], diagnostics: [diagnostic(
                code: "toc.configuration",
                message: "书源缺少目录列表规则",
                rule: book.tocUrl
            )])
        }
        let reverse = listRule.hasPrefix("-")
        if listRule.hasPrefix("-") || listRule.hasPrefix("+") { listRule.removeFirst() }
        let firstURL = nonempty(book.tocUrl) ?? book.bookUrl
        var queue = [firstURL]
        var visited = Set<String>()
        var requested = Set<String>()
        var chapters: [BookChapter] = []
        var diagnostics: [RuleDiagnostic] = []
        var sharedContext = RuleExecutionContext(
            variables: decodeVariables(book.variable),
            source: source,
            book: book
        )

        while let pageURL = queue.first, visited.count < max(maxPages, 1) {
            queue.removeFirst()
            guard requested.insert(pageURL).inserted else { continue }
            do {
                let response = try await request(
                    pageURL,
                    source: source,
                    stage: .toc,
                    baseURL: URL(string: book.bookUrl),
                    context: .init(variables: sharedContext.variables, source: source, book: book)
                )
                let canonicalURL = response.finalURL.absoluteString
                guard visited.insert(pageIdentity(pageURL, finalURL: canonicalURL)).inserted else { continue }
                let document = PageDocument(response: response)
                var pageContext = sharedContext
                pageContext.variables.merge(response.requestVariables) { _, requestValue in requestValue }
                pageContext.baseURL = document.baseURL
                let list = await evaluate(listRule, in: document, listMode: true, context: pageContext)
                diagnostics += list.diagnostics
                pageContext.variables = list.variables
                for item in list.listItems(rule: listRule) {
                    try Task.checkCancellation()
                    let fragment = PageDocument(value: item, baseURL: document.baseURL, isFragment: true)
                    var itemContext = pageContext
                    var chapter = BookChapter(url: "", title: "", bookUrl: book.bookUrl, index: 0)
                    chapter.baseUrl = canonicalURL
                    itemContext.chapter = chapter
                    let name = await evaluate(rules.chapterName, in: fragment, context: itemContext)
                    itemContext.variables = name.variables
                    chapter.title = name.joinedString ?? ""
                    itemContext.chapter = chapter
                    let url = await evaluate(rules.chapterUrl, in: fragment, context: itemContext)
                    itemContext.variables = url.variables
                    chapter.url = (fragment.isHTML ? url.leadingString : url.joinedString) ?? ""
                    itemContext.chapter = chapter
                    let info = await evaluate(rules.updateTime, in: fragment, context: itemContext)
                    itemContext.variables = info.variables
                    let volume = await evaluate(rules.isVolume, in: fragment, context: itemContext)
                    itemContext.variables = volume.variables
                    chapter.isVolume = truthy(volume.joinedString)
                    chapter.tag = nonempty(info.joinedString)
                    if nonempty(chapter.url) == nil {
                        chapter.url = chapter.isVolume ? "#volume-\(chapters.count)" : canonicalURL
                    }
                    itemContext.chapter = chapter
                    let vip = await evaluate(rules.isVip, in: fragment, context: itemContext)
                    itemContext.variables = vip.variables
                    chapter.isVip = truthy(vip.joinedString)
                    itemContext.chapter = chapter
                    let pay = await evaluate(rules.isPay, in: fragment, context: itemContext)
                    itemContext.variables = pay.variables
                    diagnostics += [name, url, volume, vip, pay, info].flatMap(\.diagnostics)
                    guard nonempty(chapter.title) != nil else { continue }
                    chapter.url = resolve(chapter.url, against: response.finalURL)
                    chapter.isPay = truthy(pay.joinedString)
                    chapter.variable = encodeVariables(itemContext.variables)
                    chapters.append(chapter)
                }
                let next = await evaluate(rules.nextTocUrl, in: document, context: pageContext)
                diagnostics += next.diagnostics
                sharedContext.variables = next.variables
                for value in next.strings where !value.isEmpty {
                    let absolute = resolve(value, against: response.finalURL)
                    if !requested.contains(absolute), !queue.contains(absolute) { queue.append(absolute) }
                }
            } catch is CancellationError {
                diagnostics.append(diagnostic(code: "toc.cancelled", message: "目录加载已取消", rule: pageURL))
                break
            } catch {
                diagnostics.append(diagnostic(error, stage: "toc", rule: pageURL))
            }
        }

        if !queue.isEmpty, visited.count >= max(maxPages, 1) {
            diagnostics.append(diagnostic(code: "toc.page_limit", message: "目录超过分页上限，未能完整加载，请调整书源分页规则。", rule: firstURL))
        }
        // Deduplicate from the end of the logical reading order, as Android's
        // reverse -> LinkedHashSet -> reverse sequence does. Overlapping TOC
        // pages can contain a stale title/VIP status for the same chapter URL.
        if !reverse { chapters.reverse() }
        var unique = Set<String>()
        chapters = chapters.filter { unique.insert($0.url).inserted }
        if book.readConfig?.reverseToc != true { chapters.reverse() }
        for index in chapters.indices { chapters[index].index = index }
        if let script = nonempty(rules.formatJs), !chapters.isEmpty {
            do {
                let formatted = try await JavaScriptRuleEvaluator().formatChapterTitles(script: script, chapters: chapters)
                chapters = formatted.chapters
                diagnostics += formatted.diagnostics
            } catch is CancellationError {
                diagnostics.append(diagnostic(code: "toc.cancelled", message: "目录加载已取消", rule: firstURL))
            } catch {
                diagnostics.append(.init(severity: .warning, code: "toc.format", message: error.localizedDescription, rule: script))
            }
        }
        if chapters.isEmpty {
            diagnostics.append(diagnostic(code: "toc.empty", message: "目录规则未解析到章节", rule: listRule))
        }
        return .init(chapters: chapters, diagnostics: diagnostics, pagesVisited: visited.count)
    }

    public func loadContent(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil,
        maxPages: Int = 20
    ) async -> ChapterContentReport {
        if chapter.isVolume, chapter.url.hasPrefix(chapter.title) {
            return .init(content: chapter.tag ?? "")
        }
        guard let rules = source.ruleContent,
              let contentRule = nonempty(rules.content) else {
            return .init(diagnostics: [diagnostic(
                code: source.bookSourceType == 1 ? "content.media_unsupported" : "content.configuration",
                message: source.bookSourceType == 1 ? "此书源直接返回音频章节地址，当前阅读器尚不支持音频播放。" : "书源缺少正文规则",
                rule: chapter.url
            )])
        }
        var queue = [chapter.url]
        var visited = Set<String>()
        var requested = Set<String>()
        var contents: [String] = []
        var supplemental: String?
        var title: String?
        var firstDocument: PageDocument?
        var diagnostics: [RuleDiagnostic] = []
        var contentVariables = decodeVariables(book.variable)
        contentVariables.merge(decodeVariables(chapter.variable)) { _, chapterValue in chapterValue }
        let stopURL = nextChapterURL.map { value in
            URL(string: chapter.baseUrl).map { resolve(value, against: $0) } ?? value
        }

        while let pageURL = queue.first, visited.count < max(maxPages, 1) {
            queue.removeFirst()
            guard pageURL != stopURL, requested.insert(pageURL).inserted else { continue }
            do {
                let response = try await request(
                    pageURL,
                    source: source,
                    stage: .content,
                    baseURL: URL(string: chapter.baseUrl),
                    context: .init(
                        variables: contentVariables,
                        source: source,
                        book: book,
                        chapter: chapter
                    ),
                    contentRules: rules
                )
                let canonicalURL = response.finalURL.absoluteString
                guard canonicalURL != stopURL,
                      visited.insert(pageIdentity(pageURL, finalURL: canonicalURL)).inserted else { continue }
                let document = PageDocument(response: response)
                if firstDocument == nil { firstDocument = document }
                var execution = RuleExecutionContext(
                    variables: contentVariables.merging(response.requestVariables) { _, requestValue in requestValue },
                    baseURL: canonicalURL,
                    source: source,
                    book: book,
                    chapter: chapter
                )
                let content = await evaluate(contentRule, in: document, context: execution)
                diagnostics += content.diagnostics
                execution.variables = content.variables
                contentVariables = execution.variables
                var pageContent = content.strings.filter { !$0.isEmpty }.joined(separator: "\n")
                pageContent = ChapterImageParser().normalize(pageContent, baseURL: response.finalURL,
                    allowBareURLs: source.bookSourceType == 2 || rules.imageStyle?.uppercased() == "FULL")
                if source.bookSourceType == 0 || source.bookSourceType == 2 {
                    pageContent = ChapterHTMLFormatter().format(pageContent, baseURL: response.finalURL)
                }
                if !pageContent.isEmpty { contents.append(pageContent) }
                let next = await evaluate(rules.nextContentUrl, in: document, context: execution)
                diagnostics += next.diagnostics
                contentVariables = next.variables
                for value in next.strings where !value.isEmpty {
                    let absolute = resolve(value, against: response.finalURL)
                    if absolute != stopURL, !requested.contains(absolute), !queue.contains(absolute) {
                        queue.append(absolute)
                    }
                }
            } catch is CancellationError {
                diagnostics.append(diagnostic(code: "content.cancelled", message: "正文加载已取消", rule: pageURL))
                break
            } catch {
                diagnostics.append(diagnostic(error, stage: "content", rule: pageURL))
            }
        }

        if !queue.isEmpty, visited.count >= max(maxPages, 1) {
            diagnostics.append(diagnostic(code: "content.page_limit", message: "正文超过分页上限，未能完整加载，请调整书源分页规则。", rule: chapter.url))
        }
        var execution = RuleExecutionContext(
            variables: contentVariables, baseURL: firstDocument?.baseURL ?? chapter.baseUrl,
            source: source, book: book, chapter: chapter
        )
        if let firstDocument {
            let value = await evaluate(rules.subContent, in: firstDocument, context: execution)
            diagnostics += value.diagnostics
            execution.variables = value.variables
            supplemental = nonempty(value.strings.filter { !$0.isEmpty }.joined(separator: "\n"))
            if source.bookSourceType == 0, let supplemental {
                // Text subContent is part of the chapter, including for whole
                // chapter replacement, reading, caching, TTS and TXT export.
                contents.append(supplemental)
            }
        }
        // Keep this field for media metadata, not a second copy of text.
        if source.bookSourceType == 0 { supplemental = nil }
        var content = contents.joined(separator: "\n")
        if let replacement = nonempty(rules.replaceRegex) {
            let replaced = await engine.evaluate(
                replacement, inText: content,
                context: execution
            )
            diagnostics += replaced.diagnostics
            execution.variables = replaced.variables
            if !replaced.diagnostics.contains(where: { $0.severity == .error }) {
                content = replaced.strings.joined(separator: "\n")
            }
        }
        if let firstDocument {
            let value = await evaluate(rules.title, in: firstDocument, context: execution)
            diagnostics += value.diagnostics
            title = nonempty(value.joinedString)
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chapter.isVolume {
            diagnostics.append(diagnostic(code: "content.empty", message: "正文规则未解析到内容", rule: contentRule))
        }
        return .init(
            title: title,
            content: content,
            supplementalContent: supplemental,
            diagnostics: diagnostics,
            pagesVisited: visited.count
        )
    }

    private func request(
        _ value: String,
        source: BookSource,
        stage: DifferentialStage,
        baseURL: URL? = nil,
        context: URLTemplateContext? = nil,
        contentRules: ContentRule? = nil
    ) async throws -> HTTPResponse {
        var prepared = try urlBuilder.prepare(
            value,
            context: context ?? .init(source: source),
            baseURL: baseURL ?? URL(string: source.bookSourceUrl),
            defaultHeaders: try BookSourceHeaderResolver().resolve(source)
        )
        if prepared.useWebView {
            if prepared.webJavaScript == nil { prepared.webJavaScript = contentRules?.webJs }
            prepared.sourceRegex = nonempty(contentRules?.sourceRegex)
        }
        let timeout = min(max(Double(source.respondTime) / 1_000, 5), 180)
        return try await networkPolicy.execute(
            prepared,
            source: source,
            transport: transport,
            timeout: timeout,
            webViewExecutor: webViewExecutor,
            snapshotRecorder: snapshotRecorder,
            snapshotStage: stage
        )
    }

    private func evaluate(
        _ rule: String?,
        in document: PageDocument,
        listMode: Bool = false,
        context: RuleExecutionContext = .init()
    ) async -> RuleEvaluation {
        guard let rule = nonempty(rule) else { return .init(variables: context.variables) }
        var context = context
        context.isHTMLFragment = document.isFragment
        if document.isHTML {
            return await engine.evaluate(
                rule,
                inText: document.value.stringValue,
                baseURL: document.baseURL,
                listMode: listMode,
                context: context
            )
        }
        return await engine.evaluate(rule, in: document.value, listMode: listMode, context: context)
    }

    private func resolve(_ value: String, against baseURL: URL) -> String {
        LegadoURLBuilder.resolve(value, against: baseURL)
    }

    private func pageIdentity(_ request: String, finalURL: String) -> String {
        guard let range = request.range(of: #",\s*(?=\{)"#, options: .regularExpression) else { return finalURL }
        return finalURL + request[range.lowerBound...]
    }

    private func truthy(_ value: String?) -> Bool {
        // StringExtensions.isTrue: selector text/attributes are true unless
        // blank, the null sentinel, or one of Android's explicit false values.
        guard let value, value != "null" else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !["false", "no", "not", "0", "0.0"].contains(trimmed.lowercased())
    }

    private func encodeVariables(_ variables: [String: String]) -> String? {
        guard !variables.isEmpty,
              let data = try? JSONEncoder().encode(variables) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeVariables(_ source: String?) -> [String: String] {
        guard let source, let data = source.data(using: .utf8),
              let variables = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return variables
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func diagnostic(_ error: Error, stage: String, rule: String) -> RuleDiagnostic {
        if let error = error as? RuleEngineError { return error.diagnostic }
        return diagnostic(code: "\(stage).request", message: error.localizedDescription, rule: rule)
    }

    private func diagnostic(code: String, message: String, rule: String) -> RuleDiagnostic {
        .init(severity: .error, code: code, message: message, rule: rule)
    }

    private struct PageDocument: Sendable {
        var value: JSONValue
        var isHTML: Bool
        var baseURL: String
        var isFragment = false

        init(response: HTTPResponse) {
            if let json = response.decodedJSON {
                value = json
                isHTML = false
            } else {
                value = .string(response.decodedText)
                isHTML = true
            }
            baseURL = response.finalURL.absoluteString
        }

        init(value: JSONValue, baseURL: String, isFragment: Bool = false) {
            self.value = value
            if case .string = value { self.isHTML = true }
            else { self.isHTML = false }
            self.baseURL = baseURL
            self.isFragment = isFragment
        }
    }
}
