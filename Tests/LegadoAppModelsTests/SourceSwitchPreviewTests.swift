import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct SourceSwitchPreviewTests {
    @Test func openingTheListAutomaticallyFetchesAndGroupsTheSameChapterWithoutSaving() async {
        let body = String(repeating: "雨夜中的灯塔照亮了远处的海湾。", count: 20)
        let f = SourcePreviewFixture(bodyA: body, bodyB: body, automatic: true, allExact: true)
        await f.model.load(sources: f.sources)

        #expect(f.model.candidates.count == 2)
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 1)
        #expect(f.model.referenceState == .unavailable)
        #expect(f.model.candidateGroups.count == 1)
        #expect(f.model.candidateGroups[0].candidates.count == 2)
        #expect(f.model.candidateGroups[0].title.contains("未验证"))
        #expect(f.model.comparisons.isEmpty)
        #expect(f.model.preview == nil)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test func automaticChecksDoNotReadAChapterThatOnlyMatchesReadingProgress() async {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)

        #expect(f.model.verificationStates[f.candidates[0].id] == .ready)
        #expect(f.model.verificationStates[f.candidates[1].id] == .chapterUnmatched)
        #expect(await f.loader.requestCount("b") == 0)
        #expect(f.model.comparisons[f.candidates[1].id] == nil)
    }

    @Test func automaticPublicReferenceComparisonDistinguishesWrongTextAndExtraContent() async throws {
        let opening = String(repeating: "雨夜中的灯塔照亮了远处的海湾。", count: 15)
        let reference = SourceChapterReference(provider: "QQ 阅读", chapterTitle: "第2章 灯塔",
                                               url: "https://book.qq.com/book-read/1/2", content: opening)
        let f = SourcePreviewFixture(bodyA: opening + "他看见海面上出现了一艘白色小船。",
            bodyB: String(repeating: "城主带着士兵走入王宫商议军情。", count: 30), automatic: true, allExact: true,
            reference: reference)
        await f.model.load(sources: f.sources)

        let matching = try #require(f.model.comparisons[f.candidates[0].id])
        #expect(matching.similarity == 100)
        #expect(matching.hasMoreContent)
        #expect(f.model.comparisons[f.candidates[1].id]?.similarity == 0)
        #expect(f.model.reference?.url == reference.url)
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(await f.loader.requestCount("a") == 1)
        #expect(f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func closingTheListDiscardsUnfinishedAutomaticChecks() async {
        let f = SourcePreviewFixture(suspended: ["a"], automatic: true)
        let load = Task { await f.model.load(sources: f.sources) }
        await f.loader.waitForRequest("a")
        f.model.cancelSelection()
        await f.loader.resume("a")
        await load.value

        #expect(f.model.preview == nil)
        #expect(f.model.comparisons.isEmpty)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func automaticBodyChecksRunAtMostThreeAtATime() async {
        let ids = ["a", "b", "c", "d", "e"]
        let sources = ids.map { BookSource(bookSourceUrl: $0, bookSourceName: $0) }
        let candidates = sources.map {
            BookSourceCandidate(book: SearchBook(bookURL: $0.id + "-book", origin: $0.id,
                originName: $0.bookSourceName, type: 0, name: "书"), score: 100)
        }
        var book = Book(bookUrl: "old", name: "书")
        book.durChapterTitle = "第二章 灯塔"
        let loader = SourcePreviewContentLoader(bodies: Dictionary(uniqueKeysWithValues: ids.map { ($0, "本章正文") }),
                                                suspended: Set(ids))
        let directory = SourcePreviewDirectoryLoader(exactForAll: true)
        let service = BookSourceSwitchService(detailLoader: directory, chapterLoader: directory, contentLoader: loader,
                                              chapterRepository: InMemoryBookChapterRepository())
        let model = SourceSwitchViewModel(book: book, service: service, candidates: candidates,
                                          referenceService: SourcePreviewReference(value: nil), cache: SourceSwitchCache())
        let load = Task { await model.load(sources: sources) }
        await loader.waitForRequest("c")
        #expect(await loader.requestCount("d") == 0)
        #expect(await loader.requestCount("e") == 0)
        for id in ids { await loader.resume(id) }
        await load.value
        for id in ids { #expect(await loader.requestCount(id) == 1) }
    }

    @Test func sourceSearchMatchesNamesAndURLsWithoutChangingCandidateOrder() {
        let candidates = [
            BookSourceCandidate(book: SearchBook(bookURL: "https://books.example/1", origin: "https://alpha.example", originName: "远方书库", type: 0, name: "书"), score: 190),
            BookSourceCandidate(book: SearchBook(bookURL: "https://books.example/2", origin: "https://beta.example", originName: "远方听书", type: 1, name: "书"), score: 110)
        ]
        let model = SourceSwitchViewModel(book: Book(bookUrl: "old-book", name: "书"), candidates: candidates)
        model.sourceQuery = " 远方\n"
        #expect(model.filteredCandidates == candidates)
        model.sourceQuery = "听书"
        #expect(model.filteredCandidates == [candidates[1]])
        model.sourceQuery = " ALPHA.EXAMPLE "
        #expect(model.filteredCandidates == [candidates[0]])
        model.sourceQuery = "books.example"
        #expect(model.filteredCandidates.isEmpty)
        model.sourceQuery = " \n\t"
        #expect(model.filteredCandidates == candidates)
        #expect(model.candidates == candidates)
    }

    @Test func filteringAndClearingSearchPreservesTheSelectedChapterPreview() async throws {
        let f = SourcePreviewFixture()
        await f.model.select(f.candidates[0], sources: f.sources)
        f.model.sourceQuery = "b"
        #expect(f.model.filteredCandidates == [f.candidates[1]])
        #expect(f.model.selectedCandidate == f.candidates[0])
        #expect(f.model.preview?.report.verifiedContent?.content == "甲源本章正文")
        #expect(f.model.canConfirm)
        f.model.sourceQuery = "not-found"
        #expect(f.model.filteredCandidates.isEmpty)
        f.model.sourceQuery = ""
        #expect(f.model.filteredCandidates == f.candidates)
        let confirmed = try #require(await f.model.confirmSelection())
        #expect(confirmed.source.id == "a")
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 0)
    }

    @Test func previewPreservesTheCurrentDirectoryUntilConfirmationAndReusesItsBody() async throws {
        let f = SourcePreviewFixture(sharedBookURL: true)
        await f.model.select(f.candidates[0], sources: f.sources)
        let preview = try #require(f.model.preview)
        #expect(preview.report.book.durChapterIndex == 1)
        #expect(preview.report.book.durChapterPos == 42)
        #expect(preview.report.exactChapterMatch)
        #expect(preview.report.verifiedContent?.content == "甲源本章正文")
        #expect(await f.repository.load(bookURL: f.book.bookUrl) == f.oldChapters)
        #expect(f.model.canConfirm)

        let confirmed = try #require(await f.model.confirmSelection())
        #expect(confirmed.source.id == "a")
        #expect(confirmed.report.verifiedContent?.content == preview.report.verifiedContent?.content)
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestedChapter("a") == "第二章·灯塔")
        #expect(await f.repository.load(bookURL: f.book.bookUrl) == confirmed.report.chapters)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
    }

    @Test func revisitingPreviewsUsesTheCacheAndExposesApproximateChapterMatching() async throws {
        let f = SourcePreviewFixture()
        await f.model.select(f.candidates[0], sources: f.sources)
        await f.model.select(f.candidates[1], sources: f.sources)
        #expect(f.model.preview?.report.exactChapterMatch == false)
        #expect(f.model.preview?.report.book.durChapterTitle == "第二节灯塔")
        #expect(f.model.preview?.report.book.durChapterPos == 0)
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "甲源本章正文")
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 1)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
        #expect(await f.repository.load(bookURL: "b-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func slowerOldSelectionCannotReplaceTheNewestPreview() async {
        let f = SourcePreviewFixture(suspended: ["a"])
        let first = Task { await f.model.select(f.candidates[0], sources: f.sources) }
        await f.loader.waitForRequest("a")
        await f.model.select(f.candidates[1], sources: f.sources)
        await f.loader.resume("a")
        await first.value
        #expect(f.model.selectedCandidate?.id == f.candidates[1].id)
        #expect(f.model.preview?.report.verifiedContent?.content == "乙源本章正文")
        #expect(f.model.errorMessage == nil)
        #expect(f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDiscardsAnUnfinishedPreview() async {
        let f = SourcePreviewFixture(suspended: ["a"])
        let pending = Task { await f.model.select(f.candidates[0], sources: f.sources) }
        await f.loader.waitForRequest("a")
        f.model.cancelSelection()
        await f.loader.resume("a")
        await pending.value
        #expect(f.model.preview == nil)
        #expect(f.model.selectedCandidate == nil)
        #expect(!f.model.isPreviewLoading)
        #expect(!f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test func failedPreviewCanBeRetriedAndDoesNotPreventTryingAnotherSource() async {
        let f = SourcePreviewFixture(bodyA: " \n\t")
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.errorMessage != nil)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
        await f.loader.setBody("甲源恢复后的正文", source: "a")
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "甲源恢复后的正文")
        #expect(f.model.errorMessage == nil)
        await f.model.select(f.candidates[1], sources: f.sources)
        #expect(f.model.preview?.report.verifiedContent?.content == "乙源本章正文")
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func loadingANewPreviewCannotConfirmThePreviouslySelectedSource() async {
        let f = SourcePreviewFixture(suspended: ["b"])
        await f.model.select(f.candidates[0], sources: f.sources)
        let pending = Task { await f.model.select(f.candidates[1], sources: f.sources) }
        await f.loader.waitForRequest("b")
        #expect(f.model.preview == nil)
        #expect(f.model.isPreviewLoading)
        #expect(!f.model.canConfirm)
        #expect(await f.model.confirmSelection() == nil)
        await f.loader.resume("b")
        await pending.value
        #expect(f.model.preview?.source.id == "b")
        #expect(f.model.canConfirm)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test func aRemovedSourceDoesNotLeaveThePreviousPreviewConfirmable() async {
        let f = SourcePreviewFixture()
        await f.model.select(f.candidates[0], sources: f.sources)
        await f.model.select(f.candidates[1], sources: [f.sources[0]])
        #expect(f.model.preview == nil)
        #expect(f.model.errorMessage != nil)
        #expect(!f.model.canConfirm)
    }

    @Test func reopeningThePageReusesCandidatesBodiesAndPublicReferenceWithoutRequests() async throws {
        let opening = String(repeating: "雨夜中的灯塔照亮了远处的海湾。", count: 15)
        let reference = SourceChapterReference(provider: "QQ 阅读", chapterTitle: "第二章 灯塔", url: "public", content: opening)
        let f = SourcePreviewFixture(bodyA: opening + "后续正文", bodyB: opening, automatic: true, allExact: true, reference: reference)
        await f.model.load(sources: f.sources)
        f.model.cancelSelection()
        let reopened = f.reopen()
        await reopened.load(sources: f.sources)

        #expect(reopened.loadedFromCache)
        #expect(reopened.candidates == f.model.candidates)
        #expect(reopened.reference == reference)
        #expect(reopened.comparisons[f.candidates[0].id]?.similarity == 100)
        await reopened.select(f.candidates[0], sources: f.sources)
        #expect(reopened.preview?.report.verifiedContent?.content == opening + "后续正文")
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 1)
        #expect(await f.searcher.requests == 1)
        #expect(await f.referenceService.requests == 1)
        #expect(await f.repository.load(bookURL: "a-book").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func closingDuringChecksReusesCompletedBodiesAndResumesOnlyMissingOnes() async {
        let f = SourcePreviewFixture(suspended: ["b"], automatic: true, allExact: true)
        let first = Task { await f.model.load(sources: f.sources) }
        await f.loader.waitForRequest("b")
        while f.model.verificationStates[f.candidates[0].id] != .ready { await Task.yield() }
        f.model.cancelSelection()
        await f.loader.resume("b")
        await first.value
        let reopened = f.reopen()
        await reopened.load(sources: f.sources)
        #expect(reopened.loadedFromCache)
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 2)
        #expect(reopened.verificationStates[f.candidates[1].id] == .ready)
    }

    @Test(.timeLimit(.minutes(1))) func reopeningAnIncompleteSearchOnlyQueriesSourcesNotPreviouslySearched() async {
        let f = SourcePreviewFixture(automatic: true, allExact: true)
        let tracker = PartialSearchTracker(candidates: f.candidates)
        let directory = SourcePreviewDirectoryLoader(exactForAll: true)
        let service = BookSourceSwitchService(searcher: PartialSourceSearch(tracker: tracker), detailLoader: directory,
            chapterLoader: directory, contentLoader: f.loader, chapterRepository: f.repository)
        let model = SourceSwitchViewModel(book: f.book, service: service, referenceService: f.referenceService, cache: f.cache)
        let pending = Task { await model.load(sources: f.sources) }
        while model.verificationStates[f.candidates[0].id] != .ready { await Task.yield() }
        model.cancelSelection()
        await tracker.finishFirst()
        await pending.value
        let reopened = SourceSwitchViewModel(book: f.book, service: service, referenceService: f.referenceService, cache: f.cache)
        await reopened.load(sources: f.sources)
        #expect(reopened.loadedFromCache)
        #expect(await tracker.sourceLists == [["a", "b"], ["b"]])
        #expect(await f.loader.requestCount("a") == 1)
        #expect(await f.loader.requestCount("b") == 1)
        #expect(reopened.candidates.count == 2)
    }

    @Test func changingTheChapterOrSourceRulesDoesNotReuseTheOldContext() async {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)
        var book = f.book
        book.durChapterIndex = 2
        book.durChapterTitle = "第三章 潮声"
        let otherChapter = f.reopen(book: book)
        await otherChapter.load(sources: f.sources)
        #expect(!otherChapter.loadedFromCache)
        var sources = f.sources
        sources[0].ruleContent = ContentRule()
        sources[0].ruleContent?.content = "new-rule"
        let changedRules = f.reopen()
        await changedRules.load(sources: sources)
        #expect(!changedRules.loadedFromCache)
        #expect(await f.searcher.requests == 3)
    }

    @Test func cachedConfirmationUsesTheCurrentPositionAndSettings() async throws {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)
        var book = f.book
        book.durChapterPos = 208
        book.customTag = "最新标记"
        let reopened = f.reopen(book: book)
        await reopened.load(sources: f.sources)
        await reopened.select(f.candidates[0], sources: f.sources)
        let result = try #require(await reopened.confirmSelection())
        #expect(reopened.loadedFromCache)
        #expect(result.report.book.durChapterPos == 208)
        #expect(result.report.book.customTag == "最新标记")
        #expect(await f.loader.requestCount("a") == 1)
    }

    @Test func manualRefreshFetchesNewBodiesAndReference() async {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)
        await f.loader.setBody("刷新后的本章正文", source: "a")
        await f.model.refresh(sources: f.sources)
        await f.model.select(f.candidates[0], sources: f.sources)
        #expect(!f.model.loadedFromCache)
        #expect(f.model.preview?.report.verifiedContent?.content == "刷新后的本章正文")
        #expect(await f.loader.requestCount("a") == 2)
        #expect(await f.searcher.requests == 2)
        #expect(await f.referenceService.requests == 2)
    }

    @Test func unavailableReferenceIsBrieflyCachedThenRetriedWithoutReloadingBodies() async throws {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)
        let reopened = f.reopen()
        await reopened.load(sources: f.sources)
        #expect(await f.referenceService.requests == 1)
        let key = try #require(SourceSwitchCache.key(book: f.book, sources: f.sources))
        var value = try #require(await f.cache.load(key))
        value.referenceCheckedAt = Date().addingTimeInterval(-301)
        f.cache.store(value, key: key)
        await f.reopen().load(sources: f.sources)
        #expect(await f.referenceService.requests == 2)
        #expect(await f.loader.requestCount("a") == 1)
    }

    @Test func anEmptyCachedBodyIsRetriedInsteadOfBecomingAnUnusablePreview() async throws {
        let f = SourcePreviewFixture(automatic: true)
        await f.model.load(sources: f.sources)
        let key = try #require(SourceSwitchCache.key(book: f.book, sources: f.sources))
        var value = try #require(await f.cache.load(key))
        value.reports[f.candidates[0].id]?.verifiedContent?.content = " \n"
        f.cache.store(value, key: key)
        let reopened = f.reopen()
        await reopened.load(sources: f.sources)
        await reopened.select(f.candidates[0], sources: f.sources)
        #expect(reopened.canConfirm)
        #expect(reopened.preview?.report.verifiedContent?.content == "甲源本章正文")
        #expect(await f.loader.requestCount("a") == 2)
    }

    @Test(.timeLimit(.minutes(1))) func oldReferenceFinishingAfterRefreshCannotOverwriteTheNewCache() async throws {
        let f = SourcePreviewFixture(automatic: true)
        let reference = SourceChapterReference(provider: "QQ 阅读", chapterTitle: "第二章 灯塔", url: "new", content: "新参照")
        let delayed = DelayedFirstSourceReference(current: reference)
        let model = SourceSwitchViewModel(book: f.book, service: f.service, referenceService: delayed, cache: f.cache)
        let old = Task { await model.load(sources: f.sources) }
        await delayed.waitForFirst()
        await model.refresh(sources: f.sources)
        await delayed.finishFirst()
        await old.value
        let reopened = SourceSwitchViewModel(book: f.book, service: f.service, referenceService: delayed, cache: f.cache)
        await reopened.load(sources: f.sources)
        #expect(reopened.reference == reference)
        #expect(await delayed.requests == 2)
    }
}

