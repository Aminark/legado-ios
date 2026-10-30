import Foundation
import SQLite3

public enum LegadoDatabaseError: Error, LocalizedError, Sendable {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message), .execute(let message), .prepare(let message),
             .bind(let message), .decode(let message): message
        }
    }
}

public actor LegadoDatabase {
    public static let schemaVersion: Int32 = 7

    // SQLite is opened with FULLMUTEX and every operational access remains
    // actor-isolated. `nonisolated(unsafe)` only permits closing the handle
    // from Swift 6's nonisolated actor deinitializer.
    nonisolated(unsafe) private let handle: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            throw LegadoDatabaseError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        do {
            try Self.execute(database, "PRAGMA foreign_keys = ON")
            try Self.execute(database, "PRAGMA journal_mode = WAL")
            try Self.migrate(database)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/legado.sqlite3")
    }

    public func compact() throws {
        try Self.execute(handle, "PRAGMA wal_checkpoint(TRUNCATE)")
        try Self.execute(handle, "VACUUM")
    }

    public func librarySnapshot(includeChapters: Bool = true) throws -> LibrarySnapshot {
        var value = LibrarySnapshot()
        try transaction {
            value.books = try loadBooks(); value.sources = try loadBookSources(); value.groups = try loadBookGroups()
            value.bookmarks = try loadBookmarks(); value.records = try loadReadRecords()
            value.searchKeywords = try loadSearchKeywords(order: .lastUseTime)
            value.rssSources = try loadRssSources(); value.rssStars = try loadRssStars()
            value.rssReadRecords = try loadRssReadRecords()
            value.txtRules = try loadTxtTocRules(); value.tts = try loadHttpTTS()
            value.subscriptions = try loadRuleSubs(); value.keyboardAssists = try loadKeyboardAssists()
            if includeChapters {
                for book in value.books { value.chapters[book.id] = try loadChapters(bookURL: book.id) }
            }
        }
        return value
    }

    /// An optimistic check inside the write transaction prevents network waits from overwriting newer local edits.
    public func applyLibrarySnapshot(_ value: LibrarySnapshot, expected: LibrarySnapshot, transactionID: String? = nil) throws {
        _ = try value.validated()
        try transaction {
            guard try librarySnapshot(includeChapters: false).databaseOnly == expected.databaseOnly else {
                throw LibraryBackupError.changed
            }
            try replaceBooks(value.books); try replaceBookSources(value.sources); try replaceBookGroups(value.groups)
            try replaceBookmarks(value.bookmarks); try replaceReadRecords(value.records)
            try replaceSearchKeywords(value.searchKeywords)
            try replaceRssSources(value.rssSources); try replaceRssStars(value.rssStars)
            try clearRssReadRecords(); try appendRssReadRecords(value.rssReadRecords)
            try replaceTxtTocRules(value.txtRules); try replaceHttpTTS(value.tts)
            try replaceRuleSubs(value.subscriptions); try replaceKeyboardAssists(value.keyboardAssists)
            for (bookURL, chapters) in value.chapters { try replaceChapters(chapters, bookURL: bookURL) }
            if let transactionID { try putCache(.init(key: "library.lastImport", value: transactionID)) }
        }
    }

    public func loadBookSources() throws -> [BookSource] {
        try load("SELECT payload FROM book_sources ORDER BY position, book_source_url", as: BookSource.self)
    }

    public func replaceBookSources(_ values: [BookSource]) throws {
        try transaction {
            if values.isEmpty {
                try Self.execute(handle, "DELETE FROM book_sources")
            } else {
                let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
                let prune = try prepare("DELETE FROM book_sources WHERE book_source_url NOT IN (\(placeholders))")
                defer { sqlite3_finalize(prune) }
                for (offset, value) in values.enumerated() {
                    try bind(value.bookSourceUrl, to: prune, at: Int32(offset + 1))
                }
                try stepDone(prune)
            }
            let statement = try prepare("""
                INSERT INTO book_sources(
                    book_source_url, book_source_group, custom_order, enabled, position, payload
                ) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(book_source_url) DO UPDATE SET
                    book_source_group = excluded.book_source_group,
                    custom_order = excluded.custom_order,
                    enabled = excluded.enabled,
                    position = excluded.position,
                    payload = excluded.payload
                """)
            defer { sqlite3_finalize(statement) }
            for (position, value) in values.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(value.bookSourceUrl, to: statement, at: 1)
                if let group = value.bookSourceGroup { try bind(group, to: statement, at: 2) }
                else { sqlite3_bind_null(statement, 2) }
                sqlite3_bind_int64(statement, 3, Int64(value.customOrder))
                sqlite3_bind_int(statement, 4, value.enabled ? 1 : 0)
                sqlite3_bind_int64(statement, 5, Int64(position))
                try bind(try encoder.encode(value), to: statement, at: 6)
                try stepDone(statement)
            }
        }
    }

    public func loadBooks() throws -> [Book] {
        try load("SELECT payload FROM books ORDER BY position, book_url", as: Book.self)
    }

    public func replaceBooks(_ values: [Book]) throws {
        try transaction {
            if values.isEmpty {
                try Self.execute(handle, "DELETE FROM books")
            } else {
                let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
                let prune = try prepare("DELETE FROM books WHERE book_url NOT IN (\(placeholders))")
                defer { sqlite3_finalize(prune) }
                for (offset, value) in values.enumerated() {
                    try bind(value.bookUrl, to: prune, at: Int32(offset + 1))
                }
                try stepDone(prune)
            }
            let insert = try prepare("""
                INSERT INTO books(book_url, name, author, position, payload) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(book_url) DO UPDATE SET
                    name = excluded.name,
                    author = excluded.author,
                    position = excluded.position,
                    payload = excluded.payload
                """)
            defer { sqlite3_finalize(insert) }
            for (position, value) in values.enumerated() {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(value.bookUrl, to: insert, at: 1)
                try bind(value.name, to: insert, at: 2)
                try bind(value.author, to: insert, at: 3)
                sqlite3_bind_int64(insert, 4, Int64(position))
                try bind(try encoder.encode(value), to: insert, at: 5)
                try stepDone(insert)
            }
        }
    }

    public func loadChapters(bookURL: String) throws -> [BookChapter] {
        let statement = try prepare("SELECT payload FROM chapters WHERE book_url = ? ORDER BY chapter_index")
        defer { sqlite3_finalize(statement) }
        try bind(bookURL, to: statement, at: 1)
        return try decodeRows(statement, as: BookChapter.self)
    }

    public func replaceChapters(_ chapters: [BookChapter], bookURL: String) throws {
        try transaction {
            let delete = try prepare("DELETE FROM chapters WHERE book_url = ?")
            defer { sqlite3_finalize(delete) }
            try bind(bookURL, to: delete, at: 1)
            try stepDone(delete)

            let insert = try prepare(
                "INSERT INTO chapters(url, book_url, chapter_index, payload) VALUES(?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(insert) }
            for (position, original) in chapters.enumerated() {
                var chapter = original
                chapter.bookUrl = bookURL
                chapter.index = position
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(chapter.url, to: insert, at: 1)
                try bind(bookURL, to: insert, at: 2)
                sqlite3_bind_int64(insert, 3, Int64(position))
                try bind(try encoder.encode(chapter), to: insert, at: 4)
                try stepDone(insert)
            }
        }
    }

    public func removeChapters(bookURL: String) throws {
        let statement = try prepare("DELETE FROM chapters WHERE book_url = ?")
        defer { sqlite3_finalize(statement) }
        try bind(bookURL, to: statement, at: 1)
        try stepDone(statement)
    }

    public func loadBookmarks() throws -> [Bookmark] {
        try load("SELECT payload FROM bookmarks ORDER BY time", as: Bookmark.self)
    }

    public func loadBookGroups() throws -> [BookGroup] {
        try load("SELECT payload FROM book_groups ORDER BY position, group_id", as: BookGroup.self)
    }

    public func replaceBookGroups(_ values: [BookGroup]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM book_groups",
            insertSQL: "INSERT INTO book_groups(group_id, position, payload) VALUES(?, ?, ?)",
            values: values
        ) { statement, value, position, data in
            sqlite3_bind_int64(statement, 1, value.groupId)
            sqlite3_bind_int64(statement, 2, Int64(position))
            try self.bind(data, to: statement, at: 3)
        }
    }

    public func replaceBookmarks(_ values: [Bookmark]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM bookmarks",
            insertSQL: "INSERT INTO bookmarks(time, payload) VALUES(?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, value.time)
            try self.bind(data, to: statement, at: 2)
        }
    }

    public func loadReadRecords() throws -> [ReadRecord] {
        try load("SELECT payload FROM read_records ORDER BY last_read DESC", as: ReadRecord.self)
    }

    public func replaceReadRecords(_ values: [ReadRecord]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM read_records",
            insertSQL: "INSERT INTO read_records(device_id, book_name, last_read, payload) VALUES(?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            try self.bind(value.deviceId, to: statement, at: 1)
            try self.bind(value.bookName, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, value.lastRead)
            try self.bind(data, to: statement, at: 4)
        }
    }

    public func loadSearchKeywords(order: SearchKeywordOrder) throws -> [SearchKeyword] {
        let orderSQL = switch order {
        case .usage: "usage DESC, last_use_time DESC"
        case .lastUseTime: "last_use_time DESC, usage DESC"
        }
        let statement = try prepare("SELECT word, usage, last_use_time FROM search_keywords ORDER BY \(orderSQL)")
        defer { sqlite3_finalize(statement) }
        var result: [SearchKeyword] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError(.execute) }
            result.append(.init(
                word: columnString(statement, at: 0),
                usage: Int(sqlite3_column_int64(statement, 1)),
                lastUseTime: sqlite3_column_int64(statement, 2)
            ))
        }
    }

    public func recordSearchKeyword(_ rawWord: String, at time: Int64) throws -> SearchKeyword {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw LegadoDatabaseError.bind("搜索词不能为空") }
        try transaction {
            let statement = try prepare("""
                INSERT INTO search_keywords(word, usage, last_use_time) VALUES(?, 1, ?)
                ON CONFLICT(word) DO UPDATE SET
                    usage = search_keywords.usage + 1,
                    last_use_time = excluded.last_use_time
                """)
            defer { sqlite3_finalize(statement) }
            try bind(word, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, time)
            try stepDone(statement)
        }
        let statement = try prepare("SELECT usage, last_use_time FROM search_keywords WHERE word = ?")
        defer { sqlite3_finalize(statement) }
        try bind(word, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(.execute) }
        return .init(
            word: word,
            usage: Int(sqlite3_column_int64(statement, 0)),
            lastUseTime: sqlite3_column_int64(statement, 1)
        )
    }

    public func deleteSearchKeyword(_ word: String) throws {
        try executeBound("DELETE FROM search_keywords WHERE word = ?", text: word)
    }

    public func deleteAllSearchKeywords() throws { try Self.execute(handle, "DELETE FROM search_keywords") }

    private func replaceSearchKeywords(_ values: [SearchKeyword]) throws {
        try transaction {
            try deleteAllSearchKeywords()
            let statement = try prepare("INSERT INTO search_keywords(word, usage, last_use_time) VALUES(?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(value.word, to: statement, at: 1)
                sqlite3_bind_int64(statement, 2, Int64(value.usage))
                sqlite3_bind_int64(statement, 3, value.lastUseTime)
                try stepDone(statement)
            }
        }
    }

    public func importLegacySearchKeywords(_ words: [String]) throws {
        guard try count("search_keywords") == 0, !words.isEmpty else { return }
        let now: Int64 = 0
        try transaction {
            let statement = try prepare(
                "INSERT OR IGNORE INTO search_keywords(word, usage, last_use_time) VALUES(?, 1, ?)"
            )
            defer { sqlite3_finalize(statement) }
            for (offset, rawWord) in words.enumerated() {
                let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(word, to: statement, at: 1)
                sqlite3_bind_int64(statement, 2, now - Int64(offset))
                try stepDone(statement)
            }
        }
    }

    public func cacheValue(for key: String, now: Int64) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM caches WHERE `key` = ? AND (deadline = 0 OR deadline > ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, now)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : columnString(statement, at: 0)
    }

    public func putCache(_ cache: LegadoCache) throws {
        let statement = try prepare("""
            INSERT INTO caches(`key`, value, deadline) VALUES(?, ?, ?)
            ON CONFLICT(`key`) DO UPDATE SET value = excluded.value, deadline = excluded.deadline
            """)
        defer { sqlite3_finalize(statement) }
        try bind(cache.key, to: statement, at: 1)
        if let value = cache.value { try bind(value, to: statement, at: 2) }
        else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_int64(statement, 3, cache.deadline)
        try stepDone(statement)
    }

    public func deleteCache(_ key: String) throws {
        try executeBound("DELETE FROM caches WHERE `key` = ?", text: key)
    }

    public func deleteSourceVariables(_ sourceKey: String) throws {
        let statement = try prepare("""
            DELETE FROM caches WHERE `key` LIKE 'v_' || ? || '_%'
                OR `key` = 'userInfo_' || ?
                OR `key` = 'loginHeader_' || ?
                OR `key` = 'sourceVariable_' || ?
                OR `key` = 'infoMap_' || ?
            """)
        defer { sqlite3_finalize(statement) }
        for index in 1...5 { try bind(sourceKey, to: statement, at: Int32(index)) }
        try stepDone(statement)
    }

    public func clearExpiredCaches(now: Int64) throws {
        let statement = try prepare("DELETE FROM caches WHERE deadline > 0 AND deadline < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, now)
        try stepDone(statement)
    }

    public func cookie(for url: String) throws -> LegadoCookie? {
        let statement = try prepare("SELECT cookie FROM cookies WHERE url = ?")
        defer { sqlite3_finalize(statement) }
        try bind(url, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return .init(url: url, cookie: columnString(statement, at: 0))
    }

    public func loadOkHTTPCookies() throws -> [LegadoCookie] {
        let statement = try prepare("SELECT url, cookie FROM cookies WHERE url LIKE '%|%'")
        defer { sqlite3_finalize(statement) }
        var result: [LegadoCookie] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError(.execute) }
            result.append(.init(url: columnString(statement, at: 0), cookie: columnString(statement, at: 1)))
        }
    }

    public func putCookie(_ cookie: LegadoCookie) throws {
        let statement = try prepare("""
            INSERT INTO cookies(url, cookie) VALUES(?, ?)
            ON CONFLICT(url) DO UPDATE SET cookie = excluded.cookie
            """)
        defer { sqlite3_finalize(statement) }
        try bind(cookie.url, to: statement, at: 1)
        try bind(cookie.cookie, to: statement, at: 2)
        try stepDone(statement)
    }

    public func deleteCookie(_ url: String) throws {
        try executeBound("DELETE FROM cookies WHERE url = ?", text: url)
    }

    public func deleteOkHTTPCookies() throws { try Self.execute(handle, "DELETE FROM cookies WHERE url LIKE '%|%'") }

    public func loadSearchBooks() throws -> [SearchBook] {
        try load("SELECT payload FROM searchBooks ORDER BY time DESC", as: SearchBook.self)
    }

    public func cachedSearchMatches(keyword: String) throws -> [SearchBook] {
        guard !keyword.isEmpty else { return [] }
        return try load("""
            SELECT payload FROM searchBooks
            WHERE instr(lower(name), lower(?1)) > 0 OR instr(lower(author), lower(?1)) > 0
            ORDER BY CASE WHEN name = ?1 OR author = ?1 THEN 0 ELSE 1 END, time DESC
            LIMIT 200
            """, as: SearchBook.self, bindings: [keyword])
    }

    public func putSearchBooks(_ values: [SearchBook]) throws {
        try transaction {
            let statement = try prepare("""
                INSERT INTO searchBooks(book_url, origin, name, author, time, payload)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(book_url) DO UPDATE SET
                    origin = excluded.origin,
                    name = excluded.name,
                    author = excluded.author,
                    time = excluded.time,
                    payload = excluded.payload
                """)
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(value.bookURL, to: statement, at: 1)
                try bind(value.origin, to: statement, at: 2)
                try bind(value.name, to: statement, at: 3)
                try bind(value.author, to: statement, at: 4)
                sqlite3_bind_int64(statement, 5, value.time)
                try bind(try encoder.encode(value), to: statement, at: 6)
                try stepDone(statement)
            }
        }
    }

    public func deleteSearchBooks(name: String, author: String) throws {
        let statement = try prepare("DELETE FROM searchBooks WHERE name = ? AND author = ?")
        defer { sqlite3_finalize(statement) }
        try bind(name, to: statement, at: 1)
        try bind(author, to: statement, at: 2)
        try stepDone(statement)
    }

    public func clearExpiredSearchBooks(before time: Int64) throws {
        let statement = try prepare("DELETE FROM searchBooks WHERE time < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, time)
        try stepDone(statement)
    }

    public func loadTxtTocRules() throws -> [TxtTocRule] {
        try load("SELECT payload FROM txtTocRules ORDER BY serial_number, id", as: TxtTocRule.self)
    }
    public func replaceTxtTocRules(_ values: [TxtTocRule]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM txtTocRules",
            insertSQL: "INSERT INTO txtTocRules(id, serial_number, enabled, payload) VALUES(?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, value.id)
            sqlite3_bind_int64(statement, 2, Int64(value.serialNumber))
            sqlite3_bind_int(statement, 3, value.enable ? 1 : 0)
            try self.bind(data, to: statement, at: 4)
        }
    }

    public func loadHttpTTS() throws -> [HttpTTS] { try load("SELECT payload FROM httpTTS ORDER BY name", as: HttpTTS.self) }
    public func replaceHttpTTS(_ values: [HttpTTS]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM httpTTS",
            insertSQL: "INSERT INTO httpTTS(id, name, payload) VALUES(?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, value.id)
            try self.bind(value.name, to: statement, at: 2)
            try self.bind(data, to: statement, at: 3)
        }
    }

    public func loadRuleSubs() throws -> [RuleSub] {
        try load("SELECT payload FROM ruleSubs ORDER BY custom_order, id", as: RuleSub.self)
    }
    public func replaceRuleSubs(_ values: [RuleSub]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM ruleSubs",
            insertSQL: "INSERT INTO ruleSubs(id, type, custom_order, payload) VALUES(?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, value.id)
            sqlite3_bind_int64(statement, 2, Int64(value.type))
            sqlite3_bind_int64(statement, 3, Int64(value.customOrder))
            try self.bind(data, to: statement, at: 4)
        }
    }

    public func loadKeyboardAssists() throws -> [KeyboardAssist] {
        try load("SELECT payload FROM keyboardAssists ORDER BY serial_no", as: KeyboardAssist.self)
    }
    public func replaceKeyboardAssists(_ values: [KeyboardAssist]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM keyboardAssists",
            insertSQL: "INSERT INTO keyboardAssists(type, key, serial_no, payload) VALUES(?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, Int64(value.type))
            try self.bind(value.key, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(value.serialNo))
            try self.bind(data, to: statement, at: 4)
        }
    }

    public func loadServers() throws -> [Server] {
        try load("SELECT payload FROM servers ORDER BY sort_number, id", as: Server.self)
    }
    public func replaceServers(_ values: [Server]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM servers",
            insertSQL: "INSERT INTO servers(id, sort_number, payload) VALUES(?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            sqlite3_bind_int64(statement, 1, value.id)
            sqlite3_bind_int64(statement, 2, Int64(value.sortNumber))
            try self.bind(data, to: statement, at: 3)
        }
    }

    public func loadRssSources() throws -> [RssSource] {
        try load("SELECT payload FROM rssSources ORDER BY custom_order", as: RssSource.self)
    }

    public func replaceRssSources(_ values: [RssSource]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM rssSources",
            insertSQL: "INSERT INTO rssSources(source_url, source_name, source_group, source_comment, enabled, custom_order, login_url, payload) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            try self.bind(value.sourceUrl, to: statement, at: 1)
            try self.bind(value.sourceName, to: statement, at: 2)
            if let group = value.sourceGroup { try self.bind(group, to: statement, at: 3) } else { sqlite3_bind_null(statement, 3) }
            if let comment = value.sourceComment { try self.bind(comment, to: statement, at: 4) } else { sqlite3_bind_null(statement, 4) }
            sqlite3_bind_int(statement, 5, value.enabled ? 1 : 0)
            sqlite3_bind_int64(statement, 6, Int64(value.customOrder))
            if let loginURL = value.loginUrl { try self.bind(loginURL, to: statement, at: 7) } else { sqlite3_bind_null(statement, 7) }
            try self.bind(data, to: statement, at: 8)
        }
    }

    public func setRssSourceEnabled(_ enabled: Bool, sourceURL: String) throws {
        try transaction {
            let query = try prepare("SELECT payload FROM rssSources WHERE source_url = ? LIMIT 1")
            defer { sqlite3_finalize(query) }
            try bind(sourceURL, to: query, at: 1)
            guard var source = try decodeFirst(query, as: RssSource.self) else { return }
            source.enabled = enabled
            let update = try prepare("UPDATE rssSources SET enabled = ?, payload = ? WHERE source_url = ?")
            defer { sqlite3_finalize(update) }
            sqlite3_bind_int(update, 1, enabled ? 1 : 0)
            try bind(try encoder.encode(source), to: update, at: 2)
            try bind(sourceURL, to: update, at: 3)
            try stepDone(update)
        }
    }

    public func removeRssSource(sourceURL: String) throws {
        try transaction {
            try executeBound("DELETE FROM rssSources WHERE source_url = ?", text: sourceURL)
            try removeRssArticles(origin: sourceURL)
            try deleteSourceVariables(sourceURL)
        }
    }

    public func loadRssArticles(origin: String, sort: String) throws -> [RssArticle] {
        let statement = try prepare("SELECT a.payload, EXISTS(SELECT 1 FROM rssReadRecords r WHERE r.record = a.link) FROM rssArticles a WHERE a.origin = ? AND a.sort = ? ORDER BY a.article_order DESC")
        defer { sqlite3_finalize(statement) }
        try bind(origin, to: statement, at: 1)
        try bind(sort, to: statement, at: 2)
        var result: [RssArticle] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError(.execute) }
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw LegadoDatabaseError.decode("RSS文章记录缺少payload") }
            var article = try decoder.decode(RssArticle.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            article.read = sqlite3_column_int(statement, 1) != 0
            result.append(article)
        }
    }

    public func findRssArticle(origin: String, link: String, sort: String? = nil) throws -> RssArticle? {
        let sql = sort == nil
            ? "SELECT payload FROM rssArticles WHERE origin = ? AND link = ? LIMIT 1"
            : "SELECT payload FROM rssArticles WHERE origin = ? AND link = ? AND sort = ? LIMIT 1"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(origin, to: statement, at: 1); try bind(link, to: statement, at: 2)
        if let sort { try bind(sort, to: statement, at: 3) }
        return try decodeFirst(statement, as: RssArticle.self)
    }

    public func replaceRssArticles(_ values: [RssArticle], origin: String, sort: String) throws {
        try transaction {
            let delete = try prepare("DELETE FROM rssArticles WHERE origin = ? AND sort = ?")
            defer { sqlite3_finalize(delete) }
            try bind(origin, to: delete, at: 1); try bind(sort, to: delete, at: 2); try stepDone(delete)
            try insertRssArticles(values, conflict: "REPLACE")
        }
    }

    public func appendRssArticles(_ values: [RssArticle]) throws {
        try transaction { try insertRssArticles(values, conflict: "IGNORE") }
    }

    public func putRssArticles(_ values: [RssArticle]) throws {
        try transaction { try insertRssArticles(values, conflict: "REPLACE") }
    }

    public func updateRssArticles(_ values: [RssArticle]) throws {
        try transaction {
            let statement = try prepare("UPDATE rssArticles SET article_order = ?, payload = ? WHERE origin = ? AND link = ? AND sort = ?")
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, value.order); try bind(try encoder.encode(value), to: statement, at: 2)
                try bind(value.origin, to: statement, at: 3); try bind(value.link, to: statement, at: 4)
                try bind(value.sort, to: statement, at: 5); try stepDone(statement)
            }
        }
    }

    public func updateRssArticleOrigin(from oldOrigin: String, to origin: String) throws {
        let statement = try prepare("SELECT payload FROM rssArticles WHERE origin = ?")
        defer { sqlite3_finalize(statement) }
        try bind(oldOrigin, to: statement, at: 1)
        var values = try decodeRows(statement, as: RssArticle.self)
        values.indices.forEach { values[$0].origin = origin }
        try transaction {
            let update = try prepare("UPDATE rssArticles SET origin = ?, payload = ? WHERE origin = ? AND link = ? AND sort = ?")
            defer { sqlite3_finalize(update) }
            for value in values {
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                try bind(origin, to: update, at: 1); try bind(try encoder.encode(value), to: update, at: 2)
                try bind(oldOrigin, to: update, at: 3); try bind(value.link, to: update, at: 4)
                try bind(value.sort, to: update, at: 5); try stepDone(update)
            }
        }
    }

    public func clearOldRssArticles(origin: String, sort: String, before order: Int64) throws {
        let statement = try prepare("DELETE FROM rssArticles WHERE origin = ? AND sort = ? AND article_order < ?")
        defer { sqlite3_finalize(statement) }
        try bind(origin, to: statement, at: 1); try bind(sort, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, order); try stepDone(statement)
    }

    public func removeRssArticles(origin: String) throws {
        try executeBound("DELETE FROM rssArticles WHERE origin = ?", text: origin)
    }

    public func loadRssReadRecords() throws -> [RssReadRecord] {
        try load("SELECT payload FROM rssReadRecords ORDER BY read_time DESC", as: RssReadRecord.self)
    }

    public func appendRssReadRecords(_ values: [RssReadRecord]) throws {
        try transaction {
            let statement = try prepare("INSERT OR IGNORE INTO rssReadRecords(record, origin, read_time, payload) VALUES(?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(value.record, to: statement, at: 1); try bind(value.origin, to: statement, at: 2)
                if let time = value.readTime { sqlite3_bind_int64(statement, 3, time) } else { sqlite3_bind_null(statement, 3) }
                try bind(try encoder.encode(value), to: statement, at: 4); try stepDone(statement)
            }
        }
    }

    public func updateRssReadRecords(_ values: [RssReadRecord]) throws {
        try transaction {
            let statement = try prepare("UPDATE rssReadRecords SET origin = ?, read_time = ?, payload = ? WHERE record = ?")
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(value.origin, to: statement, at: 1)
                if let time = value.readTime { sqlite3_bind_int64(statement, 2, time) } else { sqlite3_bind_null(statement, 2) }
                try bind(try encoder.encode(value), to: statement, at: 3); try bind(value.record, to: statement, at: 4)
                try stepDone(statement)
            }
        }
    }

    public func findRssReadRecord(record: String, origin: String) throws -> RssReadRecord? {
        let statement = try prepare("SELECT payload FROM rssReadRecords WHERE record = ? AND origin = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(record, to: statement, at: 1); try bind(origin, to: statement, at: 2)
        return try decodeFirst(statement, as: RssReadRecord.self)
    }

    public func clearRssReadRecords() throws { try Self.execute(handle, "DELETE FROM rssReadRecords") }

    public func removeRssReadRecords(origin: String) throws {
        try executeBound("DELETE FROM rssReadRecords WHERE origin = ?", text: origin)
    }

    public func loadRssStars() throws -> [RssStar] {
        try load("SELECT payload FROM rssStars ORDER BY star_time DESC", as: RssStar.self)
    }

    public func replaceRssStars(_ values: [RssStar]) throws {
        try replaceAll(
            deleteSQL: "DELETE FROM rssStars",
            insertSQL: "INSERT INTO rssStars(origin, link, star_time, group_name, payload) VALUES(?, ?, ?, ?, ?)",
            values: values
        ) { statement, value, _, data in
            try self.bind(value.origin, to: statement, at: 1); try self.bind(value.link, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, value.starTime); try self.bind(value.group, to: statement, at: 4)
            try self.bind(data, to: statement, at: 5)
        }
    }

    public func updateRssStars(_ values: [RssStar]) throws {
        try transaction {
            let statement = try prepare("INSERT OR REPLACE INTO rssStars(origin, link, star_time, group_name, payload) VALUES(?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            for value in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(value.origin, to: statement, at: 1); try bind(value.link, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, value.starTime); try bind(value.group, to: statement, at: 4)
                try bind(try encoder.encode(value), to: statement, at: 5); try stepDone(statement)
            }
        }
    }

    public func findRssStar(origin: String, link: String) throws -> RssStar? {
        let statement = try prepare("SELECT payload FROM rssStars WHERE origin = ? AND link = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(origin, to: statement, at: 1); try bind(link, to: statement, at: 2)
        return try decodeFirst(statement, as: RssStar.self)
    }

    public func removeRssStars(origin: String, link: String? = nil) throws {
        let sql = link == nil ? "DELETE FROM rssStars WHERE origin = ?" : "DELETE FROM rssStars WHERE origin = ? AND link = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(origin, to: statement, at: 1); if let link { try bind(link, to: statement, at: 2) }
        try stepDone(statement)
    }

    public func removeRssStars(group: String) throws { try executeBound("DELETE FROM rssStars WHERE group_name = ?", text: group) }
    public func clearRssStars() throws { try Self.execute(handle, "DELETE FROM rssStars") }

    public func updateRssStarOrigin(from oldOrigin: String, to origin: String) throws {
        let statement = try prepare("SELECT payload FROM rssStars WHERE origin = ?")
        defer { sqlite3_finalize(statement) }
        try bind(oldOrigin, to: statement, at: 1)
        var values = try decodeRows(statement, as: RssStar.self)
        values.indices.forEach { values[$0].origin = origin }
        try transaction {
            let update = try prepare("UPDATE rssStars SET origin = ?, payload = ? WHERE origin = ? AND link = ?")
            defer { sqlite3_finalize(update) }
            for value in values {
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                try bind(origin, to: update, at: 1); try bind(try encoder.encode(value), to: update, at: 2)
                try bind(oldOrigin, to: update, at: 3); try bind(value.link, to: update, at: 4)
                try stepDone(update)
            }
        }
    }

    private func insertRssArticles(_ values: [RssArticle], conflict: String) throws {
        let statement = try prepare("INSERT OR \(conflict) INTO rssArticles(origin, link, sort, article_order, payload) VALUES(?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        for value in values {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(value.origin, to: statement, at: 1); try bind(value.link, to: statement, at: 2)
            try bind(value.sort, to: statement, at: 3); sqlite3_bind_int64(statement, 4, value.order)
            try bind(try encoder.encode(value), to: statement, at: 5); try stepDone(statement)
        }
    }

    public func importLegacyJSON(
        bookSourcesURL: URL?,
        booksURL: URL?,
        chaptersDirectory: URL? = nil,
        bookGroupsURL: URL? = nil,
        bookmarksURL: URL? = nil,
        readRecordsURL: URL? = nil
    ) throws {
        if try count("book_sources") == 0,
           let bookSourcesURL,
           FileManager.default.fileExists(atPath: bookSourcesURL.path) {
            try replaceBookSources(decoder.decode([BookSource].self, from: Data(contentsOf: bookSourcesURL)))
        }
        if try count("books") == 0,
           let booksURL,
           FileManager.default.fileExists(atPath: booksURL.path) {
            try replaceBooks(decoder.decode([Book].self, from: Data(contentsOf: booksURL)))
        }
        if let chaptersDirectory, !legacyChaptersImported() {
            if try count("chapters") == 0,
               FileManager.default.fileExists(atPath: chaptersDirectory.path) {
                for url in try FileManager.default.contentsOfDirectory(at: chaptersDirectory, includingPropertiesForKeys: nil)
                    where url.pathExtension.lowercased() == "json" {
                    let chapters = try decoder.decode([BookChapter].self, from: Data(contentsOf: url))
                    if let bookURL = chapters.first?.bookUrl, !bookURL.isEmpty {
                        try replaceChapters(chapters, bookURL: bookURL)
                    }
                }
            }
            try Self.execute(handle, "INSERT OR IGNORE INTO legacy_imports(key) VALUES('chapters')")
        }
        if try count("bookmarks") == 0,
           let bookmarksURL,
           FileManager.default.fileExists(atPath: bookmarksURL.path) {
            try replaceBookmarks(decoder.decode([Bookmark].self, from: Data(contentsOf: bookmarksURL)))
        }
        if try count("book_groups") == 0,
           let bookGroupsURL,
           FileManager.default.fileExists(atPath: bookGroupsURL.path) {
            try replaceBookGroups(decoder.decode([BookGroup].self, from: Data(contentsOf: bookGroupsURL)))
        }
        if try count("read_records") == 0,
           let readRecordsURL,
           FileManager.default.fileExists(atPath: readRecordsURL.path) {
            try replaceReadRecords(decoder.decode([ReadRecord].self, from: Data(contentsOf: readRecordsURL)))
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = try scalarInt32(database, "PRAGMA user_version")
        guard version <= schemaVersion else {
            throw LegadoDatabaseError.open("数据库版本 \(version) 高于当前支持版本 \(schemaVersion)")
        }
        if version < 1 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE book_sources(
                        book_source_url TEXT PRIMARY KEY NOT NULL,
                        position INTEGER NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX book_sources_position ON book_sources(position);
                    CREATE TABLE books(
                        book_url TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        author TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE UNIQUE INDEX books_name_author ON books(name, author);
                    CREATE INDEX books_position ON books(position);
                    CREATE TABLE chapters(
                        url TEXT NOT NULL,
                        book_url TEXT NOT NULL,
                        chapter_index INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(url, book_url),
                        UNIQUE(book_url, chapter_index),
                        FOREIGN KEY(book_url) REFERENCES books(book_url)
                            ON UPDATE CASCADE ON DELETE CASCADE
                    );
                    CREATE INDEX chapters_book_url ON chapters(book_url);
                    PRAGMA user_version = 1;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 2 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE book_groups(
                        group_id INTEGER PRIMARY KEY NOT NULL,
                        position INTEGER NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE bookmarks(
                        time INTEGER PRIMARY KEY NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE read_records(
                        device_id TEXT NOT NULL,
                        book_name TEXT NOT NULL,
                        last_read INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(device_id, book_name)
                    );
                    CREATE INDEX read_records_last_read ON read_records(last_read DESC);
                    PRAGMA user_version = 2;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 3 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE search_keywords(
                        word TEXT PRIMARY KEY NOT NULL,
                        usage INTEGER NOT NULL DEFAULT 1,
                        last_use_time INTEGER NOT NULL
                    );
                    CREATE TABLE caches(
                        `key` TEXT PRIMARY KEY NOT NULL,
                        value TEXT,
                        deadline INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE cookies(
                        url TEXT PRIMARY KEY NOT NULL,
                        cookie TEXT NOT NULL DEFAULT ''
                    );
                    CREATE TABLE searchBooks(
                        book_url TEXT PRIMARY KEY NOT NULL,
                        origin TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        FOREIGN KEY(origin) REFERENCES book_sources(book_source_url) ON DELETE CASCADE
                    );
                    CREATE INDEX searchBooks_origin ON searchBooks(origin);
                    PRAGMA user_version = 3;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 4 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    ALTER TABLE book_sources ADD COLUMN book_source_group TEXT;
                    ALTER TABLE book_sources ADD COLUMN custom_order INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE book_sources ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
                    CREATE INDEX book_sources_group ON book_sources(book_source_group);
                    CREATE INDEX book_sources_enabled_order ON book_sources(enabled, custom_order);
                    ALTER TABLE searchBooks ADD COLUMN name TEXT NOT NULL DEFAULT '';
                    ALTER TABLE searchBooks ADD COLUMN author TEXT NOT NULL DEFAULT '';
                    ALTER TABLE searchBooks ADD COLUMN time INTEGER NOT NULL DEFAULT 0;
                    CREATE INDEX searchBooks_name_author ON searchBooks(name, author);
                    CREATE INDEX searchBooks_time ON searchBooks(time);
                    PRAGMA user_version = 4;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 5 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE txtTocRules(
                        id INTEGER PRIMARY KEY NOT NULL,
                        serial_number INTEGER NOT NULL DEFAULT -1,
                        enabled INTEGER NOT NULL DEFAULT 1,
                        payload BLOB NOT NULL
                    );
                    -- Retain the historical v5 schema for existing databases; no dictionary APIs remain.
                    CREATE TABLE dictRules(
                        name TEXT PRIMARY KEY NOT NULL,
                        sort_number INTEGER NOT NULL DEFAULT 0,
                        enabled INTEGER NOT NULL DEFAULT 1,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE httpTTS(
                        id INTEGER PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE ruleSubs(
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        type INTEGER NOT NULL DEFAULT 0,
                        custom_order INTEGER NOT NULL DEFAULT 0,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE keyboardAssists(
                        type INTEGER NOT NULL DEFAULT 0,
                        key TEXT NOT NULL,
                        serial_no INTEGER NOT NULL DEFAULT 0,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(type, key)
                    );
                    CREATE TABLE servers(
                        id INTEGER PRIMARY KEY NOT NULL,
                        sort_number INTEGER NOT NULL DEFAULT 0,
                        payload BLOB NOT NULL
                    );
                    PRAGMA user_version = 5;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 6 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE rssSources(
                        source_url TEXT PRIMARY KEY NOT NULL,
                        source_name TEXT NOT NULL,
                        source_group TEXT,
                        source_comment TEXT,
                        enabled INTEGER NOT NULL DEFAULT 1,
                        custom_order INTEGER NOT NULL DEFAULT 0,
                        login_url TEXT,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX rssSources_order ON rssSources(custom_order, source_url);
                    CREATE TABLE rssArticles(
                        origin TEXT NOT NULL,
                        link TEXT NOT NULL,
                        sort TEXT NOT NULL,
                        article_order INTEGER NOT NULL DEFAULT 0,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(origin, link, sort)
                    );
                    CREATE INDEX rssArticles_origin_sort_order ON rssArticles(origin, sort, article_order DESC);
                    CREATE TABLE rssReadRecords(
                        record TEXT PRIMARY KEY NOT NULL,
                        origin TEXT NOT NULL,
                        read_time INTEGER,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX rssReadRecords_time ON rssReadRecords(read_time DESC);
                    CREATE INDEX rssReadRecords_origin ON rssReadRecords(origin);
                    CREATE TABLE rssStars(
                        origin TEXT NOT NULL,
                        link TEXT NOT NULL,
                        star_time INTEGER NOT NULL DEFAULT 0,
                        group_name TEXT NOT NULL DEFAULT '默认分组',
                        payload BLOB NOT NULL,
                        PRIMARY KEY(origin, link)
                    );
                    CREATE INDEX rssStars_time ON rssStars(star_time DESC);
                    PRAGMA user_version = 6;
                    """)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
        if version < 7 {
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try execute(database, """
                    CREATE TABLE legacy_imports(key TEXT PRIMARY KEY NOT NULL);
                    PRAGMA user_version = 7;
                    """)
                if version > 0, try scalarInt32(database, "SELECT COUNT(*) FROM chapters") > 0 {
                    try execute(database, "INSERT INTO legacy_imports(key) VALUES('chapters')")
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private func legacyChaptersImported() -> Bool {
        (try? Self.scalarInt32(handle, "SELECT COUNT(*) FROM legacy_imports WHERE key = 'chapters'")) == 1
    }

    private func load<T: Decodable>(_ sql: String, as type: T.Type, bindings: [String] = []) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        return try decodeRows(statement, as: type)
    }

    private func decodeRows<T: Decodable>(_ statement: OpaquePointer, as type: T.Type) throws -> [T] {
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError(.execute) }
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw LegadoDatabaseError.decode("数据库记录缺少payload")
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            do { result.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: count))) }
            catch { throw LegadoDatabaseError.decode(error.localizedDescription) }
        }
    }

    private func decodeFirst<T: Decodable>(_ statement: OpaquePointer, as type: T.Type) throws -> T? {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw databaseError(.execute)
        }
        do {
            return try decoder.decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        } catch {
            throw LegadoDatabaseError.decode(error.localizedDescription)
        }
    }

    private func replaceAll<T: Encodable & Sendable>(
        deleteSQL: String,
        insertSQL: String,
        values: [T],
        binder: (OpaquePointer, T, Int, Data) throws -> Void
    ) throws {
        try transaction {
            try Self.execute(handle, deleteSQL)
            let statement = try prepare(insertSQL)
            defer { sqlite3_finalize(statement) }
            for (position, value) in values.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try binder(statement, value, position, try encoder.encode(value))
                try stepDone(statement)
            }
        }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        // Savepoints compose with snapshot imports while retaining rollback for every repository write.
        let outermost = sqlite3_get_autocommit(handle) != 0
        try Self.execute(handle, outermost ? "BEGIN IMMEDIATE" : "SAVEPOINT legado_write")
        do {
            try operation()
            try Self.execute(handle, outermost ? "COMMIT" : "RELEASE SAVEPOINT legado_write")
        } catch {
            if outermost { try? Self.execute(handle, "ROLLBACK") }
            else {
                try? Self.execute(handle, "ROLLBACK TO SAVEPOINT legado_write")
                try? Self.execute(handle, "RELEASE SAVEPOINT legado_write")
            }
            throw error
        }
    }

    private func count(_ table: String) throws -> Int64 {
        let allowed = [
            "book_sources", "books", "chapters", "book_groups", "bookmarks", "read_records",
            "search_keywords", "caches", "cookies", "searchBooks"
            , "txtTocRules", "httpTTS", "ruleSubs", "keyboardAssists", "servers",
            "rssSources", "rssArticles", "rssReadRecords", "rssStars"
        ]
        guard allowed.contains(table) else { throw LegadoDatabaseError.execute("非法表名") }
        let statement = try prepare("SELECT COUNT(*) FROM \(table)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(.execute) }
        return sqlite3_column_int64(statement, 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(.prepare)
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw databaseError(.bind)
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let status = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard status == SQLITE_OK else { throw databaseError(.bind) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(.execute) }
    }

    private func executeBound(_ sql: String, text: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(text, to: statement, at: 1)
        try stepDone(statement)
    }

    private func columnString(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private enum ErrorKind { case execute, prepare, bind }
    private func databaseError(_ kind: ErrorKind) -> LegadoDatabaseError {
        let message = String(cString: sqlite3_errmsg(handle))
        switch kind {
        case .execute: return LegadoDatabaseError.execute(message)
        case .prepare: return LegadoDatabaseError.prepare(message)
        case .bind: return LegadoDatabaseError.bind(message)
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw LegadoDatabaseError.execute(message)
        }
    }

    private static func scalarInt32(_ database: OpaquePointer, _ sql: String) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LegadoDatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LegadoDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int(statement, 0)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

public actor SQLiteBookSourceRepository: BookSourceRepository {
    private let database: LegadoDatabase
    private let legacyFileURL: URL?
    public init(database: LegadoDatabase, legacyFileURL: URL? = nil) {
        self.database = database
        self.legacyFileURL = legacyFileURL
    }
    public func load() async throws -> [BookSource] {
        try await database.importLegacyJSON(bookSourcesURL: legacyFileURL, booksURL: nil)
        return try await database.loadBookSources()
    }
    public func save(_ sources: [BookSource]) async throws { try await database.replaceBookSources(sources) }
}

public actor SQLiteBookRepository: BookRepository {
    private let database: LegadoDatabase
    private let legacyFileURL: URL?
    public init(database: LegadoDatabase, legacyFileURL: URL? = nil) {
        self.database = database
        self.legacyFileURL = legacyFileURL
    }
    public func load() async throws -> [Book] {
        try await database.importLegacyJSON(bookSourcesURL: nil, booksURL: legacyFileURL)
        return try await database.loadBooks()
    }
    public func save(_ books: [Book]) async throws { try await database.replaceBooks(books) }
}

public actor SQLiteBookChapterRepository: BookChapterRepository {
    private let database: LegadoDatabase
    private let legacyDirectory: URL?
    public init(database: LegadoDatabase, legacyDirectory: URL? = nil) {
        self.database = database
        self.legacyDirectory = legacyDirectory
    }
    public func load(bookURL: String) async throws -> [BookChapter] {
        try await database.importLegacyJSON(
            bookSourcesURL: nil,
            booksURL: nil,
            chaptersDirectory: legacyDirectory
        )
        return try await database.loadChapters(bookURL: bookURL)
    }
    public func save(_ chapters: [BookChapter], bookURL: String) async throws {
        try await database.replaceChapters(chapters, bookURL: bookURL)
    }
    public func remove(bookURL: String) async throws { try await database.removeChapters(bookURL: bookURL) }
}

public actor SQLiteReadingActivityRepository: ReadingActivityRepository {
    private let database: LegadoDatabase
    private let legacyBookmarksURL: URL?
    private let legacyRecordsURL: URL?

    public init(
        database: LegadoDatabase,
        legacyBookmarksURL: URL? = nil,
        legacyRecordsURL: URL? = nil
    ) {
        self.database = database
        self.legacyBookmarksURL = legacyBookmarksURL
        self.legacyRecordsURL = legacyRecordsURL
    }

    public func loadBookmarks() async throws -> [Bookmark] {
        try await migrate()
        return try await database.loadBookmarks()
    }

    public func saveBookmarks(_ bookmarks: [Bookmark]) async throws {
        try await database.replaceBookmarks(bookmarks)
    }

    public func loadReadRecords() async throws -> [ReadRecord] {
        try await migrate()
        return try await database.loadReadRecords()
    }

    public func saveReadRecords(_ records: [ReadRecord]) async throws {
        try await database.replaceReadRecords(records)
    }

    private func migrate() async throws {
        try await database.importLegacyJSON(
            bookSourcesURL: nil,
            booksURL: nil,
            bookmarksURL: legacyBookmarksURL,
            readRecordsURL: legacyRecordsURL
        )
    }
}

public actor SQLiteBookGroupRepository: BookGroupRepository {
    private let database: LegadoDatabase
    private let legacyFileURL: URL?
    public init(database: LegadoDatabase, legacyFileURL: URL? = nil) {
        self.database = database
        self.legacyFileURL = legacyFileURL
    }
    public func load() async throws -> [BookGroup] {
        try await database.importLegacyJSON(
            bookSourcesURL: nil,
            booksURL: nil,
            bookGroupsURL: legacyFileURL
        )
        return try await database.loadBookGroups()
    }
    public func save(_ groups: [BookGroup]) async throws { try await database.replaceBookGroups(groups) }
}
