import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ReaderRegressionTests {
    @Test func reopenedShelfBookReadsDirectoryAndVisitedChaptersWithNetworkOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("books.sqlite")
        let cacheURL = dir.appendingPathComponent("cache")
        let db = try LegadoDatabase(url: dbURL)
        let store = SQLiteBookRepository(database: db)
        let directory = SQLiteBookChapterRepository(database: db)
        let library = BookLibraryModel(repository: store, chapterRepository: directory)
        let source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "源")
        var book = Book(bookUrl: "book", name: "书", origin: source.id)
        book.totalChapterNum = 2
        let chapters = (0..<2).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let service = CacheRegressionSource()
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0, source: source,
                                     service: service, cache: .init(directory: cacheURL))
        await reader.load(rules: [], prefetchNextChapter: false)
        reader.goNext()
        await reader.load(rules: [], prefetchNextChapter: false)
        #expect(await library.addOrUpdate(book, chapters: chapters))
        await library.updateProgress(for: book, chapter: chapters[1], position: 2)
        await service.disconnect()

        let reopenedDB = try LegadoDatabase(url: dbURL)
        let restored = try #require(try await reopenedDB.loadBooks().first)
        let opener = BookshelfReadViewModel(updateCoordinator: .init(repository: SQLiteBookChapterRepository(database: reopenedDB),
                                                                    loader: service))
        await opener.load(book: restored, source: source)
        #expect(opener.chapters == chapters)
        let reopened = ReaderViewModel(book: restored, chapters: opener.chapters, initialIndex: restored.durChapterIndex,
                                       source: source, service: service, cache: .init(directory: cacheURL))
        #expect(reopened.requestedPosition == 2)
        for index in [1, 0, 1] {
            reopened.select(index: index)
            await reopened.load(rules: [], prefetchNextChapter: false)
            #expect(reopened.content == "正文\(index)")
            #expect(reopened.loadedFromCache)
        }
        #expect(await service.contentRequests == [0, 1])
        #expect(await service.directoryRequests == 0)
    }

    @Test func coldShelfAndPreparedNextChapterAreReadableBeforeTheirViewTasksStart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ChapterContentCache(directory: dir)
        let loader = CacheRegressionSource()
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        var book = Book(bookUrl: "book", name: "书", origin: source.id)
        book.durChapterPos = 2
        let chapters = (0..<7).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        try await cache.save(.init(bookURL: "book", chapterURL: "c0", content: "第0章\n第一段", sourceID: source.id))
        try await cache.save(.init(bookURL: "book", chapterURL: "c1", content: "第1章\n下一段", sourceID: source.id))
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0, source: source, service: loader, cache: cache)
        defer { reader.stopBackgroundReading() }
        await reader.prepareCachedOpening(rules: [])
        #expect(reader.content == "第一段")
        #expect(reader.visibleScrollChapters.first?.id == 0)
        #expect(reader.requestedPosition == 2 && reader.hasLoadedCurrentChapter && !reader.isWaitingForSource)
        #expect(await loader.contentRequests.isEmpty)
        #expect(reader.canResumePrepared(book: book, chapters: chapters, source: source, rules: []))
        var revised = chapters
        revised[1].url = "replaced"
        #expect(!reader.canResumePrepared(book: book, chapters: revised, source: source, rules: []))

        await reader.load(rules: [])
        for _ in 0..<150 {
            if try await cache.load(bookURL: "book", chapterURL: "c4") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        reader.goNext()
        #expect(reader.currentIndex == 1 && reader.content == "下一段")
        #expect(reader.hasLoadedCurrentChapter && !reader.isWaitingForSource)
        #expect(reader.visibleScrollChapters.first?.content == "下一段")
        reader.goPrevious()
        #expect(reader.hasLoadedCurrentChapter && reader.content == "第一段")
        reader.goNext()
        // A later edit must supersede any display-ready copy of chapter two.
        try await cache.save(.init(bookURL: "book", chapterURL: "c2", content: "修改后的正文", sourceID: source.id))
        reader.goNext()
        #expect(!reader.hasLoadedCurrentChapter)
        await reader.load(rules: [], prefetchNextChapter: false)
        #expect(reader.content == "修改后的正文" && reader.loadedFromCache)
        #expect(await loader.contentRequests.filter { $0 < 2 }.isEmpty)
    }

    @Test func cachedChapterButtonsKeepTheContinuousWindowAndRecheckEditedContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ChapterContentCache(directory: dir)
        let loader = CacheRegressionSource()
        await loader.disconnect()
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        var book = Book(bookUrl: "book", name: "书", origin: source.id)
        book.durChapterIndex = 1
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        for chapter in chapters {
            try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapter.url, content: "正文\(chapter.index)", sourceID: source.id))
        }
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 1, source: source, service: loader, cache: cache)
        defer { reader.stopBackgroundReading() }
        await reader.prepareCachedOpening(rules: [], speculative: true)
        await reader.load(rules: [], prefetchNextChapter: false)
        await reader.prepareContinuousReading(rules: [])
        let window = reader.scrollChapters
        #expect(window.map(\.id) == [0, 1, 2])
        reader.goPrevious()
        #expect(reader.content == "正文0" && reader.scrollChapters == window)
        reader.goNext()
        #expect(reader.content == "正文1" && reader.scrollChapters == window)
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: "c2", content: "本地修订", sourceID: source.id))
        reader.goNext()
        #expect(!reader.hasLoadedCurrentChapter && reader.scrollChapters.isEmpty)
        await reader.load(rules: [], prefetchNextChapter: false)
        #expect(reader.content == "本地修订")
        #expect(await loader.contentRequests.isEmpty)
    }

    @Test func cachedPageStartsNextPreloadAndImmediateForwardTapSharesIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ChapterContentCache(directory: dir)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<2).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapters[0].url, content: "已读正文", sourceID: book.origin))
        let source = CacheRegressionSource()
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: book.origin, bookSourceName: "源"),
                                    service: source, cache: cache)
        await model.load(rules: [])
        for _ in 0..<100 where await source.contentRequests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(await source.contentRequests == [1])
        model.goNext()
        await model.load(rules: [])
        #expect(model.content == "正文1")
        #expect(await source.contentRequests == [1])
    }

    @Test(arguments: [false, true])
    func jumpingBackWhileASlowUpcomingChapterOccupiesTheSource(targetCached: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ChapterContentCache(directory: dir)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<6).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        for index in targetCached ? [1, 2] : [2] {
            try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapters[index].url, content: "缓存\(index)"))
        }
        let service = SlowPrefetchReaderSource()
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 2,
                                     source: .init(bookSourceUrl: book.origin, bookSourceName: "源"),
                                     service: service, cache: cache)
        defer { reader.stopBackgroundReading() }
        await reader.load(rules: [])
        for _ in 0..<100 where !(await service.slotOccupied) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(await service.slotOccupied)
        reader.goPrevious()
        await reader.load(rules: [])
        #expect(reader.content == (targetCached ? "缓存1" : "正文1"))
        #expect(await service.prefetchCancelled == !targetCached)
        #expect(await service.foregroundRequests == (targetCached ? 0 : 1))
        reader.goNext()
        #expect(reader.hasLoadedCurrentChapter && reader.content == "缓存2")
    }

    @Test(arguments: [false, true])
    func silentPrefetchPersistsFiveReadableChaptersAndAdvancesWithTheReader(continuous: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        let cache = ChapterContentCache(directory: dir)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        var chapters = (0..<9).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        chapters[1].isVolume = true
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: "c3", content: "已有正文", sourceID: book.origin))
        let loader = CacheRegressionSource()
        let source = BookSource(bookSourceUrl: book.origin, bookSourceName: "源")
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0, source: source,
                                     service: loader, cache: cache, settingsStore: store)
        defer { reader.cancelPreload() }
        func waitForChapter(_ index: Int) async throws {
            for _ in 0..<150 {
                if try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[index].url) != nil { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            Issue.record("预读未保存第 \(index) 章")
        }

        await reader.load(rules: [])
        if continuous { await reader.prepareContinuousReading(rules: []) }
        try await waitForChapter(6)
        #expect(reader.currentIndex == 0)
        #expect(reader.content == "正文0")
        #expect(reader.diagnostics.isEmpty)
        #expect(await loader.contentRequests.sorted() == [0, 2, 4, 5, 6])
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: "c7") == nil)

        if continuous {
            #expect(reader.updateContinuousPosition(chapter: 2))
        } else {
            reader.goNext()
            await reader.load(rules: [])
        }
        try await waitForChapter(7)
        #expect(await loader.contentRequests.sorted() == [0, 2, 4, 5, 6, 7])
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: "c8") == nil)
        reader.cancelPreload()
        await loader.disconnect()

        let reopened = ReaderViewModel(book: book, chapters: chapters, initialIndex: 2, source: source,
                                       service: loader, cache: .init(directory: dir), settingsStore: store)
        for index in [2, 3, 4, 5, 6, 7] {
            reopened.select(index: index)
            await reopened.load(rules: [], prefetchNextChapter: false)
            #expect(reopened.loadedFromCache)
            #expect(reopened.content == (index == 3 ? "已有正文" : "正文\(index)"))
        }
        #expect(await loader.contentRequests.sorted() == [0, 2, 4, 5, 6, 7])
    }

    @Test(arguments: [0, 1, 5])
    func savedPrefetchCountAndBookEndLimitSilentRequests(count: Int) async throws {
        let suite = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        var settings = store.settings
        settings.prefetchChapters = count
        try store.save(settings)
        let source = CacheRegressionSource()
        await source.disconnect()
        let cache = ChapterContentCache(directory: dir)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<4).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: "c1", content: "读到这里", sourceID: book.origin))
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 1,
                                     source: .init(bookSourceUrl: book.origin, bookSourceName: "源"),
                                     service: source, cache: cache, settingsStore: store)
        await reader.load(rules: [])
        let expected = Array([2, 3].prefix(count))
        for _ in 0..<100 where await source.contentRequests.count < expected.count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await source.contentRequests == expected)
        #expect(reader.currentIndex == 1)
        #expect(reader.content == "读到这里")
        #expect(reader.diagnostics.isEmpty)
        #expect(reader.currentChapterError == nil)
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: "c2") == nil)
    }

    @Test func readingNearTheEndAppendsAndCachesNewlyPublishedChapters() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = InMemoryBookRepository()
        let directory = InMemoryBookChapterRepository()
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        var book = Book(bookUrl: "book", name: "连载", origin: source.id)
        book.totalChapterNum = 7
        let chapters = (0..<9).map { BookChapter(url: "c\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let initial = Array(chapters.prefix(7))
        let loader = CacheRegressionSource()
        let coordinator = BookUpdateCoordinator(repository: directory, loader: loader)
        let library = BookLibraryModel(repository: shelf, updateCoordinator: coordinator, chapterRepository: directory)
        #expect(await library.addOrUpdate(book, chapters: initial))
        let cache = ChapterContentCache(directory: dir)
        let reader = ReaderViewModel(book: book, chapters: initial, initialIndex: 0, source: source, service: loader, cache: cache)
        defer { reader.stopBackgroundReading() }
        await reader.load(rules: [])
        #expect(reader.checkForNewChapters(using: library) { 0 } == nil)
        reader.goNext()
        await reader.load(rules: [])
        await library.updateProgress(for: book, chapter: chapters[1], position: 2)
        await loader.publish(chapters)
        let check = try #require(reader.checkForNewChapters(using: library) { 2 })
        await check.value
        #expect(reader.content == "正文1")
        #expect(reader.currentIndex == 1)
        #expect(reader.chapters == chapters)
        #expect(library.books.first?.durChapterPos == 2)
        #expect(await coordinator.storedChapters(bookURL: book.bookUrl) == chapters)
        reader.goNext()
        await reader.load(rules: [])
        #expect(reader.checkForNewChapters(using: library) { 0 } == nil)
        for _ in 0..<150 {
            if try await cache.load(bookURL: book.bookUrl, chapterURL: "c7") != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: "c7")?.content == "正文7")
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: "c8") == nil)
        #expect(await loader.directoryRequests == 1)
    }

    @Test func chapterDirectoryNumbersAndSearchStayInReadingOrderAcrossVolumeHeadings() {
        let chapters = ["上卷", "归来", "下卷", "归来", "天明"].enumerated().map { index, title in
            var chapter = BookChapter(url: "chapter", title: title, bookUrl: "book", index: index + 10)
            chapter.isVolume = index == 0 || index == 2
            return chapter
        }
        let directory = ReaderChapterDirectory(chapters)
        #expect(directory.readableIndices == [1, 3, 4])
        #expect(directory.rows.map(\.number) == [nil, 1, nil, 2, 3])
        #expect(directory.rows(matching: "归来", descending: true).map(\.id) == [3, 1])
        #expect(directory.rows(matching: " 2 ", descending: false).map(\.id) == [3])
        #expect(directory.rows(matching: "无此章", descending: true).isEmpty)
    }

    @Test func commentPagesKeepOrderAndIgnoreDuplicatesLatePagesAndCursorLoops() {
        let firstNext = URL(string: "https://comments.test/page/2")!
        let secondNext = URL(string: "https://comments.test/page/3")!
        func page(_ ids: [String], next: URL?) -> ChapterCommentPage {
            .init(comments: ids.map { ChapterComment(id: $0, content: "相同内容") }, nextPageURL: next)
        }
        var pages = ReaderChapterCommentPages()
        pages.append(page(["late"], next: nil), requestedURL: firstNext)
        #expect(pages.comments.isEmpty)
        pages.append(page(["a", "a", "b"], next: firstNext), requestedURL: nil)
        #expect(pages.comments.map(\.id) == ["a", "b"])
        pages.append(page(["wrong"], next: nil), requestedURL: secondNext)
        pages.append(page(["late"], next: nil), requestedURL: nil)
        #expect(pages.nextPageURL == firstNext)
        pages.append(page(["b", "c"], next: secondNext), requestedURL: firstNext)
        #expect(pages.nextPageURL == secondNext)
        pages.append(page(["d"], next: firstNext), requestedURL: secondNext)
        #expect(pages.comments.map(\.id) == ["a", "b", "c", "d"])
        #expect(pages.nextPageURL == nil)
        pages.append(page(["late"], next: firstNext), requestedURL: secondNext)
        #expect(pages.comments.count == 4)
        #expect(pages.nextPageURL == nil)
    }

    @Test func commentTargetsKeepTheirChapterAndSourceAcrossScrollingAndSourceSwitching() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "评论源")
        var rules = ReviewRule()
        rules.reviewUrl = "/comments/{{chapter.index}}"
        rules.contentRule = "$.comments[*].content"
        source.ruleReview = rules
        let book = Book(bookUrl: "https://source.test/book/42", name: "书", origin: source.id)
        let chapters = (0..<3).map { BookChapter(url: "chapter/\($0)", title: "相同的标题", bookUrl: book.bookUrl, index: $0) }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0, source: source,
                                    service: SourceAwareReaderLoader(), cache: .init(directory: directory))
        await model.load(rules: [], prefetchNextChapter: false)
        await model.prepareContinuousReading(rules: [])
        let selected = try #require(model.commentsTarget(at: 1))
        #expect(model.scrollChapters.count == 3)
        #expect(model.scrollChapters.allSatisfy { $0.hasComments })
        #expect(model.currentIndex == 0)
        #expect(selected.chapter.url == chapters[1].url)
        #expect(model.updateContinuousPosition(chapter: 2))
        #expect(model.commentsTarget(at: model.currentIndex)?.chapter == chapters[2])
        #expect(selected.chapter == chapters[1])

        var replacement = book
        replacement.origin = "https://new-source.test"
        model.applySourceSwitch(.init(book: replacement, chapters: chapters, exactChapterMatch: true),
                                source: .init(bookSourceUrl: replacement.origin, bookSourceName: "无评论"))
        #expect(model.commentsTarget(at: 1) == nil)
        #expect(selected.book.origin == source.id)
        #expect(selected.source.id == source.id)
    }

    @Test func commentTargetsRejectMismatchesAndExposeOnlyExactOfficialChaptersWithoutRules() {
        let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "书源")
        let book = Book(bookUrl: "https://source.test/book/1", name: "书", origin: source.id)
        let official = BookChapter(url: "https://fanqienovel.com/reader/123", title: "第一章", bookUrl: book.bookUrl, index: 0)
        var volume = official
        volume.isVolume = true
        var otherBook = official
        otherBook.bookUrl = "different"
        var detail = official
        detail.url = "https://fanqienovel.com/page/123"
        let model = ReaderViewModel(book: book, chapters: [official, volume, otherBook, detail], initialIndex: 0, source: source)
        #expect(model.commentsTarget(at: 0)?.official?.platform == .fanqie)
        for index in [-1, 1, 2, 3, 4] { #expect(model.commentsTarget(at: index) == nil) }
        let localModel = ReaderViewModel(book: book, chapters: [official], initialIndex: 0)
        #expect(localModel.commentsTarget(at: 0) == nil)
        let wrongSource = BookSource(bookSourceUrl: "https://other.test", bookSourceName: "其他源")
        let wrongModel = ReaderViewModel(book: book, chapters: [official], initialIndex: 0, source: wrongSource)
        #expect(wrongModel.commentsTarget(at: 0) == nil)
    }

    @Test func resegmentationKeepsCachedImagesAcrossCurrentAdjacentAndContinuousContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var book = Book(bookUrl: "book", name: "书", origin: "source")
        book.readConfig = BookReadConfig()
        book.readConfig?.reSegment = true
        let image = #"<img src="https://images.test/formula~large.png?key=one&amp;size=2">"#
        let input = "图片前正文。\n" + image + "\n图片后正文。"
        let chapters = (0..<3).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let cache = ChapterContentCache(directory: directory)
        for chapter in chapters {
            try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapter.url, content: input, sourceID: book.origin))
        }
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 1,
            source: .init(bookSourceUrl: book.origin, bookSourceName: "源"), service: SourceAwareReaderLoader(), cache: cache)

        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content.contains(image))
        await model.loadAdjacentChapters(rules: [])
        #expect(model.previousContent.contains(image))
        #expect(model.continuationContent.contains(image))
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.content.contains(image) })
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[1].url)?.content == input)
    }

    @Test func resegmentationUsesOriginalCacheAcrossReaderWindowsAndSpeechAndCanBeDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = (0..<3).map { BookChapter(url: "chapter\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        let cache = ChapterContentCache(directory: directory)
        let loader = ResegmentationReaderLoader()
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 1,
                                    source: .init(bookSourceUrl: "source", bookSourceName: "源"), service: loader, cache: cache)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == ResegmentationReaderLoader.original)
        let generation = model.chapterLoadGeneration
        let updated = model.toggleParagraphResegmentation(position: 5)
        #expect(updated.readConfig?.reSegment == true)
        #expect(try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(updated)).readConfig?.reSegment == true)
        #expect(model.chapterLoadGeneration > generation)
        #expect(model.requestedPosition == 5)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.loadedFromCache)
        #expect(model.content == ResegmentationReaderLoader.processed)
        await model.loadAdjacentChapters(rules: [])
        #expect(model.previousContent == ResegmentationReaderLoader.processed)
        #expect(model.continuationContent == ResegmentationReaderLoader.processed)
        #expect(await model.nextSpeechContent(rules: []) == ResegmentationReaderLoader.processed)
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.allSatisfy { $0.content == ResegmentationReaderLoader.processed })
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapters[1].url)?.content == ResegmentationReaderLoader.original)
        model.toggleParagraphResegmentation()
        #expect(model.scrollChapters.isEmpty)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.content == ResegmentationReaderLoader.original)
        #expect(await loader.calls == 3)
    }

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
}

