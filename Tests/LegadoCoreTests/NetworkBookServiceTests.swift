import Foundation
import Testing
@testable import LegadoCore

private struct BookFlowMockTransport: HTTPTransport {
    let pages: [String: String]

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body = try #require(pages[url.absoluteString], "缺少 mock 页面：\(url.absoluteString)")
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

struct NetworkBookServiceTests {
    @Test(arguments: [
        #"<img alt="x > y" src="/formula~large.png?token=one&amp;size=2">"#,
        #"<IMG alt='x > y' src='/formula~large.png?token=one&amp;size=2' />"#,
        #"<img alt='x > y' data-src='/formula~large.png?token=one&amp;size=2' src='/placeholder.png'>"#
    ]) func chapterImageWithGreaterThanInQuotedAttributeKeepsItsFullSourceURL(image: String) async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/chapter":
            "<p>图片前正文。</p>" + image + "<p>图片后正文。</p>"])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "图片正文")
        var rules = ContentRule()
        // A JS content rule can return raw markup without a selector reserializing it first.
        rules.content = "@js:result"
        source.ruleContent = rules
        let book = Book(bookUrl: base + "/book", name: "书", origin: base)
        let chapter = BookChapter(url: base + "/chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)

        let report = await NetworkBookService(transport: transport).loadContent(book: book, chapter: chapter, source: source)

        #expect(report.diagnostics.isEmpty)
        #expect(report.content == #"图片前正文。"# + "\n" + #"<img src="https://reader.example.test/formula~large.png?token=one&amp;size=2">"# + "\n图片后正文。")
    }

    @Test func reportsPaginationLimitInsteadOfSilentlyAcceptingTruncatedResults() async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [
            base + "/toc": "<li><a href='/chapter'>第一章</a></li><a class='next' href='/toc2'>下一页</a>",
            base + "/chapter": "<article>第一页正文</article><a class='next' href='/chapter2'>下一页</a>"
        ])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "分页源")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        toc.nextTocUrl = "@CSS:a.next@href"
        source.ruleToc = toc
        var content = ContentRule()
        content.content = "@CSS:article@text"
        content.nextContentUrl = "@CSS:a.next@href"
        source.ruleContent = content
        var book = Book(bookUrl: base + "/book", name: "书", origin: base)
        book.tocUrl = base + "/toc"
        let service = NetworkBookService(transport: transport)

        let directory = await service.loadChapters(book: book, source: source, maxPages: 1)
        #expect(directory.chapters.count == 1)
        #expect(directory.diagnostics.contains { $0.severity == .error && $0.code == "toc.page_limit" })
        let body = await service.loadContent(book: book,
            chapter: .init(url: base + "/chapter", title: "第一章", bookUrl: book.bookUrl, index: 0), source: source, maxPages: 1)
        #expect(body.content == "第一页正文")
        #expect(body.diagnostics.contains { $0.severity == .error && $0.code == "content.page_limit" })
    }

    @Test func loadsDetailPaginatedTocAndPaginatedContent() async throws {
        let transport = BookFlowMockTransport(pages: [
            "https://reader.example.test/book/1": """
                <main class="book"><h1>迁移实战</h1><a class="author">作者甲</a>
                <img class="cover" src="/cover.jpg"><p class="intro">一本测试书</p>
                <a class="toc" href="/book/1/toc/1">目录</a></main>
                """,
            "https://reader.example.test/book/1/toc/1": """
                <ul><li class="chapter"><a href="/chapter/1">第一章</a></li></ul>
                <a class="next" href="/book/1/toc/2">下一页</a>
                """,
            "https://reader.example.test/book/1/toc/2": """
                <ul><li class="chapter"><a href="/chapter/2">第二章</a></li></ul>
                """,
            "https://reader.example.test/chapter/1": """
                <h1>第一章 新标题</h1><article><p>第一段</p></article>
                <a class="next" href="/chapter/1?page=2">下一页</a>
                """,
            "https://reader.example.test/chapter/1?page=2": """
                <article><p>第二段</p></article>
                """
        ])
        var source = BookSource(
            bookSourceUrl: "https://reader.example.test",
            bookSourceName: "完整链路源"
        )
        var info = BookInfoRule()
        info.`init` = "@CSS:main.book"
        info.name = "@CSS:h1@text"
        info.author = "@CSS:.author@text"
        info.canReName = "true"
        info.intro = "@CSS:.intro@text"
        info.coverUrl = "@CSS:img.cover@src"
        info.tocUrl = "@CSS:a.toc@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "@CSS:li.chapter"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        toc.nextTocUrl = "@CSS:a.next@href"
        source.ruleToc = toc
        var content = ContentRule()
        content.content = "@CSS:article p@text"
        content.title = "@CSS:h1@text"
        content.nextContentUrl = "@CSS:a.next@href"
        source.ruleContent = content
        let searchBook = SearchBook(
            bookURL: "https://reader.example.test/book/1",
            origin: source.bookSourceUrl,
            originName: source.bookSourceName,
            type: 0,
            name: "搜索结果名"
        )
        let service = NetworkBookService(transport: transport)

        let detail = await service.loadDetail(searchBook: searchBook, source: source)
        #expect(detail.book.name == "迁移实战")
        #expect(detail.book.author == "作者甲")
        #expect(detail.book.coverUrl == "https://reader.example.test/cover.jpg")
        #expect(detail.book.tocUrl == "https://reader.example.test/book/1/toc/1")
        #expect(detail.diagnostics.isEmpty)

        let tocReport = await service.loadChapters(book: detail.book, source: source)
        #expect(tocReport.chapters.map(\.title) == ["第一章", "第二章"])
        #expect(tocReport.chapters.map(\.index) == [0, 1])
        #expect(tocReport.pagesVisited == 2)
        #expect(tocReport.diagnostics.isEmpty)

        let chapter = try #require(tocReport.chapters.first)
        let contentReport = await service.loadContent(
            book: detail.book,
            chapter: chapter,
            source: source,
            nextChapterURL: tocReport.chapters[1].url
        )
        #expect(contentReport.title == "第一章 新标题")
        #expect(contentReport.content == "第一段\n第二段")
        #expect(contentReport.pagesVisited == 2)
        #expect(contentReport.diagnostics.isEmpty)
    }

    @Test func returnsDiagnosticsForEmptyContentAndStopsTocLoops() async throws {
        let transport = BookFlowMockTransport(pages: [
            "https://reader.example.test/toc": """
                <li class="chapter"><a href="/chapter/empty">空章</a></li>
                <a class="next" href="/toc">循环</a>
                """,
            "https://reader.example.test/chapter/empty": "<article></article>"
        ])
        var source = BookSource(bookSourceUrl: "https://reader.example.test", bookSourceName: "诊断源")
        var toc = TocRule()
        toc.chapterList = "@CSS:li.chapter"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        toc.nextTocUrl = "@CSS:a.next@href"
        source.ruleToc = toc
        var content = ContentRule()
        content.content = "@CSS:article@text"
        source.ruleContent = content
        var book = Book(
            bookUrl: "https://reader.example.test/book/empty",
            name: "空书",
            origin: source.bookSourceUrl
        )
        book.tocUrl = "https://reader.example.test/toc"
        let service = NetworkBookService(transport: transport)

        let tocReport = await service.loadChapters(book: book, source: source)
        #expect(tocReport.pagesVisited == 1)
        #expect(tocReport.chapters.count == 1)
        let chapter = try #require(tocReport.chapters.first)
        let contentReport = await service.loadContent(book: book, chapter: chapter, source: source)

        #expect(contentReport.content.isEmpty)
        #expect(contentReport.diagnostics.contains { $0.code == "content.empty" })
    }

    @Test func carriesBookVariablesIntoJavaScriptChapterRules() async throws {
        let transport = BookFlowMockTransport(pages: [
            "https://audio.example.test/toc": #"{"content":{"content":[{"id":2002,"chapterTitle":"第一集"}]}}"#
        ])
        var source = BookSource(bookSourceUrl: "https://audio.example.test", bookSourceName: "变量源")
        var toc = TocRule()
        toc.chapterList = "$.content.content"
        toc.chapterName = "$.chapterTitle"
        toc.chapterUrl = "$.id@js:java.put('chapterId', result); '/audio?bookId=' + java.get('bookId') + '&chapterId=' + result"
        source.ruleToc = toc
        var book = Book(
            bookUrl: "https://audio.example.test/book/1001",
            name: "听书",
            origin: source.bookSourceUrl
        )
        book.tocUrl = "https://audio.example.test/toc"
        book.variable = #"{"bookId":"1001"}"#

        let report = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)

        let chapter = try #require(report.chapters.first)
        #expect(chapter.url == "https://audio.example.test/audio?bookId=1001&chapterId=2002")
        let variables = try JSONDecoder().decode(
            [String: String].self,
            from: Data(try #require(chapter.variable).utf8)
        )
        #expect(variables["bookId"] == "1001")
        #expect(variables["chapterId"] == "2002")
        #expect(report.diagnostics.isEmpty)
    }

    @Test(arguments: [nil, "", " ", "false", "true"] as [String?])
    func detailOnlyRenamesExistingMetadataWhenOptedIn(marker: String?) async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/book": "<h1>详情书名</h1><p>详情作者</p>"])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "改名规则")
        var info = BookInfoRule()
        info.name = "@CSS:h1@text"
        info.author = "@CSS:p@text"
        info.canReName = marker
        source.ruleBookInfo = info
        var search = SearchBook(bookURL: base + "/book", origin: base, originName: source.bookSourceName,
                                type: 0, name: "搜索书名", author: "搜索作者")
        let service = NetworkBookService(transport: transport)
        let kept = await service.loadDetail(searchBook: search, source: source)
        let rename = marker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        #expect(kept.book.name == (rename ? "详情书名" : "搜索书名"))
        #expect(kept.book.author == (rename ? "详情作者" : "搜索作者"))
        #expect(kept.diagnostics.isEmpty)

        search.name = ""
        search.author = ""
        let filled = await service.loadDetail(searchBook: search, source: source)
        #expect(filled.book.name == "详情书名")
        #expect(filled.book.author == "详情作者")
    }

    @Test(arguments: [false, true], [false, true])
    func tocDeduplicatesAndOrdersLikeAndroid(reversedRule: Bool, reversedBook: Bool) async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/toc": """
            <li><a href='/one'>旧第一章</a></li>
            <li><a href='/two'>第二章</a></li>
            <li><a href='/one'>新第一章</a></li>
            <li><a href='/three'>第三章</a></li>
            """])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "目录顺序")
        var toc = TocRule()
        toc.chapterList = (reversedRule ? "-" : "+") + "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        source.ruleToc = toc
        var book = Book(bookUrl: base + "/book", name: "书", origin: base)
        book.tocUrl = base + "/toc"
        book.readConfig = .init()
        book.readConfig?.reverseToc = reversedBook
        let report = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)

        var expected = reversedRule ? ["旧第一章", "第二章", "第三章"] : ["第三章", "新第一章", "第二章"]
        if !reversedBook { expected.reverse() }
        #expect(report.chapters.map(\.title) == expected)
        #expect(report.chapters.map(\.index) == [0, 1, 2])
        #expect(report.diagnostics.isEmpty)
    }

    @Test func tocFlagsAcceptSelectorTextAndRejectAndroidFalseValues() async {
        let base = "https://reader.example.test"
        let trueValues = ["VIP章节", "volume", "已购买", "2", "TRUE"]
        let falseValues = ["", "null", " false ", "NO", "not", "0", "0.0"]
        let rows = (trueValues + falseValues).enumerated().map { index, value in
            "<li data-flag='\(value)'><a href='/chapter/\(index)'>章节\(index)</a></li>"
        }.joined()
        let transport = BookFlowMockTransport(pages: [base + "/toc": rows])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "目录标志")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        toc.isVolume = "data-flag"
        toc.isVip = "data-flag"
        toc.isPay = "data-flag"
        source.ruleToc = toc
        var book = Book(bookUrl: base + "/book", name: "书", origin: base)
        book.tocUrl = base + "/toc"
        let report = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)
        let expected = Array(repeating: true, count: trueValues.count) + Array(repeating: false, count: falseValues.count)
        #expect(report.chapters.map(\.isVolume) == expected)
        #expect(report.chapters.map(\.isVip) == expected)
        #expect(report.chapters.map(\.isPay) == expected)
        #expect(report.diagnostics.isEmpty)
    }

    @Test func formatsTitlesAfterDeduplicationWithSharedStateAndKeepsFailuresReadable() async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/toc": """
            <li><a href='/one'>旧第一章</a></li><li><a href='/one'>第一章</a></li>
            <li><a href='/two'>第二章</a></li><li><a href='/three'>第三章</a></li>
            """])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "标题处理")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        toc.formatJs = "gInt += 10; if (index === 2) throw new Error('bad title'); title + ':' + index + ':' + chapter.getIndex() + ':' + gInt"
        source.ruleToc = toc
        var book = Book(bookUrl: base + "/book", name: "书", origin: base)
        book.tocUrl = base + "/toc"
        let report = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)
        #expect(report.chapters.map(\.title) == ["第一章:1:0:10", "第二章", "第三章:3:2:30"])
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics.first?.code == "toc.format")
        #expect(report.diagnostics.first?.severity == .warning)

        toc.formatJs = "null"
        source.ruleToc = toc
        let unchanged = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)
        #expect(unchanged.chapters.map(\.title) == ["第一章", "第二章", "第三章"])
        #expect(unchanged.diagnostics.isEmpty)

        toc.formatJs = "while (true) {}"
        source.ruleToc = toc
        let limited = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)
        #expect(limited.chapters.map(\.title) == ["第一章", "第二章", "第三章"])
        #expect(limited.diagnostics.first?.code == "toc.format")
        #expect(limited.diagnostics.first?.severity == .warning)
    }

    @Test func tocRulesReceiveCurrentChapterAndEarlierRuleVariables() async throws {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/toc": "<li><span>chapter-one</span></li>"])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "章节上下文")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:span@text"
        toc.chapterUrl = "@js:'/' + chapter.getTitle()"
        toc.updateTime = "@js:java.put('seenURL', chapter.getUrl()); 'updated'"
        toc.isVolume = "@js:java.get('seenURL') === '/chapter-one'"
        toc.isVip = "@js:chapter.isVolume && chapter.tag === 'updated'"
        toc.isPay = "@js:chapter.isVip"
        source.ruleToc = toc
        var book = Book(bookUrl: base + "/book", name: "书", origin: base)
        book.tocUrl = base + "/toc"

        let report = await NetworkBookService(transport: transport).loadChapters(book: book, source: source)
        let chapter = try #require(report.chapters.first)
        #expect(chapter.url == base + "/chapter-one")
        #expect(chapter.title == "chapter-one")
        #expect(chapter.isVolume)
        #expect(chapter.isVip)
        #expect(chapter.isPay)
        #expect(chapter.tag == "updated")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func textSubContentParticipatesInReplacementCacheAndExportExactlyOnce() async throws {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [
            base + "/chapter": "<article>第一页</article><aside>附录广告</aside><h1>原始标题</h1><a href='/page2'>下一页</a>",
            base + "/page2": "<article>第二页</article><aside>忽略分页副文</aside><h1>忽略分页标题</h1>"
        ])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "副正文")
        var rules = ContentRule()
        rules.content = "@CSS:article@text"
        rules.subContent = "@CSS:aside@text"
        rules.nextContentUrl = "@CSS:a@href"
        rules.replaceRegex = "@js:java.put('replaced', '完成'); result.replace('广告', '')"
        rules.title = "@CSS:h1@text@js:result + java.get('replaced')"
        source.ruleContent = rules
        let book = Book(bookUrl: base + "/book", name: "书", origin: base)
        let chapter = BookChapter(url: base + "/chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"))
        let coordinator = ChapterContentCoordinator(loader: NetworkBookService(transport: transport), cache: cache)

        let first = await coordinator.load(book: book, chapter: chapter, source: source)
        #expect(first.report.content == "第一页\n第二页\n附录")
        #expect(first.report.title == "原始标题完成")
        #expect(first.report.supplementalContent == nil)
        #expect(first.report.diagnostics.isEmpty)
        #expect(!first.loadedFromCache)

        let second = await coordinator.load(book: book, chapter: chapter, source: source)
        #expect(second.report.content == first.report.content)
        #expect(second.loadedFromCache)
        let export = try await BookFileExporter(directory: root.appendingPathComponent("export"), cache: cache)
            .cachedBook(book, chapters: [chapter])
        let exported = try String(contentsOf: export.url, encoding: .utf8)
        #expect(exported.components(separatedBy: "附录").count == 2)
        #expect(exported.contains(first.report.content))
    }

    @Test func textSupplementCanSupplyOtherwiseEmptyChapter() async {
        let base = "https://reader.example.test"
        let transport = BookFlowMockTransport(pages: [base + "/chapter": "<aside>完整副文</aside>"])
        var source = BookSource(bookSourceUrl: base, bookSourceName: "副正文")
        var rules = ContentRule()
        rules.content = "@CSS:article@text"
        rules.subContent = "@CSS:aside@text"
        source.ruleContent = rules
        let book = Book(bookUrl: base + "/book", name: "书", origin: base)
        let chapter = BookChapter(url: base + "/chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let report = await NetworkBookService(transport: transport).loadContent(book: book, chapter: chapter, source: source)
        #expect(report.content == "完整副文")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func titleFormattingRejectsOversizedScriptAndPreservesOversizedOrUndefinedResults() async throws {
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "章\($0)", bookUrl: "book", index: $0) }
        let limited = JavaScriptRuleEvaluator(maximumScriptLength: 1_024, maximumResultLength: 8)
        let output = try await limited.formatChapterTitles(
            script: "if (index === 1) 'x'.repeat(9); else if (index === 2) undefined; else 'ok'",
            chapters: chapters
        )
        #expect(output.chapters.map(\.title) == ["章0", "章1", "ok"])
        #expect(output.diagnostics.count == 1)
        #expect(output.diagnostics.first?.severity == .warning)
        await #expect(throws: RuleEngineError.self) {
            try await JavaScriptRuleEvaluator(maximumScriptLength: 4).formatChapterTitles(script: "title", chapters: chapters)
        }
    }
}
