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

        let match = ChapterProgressMatcher.match(current: current, chapters: chapters)
        let resolvedIndex = match.index
        migrated.durChapterPos = match.matched ? max(current.durChapterPos, 0) : 0
        migrated.durChapterIndex = resolvedIndex
        migrated.durChapterTitle = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : nil
        migrated.durChapterTime = current.durChapterTime
        return .init(book: migrated, chapters: chapters, exactChapterMatch: match.matched)
    }
}

/// Android BookHelp.getDurChapter: compare names and chapter numbers near the old
/// position, then keep the old index. A ratio alone can skip unread chapters when
/// one source has more recent updates than another.
private enum ChapterProgressMatcher {
    private static let numerals = #"\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟"#
    private static let numbered = try! NSRegularExpression(pattern: ".*?第([\(numerals)]+)[章节篇回集话]")
    private static let prefixed = try! NSRegularExpression(pattern: "^(?:[\(numerals)]+[,:、])*([\(numerals)]+)(?:[,:、]|\\.[^\\d])")

    static func match(current: Book, chapters: [BookChapter]) -> (index: Int, matched: Bool) {
        guard !chapters.isEmpty else { return (0, false) }
        let oldIndex = max(current.durChapterIndex, 0)
        let fallback = min(oldIndex, chapters.count - 1)
        let oldTitle = normalized(current.durChapterTitle ?? "")
        let readable = chapters.indices.filter { !chapters[$0].isVolume }
        // Retain the iOS exact-title match, choosing the closest occurrence for
        // repeated names such as 番外 instead of silently jumping to the first.
        let exact = readable.filter { !oldTitle.isEmpty && normalized(chapters[$0].title) == oldTitle }
        if let index = nearest(exact, to: fallback) { return (index, true) }
        guard oldIndex > 0 else { return (fallback, false) }

        // Use the original search window, with bounded arithmetic for imported
        // metadata; malformed chapter counts must not overflow or trap.
        let scaled = current.totalChapterNum > 0
            ? Double(oldIndex) * Double(current.totalChapterNum) / Double(chapters.count)
            : Double(oldIndex)
        let lower = Int(min(Double(chapters.count - 1), max(0, min(Double(oldIndex), scaled) - 10)))
        let upper = Int(min(Double(chapters.count - 1), max(Double(oldIndex), scaled) + 10))
        let candidates = readable.filter { $0 >= lower && $0 <= upper }
        let oldName = pureName(current.durChapterTitle ?? "")
        if !oldName.isEmpty {
            let matches = candidates.filter { similarity(oldName, pureName(chapters[$0].title)) > 0.96 }
            if let index = nearest(matches, to: fallback) { return (index, true) }
        }
        if let number = chapterNumber(current.durChapterTitle ?? ""), number > 0 {
            let matches = candidates.filter { chapterNumber(chapters[$0].title) == number }
            if let index = nearest(matches, to: fallback) { return (index, true) }
        }
        return (fallback, false)
    }

    private static func nearest(_ indices: [Int], to index: Int) -> Int? {
        indices.min { abs($0 - index) < abs($1 - index) }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
            .replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
    }

    private static func normalized(_ value: String) -> String {
        String(folded(value).unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }).lowercased()
    }

    private static func pureName(_ value: String) -> String {
        folded(value)
            .replacingOccurrences(of: "^.*?第[\(numerals)]+[章节篇回集话](?!$)|^(?:[\(numerals)]+[,:、])*[\(numerals)]+(?:[,:、](?!$)|\\.(?=[^\\d]))", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?!^)(?:[〖【《〔\[{(][^〖【《〔\[{()〕》】〗\]}]+)?[)〕》】〗\]}]$|^[〖【《〔\[{(](?:[^〖【《〔\[{()〕》】〗\]}]+[〕》】〗\]})])?(?!$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^A-Za-z0-9_\p{Han}]"#, with: "", options: .regularExpression)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(lhs.utf16), b = Set(rhs.utf16)
        let total = a.union(b).count
        return total == 0 ? 0 : Double(a.intersection(b).count) / Double(total)
    }

    private static func chapterNumber(_ title: String) -> Int? {
        let title = folded(title)
        let range = NSRange(title.startIndex..., in: title)
        guard let match = numbered.firstMatch(in: title, range: range) ?? prefixed.firstMatch(in: title, range: range),
              let captured = Range(match.range(at: 1), in: title) else { return nil }
        let value = String(title[captured])
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "两": 2, "贰": 2,
                                      "三": 3, "叁": 3, "四": 4, "肆": 4, "五": 5, "伍": 5, "六": 6,
                                      "陆": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9]
        let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10_000]
        var total = 0, pending = 0
        let characters = Array(value)
        for (index, character) in characters.enumerated() {
            if let digit = digits[character] ?? (units[character] == nil ? character.wholeNumberValue : nil) {
                if index >= 2, index == characters.count - 1, let previous = units[characters[index - 1]], previous > 10 {
                    pending = digit * (previous / 10)
                } else {
                    let (multiplied, overflow) = pending.multipliedReportingOverflow(by: 10)
                    let (sum, sumOverflow) = multiplied.addingReportingOverflow(digit)
                    guard !overflow, !sumOverflow else { return nil }
                    pending = sum
                }
            } else if let unit = units[character] {
                if unit == 10_000 {
                    let (sum, overflow) = total.addingReportingOverflow(pending)
                    let (product, productOverflow) = sum.multipliedReportingOverflow(by: unit)
                    guard !overflow, !productOverflow else { return nil }
                    total = product
                } else {
                    let (product, overflow) = max(pending, 1).multipliedReportingOverflow(by: unit)
                    let (sum, sumOverflow) = total.addingReportingOverflow(product)
                    guard !overflow, !sumOverflow else { return nil }
                    total = sum
                }
                pending = 0
            } else { return nil }
        }
        let (result, overflow) = total.addingReportingOverflow(pending)
        return overflow ? nil : result
    }
}

public actor BookSourceSwitchService {
    private let searcher: any BookSourceSearching
    private let detailLoader: any BookDetailLoading
    private let chapterLoader: any ChapterListLoading
    private let contentLoader: any ChapterContentLoading
    private let mapper: BookSourceProgressMapper

    public init(
        searcher: any BookSourceSearching = BookSearchService(),
        detailLoader: any BookDetailLoading = NetworkBookService(),
        chapterLoader: any ChapterListLoading = NetworkBookService(),
        contentLoader: any ChapterContentLoading = NetworkBookService(),
        mapper: BookSourceProgressMapper = .init()
    ) {
        self.searcher = searcher
        self.detailLoader = detailLoader
        self.chapterLoader = chapterLoader
        self.contentLoader = contentLoader
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
        var replacement = detail.book
        replacement.readConfig = current.readConfig
        let toc = await chapterLoader.loadChapters(book: replacement, source: source, maxPages: 20)
        guard !Task.isCancelled, toc.chapters.contains(where: { !$0.isVolume }),
              !toc.diagnostics.contains(where: { $0.severity == .error }) else { return nil }
        var result = mapper.migrate(
            current: current,
            replacement: replacement,
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
        // Preparation is read-only. The caller commits chapters and shelf state
        // together after selection, including when both sources share a URL.
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
