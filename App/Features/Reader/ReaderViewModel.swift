import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct ReaderParagraph: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct ReaderScrollChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let content: String
    var error: String? = nil
}

struct ReaderChapterTransition: Equatable {
    let id: Int
    let direction: Int
}

struct ReaderPreparedChapter {
    let request: Int
    let generation: Int
    let fromIndex: Int
    let targetIndex: Int
    let direction: Int
    let title: String
    let content: String
    let fromCache: Bool
}

enum ReaderPositionResolver {
    static func renderedLocation(position: Int, prefixLength: Int, renderedLength: Int) -> Int {
        let lastLocation = max(renderedLength, 1) - 1
        let prefix = min(max(prefixLength, 0), lastLocation)
        return prefix + min(max(position, 0), lastLocation - prefix)
    }
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var title: String
    @Published private(set) var content = ""
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var currentIndex: Int
    @Published private(set) var chapterLoadGeneration = 0
    @Published private(set) var paragraphs: [ReaderParagraph] = []
    @Published private(set) var requestedPosition: Int
    @Published private(set) var loadedFromCache = false
    @Published private(set) var hasLoadedCurrentChapter = false
    @Published private(set) var pagedChapterDirection: Int?
    @Published private(set) var showsPagedChapterLoading = false
    @Published private(set) var pagedChapterError: String?
    @Published private(set) var chapterTransition: ReaderChapterTransition?
    @Published private(set) var previousTitle = ""
    @Published private(set) var previousContent = ""
    @Published private(set) var continuationTitle = ""
    @Published private(set) var continuationContent = ""
    @Published private(set) var isPreviousWindowReady = false
    @Published private(set) var isContinuationWindowReady = false
    @Published private(set) var scrollChapters: [ReaderScrollChapter] = []
    @Published private(set) var scrollRevision = 0
    @Published private(set) var isLoadingScrollAhead = false
    @Published private(set) var isLoadingScrollBehind = false
    @Published private(set) var isCaching = false
    @Published private(set) var cacheCompleted = 0
    @Published private(set) var cacheTotal = 0
    @Published private(set) var cacheFailed = 0
    @Published private(set) var cacheError: String?
    @Published private(set) var cachedChapterURLs: Set<String> = []

    @Published private(set) var book: Book
    private(set) var chapters: [BookChapter]
    private var source: BookSource?
    private let localService: LocalBookService
    private let sanitizer = ContentSanitizer()
    private let contentCoordinator: ChapterContentCoordinator
    private var demoChapterContent: String?
    private var previousLoadedIndex: Int?
    private var continuationLoadedIndex: Int?
    @Published private(set) var scrollRetries: Set<Int> = []
    private var sourceCacheNeedsInvalidation = false
    private var refreshAfterRuleChange = false
    private var pendingSourceContent: ChapterContentReport?
    private var cacheTask: Task<Void, Never>?
    private var cacheGeneration = 0
    private var cacheRefreshGeneration = 0
    private var pagedRequestGeneration = 0
    private var preloadTask: Task<Void, Never>?
    private var prefetchLimit: Int?

    var cacheSucceeded: Int { cacheCompleted - cacheFailed }

    func bookmarks(at position: Int, in bookmarks: [Bookmark], pageRange: NSRange? = nil) -> [Bookmark] {
        bookmarks.filter { bookmark in
            guard bookmark.bookName == book.name, bookmark.bookAuthor == book.author,
                  bookmark.resolvedChapterIndex(in: chapters) == currentIndex else { return false }
            if bookmark.chapterPosition == max(position, 0) { return true }
            if let pageRange, pageRange.length > 0 {
                return NSLocationInRange(bookmark.chapterPosition, pageRange)
            }
            return false
        }
    }

    func prepareContinuousReading(rules: [ReplaceRule]) async {
        guard hasLoadedCurrentChapter else { return }
        if scrollChapters.isEmpty {
            scrollChapters = [scrollChapterForCurrentContent()]
        }
        async let ahead: Void = extendContinuousReading(direction: 1, rules: rules)
        async let behind: Void = extendContinuousReading(direction: -1, rules: rules)
        _ = await (ahead, behind)
    }