@MainActor
private struct SourcePreviewFixture {
    let book: Book
    let sources: [BookSource]
    let candidates: [BookSourceCandidate]
    let oldChapters: [BookChapter]
    let repository: InMemoryBookChapterRepository
    let loader: SourcePreviewContentLoader
    let model: SourceSwitchViewModel
    let cache: SourceSwitchCache
    let searcher: SourcePreviewSearch
    let service: BookSourceSwitchService
    let referenceService: SourcePreviewReference

    init(sharedBookURL: Bool = false, suspended: Set<String> = [], bodyA: String = "甲源本章正文",
         bodyB: String = "乙源本章正文", automatic: Bool = false, allExact: Bool = false,
         reference: SourceChapterReference? = nil) {
        var current = Book(bookUrl: "old-book", name: "书", origin: "old")
        current.durChapterIndex = 1
        current.durChapterTitle = "第二章 灯塔"
        current.durChapterPos = 42
        current.totalChapterNum = 3
        book = current
        sources = ["a", "b"].map {
            var source = BookSource(bookSourceUrl: $0, bookSourceName: $0)
            source.searchUrl = "/search"
            return source
        }
        candidates = sources.map { source in
            .init(book: SearchBook(bookURL: sharedBookURL && source.id == "a" ? current.bookUrl : source.id + "-book",
                                   origin: source.id, originName: source.bookSourceName, type: 0, name: current.name), score: 100)
        }
        oldChapters = (0..<3).map { BookChapter(url: "old-\($0)", title: "旧章节\($0)", bookUrl: current.bookUrl, index: $0) }
        repository = InMemoryBookChapterRepository(values: [current.bookUrl: oldChapters])
        loader = SourcePreviewContentLoader(bodies: ["a": bodyA, "b": bodyB], suspended: suspended)
        let directory = SourcePreviewDirectoryLoader(exactForAll: allExact)
        searcher = SourcePreviewSearch(candidates: candidates)
        cache = SourceSwitchCache()
        referenceService = SourcePreviewReference(value: reference)
        service = BookSourceSwitchService(searcher: searcher,
                                              detailLoader: directory, chapterLoader: directory,
                                              contentLoader: loader, chapterRepository: repository)
        model = SourceSwitchViewModel(book: current, service: service, candidates: automatic ? [] : candidates,
                                      referenceService: referenceService, cache: cache)
    }

