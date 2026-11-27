import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct ReaderParagraph: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Row IDs are offsets in the current source's chapter array. Volume headings
/// have rows, but do not occupy a stop on the chapter slider.
struct ReaderChapterDirectory {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let number: Int?
        let chapterURL: String
    }

    let rows: [Row]
    let readableIndices: [Int]

    init(_ chapters: [BookChapter]) {
        var indices: [Int] = []
        rows = chapters.enumerated().map { index, chapter in
            if !chapter.isVolume { indices.append(index) }
            return Row(id: index, title: chapter.title, number: chapter.isVolume ? nil : indices.count, chapterURL: chapter.url)
        }
        readableIndices = indices
    }

    func rows(matching search: String, descending: Bool) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Int(query)
        let matches = query.isEmpty ? rows : rows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || (number != nil && $0.number == number)
        }
        return descending ? Array(matches.reversed()) : matches
    }
}

struct ReaderScrollChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let content: String
    var error: String? = nil
    var hasComments = false
}

struct ReaderChapterCommentsTarget: Identifiable {
    let book: Book
    let chapter: BookChapter
    let source: BookSource
    let official: OfficialCommentChapter?

    var id: String { "\(source.id)\u{0}\(chapter.id)\u{0}\(chapter.index)" }
}

struct ReaderChapterCommentPages {
    private(set) var comments: [ChapterComment] = []
    private(set) var nextPageURL: URL?
    private var receivedFirstPage = false
    private var seenIDs: Set<String> = []
    private var visited: Set<URL> = []

    mutating func append(_ page: ChapterCommentPage, requestedURL: URL?) {
        if let requestedURL {
            guard receivedFirstPage, nextPageURL == requestedURL, visited.insert(requestedURL).inserted else { return }
        } else {
            guard !receivedFirstPage else { return }
            receivedFirstPage = true
        }
        for comment in page.comments where seenIDs.insert(comment.id).inserted {
            comments.append(comment)
        }
        nextPageURL = page.nextPageURL.flatMap { visited.contains($0) ? nil : $0 }
    }
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
    @Published private(set) var isWaitingForSource = false
    @Published private(set) var title: String
    @Published private(set) var content = "" {
        didSet {
            cachedParagraphs = nil
            updateImageBlocks()
        }
    }
    @Published private(set) var imageBlocks: [ChapterContentBlock] = []
    private(set) var hasImageContent = false
    var imageSource: BookSource { source ?? BookSource(bookSourceUrl: book.origin, bookSourceName: book.originName) }

    private func updateImageBlocks() {
        hasImageContent = false
        let allowBareURLs = source?.bookSourceType == 2 || source?.ruleContent?.imageStyle?.uppercased() == "FULL"
        guard allowBareURLs || content.range(of: "<img", options: .caseInsensitive) != nil
                || content.range(of: "<mip-img", options: .caseInsensitive) != nil
                || content.contains("://") else {
            imageBlocks = []
            return
        }
        imageBlocks = ChapterImageParser().blocks(in: content,
            baseURL: currentChapter.flatMap { URL(string: $0.baseUrl.isEmpty ? $0.url : $0.baseUrl) },
            allowBareURLs: allowBareURLs)
        let hasPictures = imageBlocks.contains { if case .image = $0.content { return true }; return false }
        let hasProse = imageBlocks.contains { if case .text = $0.content { return true }; return false }
        let mixedText = source?.bookSourceType != 2 && hasProse && hasPictures &&
            (source?.ruleContent?.imageStyle?.uppercased() == "TEXT" || ChapterInlineMedia(content).items.contains(where: \.isCard))
        hasImageContent = hasPictures && !mixedText
    }
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var currentIndex: Int
    @Published private(set) var chapterLoadGeneration = 0
    private(set) var displayedChapterGeneration = 0
    private var cachedParagraphs: [ReaderParagraph]?
    var paragraphs: [ReaderParagraph] {
        if let cachedParagraphs { return cachedParagraphs }
        let result = Self.makeParagraphs(content)
        cachedParagraphs = result
        return result
    }
    @Published private(set) var requestedPosition: Int
    @Published private(set) var loadedFromCache = false
    @Published private(set) var hasLoadedCurrentChapter = false
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

