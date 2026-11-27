import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import LegadoCore

struct PortableLibraryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func archive(_ files: [String: String], in root: URL) throws -> AndroidLibraryImport {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let zip = try Archive(url: url, accessMode: .create)
        for (path, text) in files {
            let data = Data(text.utf8)
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { start, length in
                data.subdata(in: Int(start)..<min(Int(start) + length, data.count))
            }
        }
        return try AndroidLibraryImport(url: url)
    }

    @Test(arguments: ["", "backup/"]) func selectedImportPreservesLocalChoices(prefix: String) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LegadoDatabase(url: root.appendingPathComponent("db"))
        var current = Book(bookUrl: "book", name: "本机书名", origin: "web")
        current.durChapterTime = 100
        current.durChapterIndex = 5
        try await db.replaceBooks([current])
        let data = try archive([
            prefix + "bookshelf.json": #"[{"bookUrl":"book","origin":"web","name":"旧版","durChapterIndex":4,"durChapterTime":50},{"bookUrl":"new","origin":"web","name":"新增","durChapterIndex":2,"durChapterPos":17}]"#,
            prefix + "bookSource.json": #"[{"bookSourceUrl":"source","bookSourceName":"源"}]"#,
            prefix + "replaceRule.json": #"[{"id":8,"name":"移除页尾","pattern":"（完）"}]"#,
            prefix + "config.xml": #"<map><boolean name="enableReadRecord" value="false"/><boolean name="unsupported" value="true"/></map>"#
        ], in: root)
        #expect(data.preferences == ["enableReadRecord": false])
        let legacy = root.appendingPathComponent("rules.json")
        try await db.restoreLibrary(data, sections: [.rules, .books], legacyRulesURL: legacy)
        try await db.restoreLibrary(data, sections: [.rules, .books], legacyRulesURL: legacy)
        let books = try await db.loadBooks()
        #expect(books.count == 2)
        #expect(books.first == current)
        #expect(books.last?.durChapterPos == 17)
        #expect(try await db.loadBookSources().isEmpty)
        #expect(try await db.storedRules(legacyURL: legacy).map(\.id) == [8])
    }

    @Test func lateImportFailureRollsBackBooksAndSources() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LegadoDatabase(url: root.appendingPathComponent("db"))
        let old = Book(bookUrl: "old", name: "旧书")
        try await db.replaceBooks([old])
        let data = try archive(["bookshelf.json": #"[{"bookUrl":"new","name":"新书","origin":"web"}]"#,
                                "bookSource.json": #"[{"bookSourceUrl":"source","bookSourceName":"源"}]"#,
                                "replaceRule.json": #"[{"id":1,"name":"净化","pattern":"x"}]"#], in: root)
        let broken = root.appendingPathComponent("legacy.json")
        try Data("broken".utf8).write(to: broken)
        await #expect(throws: DecodingError.self) {
            try await db.restoreLibrary(data, sections: [.books, .sources, .rules], legacyRulesURL: broken)
        }
        #expect(try await db.loadBooks() == [old])
        #expect(try await db.loadBookSources().isEmpty)
    }

    @Test func rejectsAmbiguousArchiveRoots() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CocoaError.self) {
            try archive(["bookshelf.json": "[]", "backup/bookshelf.json": "[]"], in: root)
        }
    }

    @Test func searchesAvailableBooksWithLiteralQueriesAndReaderOffsets() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"))
        let index = try LibraryPassageSearch(cache: cache)
        let localURL = root.appendingPathComponent("甲.txt")
        try Data("第一章 前言\n😀山海之间%_实录。".utf8).write(to: localURL)
        let imported = try LocalBookService().importFile(at: localURL, into: root.appendingPathComponent("local"))
        try await index.collect(book: imported.book, chapters: imported.chapters, rules: [])
        let book = Book(bookUrl: "net", name: "乙", origin: "src")
        let chapter = BookChapter(url: "p1", title: "开始", bookUrl: book.id, index: 0)
        let raw = "😀一起走过山海之间%_的路。"
        try await cache.save(.init(bookURL: book.id, chapterURL: chapter.url, content: raw, sourceID: book.origin))
        try await index.collect(book: book, chapters: [chapter], rules: [])
        for needle in ["山", "之间", "山海之", "%_"] {
            let hits = try await index.matches(needle)
            #expect(Set(hits.map(\.bookID)) == [imported.book.id, book.id])
            let rendered = ContentSanitizer().process(book: book, chapter: chapter, content: raw, rules: []).content
            #expect(hits.last?.position == (rendered as NSString).range(of: needle).location)
        }
        try await cache.save(.init(bookURL: book.id, chapterURL: chapter.url, content: "清风又见清风", sourceID: book.origin))
        let edited = try LibraryPassageSearch(cache: cache)
        try await edited.collect(book: book, chapters: [chapter], rules: [])
        try await edited.collect(book: book, chapters: [chapter], rules: [])
        let repeated = try await edited.matches("清风")
        #expect(repeated.count == 2)
        #expect(Set(repeated.map(\.id)).count == 2)
        let first = try #require(repeated.first)
        let last = try #require(repeated.last)
        #expect(last.position - first.position == 4)
        #expect(try await edited.matches("山海之").isEmpty)
        try await cache.removeAll()
        let next = try LibraryPassageSearch(cache: cache)
        try await next.collect(book: book, chapters: [chapter], rules: [])
        #expect(try await next.matches("山").isEmpty)
    }

    @Test func resumesAfterRestartAndRetriesOnlyFailedPages() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OfflineEditionFiles(root: root.appendingPathComponent("editions"))
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"), offlineFiles: files)
        let source = BookSource(bookSourceUrl: "src", bookSourceName: "test")
        let book = Book(bookUrl: "book", name: "离线", origin: source.id)
        let chapters = (0..<4).map { BookChapter(url: "p\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        var volume = chapters[0]
        volume.isVolume = true
        let loader = OfflineTestLoader()
        let coordinator = ChapterContentCoordinator(loader: loader, cache: cache)
        let queue = OfflineEditions(files: files, coordinator: coordinator)
        try await queue.enqueue(book: book, chapters: [volume] + chapters.dropFirst(), source: source)
        let first = try await completion(queue)
        #expect(first.failed == 1 && first.saved == 2)
        try await cache.removeAll()
        #expect(try await cache.load(bookURL: book.id, chapterURL: "p1")?.content == "正文 p1")
        let reopened = OfflineEditions(files: files, coordinator: coordinator)
        try await reopened.activate(sources: [source])
        try await reopened.resume(book.id)
        let second = try await completion(reopened)
        #expect(second.saved == 3 && second.failed == 0)
        #expect(await loader.calls == ["p1", "p2", "p3", "p2"])
        try await reopened.remove(book.id)
        #expect(try files.content(book: book.id, chapter: "p1") == nil)
    }

    @Test func interruptedBatchRecoversChaptersWrittenBeforeCheckpoint() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OfflineEditionFiles(root: root.appendingPathComponent("editions"))
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"), offlineFiles: files)
        let source = BookSource(bookSourceUrl: "src", bookSourceName: "test")
        let book = Book(bookUrl: "book", name: "断点", origin: source.id)
        let chapters = (0..<2).map { BookChapter(url: "p\($0)", title: "第\($0)章", bookUrl: book.id, index: $0) }
        let gate = InterruptedLoader()
        let queue = OfflineEditions(files: files, coordinator: .init(loader: gate, cache: cache))
        try await queue.enqueue(book: book, chapters: chapters, source: source)
        for _ in 0..<500 {
            if await gate.waiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Snapshot precisely while chapter two is in flight and the first batch
        // has not checkpointed. Reopen the snapshot with an empty transient cache.
        let stopped = OfflineEditionFiles(root: root.appendingPathComponent("snapshot"))
        do {
            try #require(await gate.waiting)
            try FileManager.default.copyItem(at: files.root, to: stopped.root)
            try await queue.pause(book.id)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        let freshCache = ChapterContentCache(directory: root.appendingPathComponent("fresh-cache"), offlineFiles: stopped)
        let loader = OfflineTestLoader()
        let restored = OfflineEditions(files: stopped, coordinator: .init(loader: loader, cache: freshCache))
        try await restored.activate(sources: [source])
        #expect(try await completion(restored).saved == 2)
        #expect(await loader.calls == ["p1"])
    }

    private func completion(_ queue: OfflineEditions) async throws -> OfflineEditionProgress {
        for _ in 0..<500 {
            if let value = await queue.progress.first, value.state == .finished { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }
}

private actor OfflineTestLoader: ChapterContentLoading {
    var calls: [String] = []
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        let fail = chapter.url == "p2" && !calls.contains(chapter.url)
        calls.append(chapter.url)
        return .init(content: fail ? "" : "正文 " + chapter.url)
    }
}

private actor InterruptedLoader: ChapterContentLoading {
    private var suspended: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { suspended != nil }

    func release() {
        released = true
        suspended?.resume()
        suspended = nil
    }

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        if chapter.url == "p1", !released { await withCheckedContinuation { suspended = $0 } }
        return .init(content: "正文 " + chapter.url)
    }
}