    func reopen(book: Book? = nil, cache: SourceSwitchCache? = nil) -> SourceSwitchViewModel {
        SourceSwitchViewModel(book: book ?? self.book, service: service, referenceService: referenceService, cache: cache ?? self.cache)
    }
}

private struct SourcePreviewDirectoryLoader: BookDetailLoading, ChapterListLoading {
    var exactForAll = false
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
        .init(book: Book(bookUrl: searchBook.bookURL, name: searchBook.name, origin: source.id))
    }

    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        let titles = ["第一章雨夜", source.id == "a" || exactForAll ? "第二章·灯塔" : "第二节灯塔", "第三章潮声"]
        return .init(chapters: titles.enumerated().map {
            BookChapter(url: source.id + "/\($0.offset)", title: $0.element, bookUrl: book.bookUrl, index: $0.offset)
        })
    }
}

private actor SourcePreviewSearch: BookSourceSearching {
    let candidates: [BookSourceCandidate]
    private(set) var requests = 0
    init(candidates: [BookSourceCandidate]) { self.candidates = candidates }
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport {
        requests += 1
        return .init(books: candidates.map(\.book), outcomes: candidates.map {
            .init(sourceID: $0.book.origin, books: [$0.book], diagnostics: [])
        })
    }
}

private actor SourcePreviewReference: SourceChapterReferencing {
    let value: SourceChapterReference?
    private(set) var requests = 0
    init(value: SourceChapterReference?) { self.value = value }
    func reference(for book: Book) async -> SourceChapterReference? { requests += 1; return value }
}