    @Published private(set) var book: Book
    private(set) var chapters: [BookChapter] {
        didSet { directory = ReaderChapterDirectory(chapters) }
    }
    private(set) lazy var directory = ReaderChapterDirectory(chapters)
    var currentChapterNumber: Int {
        directory.rows.indices.contains(currentIndex) ? directory.rows[currentIndex].number ?? 0 : 0
    }
    var onlineSourceID: String? { source?.id }
    let chapterCache: ChapterContentCache
    private var source: BookSource?
    private let localService: LocalBookService
    private var preloadTask: Task<Void, Never>?
    private var previousPreparation: Task<Void, Never>?
    private var upcomingRequests: [String: Task<CoordinatedChapterContent, Never>] = [:]
    private let settingsStore: ApplicationSettingsStore
    private var preloadCount = 0
    private var readingRules: [ReplaceRule] = []
    private var initialContentStamp: ChapterContentStamp?
    private var preparedChapters: [BookChapter: (body: ContentProcessingReport, stamp: ChapterContentStamp)] = [:]
    private var directoryUpdateTask: Task<Void, Never>?
    private var lastDirectoryCheck: Int64 = 0
    private let contentCoordinator: ChapterContentCoordinator
    private var demoChapterContent: String?
    private var previousLoadedIndex: Int?
    private var continuationLoadedIndex: Int?
    @Published private(set) var scrollRetries: Set<Int> = []
    private var sourceCacheNeedsInvalidation = false
    private var pendingSourceContent: ChapterContentReport?

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

    var visibleScrollChapters: [ReaderScrollChapter] {
        if scrollChapters.isEmpty, hasLoadedCurrentChapter { return [scrollChapterForCurrentContent()] }
        return scrollChapters
    }

    func prepareContinuousReading(rules: [ReplaceRule]) async {
        guard hasLoadedCurrentChapter, !hasImageContent else { return }
        if scrollChapters.isEmpty {
            scrollChapters = [scrollChapterForCurrentContent()]
        }
        guard let active = scrollChapters.firstIndex(where: { $0.id == currentIndex }) else { return }
        let needsAhead = scrollChapters.count - active <= 2
        let needsBehind = active < 2
        async let ahead: Void = needsAhead ? extendContinuousReading(direction: 1, rules: rules) : ()
        async let behind: Void = needsBehind ? extendContinuousReading(direction: -1, rules: rules) : ()
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
                id: index, title: value.title, content: value.content, error: value.error,
                hasComments: commentsTarget(at: index) != nil
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
        scrollChapters[slot] = .init(id: index, title: value.title, content: value.content, error: value.error,
                                     hasComments: commentsTarget(at: index) != nil)
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
        diagnostics = []
        hasLoadedCurrentChapter = true
        if chapter.error == nil { schedulePreload() }
    }

    private func scrollChapterForCurrentContent() -> ReaderScrollChapter {
        .init(id: currentIndex, title: title, content: content,
              error: currentChapterError, hasComments: commentsTarget(at: currentIndex) != nil)
    }

