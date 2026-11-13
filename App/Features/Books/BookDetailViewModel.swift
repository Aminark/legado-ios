import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookDetailViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, findingSource, ready, failed }
    typealias SourceSwitchCommit = @MainActor (BookSourceSwitchReport) async -> Bool
    typealias PreparedUpdateCommit = @MainActor (BookUpdateReport) async -> Bool

    @Published private(set) var state: State = .idle
    @Published private(set) var book: Book
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var isCaching = false
    @Published private(set) var cacheCompleted = 0
    @Published private(set) var cacheTotal = 0

    @Published private(set) var source: BookSource
    private var searchBook: SearchBook?
    private let service: NetworkBookService
    private let updateCoordinator: BookUpdateCoordinator
    private let contentCoordinator: ChapterContentCoordinator
    private let sourceSwitchService: BookSourceSwitchService
    private var cacheTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(
        searchBook: SearchBook,
        source: BookSource,
        service: NetworkBookService = .init(),
        chapterRepository: any BookChapterRepository = AppBookChapterRepository.live(),
        sourceSwitchService: BookSourceSwitchService? = nil
    ) {
        self.searchBook = searchBook
        self.source = source
        self.service = service
        let chapters = chapterRepository
        updateCoordinator = BookUpdateCoordinator(repository: chapters, loader: service)
        contentCoordinator = ChapterContentCoordinator(loader: service)
        self.sourceSwitchService = sourceSwitchService ?? BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service
        )
        var book = Book(
            bookUrl: searchBook.bookURL,
            name: searchBook.name,
            author: searchBook.author,
            origin: source.bookSourceUrl
        )
        book.originName = source.bookSourceName
        book.coverUrl = searchBook.coverURL
        book.intro = searchBook.intro
        book.kind = searchBook.kind
        self.book = book
    }

    init(book: Book, source: BookSource, service: NetworkBookService = .init()) {
        searchBook = nil
        self.book = book
        self.source = source
        self.service = service
        let chapters = AppBookChapterRepository.live()
        updateCoordinator = BookUpdateCoordinator(repository: chapters, loader: service)
        contentCoordinator = ChapterContentCoordinator(loader: service)
        sourceSwitchService = BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service
        )
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        searchBook = nil
        book = demoBook
        self.source = source
        service = .init()
        updateCoordinator = .init()
        contentCoordinator = .init()
        sourceSwitchService = .init()
        self.chapters = chapters
        state = .ready
        isCaching = true
        cacheCompleted = 2
        cacheTotal = chapters.filter { !$0.isVolume }.count
    }

    func load(sources: [BookSource] = [], persistDirectory: Bool = true, runPreUpdateScript: Bool? = nil,
              commitSourceSwitch: SourceSwitchCommit? = nil, commitPreparedUpdate: PreparedUpdateCommit? = nil) async {
        guard state == .idle else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        if searchBook == nil {
            let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
            guard acceptsLoad(generation) else { return }
            if !stored.isEmpty {
                chapters = stored
                state = .ready
            }
        }
        if let searchBook {
            let detail = await service.loadDetail(searchBook: searchBook, source: source)
            guard acceptsLoad(generation) else { return }
            let details = detail.book
            book.name = details.name
            book.author = details.author
            book.originName = details.originName
            if !details.tocUrl.isEmpty { book.tocUrl = details.tocUrl }
            book.type = details.type
            book.kind = details.kind ?? book.kind
            book.coverUrl = details.coverUrl ?? book.coverUrl
            book.intro = details.intro ?? book.intro
            book.charset = details.charset ?? book.charset
            book.wordCount = details.wordCount ?? book.wordCount
            book.latestChapterTitle = details.latestChapterTitle ?? book.latestChapterTitle
            book.originOrder = details.originOrder
            book.variable = details.variable ?? book.variable
            diagnostics += detail.diagnostics
        }
        let oldBookURL = book.bookUrl
        let toc = await updateCoordinator.refresh(book: book, source: source, persistDirectory: persistDirectory,
                                                  runPreUpdateScript: runPreUpdateScript ?? (searchBook == nil), isFromBookInfo: searchBook != nil)
        guard acceptsLoad(generation) else { return }
        if toc.refreshed, toc.book.bookUrl != oldBookURL, let commitPreparedUpdate,
           !(await commitPreparedUpdate(toc)) {
            diagnostics += toc.diagnostics
            diagnostics.append(.init(severity: .error, code: "toc.persistence",
                message: "更新后的书籍地址保存失败，已保留原书籍和阅读位置。", rule: oldBookURL))
            state = chapters.isEmpty ? .failed : .ready
            return
        }
        guard acceptsLoad(generation) else { return }
        if !toc.chapters.isEmpty { chapters = toc.chapters }
        diagnostics += toc.diagnostics
        book = toc.book
        if book.bookUrl != oldBookURL { searchBook = nil }
        if !chapters.isEmpty {
            state = .ready
            return
        }

        state = .findingSource
        if let available = await sourceSwitchService.firstAvailableSource(for: book, sources: sources) {
            guard acceptsLoad(generation) else { return }
            if let commitSourceSwitch, !(await commitSourceSwitch(available.report)) {
                diagnostics.append(.init(severity: .error, code: "source_switch.persistence",
                    message: "自动换源保存失败，已保留当前书源和阅读位置。", rule: book.bookUrl))
                state = .failed
                return
            }
            applySourceSwitch(available.report, source: available.source)
        } else {
            guard acceptsLoad(generation) else { return }
            state = .failed
        }
    }

    private func acceptsLoad(_ generation: Int) -> Bool {
        guard generation == loadGeneration else { return false }
        guard !Task.isCancelled else { state = .idle; return false }
        return true
    }

    func cacheNextTen() { startCaching(limit: 10) }

    func cacheRemaining() { startCaching(limit: nil) }

    func cancelCaching() {
        cacheTask?.cancel()
        cacheTask = nil
        isCaching = false
    }

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) {
        loadGeneration &+= 1
        cancelCaching()
        searchBook = nil
        book = report.book
        chapters = report.chapters
        diagnostics = report.diagnostics
        self.source = source
        state = .ready
    }

    func toggleCanUpdate() { book.canUpdate.toggle() }

    func reportDirectorySaveFailure(_ message: String?) {
        diagnostics.append(.init(severity: .error, code: "toc.persistence",
            message: message ?? "目录保存失败，已保留原有缓存。", rule: book.bookUrl))
    }

    func restoreLibraryBook(from stored: Book, sources: [BookSource] = []) {
        guard state == .idle, stored.bookUrl == book.bookUrl else { return }
        if stored.origin != source.id,
           let resolved = sources.first(where: { $0.id == stored.origin }) {
            source = resolved
            searchBook = nil
        }
        book = stored
        book.origin = source.id
        book.originName = source.bookSourceName
    }

    func restoreSourceAfterReading(from books: [Book], sources: [BookSource]) {
        guard state == .ready,
              let stored = books.first(where: { $0.bookUrl == book.bookUrl })
                ?? books.first(where: { $0.name == book.name && $0.author == book.author }),
              stored.bookUrl != book.bookUrl || stored.origin != book.origin,
              let source = sources.first(where: { $0.id == stored.origin }) else { return }
        book = stored
        self.source = source
        searchBook = nil
        chapters = []
        diagnostics = []
        state = .idle
    }

    func restoreUserSettings(from stored: Book) {
        guard stored.bookUrl == book.bookUrl else { return }
        book.group = stored.group
        book.order = stored.order
        book.customTag = stored.customTag
        book.customCoverUrl = stored.customCoverUrl
        book.customIntro = stored.customIntro
        book.canUpdate = stored.canUpdate
        book.readConfig = stored.readConfig
        book.syncTime = stored.syncTime
    }

    func restoreReadingProgress(from stored: Book) {
        guard stored.bookUrl == book.bookUrl, stored.durChapterTime > book.durChapterTime else { return }
        let chapterIndex = stored.durChapterTitle.flatMap { title in
            let position = min(max(stored.durChapterIndex, 0), max(chapters.count - 1, 0))
            return chapters.indices.filter { !chapters[$0].isVolume && chapters[$0].title == title }
                .min { abs($0 - position) < abs($1 - position) }
        } ?? stored.durChapterIndex
        guard chapters.indices.contains(chapterIndex), !chapters[chapterIndex].isVolume else { return }
        book.durChapterIndex = chapterIndex
        book.durChapterTitle = chapters[chapterIndex].title
        book.durChapterPos = stored.durChapterPos
        book.durChapterTime = stored.durChapterTime
    }

    func refresh(sources: [BookSource] = [], persistDirectory: Bool = true,
                 commitSourceSwitch: SourceSwitchCommit? = nil, commitPreparedUpdate: PreparedUpdateCommit? = nil) async {
        cancelCaching()
        chapters = []
        diagnostics = []
        state = .idle
        await load(sources: sources, persistDirectory: persistDirectory, runPreUpdateScript: true,
                   commitSourceSwitch: commitSourceSwitch, commitPreparedUpdate: commitPreparedUpdate)
    }

    private func startCaching(limit: Int?) {
        cancelCaching()
        let start = min(max(book.durChapterIndex, 0), max(chapters.count - 1, 0))
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: start, limit: limit)
        guard !jobs.isEmpty else { return }

        isCaching = true
        cacheCompleted = 0
        cacheTotal = jobs.count
        let coordinator = contentCoordinator
        let currentBook = book
        let currentSource = source
        cacheTask = Task { [weak self] in
            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return false }
                        return await coordinator.prefetch(
                            book: currentBook,
                            chapter: job.chapter,
                            source: currentSource,
                            nextChapterURL: job.nextChapterURL
                        )
                    }
                }
                for _ in 0..<min(3, jobs.count) { enqueue() }
                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    self?.cacheCompleted += 1
                    enqueue()
                }
            }
            guard !Task.isCancelled else { return }
            self?.isCaching = false
            self?.cacheTask = nil
        }
    }
}
