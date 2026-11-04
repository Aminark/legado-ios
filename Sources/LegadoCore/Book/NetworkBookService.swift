import Foundation

public struct BookDetailReport: Sendable {
    public var book: Book
    public var diagnostics: [RuleDiagnostic]

    public init(book: Book, diagnostics: [RuleDiagnostic] = []) {
        self.book = book
        self.diagnostics = diagnostics
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

public struct ChapterContentReport: Codable, Sendable {
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

        guard let rules = source.ruleBookInfo else {
            return .init(book: book, diagnostics: [diagnostic(
                code: "detail.configuration",
                message: "书源缺少详情规则",
                rule: searchBook.bookURL
            )])
        }

        do {
            let response = try await request(
                searchBook.bookURL,
                source: source,
                stage: .detail,
                context: .init(variables: searchBook.variables, source: source, book: book)
            )
            var document = PageDocument(response: response)
            var diagnostics: [RuleDiagnostic] = []
            var execution = RuleExecutionContext(
                variables: searchBook.variables.merging(response.requestVariables) { _, requestValue in requestValue },
                baseURL: response.finalURL.absoluteString,
                source: source,
                book: book
            )
            if let initialRule = rules.`init`, !initialRule.isEmpty {
                let initial = await evaluate(initialRule, in: document, listMode: true, context: execution)
                diagnostics += initial.diagnostics
                execution.variables = initial.variables
                if let first = initial.values.first {
                    document = .init(value: first, baseURL: document.baseURL, isFragment: true)
                }
            }

            let name = await evaluate(rules.name, in: document, context: execution)
            execution.variables = name.variables
            let author = await evaluate(rules.author, in: document, context: execution)
            execution.variables = author.variables
            let kind = await evaluate(rules.kind, in: document, context: execution)
            execution.variables = kind.variables
            let intro = await evaluate(rules.intro, in: document, context: execution)
            execution.variables = intro.variables
            let lastChapter = await evaluate(rules.lastChapter, in: document, context: execution)
            execution.variables = lastChapter.variables
            let cover = await evaluate(rules.coverUrl, in: document, context: execution)
            execution.variables = cover.variables
            let toc = await evaluate(rules.tocUrl, in: document, context: execution)
            execution.variables = toc.variables
            let wordCount = await evaluate(rules.wordCount, in: document, context: execution)
            execution.variables = wordCount.variables
            let evaluations = [name, author, kind, intro, lastChapter, cover, toc, wordCount]
            diagnostics += evaluations.flatMap(\.diagnostics)

            book.name = nonempty(name.joinedString) ?? book.name
            book.author = nonempty(author.joinedString) ?? book.author
            book.kind = nonempty(kind.strings.filter { !$0.isEmpty }.joined(separator: ",")) ?? book.kind
            book.intro = MetadataTextSanitizer().clean(intro.joinedString) ?? book.intro
            book.latestChapterTitle = nonempty(lastChapter.joinedString) ?? book.latestChapterTitle
            book.wordCount = nonempty(wordCount.joinedString) ?? book.wordCount
            if let value = nonempty(cover.joinedString) {
                book.coverUrl = resolve(value, against: response.finalURL)
            }
            let tocValue = document.isHTML ? toc.leadingString : toc.joinedString
            book.tocUrl = nonempty(tocValue).map { resolve($0, against: response.finalURL) }
                ?? nonempty(book.tocUrl)
                ?? response.finalURL.absoluteString
            book.variable = encodeVariables(execution.variables)
            return .init(book: book, diagnostics: diagnostics)
        } catch {
            return .init(book: book, diagnostics: [diagnostic(error, stage: "detail", rule: searchBook.bookURL)])
        }
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
                    let name = await evaluate(rules.chapterName, in: fragment, context: itemContext)
                    itemContext.variables = name.variables
                    let url = await evaluate(rules.chapterUrl, in: fragment, context: itemContext)
                    itemContext.variables = url.variables
                    let volume = await evaluate(rules.isVolume, in: fragment, context: itemContext)
                    itemContext.variables = volume.variables
                    let vip = await evaluate(rules.isVip, in: fragment, context: itemContext)
                    itemContext.variables = vip.variables
                    let pay = await evaluate(rules.isPay, in: fragment, context: itemContext)
                    itemContext.variables = pay.variables
                    let info = await evaluate(rules.updateTime, in: fragment, context: itemContext)
                    itemContext.variables = info.variables
                    diagnostics += [name, url, volume, vip, pay, info].flatMap(\.diagnostics)
                    guard let title = nonempty(name.joinedString) else { continue }
                    let isVolume = truthy(volume.joinedString)
                    let rawURL = nonempty(fragment.isHTML ? url.leadingString : url.joinedString)
                        ?? (isVolume ? "#volume-\(chapters.count)" : canonicalURL)
                    var chapter = BookChapter(
                        url: resolve(rawURL, against: response.finalURL),
                        title: title,
                        bookUrl: book.bookUrl,
                        index: chapters.count
                    )
                    chapter.baseUrl = canonicalURL
                    chapter.isVolume = isVolume
                    chapter.isVip = truthy(vip.joinedString)
                    chapter.isPay = truthy(pay.joinedString)
                    chapter.tag = nonempty(info.joinedString)
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
        if reverse { chapters.reverse() }
        var unique = Set<String>()
        chapters = chapters.filter { unique.insert($0.url).inserted }
        for index in chapters.indices { chapters[index].index = index }
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
        guard let rules = source.ruleContent,
              let contentRule = nonempty(rules.content) else {
            return .init(diagnostics: [diagnostic(
                code: "content.configuration",
                message: "书源缺少正文规则",
                rule: chapter.url
            )])
        }
        var queue = [chapter.url]
        var visited = Set<String>()
        var requested = Set<String>()
        var contents: [String] = []
        var supplemental: String?
        var title: String?
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
                    )
                )
                let canonicalURL = response.finalURL.absoluteString
                guard canonicalURL != stopURL,
                      visited.insert(pageIdentity(pageURL, finalURL: canonicalURL)).inserted else { continue }
                let document = PageDocument(response: response)
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
                if source.bookSourceType == 0 {
                    pageContent = ChapterHTMLFormatter().format(pageContent, baseURL: response.finalURL)
                }
                if !pageContent.isEmpty { contents.append(pageContent) }
                if title == nil {
                    let value = await evaluate(rules.title, in: document, context: execution)
                    diagnostics += value.diagnostics
                    execution.variables = value.variables
                    contentVariables = execution.variables
                    title = nonempty(value.joinedString)
                }
                if supplemental == nil {
                    let value = await evaluate(rules.subContent, in: document, context: execution)
                    diagnostics += value.diagnostics
                    execution.variables = value.variables
                    contentVariables = execution.variables
                    supplemental = nonempty(value.strings.filter { !$0.isEmpty }.joined(separator: "\n"))
                }
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
        var content = contents.joined(separator: "\n")
        if let replacement = nonempty(rules.replaceRegex) {
            let replaced = await engine.evaluate(
                replacement, inText: content,
                context: .init(variables: contentVariables, baseURL: chapter.baseUrl, source: source, book: book, chapter: chapter)
            )
            diagnostics += replaced.diagnostics
            if !replaced.diagnostics.contains(where: { $0.severity == .error }) {
                content = replaced.strings.joined(separator: "\n")
            }
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
        context: URLTemplateContext? = nil
    ) async throws -> HTTPResponse {
        let prepared = try urlBuilder.prepare(
            value,
            context: context ?? .init(source: source),
            baseURL: baseURL ?? URL(string: source.bookSourceUrl),
            defaultHeaders: try BookSourceHeaderResolver().resolve(source)
        )
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
        guard let value else { return false }
        return ["true", "1", "yes", "是", "vip", "paid"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
