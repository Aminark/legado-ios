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

    public func pruneIfNeeded() throws {
        let maximumTotalBytes = maximumTotalBytes ?? ApplicationSettingsStore.shared.settings.chapterCacheMB * 1024 * 1024
        var files = try cacheFiles().sorted { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        while total > maximumTotalBytes, let oldest = files.first {
            try FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            files.removeFirst()
        }
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

public actor ChapterContentCoordinator {
    private let loader: any ChapterContentLoading
    private let cache: ChapterContentCache

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
        if !forceRefresh, let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
                  cached.sourceID == nil || cached.sourceID == source.id {
            return .init(report: .init(
                title: cached.title,
                content: cached.content,
                supplementalContent: cached.supplementalContent
            ), loadedFromCache: true)
        }
        let report = await loader.loadContent(
            book: book,
            chapter: chapter,
            source: source,
            nextChapterURL: nextChapterURL,
            maxPages: maxPages
        )
        await saveContent(report, book: book, chapter: chapter, source: source)
        return .init(report: report, loadedFromCache: false)
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
        if let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
           cached.sourceID == nil || cached.sourceID == source.id { return false }
        let result = await load(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL)
        return !Task.isCancelled && !result.report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.report.diagnostics.contains(where: { $0.severity == .error })
    }

    public func invalidate(bookURL: String) async {
        try? await cache.remove(bookURL: bookURL)
    }
}
