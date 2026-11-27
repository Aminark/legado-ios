import Foundation
import SQLite3

/// One search session owns a temporary SQLite database. Closing the screen drops
/// the text together with its index, including material from evicted chapters.
public actor LibraryPassageSearch {
    public struct Hit: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            let row: Int64
            let offset: Int
        }
        public let id: ID
        public let bookID: String
        public let chapterOffset: Int
        public let title: String
        public let excerpt: String
        public let position: Int
    }
    private struct Location {
        let book: String
        let offset: Int
        let title: String
    }
    nonisolated(unsafe) private let db: OpaquePointer
    private let indexed: Bool
    private let cache: ChapterContentCache
    private var locations: [Location] = []
    private var directories: [String: [BookChapter]] = [:]

    public init(cache: ChapterContentCache = .live()) throws {
        var handle: OpaquePointer?
        guard sqlite3_open("", &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CocoaError(.fileWriteUnknown)
        }
        self.db = handle
        self.cache = cache
        // A search session is rebuilt from its sources. Its disposable index does
        // not need to flush a rollback journal to disk for every chapter.
        sqlite3_exec(handle, "PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF", nil, nil, nil)
        // Some older system SQLite builds omit the trigram tokenizer.
        indexed = sqlite3_exec(handle, "CREATE VIRTUAL TABLE passages USING fts5(body, tokenize='trigram')", nil, nil, nil) == SQLITE_OK
        if !indexed, sqlite3_exec(handle, "CREATE TABLE passages(body TEXT NOT NULL)", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { sqlite3_close(db) }

    public func chapters(for book: String) -> [BookChapter] { directories[book] ?? [] }

    public func collect(book: Book, chapters: [BookChapter], rules: [ReplaceRule]) async throws {
        guard directories[book.id] == nil else { return }
        directories[book.id] = chapters
        let local = LocalBookService.live()
        let url = URL(string: book.bookUrl)
        let epub = try book.origin == "local" && url?.isFileURL == true && url?.pathExtension.lowercased() == "epub"
            ? url.map { try EPUBBook(url: $0) } : nil
        let textSession = try epub == nil && book.origin == "local" ? local.openTextSession(for: book) : nil
        let applicable = book.readConfig?.useReplaceRule == false ? [] : ContentSanitizer.applicableRules(rules, for: book)
        let sanitizer = ContentSanitizer()
        var batch: [(offset: Int, title: String, body: String)] = []
        batch.reserveCapacity(min(chapters.count, 128))
        for (offset, chapter) in chapters.enumerated() where !chapter.isVolume {
            try Task.checkCancellation()
            let report: ChapterContentReport
            if let epub { report = try epub.content(chapter: chapter) }
            else if let textSession { report = try textSession.loadContent(chapter: chapter) }
            else if book.origin == "local" { report = try local.loadContent(book: book, chapter: chapter) }
            else {
                guard let entry = try await cache.searchContent(bookURL: book.id, chapterURL: chapter.url),
                      entry.sourceID == nil || entry.sourceID == book.origin else { continue }
                let text = [entry.content, entry.supplementalContent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                report = .init(title: entry.title, content: text)
            }
            var heading = chapter
            if let title = report.title { heading.title = title }
            let rendered = sanitizer.process(book: book, chapter: heading, content: report.content, rules: applicable, rulesPreFiltered: true)
            guard !rendered.content.isEmpty else { continue }
            batch.append((offset: offset, title: rendered.title, body: rendered.content))
            if batch.count >= 128 {
                try insertPassages(batch, bookID: book.id)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try insertPassages(batch, bookID: book.id)
        }
    }

    private func insertPassages(_ batch: [(offset: Int, title: String, body: String)], bookID: String) throws {
        guard !batch.isEmpty else { return }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else { throw failure() }
        var committed = false
        var addedLocations: [Location] = []
        addedLocations.reserveCapacity(batch.count)
        let baseRowID = locations.count
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        let insert = try prepare("INSERT INTO passages(rowid,body) VALUES(?,?)")
        defer { sqlite3_finalize(insert) }
        for (index, item) in batch.enumerated() {
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, Int64(baseRowID + index + 1))
            try bind(item.body, to: insert)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            addedLocations.append(Location(book: bookID, offset: item.offset, title: item.title))
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        committed = true
        locations.append(contentsOf: addedLocations)
    }

    public func matches(_ input: String, limit: Int = 200) throws -> [Hit] {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !term.contains("\0"), limit > 0 else { return [] }
        let useIndex = indexed && term.unicodeScalars.count >= 3
        let sql = "SELECT rowid, body FROM passages" + (useIndex ? " WHERE passages MATCH ?1" : "") + " ORDER BY rowid"
        let query = try prepare(sql)
        defer { sqlite3_finalize(query) }
        if useIndex {
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try bind(phrase, to: query)
        }
        var hits: [Hit] = []
        while hits.count < limit {
            try Task.checkCancellation()
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(query, 1) else { throw failure() }
            let body = String(cString: text)
            let row = sqlite3_column_int64(query, 0)
            let place = locations[Int(row - 1)]
            var cursor = body.startIndex
            while hits.count < limit, cursor < body.endIndex,
                  let range = body.range(of: term, options: .caseInsensitive, range: cursor..<body.endIndex),
                  !range.isEmpty {
                try Task.checkCancellation()
                let start = body.index(range.lowerBound, offsetBy: -22, limitedBy: body.startIndex) ?? body.startIndex
                let end = body.index(range.upperBound, offsetBy: 40, limitedBy: body.endIndex) ?? body.endIndex
                let position = NSRange(range, in: body).location
                hits.append(.init(id: .init(row: row, offset: position), bookID: place.book, chapterOffset: place.offset,
                                  title: place.title, excerpt: body[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " "),
                                  position: position))
                cursor = range.upperBound
            }
        }
        return hits
    }

    private func bind(_ value: String, to statement: OpaquePointer) throws {
        let index = sqlite3_bind_parameter_count(statement)
        guard sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func failure() -> LegadoDatabaseError { .execute(String(cString: sqlite3_errmsg(db))) }
}
