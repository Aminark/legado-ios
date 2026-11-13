import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct BookDetailRegressionTests {
    @Test(arguments: [false, true]) func changedBookAddressIsPublishedOnlyAfterSuccessfulShelfCommit(succeeds: Bool) async {
        var source = BookSource(bookSourceUrl: "https://detail-regression.test", bookSourceName: "源")
        var info = BookInfoRule(); info.tocUrl = "@CSS:a.toc@href"; source.ruleBookInfo = info
        var toc = TocRule(); toc.chapterList = "@CSS:li"; toc.chapterName = "@CSS:a@text"; toc.chapterUrl = "@CSS:a@href"
        toc.preUpdateJs = "java.refreshTocUrl(); book.bookUrl = source.bookSourceUrl + '/rotated'; book.tocUrl = source.bookSourceUrl + '/toc'"
        source.ruleToc = toc
        let search = SearchBook(bookURL: source.id + "/book", origin: source.id, originName: "源", type: 0, name: "书")
        let transport = CountingDetailTransport()
        let model = BookDetailViewModel(searchBook: search, source: source, service: .init(transport: transport),
                                         chapterRepository: InMemoryBookChapterRepository())
        var commits = 0
        await model.load(persistDirectory: false, runPreUpdateScript: true, commitPreparedUpdate: { report in
            commits += 1
            #expect(model.book.bookUrl == search.bookURL)
            #expect(report.book.bookUrl == source.id + "/rotated")
            return succeeds
        })
        #expect(commits == 1)
        #expect(model.book.bookUrl == source.id + (succeeds ? "/rotated" : "/book"))
        #expect(model.state == (succeeds ? .ready : .failed))
        #expect(model.diagnostics.contains { $0.code == "toc.persistence" } == !succeeds)
        #expect(await transport.requestedPaths == ["/book", "/toc"])
        if succeeds {
            // Subsequent refreshes must not reload the stale original search URL.
            await model.refresh(persistDirectory: false)
            #expect(await transport.requestedPaths == ["/book", "/toc", "/rotated", "/toc"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func lateOldDetailCannotOverwriteManualSourceSwitch() async throws {
        var source = BookSource(bookSourceUrl: "https://old-detail.test", bookSourceName: "旧源")
        var info = BookInfoRule()
        info.name = "@CSS:h1@text"
        source.ruleBookInfo = info
        let transport = SuspendedDetailTransport()
        let search = SearchBook(bookURL: source.id + "/book", origin: source.id, originName: "旧源", type: 0, name: "书")
        let model = BookDetailViewModel(searchBook: search, source: source,
            service: NetworkBookService(transport: transport), chapterRepository: InMemoryBookChapterRepository())
        let load = Task { await model.load() }
        await transport.waitUntilRequested()
        let replacementSource = BookSource(bookSourceUrl: "https://new-detail.test", bookSourceName: "新源")
        let replacement = Book(bookUrl: replacementSource.id + "/book", name: "新书名", origin: replacementSource.id)
        let chapters = [BookChapter(url: "new/1", title: "新章", bookUrl: replacement.bookUrl, index: 0)]
        model.applySourceSwitch(.init(book: replacement, chapters: chapters, exactChapterMatch: true), source: replacementSource)
        await transport.finish()
        await load.value
        #expect(model.book == replacement)
        #expect(model.source == replacementSource)
        #expect(model.chapters == chapters)
        #expect(model.state == .ready)
    }
    @Test func unshelvedSearchDetailLoadsWithoutCreatingDatabaseBook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("detail.sqlite3"))
        var source = BookSource(bookSourceUrl: "https://detail-regression.test", bookSourceName: "测试源")
        var info = BookInfoRule()
        info.name = "@CSS:h1@text"
        info.tocUrl = "@CSS:a.toc@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        source.ruleToc = toc
        let search = SearchBook(bookURL: source.id + "/book", origin: source.id, originName: source.bookSourceName,
            type: 0, name: "书")
        let model = BookDetailViewModel(searchBook: search, source: source,
            service: NetworkBookService(transport: DetailTransport()),
            chapterRepository: SQLiteBookChapterRepository(database: database))
        await model.load(persistDirectory: false)
        #expect(model.state == .ready)
        #expect(model.chapters.count == 2)
        #expect(!model.diagnostics.contains { $0.code == "toc.persistence" })
        #expect(try await database.loadBooks().isEmpty)
        #expect(try await database.loadChapters(bookURL: search.bookURL).isEmpty)
    }
    @Test func restoringNewerReadingProgressKeepsNearestRepeatedTitle() {
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        let chapters = (0..<8).map { BookChapter(url: "\($0)", title: [1, 6].contains($0) ? "番外" : "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = BookDetailViewModel(demoBook: book, source: source, chapters: chapters)
        var stored = book
        stored.durChapterIndex = 6
        stored.durChapterTitle = "番外"
        stored.durChapterTime = 1
        stored.durChapterPos = 123
        model.restoreReadingProgress(from: stored)
        #expect(model.book.durChapterIndex == 6)
        #expect(model.book.durChapterPos == 123)
    }
    @Test(arguments: [false, true]) func automaticSourceSwitchWaitsForSuccessfulShelfCommit(succeeds: Bool) async {
        let oldSource = BookSource(bookSourceUrl: "https://old-detail.test", bookSourceName: "旧源")
        var newSource = BookSource(bookSourceUrl: "https://new-detail.test", bookSourceName: "新源")
        newSource.searchUrl = "/search"
        let search = SearchBook(bookURL: oldSource.id + "/book", origin: oldSource.id,
            originName: "旧源", type: 0, name: "书")
        let loader = AutomaticSwitchLoader()
        let switcher = BookSourceSwitchService(searcher: loader, detailLoader: loader,
            chapterLoader: loader, contentLoader: loader)
        let model = BookDetailViewModel(searchBook: search, source: oldSource,
            service: NetworkBookService(transport: DetailTransport()),
            chapterRepository: InMemoryBookChapterRepository(), sourceSwitchService: switcher)
        var commits = 0
        await model.load(sources: [newSource]) { report in
            commits += 1
            #expect(model.source.id == oldSource.id)
            #expect(report.book.origin == newSource.id)
            return succeeds
        }
        #expect(commits == 1)
        #expect(model.source.id == (succeeds ? newSource.id : oldSource.id))
        #expect(model.book.bookUrl == (succeeds ? newSource.id + "/book" : search.bookURL))
        #expect(model.state == (succeeds ? .ready : .failed))
        #expect(model.diagnostics.contains { $0.code == "source_switch.persistence" } == !succeeds)
    }
    @Test func restoringShelfSourceWithSameURLKeepsSourceAndMetadataConsistent() async {
        let oldSource = BookSource(bookSourceUrl: "https://old-detail.test", bookSourceName: "旧源")
        var newSource = BookSource(bookSourceUrl: "https://new-detail.test", bookSourceName: "新源")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        newSource.ruleToc = toc
        let search = SearchBook(bookURL: "https://shared.test/book", origin: oldSource.id, originName: oldSource.bookSourceName,
                                type: 0, name: "书")
        let model = BookDetailViewModel(searchBook: search, source: oldSource,
                                        service: NetworkBookService(transport: DetailTransport()),
                                        chapterRepository: InMemoryBookChapterRepository())
        var stored = Book(bookUrl: search.bookURL, name: "书架标题", origin: newSource.id)
        stored.originName = oldSource.bookSourceName
        stored.tocUrl = newSource.id + "/toc"
        stored.durChapterIndex = 1
        stored.durChapterPos = 120
        model.restoreLibraryBook(from: stored, sources: [oldSource, newSource])
        await model.load()
        #expect(model.state == .ready)
        #expect(model.source.id == newSource.id)
        #expect(model.book.origin == newSource.id)
        #expect(model.book.originName == newSource.bookSourceName)
        #expect(model.book.name == stored.name)
        #expect(model.book.durChapterIndex == 1)
        #expect(model.book.durChapterPos == 120)
        #expect(model.chapters.count == 2)
    }

    @Test func refreshAfterSourceSwitchUsesNewBookURLInsteadOfOriginalSearchResult() async {
        var oldSource = BookSource(bookSourceUrl: "https://old-detail.test", bookSourceName: "旧源")
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        oldSource.ruleToc = toc
        var newSource = oldSource
        newSource.bookSourceUrl = "https://new-detail.test"
        let originalSearch = SearchBook(bookURL: oldSource.id + "/book", origin: oldSource.id, originName: "旧源", type: 0, name: "书")
        let model = BookDetailViewModel(searchBook: originalSearch, source: oldSource,
                                        service: NetworkBookService(transport: DetailTransport()),
                                        chapterRepository: InMemoryBookChapterRepository())
        var replacement = Book(bookUrl: newSource.id + "/book", name: "书", origin: newSource.id)
        replacement.tocUrl = newSource.id + "/toc"
        let chapters = [BookChapter(url: newSource.id + "/1", title: "第一章", bookUrl: replacement.bookUrl, index: 0)]
        model.applySourceSwitch(.init(book: replacement, chapters: chapters, exactChapterMatch: true), source: newSource)
        await model.refresh()
        #expect(model.state == .ready)
        #expect(model.book.bookUrl == replacement.bookUrl)
        #expect(model.book.origin == newSource.id)
        #expect(model.chapters.allSatisfy { $0.bookUrl == replacement.bookUrl })
    }

    @Test func returningFromReaderAdoptsSwitchedShelfSourceBeforeSavingDetail() {
        let old = Book(bookUrl: "old-book", name: "书", author: "作者", origin: "old-source")
        let oldSource = BookSource(bookSourceUrl: "old-source", bookSourceName: "旧源")
        let newSource = BookSource(bookSourceUrl: "new-source", bookSourceName: "新源")
        let chapters = [BookChapter(url: "old-chapter", title: "旧章节", bookUrl: old.bookUrl, index: 0)]
        let model = BookDetailViewModel(demoBook: old, source: oldSource, chapters: chapters)
        var replacement = old
        replacement.bookUrl = "new-book"
        replacement.origin = newSource.id
        replacement.durChapterPos = 42
        model.restoreSourceAfterReading(from: [replacement], sources: [oldSource, newSource])
        #expect(model.book == replacement)
        #expect(model.source == newSource)
        #expect(model.state == .idle)
        #expect(model.chapters.isEmpty)
    }

    @Test func refreshingSearchDetailPreservesShelfSettingsAndProgress() async {
        var source = BookSource(bookSourceUrl: "https://detail-regression.test", bookSourceName: "测试源")
        var info = BookInfoRule()
        info.canReName = "1"
        info.name = "@CSS:h1@text"
        info.intro = "@CSS:p@text"
        info.tocUrl = "@CSS:a.toc@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "@CSS:li"
        toc.chapterName = "@CSS:a@text"
        toc.chapterUrl = "@CSS:a@href"
        source.ruleToc = toc
        let search = SearchBook(
            bookURL: source.bookSourceUrl + "/book", origin: source.bookSourceUrl,
            originName: source.bookSourceName, type: 0, name: "搜索结果"
        )
        var stored = Book(bookUrl: search.bookURL, name: "旧标题", origin: source.bookSourceUrl)
        stored.group = 8
        stored.order = 7
        stored.canUpdate = false
        stored.customTag = "自定义标签"
        stored.customCoverUrl = "https://custom.test/cover"
        stored.customIntro = "自定义简介"
        var config = BookReadConfig()
        config.pageAnim = 3
        config.ttsEngine = "custom-tts"
        stored.readConfig = config
        stored.syncTime = 900
        stored.durChapterIndex = 1
        stored.durChapterTitle = "第二章"
        stored.durChapterPos = 123
        stored.durChapterTime = 500
        stored.totalChapterNum = 2
        stored.lastCheckCount = 1
        let model = BookDetailViewModel(
            searchBook: search, source: source,
            service: NetworkBookService(transport: DetailTransport()),
            chapterRepository: InMemoryBookChapterRepository()
        )
        model.restoreLibraryBook(from: stored)

        await model.load()

        #expect(model.state == .ready)
        #expect(model.book.name == "最新标题")
        #expect(model.book.intro == "最新简介")
        #expect(model.book.group == stored.group)
        #expect(model.book.order == stored.order)
        #expect(model.book.canUpdate == false)
        #expect(model.book.customTag == stored.customTag)
        #expect(model.book.customCoverUrl == stored.customCoverUrl)
        #expect(model.book.customIntro == stored.customIntro)
        #expect(model.book.readConfig == stored.readConfig)
        #expect(model.book.syncTime == 900)
        #expect(model.book.durChapterIndex == 1)
        #expect(model.book.durChapterPos == 123)
        #expect(model.book.durChapterTime == 500)
        #expect(model.book.lastCheckCount == 1)
        #expect(model.book.totalChapterNum == 2)

        stored.group = 16
        stored.canUpdate = true
        stored.durChapterPos = 321
        stored.durChapterTime = 600
        model.restoreUserSettings(from: stored)
        model.restoreReadingProgress(from: stored)
        #expect(model.book.group == 16)
        #expect(model.book.canUpdate)
        #expect(model.book.durChapterPos == 321)
        #expect(model.book.totalChapterNum == 2)
    }
}

private struct DetailTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let html = url.path == "/book"
            ? "<h1>最新标题</h1><p>最新简介</p><a class='toc' href='/toc'>目录</a>"
            : "<ul><li><a href='/1'>第一章</a></li><li><a href='/2'>第二章</a></li></ul>"
        return .init(data: Data(html.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

private actor SuspendedDetailTransport: HTTPTransport {
    private var response: CheckedContinuation<HTTPResponse, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { continuation in
            response = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }
    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func finish() {
        response?.resume(returning: .init(data: Data("<h1>过期详情</h1>".utf8), statusCode: 200,
            headers: [:], finalURL: URL(string: "https://old-detail.test/book")!))
        response = nil
    }
}

private struct AutomaticSwitchLoader: BookSourceSearching, BookDetailLoading, ChapterListLoading, ChapterContentLoading {
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport {
        let source = sources[0]
        let book = SearchBook(bookURL: source.id + "/book", origin: source.id, originName: source.bookSourceName,
            type: 0, name: keyword)
        return .init(books: [book], outcomes: [.init(sourceID: source.id, books: [book], diagnostics: [])])
    }
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        .init(book: Book(bookUrl: searchBook.bookURL, name: searchBook.name, origin: source.id))
    }
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        .init(chapters: [BookChapter(url: source.id + "/1", title: "第一章", bookUrl: book.bookUrl, index: 0)])
    }
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: "已验证的新源正文")
    }
}

private actor CountingDetailTransport: HTTPTransport {
    private(set) var requestedPaths: [String] = []
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requestedPaths.append(request.url?.path ?? "")
        return try await DetailTransport().data(for: request)
    }
}