    private func clearContinuousReading(keepingWindow: Bool = false) {
        scrollRevision &+= 1
        if !keepingWindow { scrollChapters = [] }
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
        settingsStore: ApplicationSettingsStore = .shared
    ) {
        let resolvedIndex = Self.validIndex(initialIndex, chapters: chapters)
        self.book = book
        self.chapters = chapters
        currentIndex = resolvedIndex
        self.source = source
        self.settingsStore = settingsStore
        localService = .init()
        chapterCache = cache
        contentCoordinator = .init(loader: service, cache: cache)
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    convenience init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        self.init(book: book, chapters: chapters, initialIndex: initialIndex)
        self.content = content
        demoChapterContent = content
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
        settingsStore = .shared
        self.localService = localService
        chapterCache = cache
        contentCoordinator = .init(cache: cache)
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    var currentChapter: BookChapter? { chapters.indices.contains(currentIndex) ? chapters[currentIndex] : nil }

    func commentsTarget(at index: Int) -> ReaderChapterCommentsTarget? {
        guard let source, source.id == book.origin, chapters.indices.contains(index) else { return nil }
        let chapter = chapters[index]
        guard !chapter.isVolume, chapter.bookUrl == book.bookUrl else { return nil }
        let official = OfficialCommentChapter.resolve(book: book, chapter: chapter)
        guard official != nil || source.ruleReview?.supportsChapterComments == true ||
                source.ruleReview?.supportsChapterCommentsPage == true else { return nil }
        return .init(book: book, chapter: chapter, source: source, official: official)
    }

    var nextChapter: BookChapter? { nextReadableChapter(after: currentIndex) }
    var canGoPrevious: Bool { navigationIndex(direction: -1) != nil }
    var canGoNext: Bool { navigationIndex(direction: 1) != nil }
    var hasPreviousWindow: Bool { previousLoadedIndex != nil }
    var hasContinuationWindow: Bool { continuationLoadedIndex != nil }
    var canEditContent: Bool { source != nil }
    var usesReplaceRules: Bool { book.readConfig?.useReplaceRule ?? true }
    var usesParagraphResegmentation: Bool { book.readConfig?.reSegment ?? false }
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

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) {
        stopBackgroundReading()
        preparedChapters.removeAll()
        lastDirectoryCheck = 0
        book = report.book
        chapters = report.chapters
        self.source = source
        demoChapterContent = nil
        sourceCacheNeedsInvalidation = true
        select(index: Self.validIndex(report.book.durChapterIndex, chapters: chapters), position: report.book.durChapterPos)
        pendingSourceContent = report.verifiedContent
    }