private struct PartialSourceSearch: BookSourceSearching {
    let tracker: PartialSearchTracker
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport { .init(books: [], outcomes: []) }
    func searchStream(keyword: String, sources: [BookSource]) -> AsyncStream<SourceSearchOutcome> {
        AsyncStream { continuation in Task { await tracker.start(sources: sources, continuation: continuation) } }
    }
}

private actor PartialSearchTracker {
    let candidates: [BookSourceCandidate]
    private(set) var sourceLists: [[String]] = []
    private var first: AsyncStream<SourceSearchOutcome>.Continuation?
    init(candidates: [BookSourceCandidate]) { self.candidates = candidates }

    func start(sources: [BookSource], continuation: AsyncStream<SourceSearchOutcome>.Continuation) {
        sourceLists.append(sources.map(\.id))
        for source in sourceLists.count == 1 ? Array(sources.prefix(1)) : sources {
            continuation.yield(.init(sourceID: source.id, books: candidates.filter { $0.book.origin == source.id }.map(\.book), diagnostics: []))
        }
        if sourceLists.count == 1 { first = continuation }
        else { continuation.finish() }
    }

    func finishFirst() { first?.finish(); first = nil }
}

private actor DelayedFirstSourceReference: SourceChapterReferencing {
    let current: SourceChapterReference
    private(set) var requests = 0
    private var first: CheckedContinuation<SourceChapterReference?, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(current: SourceChapterReference) { self.current = current }

    func reference(for book: Book) async -> SourceChapterReference? {
        requests += 1
        if requests > 1 { return current }
        return await withCheckedContinuation { continuation in
            first = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForFirst() async {
        if first != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finishFirst() {
        first?.resume(returning: .init(provider: "QQ 阅读", chapterTitle: current.chapterTitle, url: "old", content: "过期参照"))
        first = nil
    }
}

private actor SourcePreviewContentLoader: ChapterContentLoading {
    private var bodies: [String: String]
    private var suspended: Set<String>
    private var requests: [(String, String)] = []
    private var pending: [String: CheckedContinuation<ChapterContentReport, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(bodies: [String: String], suspended: Set<String>) {
        self.bodies = bodies
        self.suspended = suspended
    }

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        requests.append((source.id, chapter.title))
        return await withCheckedContinuation { continuation in
            if suspended.contains(source.id) { pending[source.id] = continuation }
            else { continuation.resume(returning: .init(content: bodies[source.id] ?? "")) }
            for waiter in waiters.removeValue(forKey: source.id) ?? [] { waiter.resume() }
        }
    }

    func waitForRequest(_ source: String) async {
        if requests.contains(where: { $0.0 == source }) { return }
        await withCheckedContinuation { waiters[source, default: []].append($0) }
    }

    func resume(_ source: String) {
        suspended.remove(source)
        pending.removeValue(forKey: source)?.resume(returning: .init(content: bodies[source] ?? ""))
    }

    func requestCount(_ source: String) -> Int { requests.filter { $0.0 == source }.count }
    func requestedChapter(_ source: String) -> String? { requests.first { $0.0 == source }?.1 }
    func setBody(_ body: String, source: String) { bodies[source] = body }
}
