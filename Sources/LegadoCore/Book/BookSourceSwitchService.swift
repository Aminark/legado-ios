import Foundation

public protocol BookSourceSearching: Sendable {
    func search(keyword: String, page: Int, sources: [BookSource]) async -> BookSearchReport
    func searchStream(keyword: String, sources: [BookSource]) -> AsyncStream<SourceSearchOutcome>
}

extension BookSourceSearching {
    public func searchStream(keyword: String, sources: [BookSource]) -> AsyncStream<SourceSearchOutcome> {
        AsyncStream { continuation in
            let task = Task {
                let report = await search(keyword: keyword, page: 1, sources: sources)
                for outcome in report.outcomes {
                    guard !Task.isCancelled else { break }
                    continuation.yield(outcome)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension BookSearchService: BookSourceSearching {
    public func searchStream(keyword: String, sources: [BookSource]) -> AsyncStream<SourceSearchOutcome> {
        searchOutcomes(keyword: keyword, sources: sources)
    }
}

public protocol BookDetailLoading: Sendable {
    func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport
}

extension NetworkBookService: BookDetailLoading {}

public struct BookSourceCandidate: Identifiable, Sendable, Equatable {
    public var book: SearchBook
    public var score: Int
    public var id: String { book.origin + "|" + book.bookURL }

    public init(book: SearchBook, score: Int) {
        self.book = book
        self.score = score
    }
}

public struct BookSourceSwitchReport: Sendable {
    public var book: Book
    public var chapters: [BookChapter]
    public var diagnostics: [RuleDiagnostic]
    public var exactChapterMatch: Bool
    public var verifiedContent: ChapterContentReport?

    public init(book: Book, chapters: [BookChapter], diagnostics: [RuleDiagnostic] = [], exactChapterMatch: Bool, verifiedContent: ChapterContentReport? = nil) {
        self.book = book
        self.chapters = chapters
        self.diagnostics = diagnostics
        self.exactChapterMatch = exactChapterMatch
        self.verifiedContent = verifiedContent
    }
}

public struct AvailableBookSource: Sendable {
    public var report: BookSourceSwitchReport
    public var source: BookSource

    public init(report: BookSourceSwitchReport, source: BookSource) {
        self.report = report
        self.source = source
    }
}

public struct BookSourceProgressMapper: Sendable {
    public init() {}

    public func migrate(current: Book, replacement: Book, chapters: [BookChapter], now: Int64) -> BookSourceSwitchReport {
        var migrated = replacement
        migrated.customTag = current.customTag
        migrated.customCoverUrl = current.customCoverUrl
        migrated.customIntro = current.customIntro
        migrated.group = current.group
        migrated.order = current.order
        migrated.canUpdate = current.canUpdate
        migrated.readConfig = current.readConfig
        migrated.syncTime = current.syncTime
        migrated.lastCheckCount = 0
        migrated.lastCheckTime = now
        migrated.latestChapterTime = now
        migrated.totalChapterNum = chapters.count
        migrated.latestChapterTitle = chapters.last(where: { !$0.isVolume })?.title ?? chapters.last?.title

        let oldTitle = current.durChapterTitle ?? ""
        let normalizedOldTitle = normalize(oldTitle)
        let exactIndex = chapters.firstIndex { chapter in
            chapter.title == oldTitle || (!normalizedOldTitle.isEmpty && normalize(chapter.title) == normalizedOldTitle)
        }
        let resolvedIndex: Int
        if let exactIndex {
            resolvedIndex = exactIndex
            migrated.durChapterPos = current.durChapterPos
        } else if !chapters.isEmpty {
            let denominator = max(current.totalChapterNum - 1, 1)
            let progress = min(max(Double(current.durChapterIndex) / Double(denominator), 0), 1)
            resolvedIndex = min(Int((progress * Double(max(chapters.count - 1, 0))).rounded()), chapters.count - 1)
            migrated.durChapterPos = 0
        } else {
            resolvedIndex = 0
            migrated.durChapterPos = 0
        }
        migrated.durChapterIndex = resolvedIndex
        migrated.durChapterTitle = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : nil
        migrated.durChapterTime = current.durChapterTime
        return .init(book: migrated, chapters: chapters, exactChapterMatch: exactIndex != nil)
    }

    private func normalize(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }).lowercased()
    }
}

public actor BookSourceSwitchService {
    private let searcher: any BookSourceSearching
    private let detailLoader: any BookDetailLoading
    private let chapterLoader: any ChapterListLoading
    private let contentLoader: any ChapterContentLoading
    private let chapterRepository: any BookChapterRepository
    private let mapper: BookSourceProgressMapper

    public init(
        searcher: any BookSourceSearching = BookSearchService(),
        detailLoader: any BookDetailLoading = NetworkBookService(),
        chapterLoader: any ChapterListLoading = NetworkBookService(),
        contentLoader: any ChapterContentLoading = NetworkBookService(),
        chapterRepository: any BookChapterRepository = FileBookChapterRepository.live(),
        mapper: BookSourceProgressMapper = .init()
    ) {
        self.searcher = searcher
        self.detailLoader = detailLoader
        self.chapterLoader = chapterLoader
        self.contentLoader = contentLoader
        self.chapterRepository = chapterRepository
        self.mapper = mapper
    }

    public func candidates(for book: Book, sources: [BookSource]) async -> [BookSourceCandidate] {
        var result: [BookSourceCandidate] = []
        for await update in candidateUpdates(for: book, sources: sources) {
            guard !Task.isCancelled else { return result }
            result = update
        }
        return result
    }

    public func candidateUpdates(for book: Book, sources: [BookSource]) -> AsyncStream<[BookSourceCandidate]> {
        let eligible = sources.enumerated()
            .filter { $0.element.enabled && $0.element.bookSourceUrl != book.origin && $0.element.searchUrl?.isEmpty == false }
            .sorted {
                if $0.element.customOrder != $1.element.customOrder { return $0.element.customOrder < $1.element.customOrder }
                return $0.offset < $1.offset
            }
            .map(\.element)
        guard !eligible.isEmpty else { return AsyncStream { $0.finish() } }
        let eligibleIDs = Set(eligible.map(\.id))
        let searcher = self.searcher
        return AsyncStream { continuation in
            let task = Task {
                var found: [String: SearchBook] = [:]
                for await outcome in searcher.searchStream(keyword: book.name, sources: eligible) {
                    guard !Task.isCancelled else { break }
                    for candidate in outcome.books where eligibleIDs.contains(candidate.origin) {
                        found[BookSourceCandidate(book: candidate, score: 0).id] = candidate
                    }
                    continuation.yield(Self.ranked(Array(found.values), for: book))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func ranked(_ books: [SearchBook], for book: Book) -> [BookSourceCandidate] {
        let normalizedName = normalize(book.name)
        let normalizedAuthor = normalizeAuthor(book.author)
        return books.compactMap { candidate in
            guard normalize(candidate.name) == normalizedName else { return nil }
            let author = normalizeAuthor(candidate.author)
            var score = 100
            if !normalizedAuthor.isEmpty && author == normalizedAuthor { score += 80 }
            if candidate.latestChapterTitle?.isEmpty == false { score += 10 }
            score -= max(candidate.originOrder, 0)
            return BookSourceCandidate(book: candidate, score: score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.book.originName.localizedStandardCompare($1.book.originName) == .orderedAscending
        }
    }

    public func prepareSwitch(
        current: Book,
        candidate: SearchBook,
        source: BookSource,
        now: Int64? = nil
    ) async -> BookSourceSwitchReport? {
        guard !Task.isCancelled else { return nil }
        let detail = await detailLoader.loadDetail(searchBook: candidate, source: source)
        guard !Task.isCancelled else { return nil }
        let toc = await chapterLoader.loadChapters(book: detail.book, source: source, maxPages: 20)
        guard !Task.isCancelled, toc.chapters.contains(where: { !$0.isVolume }),
              !toc.diagnostics.contains(where: { $0.severity == .error }) else { return nil }
        var result = mapper.migrate(
            current: current,
            replacement: detail.book,
            chapters: toc.chapters,
            now: now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        )
        result.diagnostics = detail.diagnostics + toc.diagnostics
        let readableIndex = result.chapters.indices.dropFirst(result.book.durChapterIndex)
            .first(where: { !result.chapters[$0].isVolume })
            ?? result.chapters.indices.last(where: { !result.chapters[$0].isVolume })
        guard let readableIndex else { return nil }
        if readableIndex != result.book.durChapterIndex {
            result.book.durChapterIndex = readableIndex
            result.book.durChapterTitle = result.chapters[readableIndex].title
            result.book.durChapterPos = 0
        }
        let chapter = result.chapters[readableIndex]
        let nextURL = result.chapters.dropFirst(readableIndex + 1).first(where: { !$0.isVolume })?.url
        let content = await contentLoader.loadContent(
            book: result.book, chapter: chapter, source: source,
            nextChapterURL: nextURL, maxPages: 20
        )
        guard !Task.isCancelled,
              !content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.diagnostics.contains(where: { $0.severity == .error }) else { return nil }
        result.verifiedContent = content
        result.diagnostics += content.diagnostics
        do {
            try await chapterRepository.save(result.chapters, bookURL: result.book.bookUrl)
        } catch {
            result.diagnostics.append(.init(
                severity: .error,
                code: "source_switch.persistence",
                message: "换源目录保存失败：\(error.localizedDescription)",
                rule: result.book.bookUrl
            ))
        }
        return result
    }

    public func firstAvailableSource(
        for book: Book,
        sources: [BookSource],
        now: Int64? = nil
    ) async -> AvailableBookSource? {
        var tried = Set<String>()
        for await update in candidateUpdates(for: book, sources: sources) {
            for candidate in update where tried.insert(candidate.id).inserted {
                guard !Task.isCancelled else { return nil }
                guard let source = sources.first(where: { $0.bookSourceUrl == candidate.book.origin }) else { continue }
                if let report = await prepareSwitch(
                    current: book,
                    candidate: candidate.book,
                    source: source,
                    now: now
                ) {
                    return .init(report: report, source: source)
                }
            }
        }
        return nil
    }

    private nonisolated static func normalize(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }).lowercased()
    }

    private nonisolated static func normalizeAuthor(_ value: String) -> String {
        normalize(value.replacingOccurrences(of: "作者", with: "").replacingOccurrences(of: "著", with: ""))
    }
}
