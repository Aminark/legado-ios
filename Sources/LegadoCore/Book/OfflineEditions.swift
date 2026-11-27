import CryptoKit
import Foundation

/// Each edition has an immutable chapter list, a small checkpoint, and independently replaceable chapters.
/// Writing a chapter before advancing its checkpoint makes interrupted batches safe to replay.
public struct OfflineEditionFiles: Sendable {
    let root: URL
    public init(root: URL) { self.root = root }
    public static let live = Self(root: LegadoDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("OfflineBooks"))
    func folder(_ book: String) -> URL { root.appendingPathComponent(Self.key(book), isDirectory: true) }
    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func page(_ book: String, _ chapter: String) -> URL { folder(book).appendingPathComponent(Self.key(chapter) + ".page") }

    func content(book: String, chapter: String) throws -> CachedChapterContent? {
        let file = page(book, chapter)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: file))
        guard value.bookURL == book, value.chapterURL == chapter, !value.content.isEmpty else {
            throw ChapterContentCacheError.invalidEntry
        }
        return value
    }

    func save(_ entry: CachedChapterContent) throws {
        let bytes = try JSONEncoder().encode(entry)
        guard bytes.count <= ChapterContentCache.maximumEntryBytes else {
            throw ChapterContentCacheError.entryTooLarge(ChapterContentCache.maximumEntryBytes)
        }
        try bytes.write(to: page(entry.bookURL, entry.chapterURL), options: .atomic)
    }
}

public struct OfflineEditionProgress: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let total: Int
    public let saved: Int
    public let failed: Int
    public let state: OfflineEditions.State
    public let message: String?
}

