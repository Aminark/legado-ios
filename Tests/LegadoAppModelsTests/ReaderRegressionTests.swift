import Foundation
import Combine
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ReaderRegressionTests {
    @Test func partialContentKeepsFailureVisibleAcrossContinuousChapters() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let loader = RecoveringReaderLoader(partialBody: "只有第一页")
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader,
                                    cache: .init(directory: directory))
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == "只有第一页")
        #expect(model.currentChapterError != nil)
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.error != nil })
        model.updateContinuousPosition(chapter: 1)
        #expect(model.currentChapterError != nil)
        await loader.recover()
        await model.retryContinuousChapter(index: 1, rules: [])
        #expect(model.currentChapterError == nil)
        #expect(model.content == "恢复正文1")
    }

    @Test func togglingPurificationInvalidatesInFlightLoadAndKeepsNewSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let loader = PurificationRaceLoader()
        let model = ReaderViewModel(book: book, chapters: [chapter], initialIndex: 0,
                                    source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader,
                                    cache: .init(directory: directory))
        let rule = ReplaceRule(id: 1, name: "净化", pattern: "广告", replacement: "")
        let oldLoad = Task { await model.load(rules: [rule], prefetchNextChapter: false) }
        await loader.waitForRequest()
        let generation = model.chapterLoadGeneration

        model.toggleReplaceRules()
        #expect(model.chapterLoadGeneration > generation)
        #expect(!model.isLoading)
        await model.load(rules: [rule], prefetchNextChapter: false)
        await loader.finish()
        await oldLoad.value

        #expect(!model.usesReplaceRules)
        #expect(model.content == "广告新正文")
    }

    @Test func failedContinuousChapterPreservesReasonAndRetryFetchesFreshBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let loader = RecoveringReaderLoader()
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: book.origin, bookSourceName: "源"), service: loader, cache: cache)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.currentChapterError == "HTTP 403：正文访问失败")
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.error == "HTTP 403：正文访问失败" })
        model.updateContinuousPosition(chapter: 1)
        #expect(model.currentChapterError == "HTTP 403：正文访问失败")
        let revision = model.scrollRevision
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapters[1].url, content: "旧缓存正文", sourceID: book.origin))
        await loader.recover()
        await model.retryContinuousChapter(index: 1, rules: [])
        #expect(model.currentChapterError == nil)
        #expect(model.content == "恢复正文1")
        #expect(model.scrollChapters.first(where: { $0.id == 1 })?.error == nil)
        #expect(model.currentIndex == 1)
        #expect(model.scrollRevision == revision)
        #expect(model.scrollRetries.isEmpty)
    }

    @Test func switchedReaderUsesVerifiedBodyWithoutRepeatingTheRequestAndCachesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let loader = RecoveringReaderLoader()
        let book = Book(bookUrl: "book", name: "书", origin: "old")
        let chapters = [BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)]
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "old", bookSourceName: "旧源"), service: loader, cache: cache)
        var replacement = book
        replacement.origin = "new"
        replacement.durChapterPos = 2
        model.applySourceSwitch(.init(book: replacement, chapters: chapters, exactChapterMatch: true,
                                      verifiedContent: .init(content: "已验证的正文")),
                                source: .init(bookSourceUrl: "new", bookSourceName: "新源"))
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == "已验证的正文")
        #expect(model.currentChapterError == nil)
        #expect(model.requestedPosition == 2)
        #expect(await loader.calls == 0)
        let cached = try #require(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[0].url))
        #expect(cached.content == "已验证的正文")
        #expect(cached.sourceID == "new")
    }

    @Test func sameURLSourceSwitchFetchesReplacementInsteadOfOldCachedBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "shared-book", name: "书", origin: "old-source")
        let chapters = (0..<2).map { BookChapter(url: "shared-\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "old-source", bookSourceName: "旧源"),
                                    service: SourceAwareReaderLoader(), cache: cache)
        await model.load(rules: [], prefetchNextChapter: false)
        await model.prepareContinuousReading(rules: [])
        #expect(model.content == "old-source正文0")
        var replacement = book
        replacement.origin = "new-source"
        model.applySourceSwitch(.init(book: replacement, chapters: chapters, exactChapterMatch: true),
                                source: .init(bookSourceUrl: "new-source", bookSourceName: "新源"))
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == "new-source正文0")
        #expect(!model.loadedFromCache)
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.content.contains("new-source") })
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapters[1].url,
                                   content: "迟到的旧源缓存", sourceID: "old-source"))
        model.select(index: 1)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == "new-source正文1")
        #expect(!model.loadedFromCache)
    }

    @Test func sourceSwitchReplacesDirectoryBodyAndScrollWindowAtMappedPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldBook = Book(bookUrl: "old-book", name: "书", origin: "old-source")
        let oldChapters = (0..<3).map { BookChapter(url: "old-\($0)", title: "旧\($0)", bookUrl: oldBook.bookUrl, index: $0) }
        let model = ReaderViewModel(book: oldBook, chapters: oldChapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "old-source", bookSourceName: "旧源"),
                                    service: SourceAwareReaderLoader(), cache: .init(directory: directory))
        await model.load(rules: [], prefetchNextChapter: false)
        await model.prepareContinuousReading(rules: [])
        model.updateContinuousPosition(chapter: 1)
        let current = model.bookForSourceSwitch(position: 4)
        #expect(current.durChapterIndex == 1)
        #expect(current.durChapterTitle == "旧1")
        #expect(current.durChapterPos == 4)
        let generation = model.chapterLoadGeneration
        var newBook = Book(bookUrl: "new-book", name: "书", origin: "new-source")
        newBook.durChapterIndex = 2
        newBook.durChapterPos = 4
        let newChapters = (0..<4).map { BookChapter(url: "new-\($0)", title: "新\($0)", bookUrl: newBook.bookUrl, index: $0) }
        model.applySourceSwitch(.init(book: newBook, chapters: newChapters, exactChapterMatch: true),
                                source: .init(bookSourceUrl: "new-source", bookSourceName: "新源"))
        #expect(model.book.origin == "new-source")
        #expect(model.chapters == newChapters)
        #expect(model.currentIndex == 2)
        #expect(model.requestedPosition == 4)
        #expect(model.content.isEmpty)
        #expect(model.scrollChapters.isEmpty)
        #expect(model.chapterLoadGeneration > generation)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == "new-source正文2")
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.content.contains("new-source") })
    }

    @Test func localBookshelfLoadProvidesBookAndDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "本地书.txt")
        try "第一章 开始\n正文\n第二章 继续\n后续正文".write(to: file, atomically: true, encoding: .utf8)
        let imported = try LocalBookService().importTextFile(at: file, into: directory.appending(path: "books"))
        let model = BookshelfReadViewModel(updateCoordinator: .init(repository: InMemoryBookChapterRepository()))

        await model.load(book: imported.book, source: nil)

        #expect(!model.chapters.isEmpty)
        #expect(model.resolvedBook == imported.book)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    @Test func selectingSameChapterRestartsLoadAtRequestedPosition() async {
        let book = Book(bookUrl: "demo://book", name: "书")
        let chapters = [BookChapter(url: "demo://1", title: "第一章", bookUrl: book.bookUrl, index: 0)]
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "正文第一段\n正文第二段")
        let generation = model.chapterLoadGeneration

        model.select(index: 0, position: 6)
        #expect(model.currentIndex == 0)
        #expect(model.chapterLoadGeneration != generation)
        await model.load(rules: [])

        #expect(model.hasLoadedCurrentChapter)
        #expect(!model.content.isEmpty)
        #expect(model.requestedPosition == 6)
        #expect(!model.isLoading)
    }

    @Test func previousChapterEndPositionCannotOverflowRenderedOffset() async {
        let book = Book(bookUrl: "demo://book", name: "书")
        let chapters = (0..<2).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 1, content: "正文内容")
        model.goPrevious(position: Int.max)
        await model.load(rules: [])
        let prefix = model.title.utf16.count + 1
        let renderedLength = prefix + model.content.utf16.count

        #expect(ReaderPositionResolver.renderedLocation(
            position: model.requestedPosition, prefixLength: prefix, renderedLength: renderedLength
        ) == renderedLength - 1)
        #expect(ReaderPositionResolver.renderedLocation(position: 2, prefixLength: 4, renderedLength: 20) == 6)
        #expect(ReaderPositionResolver.renderedLocation(position: Int.max, prefixLength: Int.max, renderedLength: 0) == 0)
    }

    @Test func enteringScrollModePreparesContinuationWithoutChangingCurrentChapter() async {
        let book = Book(bookUrl: "demo://scroll", name: "书")
        let chapters = (0..<3).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 1, content: "章节正文")
        await model.load(rules: [])
        #expect(!model.hasContinuationWindow)

        await model.loadAdjacentChapters(rules: [])

        #expect(model.currentIndex == 1)
        #expect(model.isPreviousWindowReady)
        #expect(model.isContinuationWindowReady)
        let generation = model.chapterLoadGeneration
        model.promoteContinuation(position: 2)
        #expect(model.currentIndex == 2)
        #expect(model.chapterLoadGeneration != generation)
        #expect(model.requestedPosition == 2)
        #expect(!model.content.isEmpty)
    }

    @Test func bookmarkPrefersChapterTitleAfterDirectoryReordering() {
        let chapters = [
            BookChapter(url: "notice", title: "前言", bookUrl: "book", index: 0),
            BookChapter(url: "first", title: "第一章", bookUrl: "book", index: 1),
            BookChapter(url: "second", title: "第二章", bookUrl: "book", index: 2)
        ]
        var bookmark = Bookmark(time: 1, bookName: "书")
        bookmark.chapterIndex = 1
        bookmark.chapterName = "第二章"
        #expect(bookmark.resolvedChapterIndex(in: chapters) == 2)
        bookmark.chapterName = "旧标题"
        #expect(bookmark.resolvedChapterIndex(in: chapters) == 1)
        bookmark.chapterIndex = 99
        #expect(bookmark.resolvedChapterIndex(in: chapters) == nil)
    }

    @Test func bookmarkSelectionUsesSavedPositionAndCurrentPageAfterReopening() {
        let book = Book(bookUrl: "demo://bookmarks", name: "书", author: "作者")
        let chapters = (0..<2).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        var saved = Bookmark(time: 1, bookName: book.name, bookAuthor: book.author)
        saved.chapterIndex = 0
        saved.chapterName = chapters[0].title
        saved.chapterPosition = 40
        var otherBook = saved
        otherBook.bookAuthor = "其他作者"
        var otherChapter = saved
        otherChapter.chapterIndex = 1
        otherChapter.chapterName = chapters[1].title
        let bookmarks = [saved, otherBook, otherChapter]
        let reopened = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "正文")

        #expect(reopened.bookmarks(at: 40, in: bookmarks) == [saved])
        #expect(reopened.bookmarks(at: 0, in: bookmarks, pageRange: NSRange(location: 0, length: 80)) == [saved])
        #expect(reopened.bookmarks(at: 80, in: bookmarks, pageRange: NSRange(location: 80, length: 80)).isEmpty)
        #expect(reopened.bookmarks(at: 41, in: bookmarks).isEmpty)
        #expect(reopened.bookmarks(at: 40, in: []).isEmpty)
        reopened.select(index: 1)
        #expect(reopened.bookmarks(at: 40, in: bookmarks) == [otherChapter])
    }

    @Test func continuousReadingExtendsPastThreeChaptersWithoutNavigating() async {
        let book = Book(bookUrl: "demo://continuous", name: "书")
        let chapters = (0..<20).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 5, content: "很短的正文👨‍👩‍👧‍👦")
        let generation = model.chapterLoadGeneration
        await model.prepareContinuousReading(rules: [])
        for _ in 0..<4 { await model.extendContinuousReading(direction: 1, rules: []) }

        #expect(model.scrollChapters.map(\.id) == Array(3...15))
        #expect(model.currentIndex == 5)
        #expect(model.chapterLoadGeneration == generation)
        let revision = model.scrollRevision
        #expect(model.updateContinuousPosition(chapter: 10))
        #expect(model.currentIndex == 10)
        #expect(model.title == chapters[10].title)
        #expect(model.chapterLoadGeneration == generation)
        #expect(model.scrollRevision == revision)
        #expect(model.scrollChapters.count == 13)
        #expect(model.updateContinuousPosition(chapter: 4))
        #expect(model.currentIndex == 4)
    }

    @Test func continuousReadingSkipsVolumesAndReloadsRecycledChaptersInOrder() async {
        let book = Book(bookUrl: "demo://volumes", name: "书")
        var chapters = (0..<16).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        chapters[3].isVolume = true
        chapters[7].isVolume = true
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 5, content: "正文")
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.map(\.id) == [2, 4, 5, 6, 8])
        model.retainContinuousChapters([5, 6, 8])
        await model.extendContinuousReading(direction: -1, rules: [])
        #expect(model.scrollChapters.map(\.id) == [2, 4, 5, 6, 8])
        #expect(Set(model.scrollChapters.map(\.id)).count == model.scrollChapters.count)
    }

    @Test func explicitNavigationResetsContinuousSessionAndKeepsRequestedOffset() async {
        let book = Book(bookUrl: "demo://jump", name: "书")
        let chapters = (0..<10).map { BookChapter(url: "demo://\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 1, content: "第一段\n第二段")
        await model.prepareContinuousReading(rules: [])
        let revision = model.scrollRevision
        model.select(index: 7, position: 4)
        #expect(model.scrollChapters.isEmpty)
        #expect(model.scrollRevision != revision)
        await model.load(rules: [])
        await model.prepareContinuousReading(rules: [])
        #expect(model.currentIndex == 7)
        #expect(model.requestedPosition == 4)
        #expect(model.scrollChapters.map(\.id) == Array(5...9))
    }

    @Test func failedContinuousChapterCanBeRetriedWithoutMovingTheViewport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "retry.txt")
        try "原始正文".write(to: file, atomically: true, encoding: .utf8)
        var book = Book(bookUrl: file.absoluteString, name: "书")
        book.charset = "UTF-8"
        let chapters = (0..<2).map { BookChapter(url: "local:\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0)
        await model.load(rules: [])
        try FileManager.default.removeItem(at: file)
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.last?.error != nil)
        let revision = model.scrollRevision
        try "恢复后的正文".write(to: file, atomically: true, encoding: .utf8)
        await model.retryContinuousChapter(index: 1, rules: [])
        #expect(model.scrollChapters.last?.error == nil)
        #expect(model.scrollChapters.last?.content.contains("恢复后的正文") == true)
        #expect(model.currentIndex == 0)
        #expect(model.scrollRevision == revision)
    }

    @Test func genuinelyEmptyChaptersDoNotBecomeFailuresOrArtificialBlankScreens() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "empty.txt")
        try "正文".write(to: file, atomically: true, encoding: .utf8)
        var book = Book(bookUrl: file.absoluteString, name: "书")
        book.charset = "UTF-8"
        var chapters = (0..<2).map { BookChapter(url: "local:\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        chapters[1].start = 0
        chapters[1].end = 0
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0)
        await model.load(rules: [])
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.last?.content == "")
        #expect(model.scrollChapters.last?.error == nil)
    }

    @Test func aLatePrefetchCannotRestoreAnOldScrollSessionAfterDirectoryNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "https://test.invalid/book", name: "书")
        let chapters = (0..<6).map { BookChapter(url: "https://test.invalid/\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapters[0].url, content: "缓存正文"))
        let loader = SuspendedReaderChapterLoader()
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "https://test.invalid", bookSourceName: "测试源"),
                                    service: loader, cache: cache)
        await model.load(rules: [])
        let prefetch = Task { await model.prepareContinuousReading(rules: []) }
        await loader.waitUntilSuspended()
        model.select(index: 4, position: 2)
        await model.load(rules: [])
        await loader.release()
        await prefetch.value
        #expect(model.currentIndex == 4)
        #expect(model.requestedPosition == 2)
        #expect(model.content == "正文4")
        #expect(model.scrollChapters.isEmpty)
        #expect(!model.isLoadingScrollAhead)
    }

    @Test func cachedChaptersKeepAdvancingThePrefetchWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "rolling", name: "书", origin: "source")
        let chapters = (0..<5).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        try await cache.save(.init(bookURL: book.id, chapterURL: "c0", content: "初始缓存", sourceID: "source"))
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: SourceAwareReaderLoader(), cache: cache, prefetchLimit: 1)
        await model.load(rules: [])
        #expect(model.loadedFromCache)
        for target in 1...3 {
            for _ in 0..<100 {
                if try await cache.load(bookURL: book.id, chapterURL: "c\(target)") != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(try await cache.load(bookURL: book.id, chapterURL: "c\(target)") != nil)
            #expect(try await cache.load(bookURL: book.id, chapterURL: "c\(target + 1)") == nil)
            #expect(await model.turnPagedChapter(direction: 1, rules: []))
            #expect(model.currentIndex == target)
            #expect(model.loadedFromCache)
        }
        model.cancelPreloading()
    }

    @Test func returningToAnAlreadyLoadedPageRestartsPreloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "resume", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        try await cache.save(.init(bookURL: book.id, chapterURL: "c0", content: "缓存正文", sourceID: "source"))
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: SourceAwareReaderLoader(), cache: cache, prefetchLimit: 1)
        await model.load(rules: [], prefetchNextChapter: false)
        model.cancelPreloading()
        await model.load(rules: [])
        for _ in 0..<100 {
            if try await cache.load(bookURL: book.id, chapterURL: "c1") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try await cache.load(bookURL: book.id, chapterURL: "c1") != nil)
        #expect(model.currentIndex == 0 && model.content == "缓存正文")
        model.cancelPreloading()
    }

    @Test func preparingAPagedPreviewDoesNotNavigateAndCancellationRejectsItsCommit() async throws {
        let book = Book(bookUrl: "preview", name: "书")
        let chapters = (0..<3).map { BookChapter(url: "p\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 1, content: "正文👨‍👩‍👧‍👦末尾")
        let preview = try #require(await model.preparePagedChapter(direction: -1, rules: []))
        #expect(model.currentIndex == 1 && model.requestedPosition == 0 && model.chapterTransition == nil)
        #expect(preview.targetIndex == 0 && preview.content == model.content)
        model.cancelPagedChapterTurn()
        #expect(!model.commitPagedChapter(preview))
        #expect(model.currentIndex == 1 && model.pagedChapterDirection == nil)
        let retry = try #require(await model.preparePagedChapter(direction: -1, rules: []))
        #expect(model.commitPagedChapter(retry))
        #expect(model.currentIndex == 0 && model.requestedPosition == retry.content.utf16.count - 1)
        #expect(!model.commitPagedChapter(retry), "A released gesture can commit only once")
    }

    @Test func aPreparedPageCannotCommitAfterDirectoryNavigation() async throws {
        let book = Book(bookUrl: "preview-directory", name: "书")
        let chapters = (0..<3).map { BookChapter(url: "p\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        let model = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "原正文")
        let preview = try #require(await model.preparePagedChapter(direction: 1, rules: []))
        model.select(index: 2, position: 2)
        await model.load(rules: [])
        #expect(!model.commitPagedChapter(preview))
        #expect(model.currentIndex == 2 && model.requestedPosition == 2)
    }

    @Test func aSlowPagedTurnKeepsTheOldDocumentAndRejectsDuplicateTurns() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = SuspendedReaderChapterLoader()
        let book = Book(bookUrl: "paged", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader,
            cache: .init(directory: directory), prefetchLimit: 0)
        await model.load(rules: [])
        let turn = Task { await model.turnPagedChapter(direction: 1, rules: []) }
        await loader.waitUntilSuspended()
        #expect(model.currentIndex == 0 && model.content == "正文0")
        #expect(model.hasLoadedCurrentChapter && !model.isLoading)
        #expect(model.pagedChapterDirection == 1)
        #expect(!(await model.turnPagedChapter(direction: 1, rules: [])))
        await loader.release()
        #expect(await turn.value)
        #expect(model.currentIndex == 1 && model.content == "迟到的正文")
        #expect(model.requestedPosition == 0 && model.pagedChapterDirection == nil)
        #expect(model.chapterTransition?.direction == 1)
        #expect(await model.turnPagedChapter(direction: -1, rules: []))
        #expect(model.content == "正文0" && model.currentIndex == 0)
        #expect(model.requestedPosition == "正文0".utf16.count - 1)
        #expect(model.chapterTransition?.direction == -1)
    }

    @Test(arguments: [false, true])
    func latePagedTurnsCannotOverwriteDirectoryNavigationOrAClosedReader(_ navigate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = SuspendedReaderChapterLoader()
        let book = Book(bookUrl: "cancel-paged", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader,
            cache: .init(directory: directory), prefetchLimit: 0)
        await model.load(rules: [])
        let turn = Task { await model.turnPagedChapter(direction: 1, rules: []) }
        await loader.waitUntilSuspended()
        if navigate { model.select(index: 2, position: 2); await model.load(rules: []) }
        else { model.cancelPreloading() }
        await loader.release()
        #expect(!(await turn.value))
        #expect(model.currentIndex == (navigate ? 2 : 0))
        #expect(model.content == (navigate ? "正文2" : "正文0"))
        #expect(model.chapterTransition == nil && model.pagedChapterDirection == nil)
    }

    @Test func failedPagedTurnsKeepTheCurrentChapterAndRetryWithoutCachingTheFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let loader = RecoveringReaderLoader()
        let book = Book(bookUrl: "retry-paged", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        try await cache.save(.init(bookURL: book.id, chapterURL: "c0", content: "原章节", sourceID: "source"))
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader, cache: cache, prefetchLimit: 0)
        await model.load(rules: [])
        #expect(!(await model.turnPagedChapter(direction: 1, rules: [])))
        #expect(model.content == "原章节" && model.currentIndex == 0)
        #expect(model.pagedChapterError?.contains("403") == true)
        #expect(try await cache.load(bookURL: book.id, chapterURL: "c1") == nil)
        await loader.recover()
        #expect(await model.turnPagedChapter(direction: 1, rules: []))
        #expect(model.content == "恢复正文1" && model.pagedChapterError == nil)
        #expect(try await cache.load(bookURL: book.id, chapterURL: "c2") == nil, "A disabled preload setting must remain disabled")
    }

    @Test func readerPrefetchCachesUpcomingChaptersFromTheCurrentPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<4).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: 1,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"),
            service: SourceAwareReaderLoader(),
            cache: cache
        )
        await model.load(rules: [], prefetchNextChapter: false)
        model.cacheNextTen()
        for _ in 0..<80 where model.isCaching {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!model.isCaching)
        #expect(model.cacheTotal == 3)
        #expect(model.cacheCompleted == 3)
        #expect(model.cacheSucceeded == 3)
        #expect(model.cacheFailed == 0)
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[1].url)?.content == "source正文1")
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[3].url)?.content == "source正文3")
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[0].url) == nil)
        #expect(model.isChapterCached(chapters[1]))
        #expect(model.isChapterCached(chapters[3]))
        #expect(!model.isChapterCached(chapters[0]))
    }

    @Test func batchCachingPublishesIncrementalAvailabilityAndSeparatesFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "batch", name: "书", origin: "source")
        let chapters = (0..<20).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: BatchCacheReaderLoader(), cache: cache)
        var updates = 0
        let token = model.$cacheCompleted.sink { _ in updates += 1 }
        model.cacheRemaining()
        var sawIncrementalState = false
        for _ in 0..<200 {
            if model.isCaching, model.cacheCompleted > 0 {
                sawIncrementalState = model.isChapterCached(chapters[1])
            }
            if !model.isCaching { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        withExtendedLifetime(token) {}
        #expect(sawIncrementalState)
        #expect(!model.isCaching)
        #expect(model.cacheCompleted == 20)
        #expect(model.cacheFailed == 3)
        #expect(model.cacheSucceeded == 17)
        #expect(model.cacheError == "HTTP 403")
        #expect(!model.isChapterCached(chapters[5]))
        #expect(model.isChapterCached(chapters[19]))
        #expect(updates < model.cacheCompleted, "Progress must be coalesced instead of invalidating the directory once per chapter")
        try await cache.removeAll()
        await model.refreshCachedChapters()
        #expect(model.cachedChapterURLs.isEmpty)
    }

    @Test func stoppedBatchCannotOverwriteTheProgressOfANewBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(bookUrl: "batch", name: "书", origin: "source")
        let chapters = (0..<20).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: BatchCacheReaderLoader(), cache: .init(directory: directory))
        model.cacheRemaining()
        try await Task.sleep(nanoseconds: 30_000_000)
        model.cancelCaching()
        model.cacheNextTen()
        for _ in 0..<200 where model.isCaching { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!model.isCaching)
        #expect(model.cacheTotal == 10)
        #expect(model.cacheCompleted == 10)
        #expect(model.cacheFailed == 1)
        #expect(!model.isChapterCached(chapters[15]))
    }

    @Test func clearingDiskCacheDoesNotTreatTheDisplayedBodyAsDownloaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "c0", title: "一", bookUrl: book.bookUrl, index: 0)
        let model = ReaderViewModel(book: book, chapters: [chapter], initialIndex: 0,
            source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: SourceAwareReaderLoader(), cache: cache)
        await model.load(rules: [], prefetchNextChapter: false)
        await model.refreshCachedChapters()
        #expect(model.isChapterCached(chapter))
        try await cache.removeAll()
        await model.refreshCachedChapters()
        #expect(!model.content.isEmpty)
        #expect(!model.isChapterCached(chapter))
    }
}

