import CryptoKit
import Foundation

public struct CachedChapterContent: Codable, Equatable, Sendable {
    public var bookURL: String
    public var chapterURL: String
    public var title: String?
    public var content: String
    public var supplementalContent: String?
    public var savedAt: Int64
    public var sourceID: String?

    public init(
        bookURL: String,
        chapterURL: String,
        title: String? = nil,
        content: String,
        supplementalContent: String? = nil,
        savedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        sourceID: String? = nil
    ) {
        self.bookURL = bookURL
        self.chapterURL = chapterURL
        self.title = title
        self.content = content
        self.supplementalContent = supplementalContent
        self.savedAt = savedAt
        self.sourceID = sourceID
    }
}

public enum ChapterContentCacheError: Error, LocalizedError, Equatable {
    case entryTooLarge(Int)
    case invalidEntry

    public var errorDescription: String? {
        switch self {
        case .entryTooLarge(let maximum): "章节正文超过缓存上限 \(maximum / 1_024 / 1_024) MB"
        case .invalidEntry: "章节缓存内容无效"
        }
    }
}

public actor ChapterContentCache {
    public static let maximumEntryBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumTotalBytes = 256 * 1_024 * 1_024

    private let directory: URL
    private let maximumTotalBytes: Int?

    public init(directory: URL, maximumTotalBytes: Int? = nil) {
        self.directory = directory
        self.maximumTotalBytes = maximumTotalBytes.map { max($0, Self.maximumEntryBytes) }
    }

    public static func live() -> ChapterContentCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Chapters", isDirectory: true)
        return ChapterContentCache(directory: base)
    }

    public func load(bookURL: String, chapterURL: String) throws -> CachedChapterContent? {
        let url = fileURL(bookURL: bookURL, chapterURL: chapterURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            guard value.bookURL == bookURL, value.chapterURL == chapterURL, !value.content.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                throw ChapterContentCacheError.invalidEntry
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return value
        } catch let error as ChapterContentCacheError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    public func save(_ entry: CachedChapterContent) throws {
        guard !entry.bookURL.isEmpty, !entry.chapterURL.isEmpty, !entry.content.isEmpty else {
            throw ChapterContentCacheError.invalidEntry
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        guard data.count <= Self.maximumEntryBytes else {
            throw ChapterContentCacheError.entryTooLarge(Self.maximumEntryBytes)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL), options: .atomic)
        try pruneIfNeeded()
    }

    public func remove(bookURL: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let prefix = digest(bookURL) + "-"
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func remove(bookURL: String, chapterURL: String) throws {
        let url = fileURL(bookURL: bookURL, chapterURL: chapterURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func statistics() throws -> (entries: Int, bytes: Int) {
        let files = try cacheFiles()
        return (files.count, files.reduce(0) { $0 + $1.size })
    }

    public func cachedChapterURLs(bookURL: String, among chapters: [BookChapter]) throws -> Set<String> {
        let digests = try cachedChapterDigests(bookURL: bookURL)
        guard !digests.isEmpty else { return [] }
        return Set(chapters.compactMap { chapter in
            guard !chapter.url.isEmpty, digests.contains(digest(chapter.url)) else { return nil }
            return chapter.url
        })
    }

    public func pruneIfNeeded() throws {
        let maximumTotalBytes = maximumTotalBytes ?? ApplicationSettingsStore.shared.settings.chapterCacheMB * 1024 * 1024
        var files = try cacheFiles()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maximumTotalBytes else { return }
        files.sort { $0.modified < $1.modified }
        for oldest in files {
            guard total > maximumTotalBytes else { break }
            try FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    private func cachedChapterDigests(bookURL: String) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = digest(bookURL) + "-"
        var result: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            guard url.pathExtension == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            result.insert(String(name.dropFirst(prefix.count)))
        }
        return result
    }

    private func cacheFiles() throws -> [(url: URL, size: Int, modified: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func fileURL(bookURL: String, chapterURL: String) -> URL {
        directory.appendingPathComponent("\(digest(bookURL))-\(digest(chapterURL)).json")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol ChapterContentLoading: Sendable {
    func loadContent(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String?,
        maxPages: Int
    ) async -> ChapterContentReport
}

extension NetworkBookService: ChapterContentLoading {}

public struct ChapterCacheJob: Sendable, Equatable {
    public var chapter: BookChapter
    public var nextChapterURL: String?

    public init(chapter: BookChapter, nextChapterURL: String?) {
        self.chapter = chapter
        self.nextChapterURL = nextChapterURL
    }
}

public enum ChapterCachePlanner {
    public static func plan(chapters: [BookChapter], startIndex: Int, limit: Int? = nil) -> [ChapterCacheJob] {
        guard !chapters.isEmpty, limit.map({ $0 > 0 }) ?? true else { return [] }
        let start = min(max(startIndex, 0), chapters.count - 1)
        var jobs: [ChapterCacheJob] = []
        for index in chapters.indices where index >= start && !chapters[index].isVolume {
            let nextURL = chapters[(index + 1)...].first(where: { !$0.isVolume })?.url
            jobs.append(.init(chapter: chapters[index], nextChapterURL: nextURL))
            if let limit, jobs.count >= limit { break }
        }
        return jobs
    }
}

public struct CoordinatedChapterContent: Sendable {
    public var report: ChapterContentReport
    public var loadedFromCache: Bool

    public init(report: ChapterContentReport, loadedFromCache: Bool) {
        self.report = report
        self.loadedFromCache = loadedFromCache
    }
}

public enum ChapterPrefetchResult: Sendable, Equatable {
    case cached
    case downloaded
    case failed(String)

    public var isAvailable: Bool {
        switch self {
        case .cached, .downloaded: true
        case .failed: false
        }
    }
}

public actor ChapterContentCoordinator {
    private let loader: any ChapterContentLoading
    private let cache: ChapterContentCache
    private struct RequestKey: Hashable {
        let book: String
        let chapter: String
        let source: String
        let next: String?
        let maxPages: Int
        let generation: Int
    }
    private struct Download: Sendable {
        let report: ChapterContentReport
        var cacheError: String? = nil
    }
    private var requests: [RequestKey: (id: UUID, task: Task<Download, Never>)] = [:]
    private var requestGenerations: [String: Int] = [:]

    public init(loader: any ChapterContentLoading = NetworkBookService(), cache: ChapterContentCache = .live()) {
        self.loader = loader
        self.cache = cache
    }

    public func load(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil,
        maxPages: Int = 20,
        forceRefresh: Bool = false
    ) async -> CoordinatedChapterContent {
        if forceRefresh { cancelRequests(bookURL: book.bookUrl) }
        if !forceRefresh, let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
                  cached.sourceID == nil || cached.sourceID == source.id {
            return .init(report: .init(
                title: cached.title,
                content: cached.content,
                supplementalContent: cached.supplementalContent
            ), loadedFromCache: true)
        }
        let download = await download(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL, maxPages: maxPages)
        return .init(report: download.report, loadedFromCache: false)
    }

    private func download(book: Book, chapter: BookChapter, source: BookSource,
                          nextChapterURL: String?, maxPages: Int) async -> Download {
        let generation = requestGenerations[book.bookUrl, default: 0]
        let key = RequestKey(book: book.bookUrl, chapter: chapter.url, source: source.id,
                             next: nextChapterURL, maxPages: maxPages, generation: generation)
        let request: (id: UUID, task: Task<Download, Never>)
        if let existing = requests[key] { request = existing }
        else {
            let task = Task { [loader, cache] in
                let report = await loader.loadContent(book: book, chapter: chapter, source: source,
                                                      nextChapterURL: nextChapterURL, maxPages: maxPages)
                guard !Task.isCancelled, requestGenerations[book.bookUrl, default: 0] == generation else {
                    return Download(report: .init(diagnostics: [.init(severity: .error, code: "content.cancelled",
                        message: "章节请求已取消", rule: chapter.url)]))
                }
                guard !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !report.diagnostics.contains(where: { $0.severity == .error }) else { return Download(report: report) }
                do {
                    try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapter.url, title: report.title,
                        content: report.content, supplementalContent: report.supplementalContent, sourceID: source.id))
                    return Download(report: report)
                } catch { return Download(report: report, cacheError: error.localizedDescription) }
            }
            request = (UUID(), task)
            requests[key] = request
        }
        let result = await request.task.value
        if requests[key]?.id == request.id { requests[key] = nil }
        return result
    }

    private func cancelRequests(bookURL: String) {
        requestGenerations[bookURL, default: 0] &+= 1
        for (key, request) in requests where key.book == bookURL {
            request.task.cancel()
            requests[key] = nil
        }
    }

    public func saveContent(_ report: ChapterContentReport, book: Book, chapter: BookChapter, source: BookSource) async {
        if !Task.isCancelled, !report.diagnostics.contains(where: { $0.severity == .error }),
           !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await cache.save(.init(
                bookURL: book.bookUrl,
                chapterURL: chapter.url,
                title: report.title,
                content: report.content,
                supplementalContent: report.supplementalContent,
                sourceID: source.id
            ))
        }
    }

    public func saveEditedContent(book: Book, chapter: BookChapter, title: String?, content: String) async throws {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ChapterContentCacheError.invalidEntry }
        try await cache.save(.init(
            bookURL: book.bookUrl,
            chapterURL: chapter.url,
            title: title,
            content: content,
            sourceID: book.origin
        ))
    }

    @discardableResult
    public func prefetch(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil
    ) async -> Bool {
        await prefetchResult(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL) == .downloaded
    }

    public func prefetchResult(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil
    ) async -> ChapterPrefetchResult {
        guard !Task.isCancelled else { return .failed("缓存已停止") }
        if let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
           cached.sourceID == nil || cached.sourceID == source.id { return .cached }
        let result = await download(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL, maxPages: 20)
        let report = result.report
        guard !Task.isCancelled else { return .failed("缓存已停止") }
        if let error = report.diagnostics.first(where: { $0.severity == .error }) {
            return .failed(error.message)
        }
        guard !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("书源未返回正文")
        }
        if let error = result.cacheError { return .failed(error) }
        return .downloaded
    }

    public func invalidate(bookURL: String) async {
        cancelRequests(bookURL: bookURL)
        try? await cache.remove(bookURL: bookURL)
    }

    public func cachedChapterURLs(bookURL: String, among chapters: [BookChapter]) async -> Set<String> {
        (try? await cache.cachedChapterURLs(bookURL: bookURL, among: chapters)) ?? []
    }
}