    func extendContinuousReading(direction: Int, rules: [ReplaceRule]) async {
        let initialEdge = direction > 0 ? scrollChapters.last?.id : scrollChapters.first?.id
        guard let initialEdge, readableIndex(from: initialEdge, direction: direction) != nil else { return }
        if direction > 0 {
            guard !isLoadingScrollAhead else { return }
            isLoadingScrollAhead = true
        } else {
            guard !isLoadingScrollBehind else { return }
            isLoadingScrollBehind = true
        }
        let revision = scrollRevision
        defer {
            if revision == scrollRevision {
                if direction > 0 { isLoadingScrollAhead = false }
                else { isLoadingScrollBehind = false }
            }
        }
        for _ in 0..<2 {
            let edge = direction > 0 ? scrollChapters.last?.id : scrollChapters.first?.id
            guard let edge, let index = readableIndex(from: edge, direction: direction) else { return }
            let value = await loadAdjacentChapter(chapters[index], rules: rules)
            guard revision == scrollRevision, !Task.isCancelled else { return }
            // The viewport may have recycled this edge while the request was
            // in flight. Installing its result now would create a chapter gap.
            guard scrollChapters.contains(where: { $0.id == edge }) else { return }
            let chapter = ReaderScrollChapter(
                id: index, title: value.title, content: value.content, error: value.error
            )
            if !scrollChapters.contains(where: { $0.id == index }) {
                scrollChapters.append(chapter)
                scrollChapters.sort { $0.id < $1.id }
            }
        }
    }

    func retryContinuousChapter(index: Int, rules: [ReplaceRule]) async {
        guard chapters.indices.contains(index), !scrollRetries.contains(index) else { return }
        let revision = scrollRevision
        scrollRetries.insert(index)
        defer { if revision == scrollRevision { scrollRetries.remove(index) } }
        let value = await loadAdjacentChapter(chapters[index], rules: rules, forceRefresh: true)
        guard revision == scrollRevision, !Task.isCancelled,
              let slot = scrollChapters.firstIndex(where: { $0.id == index }) else { return }
        scrollChapters[slot] = .init(id: index, title: value.title, content: value.content, error: value.error)
        if currentIndex == index { setContinuousChapter(scrollChapters[slot]) }
    }

    @discardableResult
    func updateContinuousPosition(chapter index: Int) -> Bool {
        guard index != currentIndex,
              let chapter = scrollChapters.first(where: { $0.id == index }) else { return false }
        setContinuousChapter(chapter)
        return true
    }

    func retainContinuousChapters(_ indices: Set<Int>) {
        guard indices.contains(currentIndex) else { return }
        scrollChapters.removeAll { !indices.contains($0.id) }
    }

    private func setContinuousChapter(_ chapter: ReaderScrollChapter) {
        currentIndex = chapter.id
        title = chapter.title
        content = chapter.content
        paragraphs = Self.makeParagraphs(chapter.content)
        diagnostics = []
        hasLoadedCurrentChapter = true
    }

    private func scrollChapterForCurrentContent() -> ReaderScrollChapter {
        .init(id: currentIndex, title: title, content: content,
              error: currentChapterError)
    }

    private func clearContinuousReading() {
        scrollRevision &+= 1
        scrollChapters = []
        isLoadingScrollAhead = false
        isLoadingScrollBehind = false
        scrollRetries = []
    }

    init(
        book: Book,
        chapters: [BookChapter],
        initialIndex: Int,
        source: BookSource,
        service: any ChapterContentLoading = NetworkBookService(),
        cache: ChapterContentCache = .live(),
        prefetchLimit: Int? = nil
    ) {
        let resolvedIndex = Self.validIndex(initialIndex, chapters: chapters)
        self.book = book
        self.chapters = chapters
        currentIndex = resolvedIndex
        self.source = source
        localService = .init()
        contentCoordinator = .init(loader: service, cache: cache)
        self.prefetchLimit = prefetchLimit
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    convenience init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        self.init(book: book, chapters: chapters, initialIndex: initialIndex)
        self.content = content
        demoChapterContent = content
        paragraphs = Self.makeParagraphs(content)
        hasLoadedCurrentChapter = true
    }

