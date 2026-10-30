import Testing
@testable import LegadoCore

struct BookSourceSwitchServiceTests {
    @Test(arguments: [false, true]) func refusesPartiallyLoadedDirectoryOrBody(directoryFailed: Bool) async {
        let repository = InMemoryBookChapterRepository()
        let diagnostic = RuleDiagnostic(severity: .error, code: "request.failed", message: "分页加载失败", rule: "next")
        let loader = StubSwitchLoader(
            chapters: [BookChapter(url: "chapter", title: "第一章", bookUrl: "new", index: 0)],
            diagnostics: directoryFailed ? [diagnostic] : []
        )
        let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader,
                                              contentLoader: SwitchContentLoader(diagnostics: directoryFailed ? [] : [diagnostic]),
                                              chapterRepository: repository)
        let report = await service.prepareSwitch(current: Book(bookUrl: "old", name: "书", origin: "old"),
            candidate: SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书"),
            source: BookSource(bookSourceUrl: "new", bookSourceName: "新源"))

        #expect(report == nil)
        #expect(await repository.load(bookURL: "new").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func automaticRecoveryUsesEarlyValidSourceWithoutWaitingForSlowSources() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: SourceSearchOutcome.self)
        defer { continuation.finish() }
        let loader = CandidateAwareSwitchLoader()
        let service = BookSourceSwitchService(searcher: StreamingSwitchSearch(stream: stream),
                                              detailLoader: loader, chapterLoader: loader,
                                              contentLoader: SwitchContentLoader(),
                                              chapterRepository: InMemoryBookChapterRepository())
        var source = BookSource(bookSourceUrl: "valid", bookSourceName: "好源")
        source.searchUrl = "/search"
        let candidate = SearchBook(bookURL: "valid-book", origin: "valid", originName: "好源", type: 0, name: "书")
        continuation.yield(.init(sourceID: "valid", books: [candidate], diagnostics: []))
        let result = await service.firstAvailableSource(for: Book(bookUrl: "old-book", name: "书", origin: "old"), sources: [source])
        #expect(result?.source.id == "valid")
        #expect(result?.report.chapters.first?.title == "有效目录")
    }

    @Test(.timeLimit(.minutes(1))) func streamsCandidatesBeforeAllSourcesFinishAndKeepsDistinctOrigins() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: SourceSearchOutcome.self)
        defer { continuation.finish() }
        let service = BookSourceSwitchService(searcher: StreamingSwitchSearch(stream: stream))
        let book = Book(bookUrl: "old-book", name: "书", author: "作者", origin: "old")
        let sources = ["a", "b"].map { id in
            var source = BookSource(bookSourceUrl: id, bookSourceName: id)
            source.searchUrl = "/search"
            return source
        }
        var iterator = await service.candidateUpdates(for: book, sources: sources).makeAsyncIterator()
        let first = SearchBook(bookURL: "shared-url", origin: "a", originName: "A", type: 0, name: "书", author: "作者")
        continuation.yield(.init(sourceID: "a", books: [first], diagnostics: []))
        let early = try #require(await iterator.next())
        #expect(early.map(\.book.origin) == ["a"])
        var second = first
        second.origin = "b"
        continuation.yield(.init(sourceID: "b", books: [second, second], diagnostics: []))
        let updated = try #require(await iterator.next())
        #expect(Set(updated.map(\.book.origin)) == ["a", "b"])
        #expect(Set(updated.map(\.id)).count == 2)
        continuation.finish()
        #expect(await iterator.next() == nil)
    }

    @Test func ranksExactAuthorAndExcludesCurrentSource() async {
        var current = Book(bookUrl: "old", name: "长夜里的灯", author: "林舟", origin: "old-source")
        current.originName = "旧源"
        let exact = SearchBook(bookURL: "new-a", origin: "source-a", originName: "甲源", type: 0, name: "长夜里的灯", author: "作者：林舟")
        let otherAuthor = SearchBook(bookURL: "new-b", origin: "source-b", originName: "乙源", type: 0, name: "长夜里的灯", author: "另一位")
        let wrongTitle = SearchBook(bookURL: "new-c", origin: "source-c", originName: "丙源", type: 0, name: "长夜的灯", author: "林舟")
        let report = BookSearchReport(books: [], outcomes: [
            .init(sourceID: "source-a", books: [exact], diagnostics: []),
            .init(sourceID: "source-b", books: [otherAuthor], diagnostics: []),
            .init(sourceID: "source-c", books: [wrongTitle], diagnostics: [])
        ])
        let service = BookSourceSwitchService(searcher: StubSwitchSearch(report: report))
        let sources = ["old-source", "source-a", "source-b", "source-c"].map {
            var source = BookSource(bookSourceUrl: $0, bookSourceName: $0)
            source.searchUrl = "/search"
            return source
        }

        let candidates = await service.candidates(for: current, sources: sources)

        #expect(candidates.map(\.book.bookURL) == ["new-a", "new-b"])
        #expect(candidates[0].score > candidates[1].score)
    }

    @Test func preservesCharacterPositionWhenChapterTitleMatches() {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.customTag = "收藏"
        current.group = 8
        current.totalChapterNum = 10
        current.durChapterIndex = 4
        current.durChapterTitle = "第五章 · 重逢"
        current.durChapterPos = 388
        current.durChapterTime = 77
        var readConfig = BookReadConfig()
        readConfig.pageAnim = 3
        readConfig.useReplaceRule = false
        current.readConfig = readConfig
        let replacement = Book(bookUrl: "new", name: "书", origin: "new")
        let chapters = (0..<8).map {
            BookChapter(url: "n\($0)", title: $0 == 6 ? "第五章 重逢" : "第\($0)章", bookUrl: "new", index: $0)
        }

        let report = BookSourceProgressMapper().migrate(current: current, replacement: replacement, chapters: chapters, now: 100)

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 6)
        #expect(report.book.durChapterPos == 388)
        #expect(report.book.durChapterTime == 77)
        #expect(report.book.customTag == "收藏")
        #expect(report.book.group == 8)
        #expect(report.book.readConfig == current.readConfig)
    }

    @Test func fallsBackToRelativeProgressAndResetsCharacterOffset() {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.totalChapterNum = 11
        current.durChapterIndex = 5
        current.durChapterTitle = "旧目录章节"
        current.durChapterPos = 999
        let replacement = Book(bookUrl: "new", name: "书", origin: "new")
        let chapters = (0..<21).map { BookChapter(url: "n\($0)", title: "新\($0)", bookUrl: "new", index: $0) }

        let report = BookSourceProgressMapper().migrate(current: current, replacement: replacement, chapters: chapters, now: 100)

        #expect(!report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 10)
        #expect(report.book.durChapterPos == 0)
    }

    @Test func matchesChapterNameAcrossVolumeAndGlobalNumbering() {
        let (current, replacement, chapters) = renumberedChapters()

        let report = BookSourceProgressMapper().migrate(current: current, replacement: replacement, chapters: chapters, now: 100)

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 240)
        #expect(report.book.durChapterTitle == "第239章 小黑巧施漩涡计，方显大破胎盘台")
        #expect(report.book.durChapterPos == 88)
    }

    @Test func switchVerifiesTheChapterMatchedByNameInsteadOfRelativeProgress() async throws {
        let (current, replacement, chapters) = renumberedChapters()
        let loader = StubSwitchLoader(chapters: chapters)
        let contentLoader = RecordingSwitchContentLoader()
        let repository = InMemoryBookChapterRepository()
        let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader, contentLoader: contentLoader,
                                              chapterRepository: repository)

        let report = try #require(await service.prepareSwitch(current: current,
            candidate: SearchBook(bookURL: replacement.bookUrl, origin: "new", originName: "新源", type: 0, name: "书"),
            source: BookSource(bookSourceUrl: "new", bookSourceName: "新源"), persistChapters: false))

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 240)
        #expect(await contentLoader.chapterURL == "new/241")
        #expect(await contentLoader.nextURL == "new/242")
        #expect(await repository.load(bookURL: replacement.bookUrl).isEmpty)
    }

    @Test func prefersFullTitleMatchOverMatchingNamesWithOtherChapterNumbers() {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "第五章 · 重逢"
        let chapters = [
            BookChapter(url: "different-number", title: "第239章 重逢", bookUrl: "new", index: 0),
            BookChapter(url: "same-number", title: "第五章 重逢", bookUrl: "new", index: 1)
        ]

        let report = BookSourceProgressMapper().migrate(current: current,
            replacement: Book(bookUrl: "new", name: "书", origin: "new"), chapters: chapters, now: 100)

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 1)
    }

    @Test func ambiguousOrEmptyChapterNamesDoNotBecomeExactMatches() {
        for (oldTitle, firstTitle, secondTitle) in [
            ("第五章 归途", "第2章 归途", "第90章 归途"),
            ("第五章", "第2章", "第90章"),
            ("", "", ""),
            ("第一章 开端", "第一章 开端", "第一章 开端")
        ] {
            var current = Book(bookUrl: "old", name: "书", origin: "old")
            current.totalChapterNum = 11
            current.durChapterIndex = 5
            current.durChapterTitle = oldTitle
            current.durChapterPos = 88
            var chapters = (0..<21).map { BookChapter(url: "new/\($0)", title: "其他章节\($0)", bookUrl: "new", index: $0) }
            chapters[2].title = firstTitle
            chapters[18].title = secondTitle

            let report = BookSourceProgressMapper().migrate(current: current,
                replacement: Book(bookUrl: "new", name: "书", origin: "new"), chapters: chapters, now: 100)

            #expect(!report.exactChapterMatch)
            #expect(report.book.durChapterIndex == 10)
            #expect(report.book.durChapterPos == 0)
        }
    }

    @Test func chapterNameMatchingSkipsVolumeHeadersAndKeepsNumbersInTheName() {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "第一百章 第101次相遇"
        var volume = BookChapter(url: "volume", title: "第239章 第101次相遇", bookUrl: "new", index: 0)
        volume.isVolume = true
        let chapters = [volume,
            BookChapter(url: "wrong", title: "第２４０章 第102次相遇", bookUrl: "new", index: 1),
            BookChapter(url: "right", title: "第２４１章：第101次相遇", bookUrl: "new", index: 2)]

        let report = BookSourceProgressMapper().migrate(current: current,
            replacement: Book(bookUrl: "new", name: "书", origin: "new"), chapters: chapters, now: 100)

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 2)
    }

    @Test func matchesAnUnnumberedTitleToANumberedChapter() {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "归途"
        let chapters = [BookChapter(url: "wrong", title: "第一章 告别", bookUrl: "new", index: 0),
                        BookChapter(url: "right", title: "第二百三十九章 归途", bookUrl: "new", index: 1)]

        let report = BookSourceProgressMapper().migrate(current: current,
            replacement: Book(bookUrl: "new", name: "书", origin: "new"), chapters: chapters, now: 100)

        #expect(report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 1)
    }

    private func renumberedChapters() -> (Book, Book, [BookChapter]) {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.totalChapterNum = 708
        current.durChapterIndex = 250
        current.durChapterTitle = "第一百一十七章 小黑巧施漩涡计，方显大破胎盘台"
        current.durChapterPos = 88
        let replacement = Book(bookUrl: "new", name: "书", origin: "new")
        var chapters = (0..<706).map { BookChapter(url: "new/\($0 + 1)", title: "目录项\($0)", bookUrl: "new", index: $0) }
        chapters[240].title = "第239章 小黑巧施漩涡计，方显大破胎盘台"
        chapters[249].title = "第248章 新的怪谈，新的敌人"
        return (current, replacement, chapters)
    }

    @Test func refusesSwitchWhenCandidateDirectoryCannotBeLoaded() async {
        let repository = InMemoryBookChapterRepository()
        let service = BookSourceSwitchService(
            searcher: StubSwitchSearch(report: .init(books: [], outcomes: [])),
            detailLoader: StubSwitchLoader(chapters: []),
            chapterLoader: StubSwitchLoader(chapters: []),
            chapterRepository: repository
        )
        let current = Book(bookUrl: "old", name: "书", origin: "old")
        let candidate = SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书")
        let source = BookSource(bookSourceUrl: "new", bookSourceName: "新源")

        #expect(await service.prepareSwitch(current: current, candidate: candidate, source: source) == nil)
        #expect(await repository.load(bookURL: "new").isEmpty)
    }

    @Test func automaticallySkipsBrokenCandidateAndUsesFirstValidDirectory() async {
        let broken = SearchBook(bookURL: "broken-book", origin: "broken", originName: "A 坏源", type: 0, name: "书")
        let valid = SearchBook(bookURL: "valid-book", origin: "valid", originName: "B 好源", type: 0, name: "书")
        let search = StubSwitchSearch(report: .init(books: [], outcomes: [
            .init(sourceID: "broken", books: [broken], diagnostics: []),
            .init(sourceID: "valid", books: [valid], diagnostics: [])
        ]))
        let loader = CandidateAwareSwitchLoader()
        let service = BookSourceSwitchService(
            searcher: search,
            detailLoader: loader,
            chapterLoader: loader,
            contentLoader: SwitchContentLoader(),
            chapterRepository: InMemoryBookChapterRepository()
        )
        let current = Book(bookUrl: "old-book", name: "书", origin: "old")
        let sources = ["old", "broken", "valid"].map { id in
            var source = BookSource(bookSourceUrl: id, bookSourceName: id)
            source.searchUrl = "/search"
            return source
        }

        let available = await service.firstAvailableSource(for: current, sources: sources, now: 100)

        #expect(available?.source.bookSourceUrl == "valid")
        #expect(available?.report.chapters.map(\.title) == ["有效目录"])
    }

    @Test func refusesCandidateWithDirectoryButNoBodyWithoutSavingItsDirectory() async {
        let repository = InMemoryBookChapterRepository()
        let chapter = BookChapter(url: "new/1", title: "第一章", bookUrl: "new", index: 0)
        let loader = StubSwitchLoader(chapters: [chapter])
        for body in ["", " \n\t"] {
            let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader,
                                                  contentLoader: SwitchContentLoader(body: body), chapterRepository: repository)
            let report = await service.prepareSwitch(
                current: Book(bookUrl: "old", name: "书", origin: "old"),
                candidate: SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书"),
                source: BookSource(bookSourceUrl: "new", bookSourceName: "新源")
            )
            #expect(report == nil)
            #expect(await repository.load(bookURL: "new").isEmpty)
        }
    }

    @Test func automaticChapterInspectionDoesNotFetchOrSaveAnApproximateChapter() async throws {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "第212章 你的名字"
        let chapters = [BookChapter(url: "wrong", title: "第212章 别的故事", bookUrl: "new", index: 0)]
        let loader = StubSwitchLoader(chapters: chapters)
        let content = RecordingSwitchContentLoader()
        let repository = InMemoryBookChapterRepository()
        let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader,
                                              contentLoader: content, chapterRepository: repository)

        let report = try #require(await service.prepareSwitch(current: current,
            candidate: SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书"),
            source: BookSource(bookSourceUrl: "new", bookSourceName: "新源"),
            persistChapters: false, requireExactChapterMatch: true))

        #expect(!report.exactChapterMatch)
        #expect(report.verifiedContent == nil)
        #expect(await content.chapterURL == nil)
        #expect(await repository.load(bookURL: "new").isEmpty)
    }

    @Test func automaticRecoverySkipsSearchableSourcesWithDirectoriesButBrokenBodies() async throws {
        let candidates = ["broken-body", "valid"].map {
            SearchBook(bookURL: $0 + "-book", origin: $0, originName: $0, type: 0, name: "书")
        }
        let sources = candidates.map { candidate in
            var source = BookSource(bookSourceUrl: candidate.origin, bookSourceName: candidate.originName)
            source.searchUrl = "/search"
            return source
        }
        let loader = StubSwitchLoader(chapters: [BookChapter(url: "chapter", title: "第一章", bookUrl: "new", index: 0)])
        let service = BookSourceSwitchService(
            searcher: StubSwitchSearch(report: .init(books: [], outcomes: candidates.map {
                .init(sourceID: $0.origin, books: [$0], diagnostics: [])
            })), detailLoader: loader, chapterLoader: loader, contentLoader: SwitchContentLoader(),
            chapterRepository: InMemoryBookChapterRepository()
        )
        let available = try #require(await service.firstAvailableSource(for: Book(bookUrl: "old", name: "书", origin: "old"), sources: sources))
        #expect(available.source.id == "valid")
        #expect(available.report.verifiedContent?.content == "验证后的正文")
    }

    @Test func validatesMappedChapterWithNextReadableURLAndKeepsReadingPosition() async throws {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "第二章"
        current.durChapterPos = 88
        var volume = BookChapter(url: "volume", title: "卷二", bookUrl: "new", index: 2)
        volume.isVolume = true
        let chapters = [BookChapter(url: "first", title: "第一章", bookUrl: "new", index: 0),
                        BookChapter(url: "second", title: "第二章", bookUrl: "new", index: 1), volume,
                        BookChapter(url: "third", title: "第三章", bookUrl: "new", index: 3)]
        let loader = StubSwitchLoader(chapters: chapters)
        let contentLoader = RecordingSwitchContentLoader()
        let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader, contentLoader: contentLoader,
                                              chapterRepository: InMemoryBookChapterRepository())
        let report = try #require(await service.prepareSwitch(current: current,
            candidate: SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书"),
            source: BookSource(bookSourceUrl: "new", bookSourceName: "新源")))
        #expect(await contentLoader.chapterURL == "second")
        #expect(await contentLoader.nextURL == "third")
        #expect(report.book.durChapterPos == 88)
        #expect(report.verifiedContent?.content == "验证后的正文")
    }

    @Test func skippingAMatchedVolumeMarksThePreviewAsApproximate() async throws {
        var current = Book(bookUrl: "old", name: "书", origin: "old")
        current.durChapterTitle = "卷二"
        current.durChapterPos = 88
        var volume = BookChapter(url: "volume", title: "卷二", bookUrl: "new", index: 0)
        volume.isVolume = true
        let chapters = [volume, BookChapter(url: "body", title: "第二章", bookUrl: "new", index: 1)]
        let loader = StubSwitchLoader(chapters: chapters)
        let service = BookSourceSwitchService(detailLoader: loader, chapterLoader: loader,
                                              contentLoader: SwitchContentLoader(),
                                              chapterRepository: InMemoryBookChapterRepository())
        let report = try #require(await service.prepareSwitch(current: current,
            candidate: SearchBook(bookURL: "new", origin: "new", originName: "新源", type: 0, name: "书"),
            source: BookSource(bookSourceUrl: "new", bookSourceName: "新源"), persistChapters: false))
        #expect(!report.exactChapterMatch)
        #expect(report.book.durChapterIndex == 1)
        #expect(report.book.durChapterTitle == "第二章")
        #expect(report.book.durChapterPos == 0)
        #expect(report.verifiedContent?.content == "验证后的正文")
    }
}

