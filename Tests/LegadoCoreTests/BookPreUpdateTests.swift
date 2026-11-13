import Foundation
import Testing
@testable import LegadoCore

private actor PreUpdateTransport: HTTPTransport {
    let pages: [String: String]
    let delayedPath: String?
    private var paths: [String] = []
    private var wasCancelled = false

    init(pages: [String: String], delayedPath: String? = nil) {
        self.pages = pages
        self.delayedPath = delayedPath
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        paths.append(url.path)
        if url.path == delayedPath {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { wasCancelled = true; throw error }
        }
        let body = try #require(pages[url.path], "Unexpected request: \(url)")
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func requestedPaths() -> [String] { paths }
    func cancelled() -> Bool { wasCancelled }
    func waitForRequest() async -> Bool {
        for _ in 0..<1_000 {
            if !paths.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

struct BookPreUpdateTests {
    private let base = "https://preupdate.example.test"

    private func source(script: String) -> BookSource {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "更新前脚本")
        var info = BookInfoRule()
        info.name = "@CSS:h1@text"
        info.author = "@CSS:.author@text"
        info.tocUrl = "@CSS:a.toc@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.preUpdateJs = script
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        source.ruleToc = toc
        return source
    }

    private func book() -> Book {
        var book = Book(bookUrl: base + "/book", name: "原书", author: "作者", origin: base)
        book.tocUrl = base + "/old-toc"
        book.durChapterPos = 42
        book.customTag = "用户标记"
        return book
    }

    @Test func updateScriptWritesBookAndVariablesBeforeLoadingDirectory() async throws {
        let source = source(script: """
            book.setTocUrl(source.bookSourceUrl + '/new-toc');
            book.name = '脚本书名';
            book.putVariable('token', 'one');
            book.variableMap.put('second', java.get('token') + '-two');
            java.put('third', book.getVariable('second'));
            """)
        let transport = PreUpdateTransport(pages: ["/new-toc": "<li><a href='/chapter'>第一章</a></li>"])
        let book = book()
        let repository = InMemoryBookChapterRepository()
        let coordinator = BookUpdateCoordinator(repository: repository, loader: NetworkBookService(transport: transport))

        let result = await coordinator.refresh(book: book, source: source, now: 123)

        #expect(result.refreshed)
        #expect(result.book.name == "脚本书名")
        #expect(result.book.tocUrl == base + "/new-toc")
        #expect(result.book.customTag == "用户标记")
        #expect(result.book.durChapterPos == 42)
        let variables = try JSONDecoder().decode([String: String].self, from: Data(try #require(result.book.variable).utf8))
        #expect(variables == ["token": "one", "second": "one-two", "third": "one-two"])
        #expect(await transport.requestedPaths() == ["/new-toc"])
        #expect(await repository.load(bookURL: book.bookUrl) == result.chapters)
    }

    @Test func missingTocLoadsDetailsAndSkipsPreUpdateScript() async {
        let source = source(script: "throw new Error('must not run')")
        let transport = PreUpdateTransport(pages: [
            "/book": "<h1>详情名字</h1><a class='toc' href='/new-toc'>目录</a>",
            "/new-toc": "<li><a href='/chapter'>第一章</a></li>"
        ])
        var book = book()
        book.tocUrl = ""
        let coordinator = BookUpdateCoordinator(repository: InMemoryBookChapterRepository(), loader: NetworkBookService(transport: transport))

        let result = await coordinator.refresh(book: book, source: source)

        #expect(result.refreshed)
        #expect(result.book.name == "原书")
        #expect(result.book.tocUrl == base + "/new-toc")
        #expect(result.book.durChapterPos == 42)
        #expect(await transport.requestedPaths() == ["/book", "/new-toc"])
    }

    @Test func refreshTocUrlIsSynchronousAndPreservesBookIdentityFields() async throws {
        let source = source(script: """
            java.refreshTocUrl();
            if (book.getTocUrl() !== source.bookSourceUrl + '/new-toc') throw new Error('stale toc');
            java.put('refreshed', book.getTocUrl());
            """)
        let transport = PreUpdateTransport(pages: [
            "/book": "<h1>不要改名</h1><p class='author'>不要改作者</p><a class='toc' href='/new-toc'>目录</a>",
            "/new-toc": "<li><a href='/chapter'>第一章</a></li>"
        ])
        let coordinator = BookUpdateCoordinator(repository: InMemoryBookChapterRepository(), loader: NetworkBookService(transport: transport))

        let result = await coordinator.refresh(book: book(), source: source)

        #expect(result.refreshed)
        #expect(result.book.name == "原书")
        #expect(result.book.author == "作者")
        #expect(result.book.variable?.contains("new-toc") == true)
        #expect(await transport.requestedPaths() == ["/book", "/new-toc"])
    }

    @Test func freshlyLoadedDetailSkipsDuplicateRefreshButRunsRemainingScript() async {
        let source = source(script: "java.refreshTocUrl(); java.put('kept', book.getTocUrl());")
        let transport = PreUpdateTransport(pages: [:])
        let result = await NetworkBookService(transport: transport).prepareUpdate(
            book: book(), source: source, isFromBookInfo: true
        )
        #expect(result.diagnostics.isEmpty)
        #expect(result.book.variable?.contains("old-toc") == true)
        #expect(await transport.requestedPaths().isEmpty)
    }

    @Test func reGetBookUsesExactNameAndAuthorThenUpdatesDetails() async {
        var source = source(script: "java.reGetBook(); java.put('updatedURL', book.bookUrl);")
        source.searchUrl = "/search"
        source.ruleSearch = .init(bookList: "$.books", name: "$.name", author: "$.author", bookUrl: "$.url")
        let transport = PreUpdateTransport(pages: [
            "/search": #"{"books":[{"name":"原书","author":"其他作者","url":"/wrong"},{"name":"原书","author":"作者","url":"/new-book"}]}"#,
            "/new-book": "<a class='toc' href='/new-toc'>目录</a>",
            "/new-toc": "<li><a href='/chapter'>第一章</a></li>"
        ])
        let coordinator = BookUpdateCoordinator(repository: InMemoryBookChapterRepository(), loader: NetworkBookService(transport: transport))

        let result = await coordinator.refresh(book: book(), source: source, persistDirectory: false)

        #expect(result.refreshed)
        #expect(result.book.bookUrl == base + "/new-book")
        #expect(result.chapters.allSatisfy { $0.bookUrl == result.book.bookUrl })
        #expect(result.book.variable?.contains("new-book") == true)
        #expect(await transport.requestedPaths() == ["/search", "/new-book", "/new-toc"])
    }

    @Test(arguments: ["java.put('bad','value'); throw new Error('stop update')", "book.group = 'invalid number'"])
    func failedScriptDoesNotPublishMutationsOrOverwriteStoredDirectory(script: String) async {
        let source = source(script: script)
        let book = book()
        let chapters = [BookChapter(url: "old", title: "旧章", bookUrl: book.bookUrl, index: 0)]
        let repository = InMemoryBookChapterRepository(values: [book.bookUrl: chapters])
        let transport = PreUpdateTransport(pages: [:])
        let coordinator = BookUpdateCoordinator(repository: repository, loader: NetworkBookService(transport: transport))

        let result = await coordinator.refresh(book: book, source: source)

        #expect(!result.refreshed)
        #expect(result.book == book)
        #expect(result.chapters == chapters)
        #expect(await repository.load(bookURL: book.bookUrl) == chapters)
        #expect(result.diagnostics.contains { $0.code == "toc.pre_update" })
        #expect(await transport.requestedPaths().isEmpty)
    }

    @Test func cancellationInterruptsNativeRefreshWithoutPublishingItsResult() async {
        let source = source(script: "java.refreshTocUrl();")
        let book = book()
        let transport = PreUpdateTransport(pages: ["/book": "<a class='toc' href='/new-toc'>目录</a>"], delayedPath: "/book")
        let service = NetworkBookService(transport: transport)
        let task = Task { await service.prepareUpdate(book: book, source: source) }
        #expect(await transport.waitForRequest())
        task.cancel()
        let result = await task.value
        #expect(result.book == book)
        #expect(result.diagnostics.contains { $0.code == "toc.cancelled" })
        for _ in 0..<100 where !(await transport.cancelled()) { await Task.yield() }
        #expect(await transport.cancelled())
    }

    @Test func disabledPreUpdateDoesNotExecuteScriptAndAJAXUsesConfiguredTransport() async {
        let source = source(script: "book.setTocUrl(source.bookSourceUrl + java.ajax('/token'))")
        let transport = PreUpdateTransport(pages: ["/token": "/new-toc"])
        let service = NetworkBookService(transport: transport)
        let skipped = await service.prepareUpdate(book: book(), source: source, runPreUpdateScript: false)
        #expect(skipped.book == book())
        #expect(await transport.requestedPaths().isEmpty)
        let updated = await service.prepareUpdate(book: book(), source: source)
        #expect(updated.book.tocUrl == base + "/new-toc")
        #expect(updated.diagnostics.isEmpty)
        #expect(await transport.requestedPaths() == ["/token"])
    }
}