private actor ResegmentationReaderLoader: ChapterContentLoading {
    static let original = "这是错\n误断开的正文。\n下一段。"
    static let processed = "这是错误断开的正文。\n下一段。"
    var calls = 0
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        calls += 1
        return .init(content: Self.original)
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


private actor SlowPrefetchReaderSource: ChapterContentLoading {
    private(set) var slotOccupied = false
    private(set) var prefetchCancelled = false
    private(set) var foregroundRequests = 0

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        if chapter.index == 3, !prefetchCancelled {
            slotOccupied = true
            defer { slotOccupied = false }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { prefetchCancelled = true }
        } else if chapter.index == 1 {
            foregroundRequests += 1
            for _ in 0..<100 where slotOccupied { try? await Task.sleep(nanoseconds: 5_000_000) }
            if slotOccupied { return .init(content: "书源仍被预读占用") }
        }
        return .init(content: "正文\(chapter.index)")
    }
}

private actor CacheRegressionSource: ChapterListLoading, ChapterContentLoading {
    private(set) var contentRequests: [Int] = []
    private(set) var directoryRequests = 0
    private var offline = false
    private var published: [BookChapter] = []

    func publish(_ chapters: [BookChapter]) { published = chapters }
    func disconnect() { offline = true }

    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        directoryRequests += 1
        return .init(chapters: published)
    }

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        contentRequests.append(chapter.index)
        if offline { return .init(diagnostics: [.init(severity: .error, code: "offline", message: "无网络", rule: chapter.url)]) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        return .init(content: "正文\(chapter.index)")
    }
}
