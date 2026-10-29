import Testing
@testable import LegadoCore

struct BookUpdateCoordinatorTests {
    @Test func partialDirectoryFailureKeepsCompleteDirectoryAndProgress() async throws {
        let chapters = (0..<3).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: "book", index: $0) }
        let repository = InMemoryBookChapterRepository(values: ["book": chapters])
        let coordinator = BookUpdateCoordinator(repository: repository, loader: StubChapterListLoader(report: .init(
            chapters: [chapters[0]], diagnostics: [.init(severity: .error, code: "toc.request", message: "第二页加载失败", rule: "toc")]
        )))
        var book = Book(bookUrl: "book", name: "书", origin: "source")
        book.totalChapterNum = 3
        book.durChapterIndex = 2
        book.durChapterTitle = chapters[2].title
        book.durChapterPos = 42

        let result = await coordinator.refresh(book: book, source: .init(bookSourceUrl: "source", bookSourceName: "源"))

        #expect(!result.refreshed)
        #expect(result.book == book)
        #expect(result.chapters == chapters)
        #expect(await repository.load(bookURL: book.bookUrl) == chapters)
    }

    @Test func countsOnlyGrowthAndPreservesChapterMetadata() {
        var book = Book(bookUrl: "book", name: "书", origin: "source")
        book.totalChapterNum = 2
        book.durChapterIndex = 1
        book.durChapterTitle = "第二章 旧雨"
        var oldFirst = BookChapter(url: "old-1", title: "第一章", bookUrl: "book", index: 0)
        oldFirst.wordCount = "一千字"
        oldFirst.variable = #"{"token":"keep"}"#
        let oldSecond = BookChapter(url: "old-2", title: "第二章 旧雨", bookUrl: "book", index: 1)
        let incoming = [
            BookChapter(url: "new-1", title: "第一章", bookUrl: "book", index: 8),
            BookChapter(url: "new-2", title: "第二章 旧雨", bookUrl: "book", index: 9),
            BookChapter(url: "new-3", title: "第三章 天晴", bookUrl: "book", index: 10)
        ]

        let result = BookUpdateMerger().merge(
            book: book,
            oldChapters: [oldFirst, oldSecond],
            newChapters: incoming,
            now: 99
        )

        #expect(result.addedChapterCount == 1)
        #expect(result.book.lastCheckCount == 1)
        #expect(result.book.totalChapterNum == 3)
        #expect(result.book.latestChapterTitle == "第三章 天晴")
        #expect(result.book.durChapterIndex == 1)
        #expect(result.chapters[0].wordCount == "一千字")
        #expect(result.chapters[0].variable == oldFirst.variable)
        #expect(result.chapters.map(\.index) == [0, 1, 2])
    }

    @Test func retainsUnreadCountWhenDirectoryDoesNotGrow() {
        var book = Book(bookUrl: "book", name: "书", origin: "source")
        book.totalChapterNum = 2
        book.lastCheckCount = 4
        let chapters = [
            BookChapter(url: "1", title: "第一章", bookUrl: "book", index: 0),
            BookChapter(url: "2", title: "第二章", bookUrl: "book", index: 1)
        ]

        let result = BookUpdateMerger().merge(book: book, oldChapters: chapters, newChapters: chapters, now: 10)

        #expect(result.addedChapterCount == 0)
        #expect(result.book.lastCheckCount == 4)
        #expect(result.book.latestChapterTime == 0)
        #expect(result.book.lastCheckTime == 10)
    }

    @Test func remapsProgressByTitleAndResetsPositionWhenChapterIsRemoved() {
        var book = Book(bookUrl: "book", name: "书", origin: "source")
        book.durChapterIndex = 2
        book.durChapterTitle = "第二章"
        book.durChapterPos = 130
        let old = [
            BookChapter(url: "notice", title: "后记", bookUrl: "book", index: 0),
            BookChapter(url: "first", title: "第一章", bookUrl: "book", index: 1),
            BookChapter(url: "second", title: "第二章", bookUrl: "book", index: 2)
        ]
        let refreshed = Array(old.dropFirst())

        let remapped = BookUpdateMerger().merge(book: book, oldChapters: old, newChapters: refreshed, now: 10)
        #expect(remapped.book.durChapterIndex == 1)
        #expect(remapped.book.durChapterPos == 130)

        book.durChapterIndex = 0
        book.durChapterTitle = "后记"
        book.durChapterPos = 130
        let removed = BookUpdateMerger().merge(book: book, oldChapters: old, newChapters: refreshed, now: 10)
        #expect(removed.book.durChapterIndex == 0)
        #expect(removed.book.durChapterTitle == "第一章")
        #expect(removed.book.durChapterPos == 0)
    }

    @Test func coordinatorFallsBackToStoredDirectoryWhenRefreshFails() async throws {
        let old = [BookChapter(url: "1", title: "第一章", bookUrl: "book", index: 0)]
        let repository = InMemoryBookChapterRepository(values: ["book": old])
        let loader = StubChapterListLoader(report: .init(
            chapters: [],
            diagnostics: [.init(severity: .error, code: "toc.failed", message: "失败", rule: "toc")]
        ))
        let coordinator = BookUpdateCoordinator(repository: repository, loader: loader)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")

        let result = await coordinator.refresh(book: book, source: source, now: 20)

        #expect(!result.refreshed)
        #expect(result.chapters == old)
        #expect(result.diagnostics.first?.code == "toc.failed")
    }
}

private struct StubChapterListLoader: ChapterListLoading {
    let report: ChapterListReport
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport { report }
}