    static func cachedOpening(book: Book, chapters: [BookChapter], source: BookSource, rules: [ReplaceRule],
                              reusing prepared: ReaderViewModel? = nil, speculative: Bool = false) async -> ReaderViewModel {
        if let prepared, prepared.canResumePrepared(book: book, chapters: chapters, source: source, rules: rules) {
            return prepared
        }
        let index = min(max(book.durChapterIndex, 0), max(chapters.count - 1, 0))
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: index, source: source)
        await reader.prepareCachedOpening(rules: rules, speculative: speculative)
        return reader
    }

    func canResumePrepared(book: Book, chapters: [BookChapter], source: BookSource, rules: [ReplaceRule]) -> Bool {
        guard let stamp = initialContentStamp, chapterCache.isCurrent(stamp),
              self.book == book, self.source == source, currentIndex == book.durChapterIndex,
              readingRules == (usesReplaceRules ? rules : []), self.chapters == chapters else { return false }
        return hasLoadedCurrentChapter
    }

    /// A speculative opening reads local data only. Dynamic replacements run when the user opens the book.
    func prepareCachedOpening(rules: [ReplaceRule], speculative: Bool = false) async {
        guard let chapter = currentChapter, let source else { return }
        updateReadingRules(rules)
        guard !speculative || canReuseProcessedContent else { return }
        guard let cached = await contentCoordinator.cachedContent(book: book, chapter: chapter, source: source),
              !Task.isCancelled else { return }
        let rulesAtOpen = readingRules
        let processed = await Self.process(cached.report, book: book, chapter: chapter, rules: rulesAtOpen)
        guard !Task.isCancelled, rulesAtOpen == readingRules, let stamp = cached.stamp, chapterCache.isCurrent(stamp) else { return }
        display(processed, diagnostics: cached.report.diagnostics, cached: true)
        initialContentStamp = stamp
        rememberPrepared(processed, chapter: chapter, stamp: stamp)
    }

    func replaceReadingRules(_ rules: [ReplaceRule], at position: Int) {
        guard usesReplaceRules, readingRules != rules else { return }
        updateReadingRules(rules)
        invalidateProcessedContent(position: position)
    }

    private func updateReadingRules(_ rules: [ReplaceRule]) {
        let effective = usesReplaceRules ? rules : []
        guard effective != readingRules else { return }
        readingRules = effective
        preparedChapters.removeAll()
        preloadTask?.cancel()
    }

    private func display(_ processed: ContentProcessingReport, diagnostics sourceDiagnostics: [RuleDiagnostic], cached: Bool) {
        displayedChapterGeneration = chapterLoadGeneration
        loadedFromCache = cached
        title = processed.title
        content = processed.content
        diagnostics = sourceDiagnostics + processed.diagnostics
        hasLoadedCurrentChapter = true
    }

    func load(rules: [ReplaceRule], forceRefresh: Bool = false, prefetchNextChapter: Bool = true) async {
        guard let chapter = currentChapter, !isLoading else { return }
        let requestedIndex = currentIndex
        let requestedGeneration = chapterLoadGeneration
        if let stamp = initialContentStamp {
            initialContentStamp = nil
            if !chapterCache.isCurrent(stamp) || readingRules != (usesReplaceRules ? rules : []) {
                hasLoadedCurrentChapter = false
                content = ""
            }
        }
        updateReadingRules(rules)
        if forceRefresh {
            preparedChapters.removeAll()
            cancelPreload()
            pendingSourceContent = nil
            clearContinuousReading()
            content = ""
            diagnostics = []
            hasLoadedCurrentChapter = false
        }
        preloadCount = source != nil && prefetchNextChapter ? settingsStore.settings.prefetchChapters : 0
        if !content.isEmpty {
            if hasLoadedCurrentChapter, currentChapterError == nil { schedulePreload() }
            return
        }
        isLoading = true
        defer {
            if requestedGeneration == chapterLoadGeneration {
                isLoading = false
                isWaitingForSource = false
            }
        }
        let report: ChapterContentReport
        let fromCache: Bool
        var stamp: ChapterContentStamp?
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
            stamp = await contentCoordinator.saveContent(verified, book: book, chapter: chapter, source: source)
        } else if let source {
            let nextURL = nextReadableChapter(after: requestedIndex)?.url
            let result: CoordinatedChapterContent
            let pending = forceRefresh ? nil : upcomingRequests[chapter.url]
            if !forceRefresh, let cached = await contentCoordinator.cachedContent(book: book, chapter: chapter, source: source) {
                result = cached
            } else {
                guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
                isWaitingForSource = true
                if let pending {
                    cancelPreload(keeping: [chapter.url])
                    result = await pending.value
                } else {
                    // Give the newly selected chapter the source's request slot.
                    cancelPreload(keeping: [])
                    result = await contentCoordinator.load(book: book, chapter: chapter, source: source,
                                                           nextChapterURL: nextURL, forceRefresh: true)
                }
            }
            fromCache = result.loadedFromCache
            stamp = result.stamp
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
        let processed = await Self.process(report, book: book, chapter: chapter, rules: usesReplaceRules ? rules : [])
        guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
        display(processed, diagnostics: report.diagnostics, cached: fromCache)
        if let stamp, report.diagnostics.isEmpty { rememberPrepared(processed, chapter: chapter, stamp: stamp) }
        if !content.isEmpty, !diagnostics.contains(where: { $0.severity == .error }) {
            schedulePreload()
        }
    }

    private nonisolated static func process(_ report: ChapterContentReport, book: Book, chapter: BookChapter,
                                            rules: [ReplaceRule]) async -> ContentProcessingReport {
        var chapter = chapter
        if let title = report.title { chapter.title = title }
        return ContentSanitizer().process(book: book, chapter: chapter, content: report.content, rules: rules)
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

        async let previousValue: (title: String, content: String, error: String?)? = needsPrevious
            ? loadAdjacentChapter(chapters[previousIndex!], rules: rules)
            : nil
        async let nextValue: (title: String, content: String, error: String?)? = needsNext
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
    ) async -> (title: String, content: String, error: String?) {
        if !forceRefresh, rules == readingRules, let prepared = preparedContent(for: chapter) {
            return (prepared.body.title, prepared.body.content, nil)
        }
        let report: ChapterContentReport
        var stamp: ChapterContentStamp?
        if let demoChapterContent {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiScrollRegression") {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            #endif
            report = .init(title: chapter.title, content: demoChapterContent)
        } else if let source {
            let job = ChapterCacheJob(chapter: chapter, nextChapterURL: nextReadableChapter(after: chapter.index)?.url)
            let result = await upcomingContent(for: job, source: source, priority: .userInitiated, forceRefresh: forceRefresh)
            report = result.report
            stamp = result.stamp
        } else {
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return (chapter.title, "", error.localizedDescription)
            }
        }
        let processed = await Self.process(report, book: book, chapter: chapter, rules: usesReplaceRules ? rules : [])
        let error = (report.diagnostics + processed.diagnostics).first(where: { $0.severity == .error })?.message
            ?? (processed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source != nil && !chapter.isVolume
                ? "当前书源没有返回正文。" : nil)
        if let stamp, error == nil, report.diagnostics.isEmpty, rules == readingRules {
            rememberPrepared(processed, chapter: chapter, stamp: stamp)
        }
        return (processed.title, processed.content, error)
    }

    func saveEditedContent(_ value: String) async throws {
        guard let chapter = currentChapter, source != nil else { return }
        preparedChapters.removeValue(forKey: chapter)
        try await contentCoordinator.saveEditedContent(book: book, chapter: chapter, title: title, content: value)
        content = value
        loadedFromCache = true
        if let slot = scrollChapters.firstIndex(where: { $0.id == currentIndex }) {
            scrollChapters[slot] = scrollChapterForCurrentContent()
        }
    }

    func nextSpeechContent(rules: [ReplaceRule]) async -> String? {
        guard let chapter = nextReadableChapter(after: currentIndex) else { return nil }
        let report: ChapterContentReport
        if let source {
            let job = ChapterCacheJob(chapter: chapter, nextChapterURL: nextReadableChapter(after: chapter.index)?.url)
            report = await upcomingContent(for: job, source: source, priority: .userInitiated).report
        } else {
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return nil
            }
        }
        let value = await Self.process(report, book: book, chapter: chapter, rules: usesReplaceRules ? rules : []).content
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func toggleReplaceRules(position: Int? = nil) -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.useReplaceRule = !usesReplaceRules
        book.readConfig = config
        invalidateProcessedContent(position: position)
        return book
    }

    @discardableResult
    func toggleParagraphResegmentation(position: Int? = nil) -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.reSegment = !usesParagraphResegmentation
        book.readConfig = config
        invalidateProcessedContent(position: position)
        return book
    }

    private func invalidateProcessedContent(position: Int?) {
        preloadTask?.cancel()
        previousPreparation?.cancel()
        preparedChapters.removeAll()
        isWaitingForSource = false
        content = ""
        pendingSourceContent = nil
        diagnostics = []
        loadedFromCache = false
        hasLoadedCurrentChapter = false
        clearAdjacentChapters()
        if let position { requestedPosition = max(position, 0) }
        isLoading = false
        chapterLoadGeneration &+= 1
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
        if promotedContentResolved { displayedChapterGeneration = chapterLoadGeneration }
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
        if promotedContentResolved { displayedChapterGeneration = chapterLoadGeneration }
    }

    func select(index: Int, position: Int = 0) {
        guard chapters.indices.contains(index), !chapters[index].isVolume else { return }
        var reusable = Set([chapters[index].url])
        if !upcomingRequests.isEmpty, let number = directory.rows[index].number {
            let upcoming = directory.readableIndices.dropFirst(number).prefix(preloadCount)
            reusable.formUnion(upcoming.map { chapters[$0].url })
        }
        cancelPreload(keeping: reusable)
        let target = chapters[index]
        let prepared = preparedContent(for: target)
        currentIndex = index
        pendingSourceContent = nil
        requestedPosition = max(position, 0)
        let keepWindow = prepared.map { prepared in
            scrollChapters.contains {
                $0.id == index && $0.error == nil && $0.content == prepared.body.content && $0.title == prepared.body.title
            }
        } ?? false
        clearAdjacentChapters(keepingWindow: keepWindow)
        isLoading = false
        isWaitingForSource = false
        chapterLoadGeneration &+= 1
        initialContentStamp = prepared?.stamp
        if let prepared {
            requestedPosition = min(requestedPosition, max(0, prepared.body.content.utf16.count - 1))
            display(prepared.body, diagnostics: [], cached: true)
        } else {
            title = target.title
            content = ""
            diagnostics = []
            loadedFromCache = false
            hasLoadedCurrentChapter = false
        }
    }

    private func clearAdjacentChapters(keepingWindow: Bool = false) {
        clearContinuousReading(keepingWindow: keepingWindow)
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

    @discardableResult
    func checkForNewChapters(using library: BookLibraryModel,
                             position: @escaping @MainActor () -> Int) -> Task<Void, Never>? {
        if let directoryUpdateTask { return directoryUpdateTask }
        guard let source, book.canUpdate, hasLoadedCurrentChapter, !content.isEmpty, currentChapterError == nil,
              directory.readableIndices.count - currentChapterNumber <= 5 else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let lastCheck = max(book.lastCheckTime, lastDirectoryCheck)
        guard lastCheck > now || now - lastCheck >= 300_000 else { return nil }
        lastDirectoryCheck = now
        let original = book
        let wasShelved = library.contains(original)
        let task = Task(priority: .utility) { [weak self] in
            defer { if !Task.isCancelled { self?.directoryUpdateTask = nil } }
            let report = await library.updateCoordinator.refresh(book: original, source: source, persistDirectory: false)
            guard !Task.isCancelled, let self, report.refreshed, report.book.origin == source.id,
                  let last = chapters.last(where: { !$0.isVolume }),
                  let lastInUpdate = Self.match(last, in: report.chapters),
                  report.chapters.dropFirst(lastInUpdate + 1).contains(where: { !$0.isVolume }),
                  let currentChapter, Self.match(currentChapter, in: report.chapters) != nil else { return }
            if wasShelved || library.contains(original) {
                guard await library.commitPreparedUpdate(requestedBook: original, report: report) else { return }
            } else if original.bookUrl != report.book.bookUrl {
                // Some sources rotate the book URL in their update script.
                // Keep already-downloaded chapters when reading an unshelved search result.
                await contentCoordinator.copyContents(from: original, chapters: chapters, to: report.book, chapters: report.chapters)
            }
            guard !Task.isCancelled, let visible = self.currentChapter,
                  let index = Self.match(visible, in: report.chapters) else { return }
            let offset = position()
            let appended = original.bookUrl == report.book.bookUrl && chapters.count <= report.chapters.count
                && zip(chapters, report.chapters).allSatisfy { $0.url == $1.url && $0.isVolume == $1.isVolume }
            var updated = BookUpdateMerger().applyingPreparation(original: original, current: book, prepared: report.book)
            updated.totalChapterNum = report.chapters.count
            updated.latestChapterTitle = report.book.latestChapterTitle
            updated.latestChapterTime = report.book.latestChapterTime
            updated.lastCheckTime = report.book.lastCheckTime
            updated.durChapterIndex = index
            updated.durChapterTitle = report.chapters[index].title
            updated.durChapterPos = offset
            chapters = report.chapters
            book = updated
            if appended {
                schedulePreload()
            } else {
                cancelPreload()
                select(index: index, position: offset)
            }
        }
        directoryUpdateTask = task
        return task
    }

    private static func match(_ chapter: BookChapter, in updated: [BookChapter]) -> Int? {
        if let index = updated.firstIndex(where: { $0.url == chapter.url && $0.isVolume == chapter.isVolume }) { return index }
        return updated.indices.filter { updated[$0].title == chapter.title && updated[$0].isVolume == chapter.isVolume }
            .min { abs($0 - chapter.index) < abs($1 - chapter.index) }
    }

    func stopBackgroundReading() {
        if let directoryUpdateTask {
            directoryUpdateTask.cancel()
            self.directoryUpdateTask = nil
            lastDirectoryCheck = 0
        }
        cancelPreload()
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        previousPreparation?.cancel()
        if let source, canReuseProcessedContent, let previous = navigationIndex(direction: -1).map({ chapters[$0] }),
           preparedContent(for: previous) == nil {
            previousPreparation = Task(priority: .utility) { [weak self, book, contentCoordinator, readingRules] in
                guard !Task.isCancelled, let result = await contentCoordinator.cachedContent(book: book, chapter: previous, source: source),
                      let stamp = result.stamp, !Task.isCancelled else { return }
                let processed = await Self.process(result.report, book: book, chapter: previous, rules: readingRules)
                guard let self, self.readingRules == readingRules else { return }
                self.rememberPrepared(processed, chapter: previous, stamp: stamp)
            }
        }
        let start = currentIndex + 1
        guard let source, preloadCount > 0, start < chapters.count else { return }
        preloadTask = Task.detached(priority: .utility) { [weak self, book, chapters, preloadCount, readingRules] in
            guard !Task.isCancelled else { return }
            let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: start, limit: preloadCount)
            for job in jobs {
                guard !Task.isCancelled, let self else { return }
                if await self.preparedContent(for: job.chapter) != nil { continue }
                let result = await self.upcomingContent(for: job, source: source, priority: .utility)
                guard !Task.isCancelled else { return }
                // Script replacements can depend on the time or other mutable book state.
                guard let stamp = result.stamp, !result.report.content.isEmpty, result.report.diagnostics.isEmpty,
                      !readingRules.contains(where: { $0.isEnabled && $0.replacement.hasPrefix("@js:") }) else { continue }
                let processed = await Self.process(result.report, book: book, chapter: job.chapter, rules: readingRules)
                await self.rememberPrepared(processed, chapter: job.chapter, stamp: stamp)
            }
        }
    }

    private func preparedContent(for chapter: BookChapter) -> (body: ContentProcessingReport, stamp: ChapterContentStamp)? {
        guard let prepared = preparedChapters[chapter], chapterCache.isCurrent(prepared.stamp) else { return nil }
        return prepared
    }

    private var canReuseProcessedContent: Bool {
        !readingRules.contains { $0.isEnabled && $0.replacement.hasPrefix("@js:") }
    }

    private func rememberPrepared(_ processed: ContentProcessingReport, chapter: BookChapter, stamp: ChapterContentStamp) {
        guard !Task.isCancelled, canReuseProcessedContent, chapterCache.isCurrent(stamp),
              !processed.content.isEmpty, processed.diagnostics.isEmpty else { return }
        preparedChapters[chapter] = (processed, stamp)
        while preparedChapters.count > max(preloadCount, 1) + 2
                || preparedChapters.values.reduce(0, { $0 + $1.body.content.utf8.count }) > 4 * 1024 * 1024 {
            let oldest = preparedChapters.keys.min { $0.index < $1.index }
            let previousIndex = navigationIndex(direction: -1) ?? currentIndex
            if let oldest, oldest.index < previousIndex {
                preparedChapters.removeValue(forKey: oldest)
            } else if let farthest = preparedChapters.keys.max(by: { abs($0.index - currentIndex) < abs($1.index - currentIndex) }) {
                preparedChapters.removeValue(forKey: farthest)
            } else { break }
        }
    }

    // Scrolling can ask for the same chapter while the disk prefetch is still fetching it.
    private func upcomingContent(for job: ChapterCacheJob, source: BookSource,
                                 priority: TaskPriority, forceRefresh: Bool = false) async -> CoordinatedChapterContent {
        guard !Task.isCancelled else { return .init(report: .init(), loadedFromCache: false) }
        let url = job.chapter.url
        if forceRefresh { upcomingRequests.removeValue(forKey: url)?.cancel() }
        if let pending = upcomingRequests[url] { return await pending.value }
        let request = Task.detached(priority: priority) { [book, contentCoordinator] in
            await contentCoordinator.load(book: book, chapter: job.chapter, source: source,
                                          nextChapterURL: job.nextChapterURL, forceRefresh: forceRefresh)
        }
        upcomingRequests[url] = request
        let content = await request.value
        if upcomingRequests[url] == request { upcomingRequests.removeValue(forKey: url) }
        return content
    }

    func cancelPreload() {
        preloadCount = 0
        cancelPreload(keeping: [])
    }

    private func cancelPreload(keeping urls: Set<String>) {
        previousPreparation?.cancel()
        previousPreparation = nil
        preloadTask?.cancel()
        preloadTask = nil
        for (url, request) in upcomingRequests where !urls.contains(url) {
            request.cancel()
            upcomingRequests.removeValue(forKey: url)
        }
    }

    private static func makeParagraphs(_ content: String) -> [ReaderParagraph] {
        let media = ChapterInlineMedia(content)
        let body = content as NSString
        var position = 0
        var output: [ReaderParagraph] = []
        for line in content.components(separatedBy: .newlines) {
            let text = media.items.isEmpty ? line : media.textForReading(body, range: NSRange(location: position, length: line.utf16.count))
            if !text.isEmpty { output.append(.init(id: position, text: text)) }
            position += line.utf16.count + 1
        }
        if output.isEmpty, media.items.isEmpty, !content.isEmpty { output.append(.init(id: 0, text: content)) }
        return output
    }

    private static func validIndex(_ requested: Int, chapters: [BookChapter]) -> Int {
        if chapters.indices.contains(requested), !chapters[requested].isVolume { return requested }
        return chapters.firstIndex(where: { !$0.isVolume }) ?? 0
    }
}