public actor OfflineEditions {
    public enum State: String, Codable, Sendable { case waiting, paused, finished }

    private struct Catalogue: Codable {
        let book: Book
        let chapters: [BookChapter]
    }
    private struct Checkpoint: Codable {
        var cursor = 0
        var failures: [Int: String] = [:]
        var retry: [Int] = []
        var state: State = .waiting
        var message: String?
    }
    private struct Edition {
        let catalogue: Catalogue
        var checkpoint: Checkpoint
        var generation = UUID()
    }

    public static let shared = OfflineEditions(files: .live)
    private let files: OfflineEditionFiles
    private let coordinator: ChapterContentCoordinator
    private var entries: [String: Edition] = [:]
    private var sources: [String: BookSource] = [:]
    private var opened = false
    private var worker: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<[OfflineEditionProgress]>.Continuation] = [:]

    public init(files: OfflineEditionFiles, coordinator: ChapterContentCoordinator = .init()) {
        self.files = files
        self.coordinator = coordinator
    }

    private func open() throws {
        guard !opened else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: files.root, withIntermediateDirectories: true)
        var folder = files.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        var loaded: [String: Edition] = [:]
        for url in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let manifest = url.appendingPathComponent("catalogue.json")
            guard manager.fileExists(atPath: manifest.path) else { continue }
            let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: manifest))
            let checkpointURL = url.appendingPathComponent("checkpoint.json")
            let checkpoint = manager.fileExists(atPath: checkpointURL.path)
                ? try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL)) : Checkpoint()
            guard files.folder(catalogue.book.id).lastPathComponent == url.lastPathComponent,
                  (0...catalogue.chapters.count).contains(checkpoint.cursor),
                  checkpoint.retry.allSatisfy(catalogue.chapters.indices.contains) else { throw CocoaError(.fileReadCorruptFile) }
            loaded[catalogue.book.id] = Edition(catalogue: catalogue, checkpoint: checkpoint)
        }
        entries = loaded
        opened = true
    }

    public func activate(sources available: [BookSource]) throws {
        try open()
        sources = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        startWorker()
    }

    public func enqueue(book: Book, chapters: [BookChapter], source: BookSource) throws {
        try open()
        guard book.origin == source.id, book.origin != "local", source.bookSourceType == 0 else { throw CocoaError(.featureUnsupported) }
        sources[source.id] = source
        if entries[book.id] != nil { try resume(book.id); return }
        var seen = Set<String>()
        let readable = chapters.filter { !$0.isVolume && !$0.url.isEmpty && seen.insert($0.url).inserted }
        guard !readable.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let catalogue = Catalogue(book: book, chapters: readable)
        let folder = files.folder(book.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalogue).write(to: folder.appendingPathComponent("catalogue.json"), options: .atomic)
        entries[book.id] = Edition(catalogue: catalogue, checkpoint: .init())
        publish()
        startWorker()
    }

    public func pause(_ id: String) throws {
        guard var entry = entries[id] else { return }
        entry.generation = UUID()
        entry.checkpoint.state = .paused
        try commit(entry)
    }

    public func resume(_ id: String) throws {
        guard var entry = entries[id] else { return }
        if entry.checkpoint.state == .waiting { startWorker(); return }
        entry.generation = UUID()
        entry.checkpoint.state = .waiting
        entry.checkpoint.message = nil
        entry.checkpoint.retry = entry.checkpoint.failures.keys.sorted(by: >)
        try commit(entry)
        startWorker()
    }

    public func remove(_ id: String) throws {
        guard entries[id] != nil else { return }
        try FileManager.default.removeItem(at: files.folder(id))
        entries[id] = nil
        publish()
    }

    public func observe() throws -> AsyncStream<[OfflineEditionProgress]> {
        try open()
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            listeners[key] = stream
            stream.yield(progress)
            stream.onTermination = { [weak self] _ in Task { await self?.unsubscribe(key) } }
        }
    }

    private func unsubscribe(_ id: UUID) { listeners[id] = nil }

    public var progress: [OfflineEditionProgress] {
        entries.values.map { entry in
            let state = entry.checkpoint
            return .init(id: entry.catalogue.book.id, title: entry.catalogue.book.name, total: entry.catalogue.chapters.count,
                         saved: state.cursor - state.failures.count, failed: state.failures.count, state: state.state,
                         message: state.message ?? state.failures.min(by: { $0.key < $1.key })?.value)
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    private func publish() { for stream in listeners.values { stream.yield(progress) } }

    private func commit(_ entry: Edition) throws {
        let id = entry.catalogue.book.id
        try JSONEncoder().encode(entry.checkpoint).write(to: files.folder(id).appendingPathComponent("checkpoint.json"), options: .atomic)
        entries[id] = entry
        publish()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        defer { worker = nil }
        while let id = entries.keys.sorted().first(where: { entries[$0]?.checkpoint.state == .waiting }),
              var entry = entries[id] {
            let book = entry.catalogue.book
            do {
                guard let source = sources[book.origin], source.enabled else {
                    entry.checkpoint.state = .paused
                    entry.checkpoint.message = "启用原书源后可继续下载"
                    try commit(entry)
                    continue
                }
                // Bound each batch. An interrupted batch reuses its already written pages.
                for _ in 0..<12 {
                    let index = entry.checkpoint.retry.popLast() ?? entry.checkpoint.cursor
                    guard entry.catalogue.chapters.indices.contains(index) else {
                        entry.checkpoint.state = .finished
                        break
                    }
                    let chapter = entry.catalogue.chapters[index]
                    let chapters = entry.catalogue.chapters
                    if (try? files.content(book: id, chapter: chapter.url))?.sourceID != source.id {
                        let next = index + 1 < chapters.count ? chapters[index + 1].url : nil
                        let result = await coordinator.load(book: book, chapter: chapter, source: source, nextChapterURL: next)
                        guard entries[id]?.generation == entry.generation else { break }
                        let report = result.report
                        if let failure = report.diagnostics.first(where: { $0.severity == .error }) {
                            entry.checkpoint.failures[index] = failure.message
                        } else if report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            entry.checkpoint.failures[index] = "本章正文为空"
                        } else {
                            try files.save(.init(bookURL: id, chapterURL: chapter.url, title: report.title, content: report.content,
                                                 supplementalContent: report.supplementalContent, sourceID: source.id))
                            entry.checkpoint.failures[index] = nil
                        }
                    } else { entry.checkpoint.failures[index] = nil }
                    entry.checkpoint.cursor = max(entry.checkpoint.cursor, index + 1)
                    entries[id] = entry
                    publish()
                }
                if entries[id]?.generation == entry.generation { try commit(entry) }
            } catch {
                guard var previous = entries[id], previous.generation == entry.generation else { continue }
                previous.checkpoint.state = .paused
                previous.checkpoint.message = error.localizedDescription
                entries[id] = previous
                try? commit(previous)
                publish()
            }
            await Task.yield()
        }
    }
}