private struct BatchCacheReaderLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        try? await Task.sleep(nanoseconds: 90_000_000)
        if chapter.index > 0, chapter.index.isMultiple(of: 5) {
            return .init(diagnostics: [.init(severity: .error, code: "content.request", message: "HTTP 403", rule: chapter.url)])
        }
        return .init(title: chapter.title, content: "测试正文\(chapter.index)")
    }
}

private actor RecoveringReaderLoader: ChapterContentLoading {
    var calls = 0
    private var recovered = false
    private let partialBody: String
    init(partialBody: String = "") { self.partialBody = partialBody }
    func recover() { recovered = true }
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        calls += 1
        if recovered { return .init(content: "恢复正文\(chapter.index)") }
        return .init(content: partialBody, diagnostics: [.init(severity: .error, code: "content.request", message: "HTTP 403：正文访问失败", rule: chapter.url)])
    }
}

private actor PurificationRaceLoader: ChapterContentLoading {
    private var pending: CheckedContinuation<ChapterContentReport, Never>?
    private var calls = 0
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        calls += 1
        if calls > 1 { return .init(content: "广告新正文") }
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForRequest() async { while pending == nil { await Task.yield() } }
    func finish() { pending?.resume(returning: .init(content: "广告旧正文")); pending = nil }
}

private struct SourceAwareReaderLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(title: chapter.title, content: source.id + "正文\(chapter.index)")
    }
}

private actor SuspendedReaderChapterLoader: ChapterContentLoading {
    private var pending: CheckedContinuation<ChapterContentReport, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        guard chapter.index == 1 else { return .init(title: chapter.title, content: "正文\(chapter.index)") }
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume(returning: .init(title: "旧章节", content: "迟到的正文"))
        pending = nil
    }
}
