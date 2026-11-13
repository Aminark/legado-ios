import Foundation

public protocol ChapterListLoading: Sendable {
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport
}

extension NetworkBookService: ChapterListLoading {}

public protocol BookUpdatePreparing: Sendable {
    func prepareUpdate(book: Book, source: BookSource, runPreUpdateScript: Bool, isFromBookInfo: Bool) async -> BookDetailReport
}

extension NetworkBookService: BookUpdatePreparing {}

public struct BookUpdateReport: Sendable {
    public var book: Book
    public var chapters: [BookChapter]
    public var addedChapterCount: Int
    public var diagnostics: [RuleDiagnostic]
    public var refreshed: Bool

    public init(
        book: Book,
        chapters: [BookChapter],
        addedChapterCount: Int,
        diagnostics: [RuleDiagnostic] = [],
        refreshed: Bool = true
    ) {
        self.book = book
        self.chapters = chapters
        self.addedChapterCount = addedChapterCount
        self.diagnostics = diagnostics
        self.refreshed = refreshed
    }
}

public struct BookUpdateMerger: Sendable {
    public init() {}

    /// Apply prepared metadata only where the shelf has not been edited since
    /// the request started. Reading progress is always taken from the shelf.
    public func applyingPreparation(original: Book, current: Book, prepared: Book) -> Book {
        var merged = current
        func apply<Value: Equatable>(_ path: WritableKeyPath<Book, Value>) {
            if current[keyPath: path] == original[keyPath: path] { merged[keyPath: path] = prepared[keyPath: path] }
        }
        apply(\.bookUrl); apply(\.tocUrl); apply(\.origin); apply(\.originName)
        apply(\.name); apply(\.author); apply(\.kind); apply(\.customTag)
        apply(\.coverUrl); apply(\.customCoverUrl); apply(\.intro); apply(\.customIntro)
        apply(\.charset); apply(\.type); apply(\.group); apply(\.wordCount)
        apply(\.canUpdate); apply(\.order); apply(\.originOrder); apply(\.variable)
        apply(\.readConfig); apply(\.syncTime)
        return merged
    }

    public func merge(book: Book, oldChapters: [BookChapter], newChapters: [BookChapter], now: Int64) -> BookUpdateReport {
        guard !newChapters.isEmpty else {
            return .init(book: book, chapters: oldChapters, addedChapterCount: 0, refreshed: false)
        }
        var normalized = newChapters
        let metadata = Dictionary(oldChapters.map {
            ("\($0.index)\u{0}\($0.title)", ($0.wordCount, $0.variable, $0.imageURL))
        }, uniquingKeysWith: { _, latest in latest })
        for index in normalized.indices {
            normalized[index].index = index
            normalized[index].bookUrl = book.bookUrl
            if let old = metadata["\(index)\u{0}\(normalized[index].title)"] {
                if let wordCount = old.0 { normalized[index].wordCount = wordCount }
                if let variable = old.1 { normalized[index].variable = variable }
                if let imageURL = old.2 { normalized[index].imageURL = imageURL }
            }
        }

        var updated = book
        let previousTotal = max(book.totalChapterNum, oldChapters.count)
        let added = max(normalized.count - previousTotal, 0)
        if added > 0 {
            updated.lastCheckCount = added
            updated.latestChapterTime = now
        }
        updated.lastCheckTime = now
        updated.totalChapterNum = normalized.count
        updated.latestChapterTitle = normalized.last(where: { !$0.isVolume })?.title ?? normalized.last?.title
        let newReadIndex = resolveReadIndex(book: book, chapters: normalized)
        updated.durChapterIndex = newReadIndex
        if let oldTitle = book.durChapterTitle, !oldTitle.isEmpty,
           normalized.indices.contains(newReadIndex),
           normalize(normalized[newReadIndex].title) != normalize(oldTitle) {
            updated.durChapterPos = 0
        }
        updated.durChapterTitle = normalized.indices.contains(newReadIndex) ? normalized[newReadIndex].title : updated.durChapterTitle
        return .init(book: updated, chapters: normalized, addedChapterCount: added)
    }

    private func resolveReadIndex(book: Book, chapters: [BookChapter]) -> Int {
        let previousIndex = min(max(book.durChapterIndex, 0), max(chapters.count - 1, 0))
        if let title = book.durChapterTitle, !title.isEmpty {
            // Repeated titles (for example “正文” or “番外”) must not move a
            // reader back to the first occurrence on every shelf refresh.
            let exact = chapters.indices.filter { chapters[$0].title == title }
            if let nearest = exact.min(by: { abs($0 - previousIndex) < abs($1 - previousIndex) }) { return nearest }
            let normalizedTitle = normalize(title)
            let close = chapters.indices.filter { normalize(chapters[$0].title) == normalizedTitle }
            if let nearest = close.min(by: { abs($0 - previousIndex) < abs($1 - previousIndex) }) { return nearest }
        }
        return previousIndex
    }

    private func normalize(_ title: String) -> String {
        String(title.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }).lowercased()
    }
}

public actor BookUpdateCoordinator {
    private let repository: any BookChapterRepository
    private let loader: any ChapterListLoading
    private let merger: BookUpdateMerger

    public init(
        repository: any BookChapterRepository = FileBookChapterRepository.live(),
        loader: any ChapterListLoading = NetworkBookService(),
        merger: BookUpdateMerger = .init()
    ) {
        self.repository = repository
        self.loader = loader
        self.merger = merger
    }

    public func storedChapters(bookURL: String) async -> [BookChapter] {
        (try? await repository.load(bookURL: bookURL)) ?? []
    }

    public func refresh(
        book: Book, source: BookSource, now: Int64? = nil, maxPages: Int = 20,
        persistDirectory: Bool = true, runPreUpdateScript: Bool = true, isFromBookInfo: Bool = false
    ) async -> BookUpdateReport {
        let old = (try? await repository.load(bookURL: book.bookUrl)) ?? []
        let prepared: BookDetailReport
        if let preparer = loader as? any BookUpdatePreparing {
            prepared = await preparer.prepareUpdate(book: book, source: source,
                                                   runPreUpdateScript: runPreUpdateScript, isFromBookInfo: isFromBookInfo)
        } else { prepared = .init(book: book) }
        guard !Task.isCancelled, !prepared.diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(book: book, chapters: old, addedChapterCount: 0, diagnostics: prepared.diagnostics, refreshed: false)
        }
        let loaded = await loader.loadChapters(book: prepared.book, source: source, maxPages: maxPages)
        let diagnostics = prepared.diagnostics + loaded.diagnostics
        guard !Task.isCancelled, !loaded.chapters.isEmpty,
              !loaded.diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(
                book: book,
                chapters: old,
                addedChapterCount: 0,
                diagnostics: diagnostics,
                refreshed: false
            )
        }
        var result = merger.merge(
            book: prepared.book,
            oldChapters: old,
            newChapters: loaded.chapters,
            now: now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        )
        result.diagnostics = diagnostics
        guard persistDirectory else { return result }
        do {
            try await repository.save(result.chapters, bookURL: result.book.bookUrl)
        } catch {
            result.diagnostics.append(.init(
                severity: .error,
                code: "toc.persistence",
                message: "目录保存失败：\(error.localizedDescription)",
                rule: book.bookUrl
            ))
            return .init(
                book: book,
                chapters: old,
                addedChapterCount: 0,
                diagnostics: result.diagnostics,
                refreshed: false
            )
        }
        return result
    }
}
