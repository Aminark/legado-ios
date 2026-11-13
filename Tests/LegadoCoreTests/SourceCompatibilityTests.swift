import Foundation
import Testing
@testable import LegadoCore

private struct CompatibilityTransport: HTTPTransport {
    let pages: [String: String]

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let page = try #require(pages[url.absoluteString], "Unexpected URL: \(url)")
        if url.path == "/book/42" {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Token") == "token")
            #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "id=42")
        }
        return .init(data: Data(page.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

private struct PostPaginationTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        #expect(request.httpMethod == "POST")
        let second = request.httpBody == Data("page=2".utf8)
        let page = second ? "2" : "1"
        let next = second ? "" : #"/pages,{"method":"POST","body":"page=2"}"#
        let data = try JSONSerialization.data(withJSONObject: [
            "chapters": [["name": "第\(page)章", "url": "/chapter/\(page)"]],
            "content": "第\(page)段", "next": next
        ])
        return .init(data: data, statusCode: 200, headers: [:], finalURL: url)
    }
}

struct SourceCompatibilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_LIVE_READABILITY_AUDIT"] != nil))
    func liveSearchResultReadability() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_SOURCE_CATALOG"])
        let imported = try BookSourceImporter().inspect(Data(contentsOf: URL(fileURLWithPath: path)))
        let sources = Dictionary(imported.sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values
            .filter { $0.enabled && $0.bookSourceType == 0 }
        let worker = Task { () -> [SearchBook] in
            var books: [SearchBook] = []
            for await outcome in BookSearchService().searchOutcomes(keyword: "极道天魔", sources: Array(sources)) {
                guard !Task.isCancelled else { break }
                books += outcome.books.filter { $0.name == "极道天魔" && $0.author.contains("滚开") }
                if books.count >= 24 { break }
            }
            return books
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { worker.cancel() }
        }
        let books = await worker.value
        deadline.cancel()
        await withTaskGroup(of: String.self) { group in
            for book in books {
                guard let source = sources.first(where: { $0.id == book.origin }) else { continue }
                group.addTask {
                    let service = NetworkBookService()
                    let detail = await service.loadDetail(searchBook: book, source: source)
                    let toc = await service.loadChapters(book: detail.book, source: source)
                    guard let chapter = toc.chapters.first(where: { !$0.isVolume }) else {
                        return "READABILITY \(source.bookSourceName): no directory; \((detail.diagnostics + toc.diagnostics).map(\.code))"
                    }
                    let body = await service.loadContent(book: detail.book, chapter: chapter, source: source,
                                                         nextChapterURL: toc.chapters.dropFirst(chapter.index + 1).first(where: { !$0.isVolume })?.url)
                    let errors = body.diagnostics.filter { $0.severity == .error }.map { "\($0.code): \($0.message)" }
                    return "READABILITY \(source.bookSourceName): \(toc.chapters.count) chapters, \(body.content.count) characters; \(errors)"
                }
            }
            for await result in group { print(result) }
        }
        print("READABILITY audited \(books.count) search results")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SEARCH_BENCHMARK"] != nil))
    func liveMultiSourceSearchLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["LEGADO_SOURCE_CATALOG"])
        let decoded = try BookSourceImporter().inspect(Data(contentsOf: URL(fileURLWithPath: path)))
        let sources = Dictionary(decoded.sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            .values.sorted { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending }
        let started = ContinuousClock.now
        let worker = Task { () -> [String: Double] in
            var times: [String: Double] = [:]
            var completed = 0
            for await outcome in BookSearchService().searchOutcomes(keyword: "极道天魔", sources: sources) {
                guard !Task.isCancelled else { break }
                completed += 1
                let elapsed = started.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if !outcome.books.isEmpty, times["firstResultSeconds"] == nil {
                    times["firstResultSeconds"] = seconds
                    print("Search benchmark first result: \(seconds)s, \(outcome.sourceID)")
                }
                if outcome.books.contains(where: { $0.name == "极道天魔" && $0.author == "滚开" }) {
                    times["firstExactSeconds"] = seconds
                    print("Search benchmark exact result: \(seconds)s, \(outcome.sourceID)")
                    break
                }
            }
            times["completedSources"] = Double(completed)
            times["totalSources"] = Double(sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }.count)
            return times
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { worker.cancel() }
        }
        let measurements = await worker.value
        deadline.cancel()
        print("Search benchmark: \(measurements)")
        if let output = environment["LEGADO_SEARCH_BENCHMARK_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    @Test func qqArrayContentBecomesParagraphsWithoutOptionalCleanupRule() async throws {
        var source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "JSON 正文")
        var rule = ContentRule()
        rule.content = "<p>{{$.data.Content[0].Content}}</p>"
        source.ruleContent = rule
        let transport = CompatibilityTransport(pages: [
            "https://fixture.test/chapter/1": #"{"data":{"Content":[{"Content":["第一段\r\n  第二段","<p>第三段</p><img src='/image.jpg'>"]}]}}"#
        ])
        let book = Book(bookUrl: "https://fixture.test/book", name: "测试", origin: source.id)
        let chapter = BookChapter(url: "https://fixture.test/chapter/1", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let report = await NetworkBookService(transport: transport).loadContent(book: book, chapter: chapter, source: source)
        #expect(report.diagnostics.isEmpty)
        #expect(report.content == "第一段\n第二段\n第三段\n<img src=\"https://fixture.test/image.jpg\">")
    }