private struct SwitchContentLoader: ChapterContentLoading {
    var body = "验证后的正文"
    var diagnostics: [RuleDiagnostic] = []
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: source.id == "broken-body" ? "" : body, diagnostics: diagnostics)
    }
}

private actor RecordingSwitchContentLoader: ChapterContentLoading {
    var chapterURL: String?
    var nextURL: String?
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        chapterURL = chapter.url
        nextURL = nextChapterURL
        return .init(content: "验证后的正文")
    }
}

private struct StreamingSwitchSearch: BookSourceSearching {
    let stream: AsyncStream<SourceSearchOutcome>
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport {
        .init(books: [], outcomes: [])
    }
    func searchStream(keyword: String, sources: [BookSource]) -> AsyncStream<SourceSearchOutcome> { stream }
}

private struct StubSwitchSearch: BookSourceSearching {
    let report: BookSearchReport
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport { report }
}

private struct StubSwitchLoader: BookDetailLoading, ChapterListLoading {
    let chapters: [BookChapter]
    var diagnostics: [RuleDiagnostic] = []
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        .init(book: Book(bookUrl: searchBook.bookURL, name: searchBook.name, author: searchBook.author, origin: source.bookSourceUrl))
    }
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        .init(chapters: chapters, diagnostics: diagnostics)
    }
}

private struct CandidateAwareSwitchLoader: BookDetailLoading, ChapterListLoading {
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        .init(book: Book(bookUrl: searchBook.bookURL, name: searchBook.name, origin: source.bookSourceUrl))
    }

    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        guard source.bookSourceUrl == "valid" else { return .init(chapters: []) }
        return .init(chapters: [BookChapter(url: "chapter", title: "有效目录", bookUrl: book.bookUrl, index: 0)])
    }
}
