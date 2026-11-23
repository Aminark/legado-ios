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

/// Identifies one cached revision without reading the filesystem from a UI action.
public struct ChapterContentStamp: Sendable {
    fileprivate let file: URL
    fileprivate let value: UUID
}

public actor ChapterContentCache {
    public static let maximumEntryBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumTotalBytes = 256 * 1_024 * 1_024

    // NSCache synchronizes access. Only the cache actor creates or invalidates stamps.
    private final class Versions: @unchecked Sendable {
        let values = NSCache<NSURL, NSUUID>()
        init() { values.countLimit = 128 }
    }
    private nonisolated let versions = Versions()

    public nonisolated func isCurrent(_ stamp: ChapterContentStamp) -> Bool {
        (versions.values.object(forKey: stamp.file as NSURL) as UUID?) == stamp.value
    }

    private func stamp(for file: URL) -> ChapterContentStamp {
        let key = file as NSURL
        let value = versions.values.object(forKey: key) ?? NSUUID()
        versions.values.setObject(value, forKey: key)
        return .init(file: file, value: value as UUID)
    }

    fileprivate func stampedContent(bookURL: String, chapterURL: String) throws -> (CachedChapterContent, ChapterContentStamp)? {
        guard let entry = try load(bookURL: bookURL, chapterURL: chapterURL) else { return nil }
        return (entry, stamp(for: fileURL(bookURL: bookURL, chapterURL: chapterURL)))
    }

    fileprivate func storeAndStamp(_ entry: CachedChapterContent) throws -> ChapterContentStamp? {
        try save(entry)
        let file = fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL)
        return FileManager.default.fileExists(atPath: file.path) ? stamp(for: file) : nil
    }

    private let directory: URL
    private let maximumTotalBytes: Int?
    private let legacyDirectory: URL?
    private var storageReady = false

    private final class MemoryEntry: NSObject {
        let value: CachedChapterContent
        init(_ value: CachedChapterContent) { self.value = value }
    }

    // Only the application's shared owner tracks writes. Independent stores
    // may be opened on the same directory by importers and tests.
    private let recent: NSCache<NSURL, MemoryEntry>?
    private var sizeUpperBound: Int?
    private struct AvailabilityObserver {
        let sourceID: String
        let continuation: AsyncStream<Bool>.Continuation
    }
    private var observers: [URL: [UUID: AvailabilityObserver]] = [:]

    public init(directory: URL, maximumTotalBytes: Int? = nil) {
        self.directory = directory
        self.maximumTotalBytes = maximumTotalBytes.map { max($0, Self.maximumEntryBytes) }
        recent = nil
        legacyDirectory = nil
    }

    init(liveDirectory: URL, legacyDirectory: URL) {
        directory = liveDirectory
        self.legacyDirectory = legacyDirectory
        maximumTotalBytes = nil
        let entries = NSCache<NSURL, MemoryEntry>()
        entries.countLimit = 32
        entries.totalCostLimit = 4 * 1_024 * 1_024
        recent = entries
    }

    private static let shared = ChapterContentCache(
        liveDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/ChapterContent", isDirectory: true),
        legacyDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Chapters", isDirectory: true)
    )

    public static func live() -> ChapterContentCache { shared }

    private func prepareStorage() throws {
        guard !storageReady, let legacyDirectory else { return }
        let files = FileManager.default
        try files.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: legacyDirectory.path) {
            if !files.fileExists(atPath: directory.path) {
                try files.moveItem(at: legacyDirectory, to: directory)
            } else {
                // A downgrade or interrupted migration can leave both stores on disk.
                for old in try files.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil) {
                    let target = directory.appendingPathComponent(old.lastPathComponent)
                    if !files.fileExists(atPath: target.path) {
                        try files.moveItem(at: old, to: target)
                    } else if old.pathExtension == "json" {
                        let oldData = try Data(contentsOf: old)
                        let currentData = try Data(contentsOf: target)
                        let decoder = JSONDecoder()
                        let current = try? decoder.decode(CachedChapterContent.self, from: currentData)
                        if let previous = try? decoder.decode(CachedChapterContent.self, from: oldData),
                           !previous.content.isEmpty, previous.savedAt > (current?.savedAt ?? .min) {
                            try oldData.write(to: target, options: .atomic)
                        }
                    }
                }
                try files.removeItem(at: legacyDirectory)
            }
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var url = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try url.setResourceValues(attributes)
        storageReady = true
    }

    public func load(bookURL: String, chapterURL: String) throws -> CachedChapterContent? {
        try read(bookURL: bookURL, chapterURL: chapterURL, markUsed: true)
    }

    /// Observing a directory row must not make its chapter more recent for eviction.
    public func availability(bookURL: String, chapterURL: String, sourceID: String) -> AsyncStream<Bool> {
        let url = fileURL(bookURL: bookURL, chapterURL: chapterURL)
        let id = UUID()
        let entry = try? read(bookURL: bookURL, chapterURL: chapterURL, markUsed: false)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[url, default: [:]][id] = AvailabilityObserver(sourceID: sourceID, continuation: continuation)
            continuation.yield(entry.map { $0.sourceID == nil || $0.sourceID == sourceID } ?? false)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.endObservation(url: url, id: id) }
            }
        }
    }

    private func endObservation(url: URL, id: UUID) {
        observers[url]?[id] = nil
        if observers[url]?.isEmpty == true { observers[url] = nil }
    }

    private func notify(_ url: URL, entry: CachedChapterContent? = nil) {
        versions.values.removeObject(forKey: url as NSURL)
        guard let observers = observers[url] else { return }
        for observer in observers.values {
            observer.continuation.yield(entry.map { $0.sourceID == nil || $0.sourceID == observer.sourceID } ?? false)
        }
    }

    private func read(bookURL: String, chapterURL: String, markUsed: Bool) throws -> CachedChapterContent? {
        try prepareStorage()
        let url = fileURL(bookURL: bookURL, chapterURL: chapterURL)
        if let entry = recent?.object(forKey: url as NSURL) {
            if !markUsed, FileManager.default.fileExists(atPath: url.path) { return entry.value }
            do {
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                return entry.value
            } catch {
                recent?.removeObject(forKey: url as NSURL)
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            versions.values.removeObject(forKey: url as NSURL)
            return nil
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let value = try JSONDecoder().decode(CachedChapterContent.self, from: data)
            guard value.bookURL == bookURL, value.chapterURL == chapterURL, !value.content.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                notify(url)
                throw ChapterContentCacheError.invalidEntry
            }
            if markUsed { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
            recent?.setObject(MemoryEntry(value), forKey: url as NSURL, cost: data.count)
            return value
        } catch let error as ChapterContentCacheError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            notify(url)
            return nil
        }
    }

    public func save(_ entry: CachedChapterContent) throws {
        try write(entry)
        if let sizeUpperBound, recent != nil, sizeUpperBound <= byteLimit { return }
        try pruneIfNeeded()
    }

    private func write(_ entry: CachedChapterContent) throws {
        try prepareStorage()
        guard !entry.bookURL.isEmpty, !entry.chapterURL.isEmpty, !entry.content.isEmpty else {
            throw ChapterContentCacheError.invalidEntry
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        guard data.count <= Self.maximumEntryBytes else {
            throw ChapterContentCacheError.entryTooLarge(Self.maximumEntryBytes)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL)
        try data.write(to: url, options: .atomic)
        recent?.setObject(MemoryEntry(entry), forKey: url as NSURL, cost: data.count)
        notify(url, entry: entry)
        // Counting the full size of replacements can only overestimate usage.
        if let sizeUpperBound { self.sizeUpperBound = sizeUpperBound + data.count }
    }

    public func remove(bookURL: String) throws {
        try prepareStorage()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let prefix = digest(bookURL) + "-"
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: url)
            recent?.removeObject(forKey: url as NSURL)
            notify(url)
        }
    }

    /// Copy before removing an obsolete book identity. URL matches are exact;
    /// title matches are allowed only when unique in both chapter lists.
    @discardableResult
    public func copyContents(
        from oldBook: Book, chapters oldChapters: [BookChapter],
        to newBook: Book, chapters newChapters: [BookChapter]
    ) throws -> Int {
        guard oldBook.bookUrl != newBook.bookUrl else { return 0 }
        let oldByURL = Dictionary(oldChapters.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let oldByTitle = Dictionary(grouping: oldChapters.filter { !$0.isVolume }, by: \.title)
        let newByTitle = Dictionary(grouping: newChapters.filter { !$0.isVolume }, by: \.title)
        var copied = 0
        for chapter in newChapters where !chapter.isVolume {
            try Task.checkCancellation()
            let sameTitle = oldByTitle[chapter.title]
            let old = oldByURL[chapter.url] ?? (
                !chapter.title.isEmpty && sameTitle?.count == 1 && newByTitle[chapter.title]?.count == 1
                    ? sameTitle?.first : nil
            )
            guard let old, let cached = try load(bookURL: oldBook.bookUrl, chapterURL: old.url) else { continue }
            guard cached.sourceID == nil || cached.sourceID == oldBook.origin else { continue }
            var updated = cached
            updated.bookURL = newBook.bookUrl
            updated.chapterURL = chapter.url
            updated.sourceID = newBook.origin
            // Copying must not evict the old identity before the caller has
            // committed its book/directory transaction successfully.
            try write(updated)
            copied += 1
        }
        return copied
    }

    public func remove(bookURL: String, chapterURL: String) throws {
        try prepareStorage()
        let url = fileURL(bookURL: bookURL, chapterURL: chapterURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        recent?.removeObject(forKey: url as NSURL)
        notify(url)
    }

    public func removeAll() throws {
        try prepareStorage()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        recent?.removeAllObjects()
        versions.values.removeAllObjects()
        for url in observers.keys { notify(url) }
        sizeUpperBound = 0
        storageReady = false
    }

    public func statistics() throws -> (entries: Int, bytes: Int) {
        let files = try cacheFiles()
        return (files.count, files.reduce(0) { $0 + $1.size })
    }

    private var byteLimit: Int {
        maximumTotalBytes ?? ApplicationSettingsStore.shared.settings.chapterCacheMB * 1024 * 1024
    }

    public func pruneIfNeeded() throws {
        let limit = byteLimit
        let files = try cacheFiles()
        var total = files.reduce(0) { $0 + $1.size }
        if total > limit {
            for oldest in files.sorted(by: { $0.modified < $1.modified }) {
                try FileManager.default.removeItem(at: oldest.url)
                recent?.removeObject(forKey: oldest.url as NSURL)
                notify(oldest.url)
                total -= oldest.size
                if total <= limit { break }
            }
        }
        sizeUpperBound = total
    }

    private func cacheFiles() throws -> [(url: URL, size: Int, modified: Date)] {
        try prepareStorage()
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
        for index in start..<chapters.count where !chapters[index].isVolume {
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

    public var stamp: ChapterContentStamp?

    public init(report: ChapterContentReport, loadedFromCache: Bool, stamp: ChapterContentStamp? = nil) {
        self.stamp = stamp
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

    public func cachedContent(book: Book, chapter: BookChapter, source: BookSource) async -> CoordinatedChapterContent? {
        guard let (cached, stamp) = try? await cache.stampedContent(bookURL: book.bookUrl, chapterURL: chapter.url),
              cached.sourceID == nil || cached.sourceID == source.id else { return nil }
        // Older releases stored text subContent separately. Keep those downloads readable offline.
        let textSupplement = source.bookSourceType == 0 ? cached.supplementalContent : nil
        let content = [cached.content, textSupplement].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return .init(report: .init(
            title: cached.title,
            content: content,
            supplementalContent: source.bookSourceType == 0 ? nil : cached.supplementalContent
        ), loadedFromCache: true, stamp: stamp)
    }

    public func load(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil,
        maxPages: Int = 20,
        forceRefresh: Bool = false
    ) async -> CoordinatedChapterContent {
        if !forceRefresh, let cached = await cachedContent(book: book, chapter: chapter, source: source) {
            return cached
        }
        guard !Task.isCancelled else { return .init(report: .init(), loadedFromCache: false) }
        let report = await loader.loadContent(
            book: book,
            chapter: chapter,
            source: source,
            nextChapterURL: nextChapterURL,
            maxPages: maxPages
        )
        let stamp = await saveContent(report, book: book, chapter: chapter, source: source)
        return .init(report: report, loadedFromCache: false, stamp: stamp)
    }

    @discardableResult
    public func saveContent(_ report: ChapterContentReport, book: Book, chapter: BookChapter, source: BookSource) async -> ChapterContentStamp? {
        if !Task.isCancelled, !report.diagnostics.contains(where: { $0.severity == .error }),
           !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try? await cache.storeAndStamp(.init(
                bookURL: book.bookUrl,
                chapterURL: chapter.url,
                title: report.title,
                content: report.content,
                supplementalContent: report.supplementalContent,
                sourceID: source.id
            ))
        }
        return nil
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
        let result = await load(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL)
        return !result.loadedFromCache && !Task.isCancelled && !result.report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.report.diagnostics.contains(where: { $0.severity == .error })
    }

    public func copyContents(from oldBook: Book, chapters oldChapters: [BookChapter],
                             to newBook: Book, chapters newChapters: [BookChapter]) async {
        _ = try? await cache.copyContents(from: oldBook, chapters: oldChapters, to: newBook, chapters: newChapters)
    }

    public func invalidate(bookURL: String) async {
        try? await cache.remove(bookURL: bookURL)
    }
}