    @Test func paginatedPostRequestsToSameEndpointAreDistinctPages() async throws {
        var source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "POST 分页")
        var tocRule = TocRule()
        tocRule.chapterList = "$.chapters"
        tocRule.chapterName = "$.name"
        tocRule.chapterUrl = "$.url"
        tocRule.nextTocUrl = "$.next"
        source.ruleToc = tocRule
        var contentRule = ContentRule()
        contentRule.content = "$.content"
        contentRule.nextContentUrl = "$.next"
        source.ruleContent = contentRule
        var book = Book(bookUrl: "https://fixture.test/book", name: "测试", origin: source.id)
        book.tocUrl = #"https://fixture.test/pages,{"method":"POST","body":"page=1"}"#
        let service = NetworkBookService(transport: PostPaginationTransport())
        let toc = await service.loadChapters(book: book, source: source)
        #expect(toc.diagnostics.isEmpty)
        #expect(toc.chapters.map(\.title) == ["第1章", "第2章"])
        #expect(toc.pagesVisited == 2)
        let chapter = BookChapter(url: book.tocUrl, title: "第一章", bookUrl: book.bookUrl, index: 0)
        let content = await service.loadContent(book: book, chapter: chapter, source: source)
        #expect(content.diagnostics.isEmpty)
        #expect(content.content == "第1段\n第2段")
        #expect(content.pagesVisited == 2)
    }

    @Test func responseHonorsLegacyHTMLCharsetWithoutRequestOverride() throws {
        let encoding = try #require(HTTPTextDecoder.encoding(named: "gbk"))
        let html = "<meta http-equiv='Content-Type' content='text/html; charset=gbk'><h1>中文正文</h1>"
        let data = try #require(html.data(using: encoding))
        let response = HTTPResponse(data: data, statusCode: 200, headers: [:], finalURL: URL(string: "https://fixture.test")!)
        #expect(response.decodedText == html)
    }

    @Test func tableSearchCarriesRequestOptionsThroughDetailTocAndContent() async throws {
        let transport = CompatibilityTransport(pages: [
            "https://fixture.test/search": "<table class='grid'><tr><th>书名</th></tr><tr><td><a href='/42'>测试书</a></td><td>作者</td></tr></table>",
            "https://fixture.test/book/42": "<h1>测试书详情</h1><a class='toc' href='/toc'>目录</a>",
            "https://fixture.test/toc": "<div id='list'><a href='/chapter/1'>第一章</a><a href='/chapter/2'>第二章</a></div>",
            "https://fixture.test/chapter/1": "<div class='body'><p>真正正文</p><p>广告</p></div>"
        ])
        var source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "传统表格源")
        source.searchUrl = "/search"
        source.ruleSearch = .init(
            bookList: "class.grid@tag.tr!0", name: "tag.td.0@text", author: "tag.td.1@text",
            bookUrl: #"@js:'/book/42,{"method":"POST","headers":{"X-Token":"token"},"body":"id=42"}'"#,
            coverUrl: "@js:book.origin + '/cover/' + key + '-' + page + '.jpg'"
        )
        var info = BookInfoRule()
        info.name = "tag.h1@text"
        info.canReName = "true"
        info.tocUrl = "class.toc@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "id.list@tag.a"
        toc.chapterName = "text"
        toc.chapterUrl = "href"
        source.ruleToc = toc
        var content = ContentRule()
        content.content = "<js>result</js>class.body@html"
        content.replaceRegex = "##广告##"
        source.ruleContent = content

        let search = await BookSearchService(transport: transport).search(keyword: "test", page: 2, source: source)
        #expect(search.diagnostics.isEmpty)
        let found = try #require(search.books.first)
        #expect(found.name == "测试书")
        #expect(found.author == "作者")
        #expect(found.coverURL == "https://fixture.test/cover/test-2.jpg")
        #expect(found.bookURL.contains(#",{"method":"POST""#))
        let service = NetworkBookService(transport: transport)
        let detail = await service.loadDetail(searchBook: found, source: source)
        #expect(detail.diagnostics.isEmpty)
        #expect(detail.book.name == "测试书详情")
        let chapters = await service.loadChapters(book: detail.book, source: source)
        #expect(chapters.diagnostics.isEmpty)
        #expect(chapters.chapters.map(\.title) == ["第一章", "第二章"])
        let chapter = try #require(chapters.chapters.first)
        let body = await service.loadContent(book: detail.book, chapter: chapter, source: source)
        #expect(body.diagnostics.isEmpty)
        #expect(body.content.trimmingCharacters(in: .whitespacesAndNewlines) == "真正正文")
    }

    @Test func syntheticHTMLRulesExtractBareTocFieldsAndCleanContent() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "synthetic-html-rules", withExtension: "json", subdirectory: "Fixtures"))
        let source = try #require(BookSourceImporter().decode(Data(contentsOf: fixture)).first)
        let transport = CompatibilityTransport(pages: [
            "https://fixture.invalid/toc": "<div id='chapter-list'><ul><li><a href='/chapter/2'>第二章</a></li><li><a href='/chapter/1'>第一章 新开端</a></li></ul></div>",
            "https://fixture.invalid/chapter/1": "<div class='chapter-body'><h1>第一章</h1><p>信息</p><p>第一章 新开端</p><p>真正正文</p><p>(本章完)</p></div>"
        ])
        var book = Book(bookUrl: "https://fixture.invalid/book/1", name: "测试", origin: source.id)
        book.tocUrl = "https://fixture.invalid/toc"
        book.durChapterTitle = "第一章 新开端"
        let service = NetworkBookService(transport: transport)
        let toc = await service.loadChapters(book: book, source: source)
        #expect(toc.diagnostics.isEmpty)
        #expect(toc.chapters.map(\.title) == ["第一章 新开端", "第二章"])
        let first = try #require(toc.chapters.first)
        let content = await service.loadContent(book: book, chapter: first, source: source)
        #expect(content.diagnostics.isEmpty)
        #expect(content.content.trimmingCharacters(in: .whitespacesAndNewlines) == "真正正文")
    }

    @Test func searchUsesJavaScriptObjectsAndKeepsRegexCaptureRows() async throws {
        let transport = CompatibilityTransport(pages: ["https://fixture.test/search": "name=甲;url=/a\nname=乙;url=/b"])
        var source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "转换源")
        source.searchUrl = "/search"
        source.ruleSearch = .init(bookList: #":name=([^;]+);url=([^\n]+)"#, name: "$1", bookUrl: "$2")
        let regex = await BookSearchService(transport: transport).search(keyword: "甲", page: 1, source: source)
        #expect(regex.diagnostics.isEmpty)
        #expect(regex.books.map(\.name) == ["甲", "乙"])
        #expect(regex.books.map(\.bookURL) == ["https://fixture.test/a", "https://fixture.test/b"])

        source.ruleSearch = .init(bookList: "<js>[{name: '对象结果', url: '/object'}]</js>", name: "name", bookUrl: "url")
        let objects = await BookSearchService(transport: transport).search(keyword: "甲", page: 1, source: source)
        #expect(objects.diagnostics.isEmpty)
        #expect(objects.books.first?.name == "对象结果")
        #expect(objects.books.first?.bookURL == "https://fixture.test/object")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SOURCE_CATALOG"] != nil))
    func inspectsDownloadedCatalog() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_SOURCE_CATALOG"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try BookSourceImporter().inspect(data)
        let raw = try JSONDecoder().decode([JSONValue].self, from: data)
        #expect(result.sources.count + result.rejected.count == raw.count)
        #expect(!result.sources.isEmpty)
        print("Catalog import: \(result.sources.count) valid, \(result.rejected.count) rejected of \(raw.count)")
        for item in result.rejected.prefix(10) {
            print("Rejected: \(item.source.bookSourceName): \(item.issues.map(\.message).joined(separator: "; "))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_LIVE_SOURCE_ID"] != nil))
    func liveSearchToReading() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["LEGADO_SOURCE_CATALOG"])
        let sourceID = try #require(environment["LEGADO_LIVE_SOURCE_ID"])
        let catalog = try BookSourceImporter().inspect(Data(contentsOf: URL(fileURLWithPath: path)))
        let source = try #require(catalog.sources.last { $0.id == sourceID })
        let search = await BookSearchService().search(keyword: "极道天魔", page: 1, source: source)
        for issue in search.diagnostics { print("Live search diagnostic: \(issue.code): \(issue.message)") }
        print("Live search: \(search.books.count) books")
        let found = try #require(search.books.first { $0.name == "极道天魔" && $0.author == "滚开" })
        let service = NetworkBookService()
        let detail = await service.loadDetail(searchBook: found, source: source)
        #expect(detail.book.name == "极道天魔")
        let toc = await service.loadChapters(book: detail.book, source: source)
        #expect(toc.chapters.count > 2)
        for chapter in toc.chapters.prefix(2) {
            let body = await service.loadContent(book: detail.book, chapter: chapter, source: source)
            for issue in body.diagnostics { print("Live content diagnostic: \(issue.code): \(issue.message)") }
            print("Live content shape: numeric=\(body.content.prefix(100).allSatisfy { $0.isNumber || $0 == "," || $0 == "-" }), escapedNewlines=\(body.content.contains(#"\n"#)), paragraphs=\(body.content.components(separatedBy: "\n").count)")
            #expect(body.content.count > 500)
            #expect(!body.content.contains("<p>"))
            #expect(!body.content.contains(#"\r\n"#))
            #expect(body.content.components(separatedBy: "\n").count > 5)
            #expect(!body.diagnostics.contains { $0.severity == .error })
            print("Live reading: \(source.bookSourceName), \(chapter.title), \(body.content.count) characters")
        }
        for issue in detail.diagnostics + toc.diagnostics {
            print("Live diagnostic: \(issue.code): \(issue.message)")
        }
        print("Live directory: \(toc.chapters.count) chapters")
        if let replacementID = environment["LEGADO_LIVE_SWITCH_SOURCE_ID"] {
            let replacementSource = try #require(catalog.sources.last { $0.id == replacementID })
            var current = detail.book
            current.totalChapterNum = toc.chapters.count
            current.durChapterIndex = 1
            current.durChapterTitle = toc.chapters[1].title
            current.durChapterPos = 120
            let switcher = BookSourceSwitchService()
            let candidates = await switcher.candidates(for: current, sources: [source, replacementSource])
            let candidate = try #require(candidates.first { $0.book.author == "滚开" })
            let switched = try #require(await switcher.prepareSwitch(current: current, candidate: candidate.book, source: replacementSource))
            #expect(switched.book.origin == replacementID)
            #expect(switched.exactChapterMatch)
            #expect(switched.book.durChapterPos == 120)
            let chapter = switched.chapters[switched.book.durChapterIndex]
            let body = await service.loadContent(book: switched.book, chapter: chapter, source: replacementSource)
            #expect(body.content.count > 500)
            #expect(!body.diagnostics.contains { $0.severity == .error })
            print("Live switched reading: \(replacementSource.bookSourceName), \(chapter.title), \(body.content.count) characters, position \(switched.book.durChapterPos)")
        }
    }
}