    init(
        book: Book,
        chapters: [BookChapter],
        initialIndex: Int,
        localService: LocalBookService = .init(),
        cache: ChapterContentCache = .live()
    ) {
        let resolvedIndex = Self.validIndex(initialIndex, chapters: chapters)
        self.book = book
        self.chapters = chapters
        currentIndex = resolvedIndex
        source = nil
        self.localService = localService
        contentCoordinator = .init(cache: cache)
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    var currentChapter: BookChapter? { chapters.indices.contains(currentIndex) ? chapters[currentIndex] : nil }
    var nextChapter: BookChapter? { nextReadableChapter(after: currentIndex) }
    var canGoPrevious: Bool { navigationIndex(direction: -1) != nil }
    var canGoNext: Bool { navigationIndex(direction: 1) != nil }
    var hasPreviousWindow: Bool { previousLoadedIndex != nil }
    var hasContinuationWindow: Bool { continuationLoadedIndex != nil }
    var canEditContent: Bool { source != nil }
    var usesReplaceRules: Bool { book.readConfig?.useReplaceRule ?? true }
    var currentChapterError: String? {
        guard hasLoadedCurrentChapter, !isLoading,
              currentChapter?.isVolume != true else { return nil }
        return scrollChapters.first(where: { $0.id == currentIndex })?.error
            ?? diagnostics.first(where: { $0.severity == .error })?.message
            ?? (source != nil && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前书源没有返回正文。" : nil)
    }

    func bookForSourceSwitch(position: Int) -> Book {
        var current = book
        current.durChapterIndex = currentIndex
        current.durChapterTitle = currentChapter?.title
        current.durChapterPos = max(position, 0)
        current.totalChapterNum = chapters.count
        return current
    }

    func cacheNextTen() { startCaching(limit: 10) }

    func cacheRemaining() { startCaching(limit: nil) }

    func cancelCaching() {
        let wasCaching = isCaching
        cacheGeneration &+= 1
        cacheTask?.cancel()
        cacheTask = nil
        isCaching = false
        if wasCaching { Task { [weak self] in await self?.refreshCachedChapters() } }
    }

    func refreshCachedChapters() async {
        cacheRefreshGeneration &+= 1
        let generation = cacheRefreshGeneration
        let bookURL = book.bookUrl
        let sourceID = source?.id
        var urls: Set<String>
        if source == nil {
            urls = Set(chapters.map(\.url))
        } else {
            urls = await contentCoordinator.cachedChapterURLs(bookURL: bookURL, among: chapters)
        }
        guard generation == cacheRefreshGeneration, book.bookUrl == bookURL, source?.id == sourceID else { return }
        if isCaching { urls.formUnion(cachedChapterURLs) }
        if urls != cachedChapterURLs { cachedChapterURLs = urls }
    }

    func isChapterCached(_ chapter: BookChapter) -> Bool {
        source == nil || cachedChapterURLs.contains(chapter.url)
    }

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) {
        cancelCaching()
        cacheRefreshGeneration &+= 1
        cacheCompleted = 0
        cacheTotal = 0
        cacheFailed = 0
        cacheError = nil
        cachedChapterURLs = []
        book = report.book
        chapters = report.chapters
        self.source = source
        demoChapterContent = nil
        sourceCacheNeedsInvalidation = true
        select(index: Self.validIndex(report.book.durChapterIndex, chapters: chapters), position: report.book.durChapterPos)
        pendingSourceContent = report.verifiedContent
    }

    func load(rules: [ReplaceRule], forceRefresh: Bool = false, prefetchNextChapter: Bool = true) async {
        guard !isLoading else { return }
        let forceRefresh = forceRefresh || refreshAfterRuleChange
        refreshAfterRuleChange = false
        if !content.isEmpty && !forceRefresh {
            if prefetchNextChapter, let source { schedulePreload(after: currentIndex, source: source) }
            return
        }
        guard let chapter = currentChapter else { return }
        let requestedIndex = currentIndex
        let requestedGeneration = chapterLoadGeneration
        if forceRefresh {
            pendingSourceContent = nil
            clearContinuousReading()
            content = ""
            paragraphs = []
            diagnostics = []
            hasLoadedCurrentChapter = false
        }
        isLoading = true
        defer {
            if requestedGeneration == chapterLoadGeneration { isLoading = false }
        }
        let report: ChapterContentReport
        let fromCache: Bool
        if sourceCacheNeedsInvalidation {
            await contentCoordinator.invalidate(bookURL: book.bookUrl)
            guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
            sourceCacheNeedsInvalidation = false
        }
        if let demoChapterContent {
            fromCache = true
            report = .init(title: chapter.title, content: demoChapterContent)
        } else if let verified = pendingSourceContent, let source, !forceRefresh {
            pendingSourceContent = nil
            fromCache = false
            report = verified
            await contentCoordinator.saveContent(verified, book: book, chapter: chapter, source: source)
        } else if let source {
            let nextURL = nextReadableChapter(after: requestedIndex)?.url
            let result = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextURL,
                forceRefresh: forceRefresh
            )
            fromCache = result.loadedFromCache
            report = result.report
        } else {
            fromCache = false
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                report = .init(diagnostics: [
                    .init(severity: .error, code: "local.read", message: error.localizedDescription, rule: book.bookUrl)
                ])
            }
        }
        guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
        loadedFromCache = fromCache
        if prefetchNextChapter, let source { schedulePreload(after: requestedIndex, source: source) }
        hasLoadedCurrentChapter = true
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let processed = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        )
        title = processed.title
        content = processed.content
        paragraphs = Self.makeParagraphs(processed.content)
        diagnostics = report.diagnostics + processed.diagnostics
    }

    func prepareAdjacentWindows() {
        let previousIndex = navigationIndex(direction: -1)
        if previousLoadedIndex != previousIndex {
            previousLoadedIndex = previousIndex
            previousTitle = previousIndex.map { chapters[$0].title } ?? ""
            previousContent = ""
            isPreviousWindowReady = false
        }
        let nextIndex = navigationIndex(direction: 1)
        if continuationLoadedIndex != nextIndex {
            continuationLoadedIndex = nextIndex
            continuationTitle = nextIndex.map { chapters[$0].title } ?? ""
            continuationContent = ""
            isContinuationWindowReady = false
        }
    }

    func loadAdjacentChapters(rules: [ReplaceRule]) async {
        prepareAdjacentWindows()
        let requestedIndex = currentIndex
        let requestedGeneration = chapterLoadGeneration
        let previousIndex = previousLoadedIndex
        let nextIndex = continuationLoadedIndex
        let needsPrevious = previousIndex != nil && !isPreviousWindowReady
        let needsNext = nextIndex != nil && !isContinuationWindowReady

        async let previousValue: (title: String, content: String, error: String?, fromCache: Bool)? = needsPrevious
            ? loadAdjacentChapter(chapters[previousIndex!], rules: rules)
            : nil
        async let nextValue: (title: String, content: String, error: String?, fromCache: Bool)? = needsNext
            ? loadAdjacentChapter(chapters[nextIndex!], rules: rules)
            : nil
        let resolvedNext = await nextValue
        guard requestedGeneration == chapterLoadGeneration, requestedIndex == currentIndex, !Task.isCancelled else { return }
        if continuationLoadedIndex == nextIndex, needsNext {
            continuationTitle = resolvedNext?.title ?? nextIndex.map { chapters[$0].title } ?? ""
            continuationContent = resolvedNext?.content ?? ""
            isContinuationWindowReady = true
        }
        let resolvedPrevious = await previousValue
        guard requestedGeneration == chapterLoadGeneration, requestedIndex == currentIndex, !Task.isCancelled else { return }
        if previousLoadedIndex == previousIndex, needsPrevious {
            previousTitle = resolvedPrevious?.title ?? previousIndex.map { chapters[$0].title } ?? ""
            previousContent = resolvedPrevious?.content ?? ""
            isPreviousWindowReady = true
        }
    }

    private func loadAdjacentChapter(
        _ chapter: BookChapter,
        rules: [ReplaceRule],
        forceRefresh: Bool = false
    ) async -> (title: String, content: String, error: String?, fromCache: Bool) {
        let report: ChapterContentReport
        let fromCache: Bool
        if let demoChapterContent {
            fromCache = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiScrollRegression") {
                // Let the UI regression cover a response arriving after the
                // finger lifts, while the reader is still decelerating.
                let delay: UInt64 = ProcessInfo.processInfo.arguments.contains("-uiDelayedScrollLoads")
                    ? 350_000_000 : 80_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
            #endif
            report = .init(title: chapter.title, content: demoChapterContent)
        } else if let source {
            let result = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextReadableChapter(after: chapter.index)?.url,
                forceRefresh: forceRefresh
            )
            report = result.report
            fromCache = result.loadedFromCache
        } else {
            fromCache = false
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return (chapter.title, "", error.localizedDescription, false)
            }
        }
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let processed = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        )
        let error = (report.diagnostics + processed.diagnostics).first(where: { $0.severity == .error })?.message
            ?? (processed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source != nil && !chapter.isVolume
                ? "当前书源没有返回正文。" : nil)
        return (processed.title, processed.content, error, fromCache)
    }

    func saveEditedContent(_ value: String) async throws {
        guard let chapter = currentChapter, source != nil else { return }
        try await contentCoordinator.saveEditedContent(book: book, chapter: chapter, title: title, content: value)
        content = value
        paragraphs = Self.makeParagraphs(value)
        loadedFromCache = true
        if let slot = scrollChapters.firstIndex(where: { $0.id == currentIndex }) {
            scrollChapters[slot] = scrollChapterForCurrentContent()
        }
    }

    func nextSpeechContent(rules: [ReplaceRule]) async -> String? {
        guard let chapter = nextReadableChapter(after: currentIndex) else { return nil }
        let report: ChapterContentReport
        if let source {
            report = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextReadableChapter(after: chapter.index)?.url
            ).report
        } else {
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return nil
            }
        }
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let value = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        ).content
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func toggleReplaceRules(position: Int? = nil) -> Book {
        if isLoading { refreshAfterRuleChange = true }
        var config = book.readConfig ?? BookReadConfig()
        config.useReplaceRule = !usesReplaceRules
        book.readConfig = config
        content = ""
        pendingSourceContent = nil
        paragraphs = []
        diagnostics = []
        loadedFromCache = false
        hasLoadedCurrentChapter = false
        clearAdjacentChapters()
        if let position { requestedPosition = max(position, 0) }
        isLoading = false
        chapterLoadGeneration &+= 1
        return book
    }

    @discardableResult
    func useGlobalPageAnimation() -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.pageAnim = -1
        book.readConfig = config
        return book
    }

    @discardableResult
    func setTTSEngine(_ value: String?) -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.ttsEngine = value
        book.readConfig = config
        return book
    }

    func goPrevious(position: Int = 0) { if let value = navigationIndex(direction: -1) { select(index: value, position: position) } }
    func goNext(position: Int = 0) { if let value = navigationIndex(direction: 1) { select(index: value, position: position) } }

    @discardableResult
    func turnPagedChapter(direction: Int, rules: [ReplaceRule]) async -> Bool {
        guard let prepared = await preparePagedChapter(direction: direction, rules: rules) else { return false }
        return commitPagedChapter(prepared)
    }

    func preparePagedChapter(direction: Int, rules: [ReplaceRule]) async -> ReaderPreparedChapter? {
        guard direction == 1 || direction == -1, pagedChapterDirection == nil, let target = navigationIndex(direction: direction),
              hasLoadedCurrentChapter else { return nil }
        let generation = chapterLoadGeneration
        let index = currentIndex
        pagedRequestGeneration &+= 1
        let request = pagedRequestGeneration
        pagedChapterDirection = direction
        pagedChapterError = nil
        showsPagedChapterLoading = false
        let loadingIndicator = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.pagedRequestGeneration == request else { return }
            self.showsPagedChapterLoading = true
        }
        defer {
            loadingIndicator.cancel()
            if pagedRequestGeneration == request { showsPagedChapterLoading = false }
        }
        let prepared = await loadAdjacentChapter(chapters[target], rules: rules)
        guard !Task.isCancelled, chapterLoadGeneration == generation, currentIndex == index,
              pagedRequestGeneration == request else {
            if pagedRequestGeneration == request { pagedChapterDirection = nil }
            return nil
        }
        if let error = prepared.error {
            pagedChapterDirection = nil
            pagedChapterError = error
            return nil
        }
        return .init(request: request, generation: generation, fromIndex: index, targetIndex: target,
                     direction: direction, title: prepared.title, content: prepared.content, fromCache: prepared.fromCache)
    }

    @discardableResult
    func commitPagedChapter(_ prepared: ReaderPreparedChapter) -> Bool {
        guard prepared.request == pagedRequestGeneration, prepared.generation == chapterLoadGeneration,
              prepared.fromIndex == currentIndex, pagedChapterDirection == prepared.direction else { return false }
        // Keep the existing document visible until a complete, matching chapter is ready.
        clearAdjacentChapters()
        currentIndex = prepared.targetIndex
        title = prepared.title
        content = prepared.content
        paragraphs = Self.makeParagraphs(prepared.content)
        diagnostics = []
        requestedPosition = prepared.direction > 0 ? 0 : max(prepared.content.utf16.count - 1, 0)
        loadedFromCache = prepared.fromCache
        hasLoadedCurrentChapter = true
        chapterLoadGeneration &+= 1
        chapterTransition = .init(id: chapterLoadGeneration, direction: prepared.direction)
        pagedChapterDirection = nil
        if let source { schedulePreload(after: currentIndex, source: source) }
        return true
    }

    func cancelPagedChapterTurn() {
        pagedRequestGeneration &+= 1
        pagedChapterDirection = nil
        showsPagedChapterLoading = false
        pagedChapterError = nil
    }

    func cancelPreloading() {
        preloadTask?.cancel()
        preloadTask = nil
        cancelPagedChapterTurn()
    }

    func promoteContinuation(position: Int) {
        guard let value = navigationIndex(direction: 1), hasContinuationWindow else {
            return
        }
        let oldIndex = currentIndex
        let oldTitle = title
        let oldContent = content
        let promotedContentResolved = isContinuationWindowReady
        currentIndex = value
        title = continuationTitle.isEmpty ? chapters[value].title : continuationTitle
        content = continuationContent
        paragraphs = Self.makeParagraphs(continuationContent)
        diagnostics = []
        requestedPosition = max(position, 0)
        loadedFromCache = promotedContentResolved
        hasLoadedCurrentChapter = promotedContentResolved
        previousLoadedIndex = oldIndex
        previousTitle = oldTitle
        previousContent = oldContent
        isPreviousWindowReady = true
        continuationLoadedIndex = nil
        continuationTitle = ""
        continuationContent = ""
        isContinuationWindowReady = false
        isLoading = false
        chapterLoadGeneration &+= 1
    }

    func promotePrevious(position: Int) {
        guard let value = navigationIndex(direction: -1), hasPreviousWindow else { return }
        let oldIndex = currentIndex
        let oldTitle = title
        let oldContent = content
        let promotedContentResolved = isPreviousWindowReady
        currentIndex = value
        title = previousTitle.isEmpty ? chapters[value].title : previousTitle
        content = previousContent
        paragraphs = Self.makeParagraphs(previousContent)
        diagnostics = []
        requestedPosition = max(position, 0)
        loadedFromCache = promotedContentResolved
        hasLoadedCurrentChapter = promotedContentResolved
        continuationLoadedIndex = oldIndex
        continuationTitle = oldTitle
        continuationContent = oldContent
        isContinuationWindowReady = true
        previousLoadedIndex = nil
        previousTitle = ""
        previousContent = ""
        isPreviousWindowReady = false
        isLoading = false
        chapterLoadGeneration &+= 1
    }

    func select(index: Int, position: Int = 0) {
        guard chapters.indices.contains(index), !chapters[index].isVolume else { return }
        cancelPreloading()
        chapterTransition = nil
        currentIndex = index
        pendingSourceContent = nil
        title = chapters[index].title
        content = ""
        paragraphs = []
        diagnostics = []
        requestedPosition = max(position, 0)
        loadedFromCache = false
        hasLoadedCurrentChapter = false
        clearAdjacentChapters()
        isLoading = false
        chapterLoadGeneration &+= 1
    }

    private func clearAdjacentChapters() {
        clearContinuousReading()
        previousLoadedIndex = nil
        previousTitle = ""
        previousContent = ""
        isPreviousWindowReady = false
        continuationLoadedIndex = nil
        continuationTitle = ""
        continuationContent = ""
        isContinuationWindowReady = false
    }

    func paragraphID(at position: Int) -> Int? {
        paragraphs.last(where: { $0.id <= position })?.id ?? paragraphs.first?.id
    }

    private func navigationIndex(direction: Int) -> Int? {
        readableIndex(from: currentIndex, direction: direction)
    }

    private func readableIndex(from index: Int, direction: Int) -> Int? {
        var value = index + direction
        while chapters.indices.contains(value) {
            if !chapters[value].isVolume { return value }
            value += direction
        }
        return nil
    }

    private func nextReadableChapter(after index: Int) -> BookChapter? {
        var value = index + 1
        while chapters.indices.contains(value) {
            if !chapters[value].isVolume { return chapters[value] }
            value += 1
        }
        return nil
    }

    private func startCaching(limit: Int?) {
        guard let source else { return }
        cancelCaching()
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: currentIndex, limit: limit)
        guard !jobs.isEmpty else { return }
        isCaching = true
        cacheCompleted = 0
        cacheTotal = jobs.count
        cacheFailed = 0
        cacheError = nil
        let generation = cacheGeneration
        let coordinator = contentCoordinator
        let currentBook = book
        let currentSource = source
        cacheTask = Task.detached(priority: .utility) { [weak self] in
            var completed = 0
            var failed = 0
            var available: Set<String> = []
            var firstError: String?
            var lastUpdate = ProcessInfo.processInfo.systemUptime
            await withTaskGroup(of: (String, ChapterPrefetchResult).self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        let result = await coordinator.prefetchResult(
                            book: currentBook,
                            chapter: job.chapter,
                            source: currentSource,
                            nextChapterURL: job.nextChapterURL
                        )
                        return (job.chapter.url, result)
                    }
                }
                for _ in 0..<min(3, jobs.count) { enqueue() }
                while let (url, result) = await group.next() {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    completed += 1
                    if result.isAvailable { available.insert(url) }
                    else if case let .failed(reason) = result {
                        failed += 1
                        if firstError == nil { firstError = reason }
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastUpdate >= 0.25 {
                        guard await self?.publishCacheProgress(generation: generation, completed: completed,
                            failed: failed, available: available, error: firstError) == true else {
                            group.cancelAll()
                            break
                        }
                        lastUpdate = now
                    }
                    enqueue()
                }
            }
            guard !Task.isCancelled else { return }
            guard await self?.publishCacheProgress(generation: generation, completed: completed,
                failed: failed, available: available, error: firstError) == true else { return }
            await self?.finishCaching(generation: generation)
        }
    }

    private func publishCacheProgress(generation: Int, completed: Int, failed: Int,
                                      available: Set<String>, error: String?) -> Bool {
        guard generation == cacheGeneration, isCaching else { return false }
        cacheCompleted = completed
        cacheFailed = failed
        cacheError = error
        if !available.isSubset(of: cachedChapterURLs) { cachedChapterURLs.formUnion(available) }
        return true
    }

    private func finishCaching(generation: Int) async {
        guard generation == cacheGeneration else { return }
        isCaching = false
        cacheTask = nil
        await refreshCachedChapters()
    }

    private func schedulePreload(after index: Int, source: BookSource) {
        preloadTask?.cancel()
        preloadTask = nil
        let count = prefetchLimit ?? ApplicationSettingsStore.shared.settings.prefetchChapters
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: index + 1, limit: count)
        guard index + 1 < chapters.count, !jobs.isEmpty else { return }
        preloadTask = Task { [book, contentCoordinator] in
            for job in jobs {
                guard !Task.isCancelled else { return }
                await contentCoordinator.prefetch(book: book, chapter: job.chapter, source: source, nextChapterURL: job.nextChapterURL)
            }
        }
    }

    private static func makeParagraphs(_ content: String) -> [ReaderParagraph] {
        var position = 0
        var output: [ReaderParagraph] = []
        for line in content.components(separatedBy: .newlines) {
            if !line.isEmpty { output.append(.init(id: position, text: line)) }
            position += line.utf16.count + 1
        }
        if output.isEmpty, !content.isEmpty { output.append(.init(id: 0, text: content)) }
        return output
    }

    private static func validIndex(_ requested: Int, chapters: [BookChapter]) -> Int {
        if chapters.indices.contains(requested), !chapters[requested].isVolume { return requested }
        return chapters.firstIndex(where: { !$0.isVolume }) ?? 0
    }
}
