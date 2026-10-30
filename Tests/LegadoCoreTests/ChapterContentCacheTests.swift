import Foundation
import Testing
@testable import LegadoCore

struct ChapterContentCacheTests {
    @Test func failedPageDoesNotTurnPartialContentIntoSuccessfulCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let coordinator = ChapterContentCoordinator(loader: PartialChapterLoader(), cache: cache)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")

        let first = await coordinator.load(book: book, chapter: chapter, source: source)
        let second = await coordinator.load(book: book, chapter: chapter, source: source)

        #expect(first.report.content == "仅第一页")
        #expect(!second.loadedFromCache)
        #expect(second.report.diagnostics.contains { $0.severity == .error })
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url) == nil)
    }

    @Test func failedForceRefreshRetainsPreviouslyCompleteCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapter.url, content: "完整正文", sourceID: book.origin))
        let coordinator = ChapterContentCoordinator(loader: PartialChapterLoader(), cache: cache)

        let refreshed = await coordinator.load(book: book, chapter: chapter,
                                               source: .init(bookSourceUrl: "source", bookSourceName: "源"), forceRefresh: true)

        #expect(!refreshed.loadedFromCache)
        #expect(refreshed.report.diagnostics.contains { $0.severity == .error })
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url)?.content == "完整正文")
    }

    @Test func savesLoadsAndSeparatesBooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let first = CachedChapterContent(bookURL: "book-a", chapterURL: "same", title: "一", content: "正文 A")
        let second = CachedChapterContent(bookURL: "book-b", chapterURL: "same", title: "二", content: "正文 B")

        try await cache.save(first)
        try await cache.save(second)

        #expect(try await cache.load(bookURL: "book-a", chapterURL: "same") == first)
        #expect(try await cache.load(bookURL: "book-b", chapterURL: "same") == second)
        let statistics = try await cache.statistics()
        #expect(statistics.entries == 2)
        let chapters = [
            BookChapter(url: "same", title: "一", bookUrl: "book-a", index: 0),
            BookChapter(url: "missing", title: "无", bookUrl: "book-a", index: 1)
        ]
        #expect(try await cache.cachedChapterURLs(bookURL: "book-a", among: chapters) == ["same"])
        #expect(try await cache.cachedChapterURLs(bookURL: "book-b", among: chapters) == ["same"])
        #expect(try await cache.cachedChapterURLs(bookURL: "book-c", among: chapters).isEmpty)
    }

    @Test func removesOnlyRequestedBookAndRejectsEmptyEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        try await cache.save(.init(bookURL: "a", chapterURL: "1", content: "A"))
        try await cache.save(.init(bookURL: "b", chapterURL: "1", content: "B"))

        try await cache.remove(bookURL: "a")

        #expect(try await cache.load(bookURL: "a", chapterURL: "1") == nil)
        #expect(try await cache.load(bookURL: "b", chapterURL: "1")?.content == "B")
        await #expect(throws: ChapterContentCacheError.invalidEntry) {
            try await cache.save(.init(bookURL: "a", chapterURL: "2", content: ""))
        }
    }

    @Test func coordinatorUsesDiskCacheBeforeNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = StubChapterLoader(content: "网络正文")
        let coordinator = ChapterContentCoordinator(loader: loader, cache: .init(directory: directory))
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "chapter", title: "章", bookUrl: book.bookUrl, index: 0)
        let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "源")

        let first = await coordinator.load(book: book, chapter: chapter, source: source)
        let second = await coordinator.load(book: book, chapter: chapter, source: source)

        #expect(!first.loadedFromCache)
        #expect(second.loadedFromCache)
        #expect(second.report.content == "网络正文")
        #expect(await loader.calls() == 1)
    }

    @Test func aForegroundLoadSharesTheInFlightPrefetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = GatedChapterLoader()
        let cache = ChapterContentCache(directory: directory)
        let coordinator = ChapterContentCoordinator(loader: loader, cache: cache)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "c1", title: "一", bookUrl: book.id, index: 1)
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        let preload = Task { await coordinator.prefetchResult(book: book, chapter: chapter, source: source) }
        await loader.waitUntilStarted()
        let foreground = Task { await coordinator.load(book: book, chapter: chapter, source: source) }
        for _ in 0..<10 { await Task.yield() }
        preload.cancel()
        await loader.release()
        #expect(await foreground.value.report.content == "准备完成的正文")
        #expect(await preload.value == .failed("缓存已停止"))
        #expect(await loader.calls == 1)
        #expect(try await cache.load(bookURL: book.id, chapterURL: chapter.url)?.content == "准备完成的正文")
    }

    @Test func invalidatingABookPreventsAnOldDownloadFromRefillingItsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = GatedChapterLoader()
        let cache = ChapterContentCache(directory: directory)
        let coordinator = ChapterContentCoordinator(loader: loader, cache: cache)
        let book = Book(bookUrl: "book", name: "书", origin: "old")
        let chapter = BookChapter(url: "c1", title: "一", bookUrl: book.id, index: 1)
        let preload = Task { await coordinator.prefetchResult(book: book, chapter: chapter,
            source: .init(bookSourceUrl: "old", bookSourceName: "旧源")) }
        await loader.waitUntilStarted()
        await coordinator.invalidate(bookURL: book.id)
        await loader.release()
        if case .failed = await preload.value {} else { Issue.record("An invalidated response must fail") }
        #expect(try await cache.load(bookURL: book.id, chapterURL: chapter.url) == nil)
    }

    @Test func removesOneChapterAndForceRefreshesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        try await cache.save(.init(bookURL: "book", chapterURL: "one", content: "旧正文"))
        try await cache.save(.init(bookURL: "book", chapterURL: "two", content: "保留正文"))
        try await cache.remove(bookURL: "book", chapterURL: "one")
        #expect(try await cache.load(bookURL: "book", chapterURL: "one") == nil)
        #expect(try await cache.load(bookURL: "book", chapterURL: "two")?.content == "保留正文")

        let loader = StubChapterLoader(content: "刷新正文")
        let coordinator = ChapterContentCoordinator(loader: loader, cache: cache)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "two", title: "章", bookUrl: book.bookUrl, index: 0)
        let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "源")
        let refreshed = await coordinator.load(book: book, chapter: chapter, source: source, forceRefresh: true)

        #expect(!refreshed.loadedFromCache)
        #expect(refreshed.report.content == "刷新正文")
        #expect(await loader.calls() == 1)
    }

    @Test func coordinatorPrefetchesOnce() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = StubChapterLoader(content: "下一章")
        let coordinator = ChapterContentCoordinator(loader: loader, cache: .init(directory: directory))
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "next", title: "下一章", bookUrl: book.bookUrl, index: 1)
        let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "源")

        #expect(await coordinator.prefetch(book: book, chapter: chapter, source: source))
        #expect(!(await coordinator.prefetch(book: book, chapter: chapter, source: source)))
        #expect(await loader.calls() == 1)
    }

    @Test func prefetchReportsWriteFailuresInsteadOfClaimingAvailability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("regular file".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ChapterContentCoordinator(loader: StubChapterLoader(content: "正文"), cache: .init(directory: directory))
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let result = await coordinator.prefetchResult(book: book,
            chapter: .init(url: "one", title: "一", bookUrl: book.bookUrl, index: 0),
            source: .init(bookSourceUrl: "source", bookSourceName: "源"))
        #expect(!result.isAvailable)
        guard case .failed = result else { Issue.record("A failed disk write must be reported as a failed cache job"); return }
    }

    @Test func savingOverTheBudgetPrunesTheOldestChapter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory, maximumTotalBytes: ChapterContentCache.maximumEntryBytes)
        let body = String(repeating: "a", count: 3 * 1024 * 1024)
        for chapter in ["one", "two", "three"] {
            try await cache.save(.init(bookURL: "book", chapterURL: chapter, content: body))
        }
        #expect(try await cache.load(bookURL: "book", chapterURL: "one") == nil)
        #expect(try await cache.load(bookURL: "book", chapterURL: "two") != nil)
        #expect(try await cache.load(bookURL: "book", chapterURL: "three") != nil)
        #expect(try await cache.statistics().bytes <= ChapterContentCache.maximumEntryBytes)
    }

    @Test func prefetchRejectsPartialErrorResponsesAndKeepsFailedChaptersUncached() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let coordinator = ChapterContentCoordinator(loader: PartialFailureLoader(), cache: cache)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let result = await coordinator.prefetchResult(book: book,
            chapter: .init(url: "one", title: "一", bookUrl: book.bookUrl, index: 0),
            source: .init(bookSourceUrl: "source", bookSourceName: "源"))
        #expect(result == .failed("HTTP 403"))
        #expect(try await cache.load(bookURL: "book", chapterURL: "one") == nil)
    }

    @Test func cachePlannerSelectsRangeAndSkipsVolumeRows() {
        var chapters = (0..<5).map { BookChapter(url: "c\($0)", title: "第 \($0) 章", bookUrl: "book", index: $0) }
        chapters[2].isVolume = true

        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: 1, limit: 2)

        #expect(jobs.map(\.chapter.index) == [1, 3])
        #expect(jobs.map(\.nextChapterURL) == ["c3", "c4"])
    }

    @Test func cachePlannerClampsStartAndRejectsEmptyLimit() {
        let chapters = (0..<2).map { BookChapter(url: "c\($0)", title: "章", bookUrl: "book", index: $0) }

        #expect(ChapterCachePlanner.plan(chapters: chapters, startIndex: 99).map(\.chapter.index) == [1])
        #expect(ChapterCachePlanner.plan(chapters: chapters, startIndex: 0, limit: 0).isEmpty)
    }
}

private actor GatedChapterLoader: ChapterContentLoading {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        calls += 1; started?.resume(); started = nil
        if !released { await withCheckedContinuation { pending.append($0) } }
        return .init(title: chapter.title, content: "准备完成的正文")
    }
    func waitUntilStarted() async {
        if calls == 0 { await withCheckedContinuation { started = $0 } }
    }
    func release() {
        released = true
        pending.forEach { $0.resume() }; pending = []
    }
}

private struct PartialFailureLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: "仅半章正文", diagnostics: [.init(severity: .error, code: "content.request", message: "HTTP 403", rule: chapter.url)])
    }
}

private actor StubChapterLoader: ChapterContentLoading {
    private let content: String
    private var callCount = 0

    init(content: String) { self.content = content }

    func loadContent(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String?,
        maxPages: Int
    ) async -> ChapterContentReport {
        callCount += 1
        return .init(title: chapter.title, content: content)
    }

    func calls() -> Int { callCount }
}

private struct PartialChapterLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: "仅第一页", diagnostics: [.init(severity: .error, code: "content.request", message: "第二页加载失败", rule: chapter.url)])
    }
}
