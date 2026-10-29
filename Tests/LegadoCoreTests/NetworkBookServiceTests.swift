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
}
