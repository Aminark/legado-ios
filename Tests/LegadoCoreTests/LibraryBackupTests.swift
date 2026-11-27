import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import LegadoCore

@Suite struct LibraryBackupTests {
    private struct Fixture {
        let directory: URL
        let database: LegadoDatabase
        let service: LibraryBackupService
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID().uuidString)")
            database = try LegadoDatabase(url: directory.appendingPathComponent("library.sqlite3"))
            service = .init(database: database, support: directory)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func snapshot() -> LibrarySnapshot {
        var value = LibrarySnapshot()
        value.sources = [.init(bookSourceUrl: "https://source.example", bookSourceName: "测试源")]
        value.books = [.init(bookUrl: "https://source.example/book", name: "合成测试书", author: "测试作者", origin: value.sources[0].id)]
        value.chapters = [value.books[0].id: [.init(url: "https://source.example/ch1", title: "第一章", bookUrl: value.books[0].id, index: 0)]]
        value.bookmarks = [.init(time: 123, bookName: value.books[0].name)]
        return value
    }

    @Test func localEPUBArchivePreservesBytesAndRetargetsChapterURLs() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let file = original.directory.appendingPathComponent("LocalBooks/archive-fixture.epub")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Archive transport treats the EPUB as opaque bytes; EPUB parsing has its own tests.
        let bytes = Data("synthetic EPUB attachment bytes".utf8)
        try bytes.write(to: file)
        var value = LibrarySnapshot()
        value.books = [.init(bookUrl: file.absoluteString, name: "备份格式测试")]
        value.chapters[file.absoluteString] = [.init(url: file.absoluteString + "#chapter-1",
            title: "第一章", bookUrl: file.absoluteString, index: 0)]
        try await original.service.apply(value, expected: original.service.snapshot())
        let url = try await original.service.export(includeLocalBooks: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await target.service.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try await target.service.restore(prepared)
        let restored = try await target.service.snapshot()
        let book = try #require(restored.books.first)
        let restoredURL = try #require(URL(string: book.id))
        #expect(restoredURL.pathExtension == "epub")
        #expect(try Data(contentsOf: restoredURL) == bytes)
        #expect(restored.chapters[book.id]?.first?.url == book.id + "#chapter-1")
        #expect(restored.chapters[book.id]?.first?.bookUrl == book.id)
    }

    @Test func metadataExportOmitsLocalBooksAndCacheAttachments() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var value = snapshot(); value.books.append(.init(bookUrl: "file:///not-in-backup.txt", name: "本地书"))
        try await fixture.service.apply(value, expected: fixture.service.snapshot())
        let url = try await fixture.service.export(includeLocalBooks: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await fixture.service.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.manifest.snapshot.books.count == 1)
        #expect(prepared.manifest.attachments.isEmpty)
    }

    @Test(arguments: ["txt", "epub"], [true, false])
    func existingLocalBookRestoresNewestProgressWithoutReplacingItsFile(_ fileExtension: String, _ backupIsNewer: Bool) async throws {
        for sameURL in [true, false] {
            let original = try Fixture(); let target = try Fixture()
            defer { original.cleanup(); target.cleanup() }
            let localFile = target.directory.appendingPathComponent("LocalBooks/current.\(fileExtension)")
            try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let localBytes = Data("本机文件应保持不变".utf8)
            try localBytes.write(to: localFile)
            var local = LibrarySnapshot()
            local.books = [.init(bookUrl: localFile.absoluteString, name: "恢复进度测试")]
            local.books[0].tocUrl = localFile.absoluteString
            local.books[0].durChapterTime = backupIsNewer ? 100 : 300
            local.books[0].readConfig = BookReadConfig()
            local.books[0].readConfig?.pageAnim = 2
            local.books[0].readConfig?.epubLocation = fileExtension == "epub" ? "local-locator" : nil
            local.chapters[localFile.absoluteString] = [.init(url: localFile.absoluteString + "#one", title: "第一章", bookUrl: localFile.absoluteString, index: 0)]
            try await target.service.apply(local, expected: target.service.snapshot())

            let backupFile = original.directory.appendingPathComponent("backup.\(fileExtension)")
            try Data("备份附件不应覆盖本机文件".utf8).write(to: backupFile)
            let backupURL = sameURL ? localFile.absoluteString : backupFile.absoluteString
            var incoming = local
            incoming.books[0].bookUrl = backupURL; incoming.books[0].tocUrl = backupURL
            incoming.books[0].durChapterTime = 200; incoming.books[0].durChapterPos = 12
            incoming.books[0].readConfig?.epubLocation = fileExtension == "epub" ? "backup-locator" : nil
            incoming.chapters = [backupURL: [.init(url: backupURL + "#one", title: "第一章", bookUrl: backupURL, index: 0)]]
            let archive = original.directory.appendingPathComponent("local.legadobackup")
            try LibraryBackupArchive.write(snapshot: incoming, files: ["local/" + URL(string: backupURL)!.lastPathComponent: backupFile], to: archive)
            let prepared = try await target.service.prepare(archive)
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            try await target.service.restore(prepared)
            try await target.service.restore(prepared)
            let restored = try await target.service.snapshot()
            let book = try #require(restored.books.first)
            #expect(restored.books.count == 1)
            #expect(book.bookUrl == localFile.absoluteString)
            #expect(book.tocUrl == localFile.absoluteString)
            #expect(book.durChapterTime == (backupIsNewer ? 200 : 300))
            #expect(book.durChapterPos == (backupIsNewer ? 12 : 0))
            #expect(book.readConfig?.epubLocation == (backupIsNewer ? incoming : local).books[0].readConfig?.epubLocation)
            #expect(book.readConfig?.pageAnim == 2)
            #expect(restored.chapters[book.id]?.first?.url == book.id + "#one")
            #expect(try Data(contentsOf: localFile) == localBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: localFile.deletingLastPathComponent().path).count == 1)
        }
    }

    @Test(arguments: [true, false])
    func restoredDirectoryMatchesTheNewestReadingProgress(_ backupIsNewer: Bool) async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let short = snapshot()
        var complete = short
        complete.chapters[complete.books[0].id]?.append(.init(url: "https://source.example/ch2", title: "第二章", bookUrl: complete.books[0].id, index: 1))
        complete.books[0].durChapterIndex = 1; complete.books[0].durChapterTitle = "第二章"
        complete.books[0].durChapterPos = 12; complete.books[0].durChapterTime = 200
        complete.books[0].totalChapterNum = 2
        let incoming = backupIsNewer ? complete : short
        let current = backupIsNewer ? short : complete
        try await original.service.apply(incoming, expected: original.service.snapshot())
        try await target.service.apply(current, expected: target.service.snapshot())
        let chapter = try #require(complete.chapters[complete.books[0].id]?.last)
        let cache = ChapterContentCache(directory: original.directory.appendingPathComponent("cache"))
        try await cache.save(.init(bookURL: chapter.bookUrl, chapterURL: chapter.url, title: chapter.title, content: "可离线续读的第二章", sourceID: complete.sources[0].id))
        let archive = try await original.service.export(includeLocalBooks: false)
        defer { try? FileManager.default.removeItem(at: archive) }
        let prepared = try await target.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try await target.service.restore(prepared)
        let restored = try await target.service.snapshot()
        let book = try #require(restored.books.first)
        #expect(book.durChapterIndex == 1)
        #expect(book.durChapterPos == 12)
        #expect(restored.chapters[book.id] == complete.chapters[book.id])
        let targetCache = ChapterContentCache(directory: target.directory.appendingPathComponent("cache"))
        #expect(try await targetCache.load(bookURL: book.id, chapterURL: chapter.url) == nil)
    }

    @Test func newerLocalEPUBLocatorIsKeptWhenMergingAnOlderSnapshot() throws {
        var local = snapshot(); var older = local
        local.books[0].durChapterTime = 200; local.books[0].readConfig = BookReadConfig()
        local.books[0].readConfig?.epubLocation = "newer-locator"
        older.books[0].durChapterTime = 100; older.books[0].readConfig = BookReadConfig()
        older.books[0].readConfig?.epubLocation = "older-locator"
        #expect(local.merging(older).books[0].readConfig?.epubLocation == "newer-locator")
    }

    @Test func readingStatisticsSurviveMetadataArchiveAndRepeatedRestore() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        var value = snapshot()
        value.records = [
            .init(deviceId: "phone", bookName: value.books[0].name, readTime: 180_000, lastRead: 200,
                  dailyReadTimes: ["2026-10-27": 60_000, "2026-10-28": 120_000]),
            .init(deviceId: "tablet", bookName: value.books[0].name, readTime: 30_000, lastRead: 100,
                  dailyReadTimes: ["2026-10-28": 30_000])
        ]
        try await original.service.apply(value, expected: original.service.snapshot())
        let url = try await original.service.export(includeLocalBooks: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await target.service.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(Set(prepared.manifest.snapshot.records) == Set(value.records))
        try await target.service.restore(prepared)
        try await target.service.restore(prepared)
        let restored = try await target.database.loadReadRecords()
        #expect(Set(restored) == Set(value.records))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 28)))
        let statistics = ReadingActivityService().statistics(restored, now: now, calendar: calendar)
        #expect(statistics.totalReadTime == 210_000)
        #expect(statistics.todayReadTime == 150_000)
        #expect(statistics.currentStreak == 2)
        #expect(statistics.bookCount == 1)
    }

    @Test func restoringOlderArchivePreservesLocalStatisticsAndHistory() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        var older = snapshot()
        older.records = [.init(deviceId: "phone", bookName: "统计测试", readTime: 60_000, lastRead: 100,
                               dailyReadTimes: ["2026-10-27": 60_000])]
        older.searchKeywords = [.init(word: "统计测试", usage: 2, lastUseTime: 100)]
        older.rssReadRecords = [.init(record: "https://example.test/article", readTime: 100, durPos: 10)]
        try await original.service.apply(older, expected: original.service.snapshot())
        var current = older
        current.records[0].readTime = 180_000; current.records[0].lastRead = 200
        current.records[0].dailyReadTimes["2026-10-28"] = 120_000
        current.records.append(.init(deviceId: "tablet", bookName: "统计测试", readTime: 30_000, lastRead: 150,
                                     dailyReadTimes: ["2026-10-28": 30_000]))
        current.searchKeywords = [.init(word: "统计测试", usage: 5, lastUseTime: 200), .init(word: "本机搜索", lastUseTime: 300)]
        current.rssReadRecords[0].readTime = 200; current.rssReadRecords[0].durPos = 20
        try await target.service.apply(current, expected: target.service.snapshot())
        let archive = try await original.service.export(includeLocalBooks: false)
        defer { try? FileManager.default.removeItem(at: archive) }
        let prepared = try await target.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try await target.service.restore(prepared)
        try await target.service.restore(prepared)
        let restored = try await target.service.snapshot()
        #expect(Set(restored.records) == Set(current.records))
        #expect(Set(restored.searchKeywords) == Set(current.searchKeywords))
        #expect(restored.rssReadRecords == current.rssReadRecords)
        #expect(ReadingActivityService().statistics(restored.records).totalReadTime == 210_000)
    }

    @Test func historyMetadataRoundTripsAndOldArchivesKeepLocalHistory() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var value = snapshot()
        value.searchKeywords = [.init(word: "历史关键词", usage: 7, lastUseTime: 500)]
        value.rssReadRecords = [.init(record: "https://example.test/history", title: "已读文章", readTime: 500, durPos: 42)]
        try await fixture.service.apply(value, expected: fixture.service.snapshot())
        #expect(try await fixture.database.loadSearchKeywords(order: .lastUseTime) == value.searchKeywords)
        #expect(try await fixture.database.loadRssReadRecords() == value.rssReadRecords)
        var manifest = try #require(JSONSerialization.jsonObject(with: LibrarySnapshot.encode(
            LibraryBackupManifest(createdAt: Date(), snapshot: snapshot(), attachments: []))) as? [String: Any])
        var oldSnapshot = try #require(manifest["snapshot"] as? [String: Any])
        oldSnapshot.removeValue(forKey: "searchKeywords"); oldSnapshot.removeValue(forKey: "rssReadRecords")
        manifest["snapshot"] = oldSnapshot
        let data = try JSONSerialization.data(withJSONObject: manifest)
        var length = UInt64(data.count).bigEndian
        var bytes = Data("LGBK0001".utf8)
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: SHA256.hash(data: data)); bytes.append(data)
        let archive = fixture.directory.appendingPathComponent("legacy.legadobackup")
        try bytes.write(to: archive)
        let prepared = try await fixture.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.manifest.snapshot.searchKeywords.isEmpty)
        #expect(prepared.manifest.snapshot.rssReadRecords.isEmpty)
        try await fixture.service.restore(prepared)
        let restored = try await fixture.service.snapshot()
        #expect(restored.searchKeywords == value.searchKeywords)
        #expect(restored.rssReadRecords == value.rssReadRecords)
    }

    @Test func historyImportIsAtomicAndConcurrentHistoryCannotBeOverwritten() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = try await fixture.service.snapshot()
        var incoming = snapshot()
        incoming.searchKeywords = [.init(word: "导入搜索", usage: 2, lastUseTime: 100)]
        incoming.rssReadRecords = [.init(record: "https://example.test/restore", readTime: 100)]
        var handle: OpaquePointer?
        #expect(sqlite3_open(fixture.directory.appendingPathComponent("library.sqlite3").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER fail_history BEFORE INSERT ON rssReadRecords BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: (any Error).self) { try await fixture.service.apply(incoming, expected: before) }
        #expect(try await fixture.service.snapshot() == before)
        #expect(sqlite3_exec(handle, "DROP TRIGGER fail_history", nil, nil, nil) == SQLITE_OK)
        _ = try await fixture.database.recordSearchKeyword("并发搜索", at: 200)
        await #expect(throws: LibraryBackupError.changed) { try await fixture.service.apply(incoming, expected: before) }
        #expect(try await fixture.database.loadSearchKeywords(order: .lastUseTime).map(\.word) == ["并发搜索"])
        #expect(try await fixture.database.loadRssReadRecords().isEmpty)
    }

    @Test func invalidStatisticsAreRejectedBeforeAnyRestoreMutation() async throws {
        let invalidRecords: [[ReadRecord]] = [
            [.init(deviceId: "A", bookName: "测试", readTime: -1)],
            [.init(deviceId: "A", bookName: "测试", dailyReadTimes: ["2026-10-28": -1])],
            [.init(deviceId: "A", bookName: "测试", readTime: Int64.max), .init(deviceId: "B", bookName: "测试", readTime: 1)],
            [.init(deviceId: "A", bookName: "测试", dailyReadTimes: ["2026-10-28": Int64.max]),
             .init(deviceId: "B", bookName: "测试", dailyReadTimes: ["2026-10-28": 1])],
            [.init(deviceId: "A", bookName: "测试", dailyReadTimes: ["2026-10-27": Int64.max, "2026-10-28": 1])]
        ]
        for records in invalidRecords {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let before = try await fixture.service.snapshot()
            var incoming = snapshot(); incoming.records = records
            await #expect(throws: (any Error).self) { try await fixture.service.apply(incoming, expected: before) }
            #expect(try await fixture.service.snapshot() == before)
        }
    }

    @Test func truncatedTamperedAndTraversalArchivesAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let url = fixture.directory.appendingPathComponent("archive.legadobackup")
        try LibraryBackupArchive.write(snapshot: snapshot(), files: [:], to: url)
        let good = try Data(contentsOf: url)
        try Data(good.dropLast()).write(to: url)
        #expect(throws: (any Error).self) { try LibraryBackupArchive.prepare(url) }
        var bad = good; bad[bad.count - 1] ^= 1
        try bad.write(to: url)
        #expect(throws: (any Error).self) { try LibraryBackupArchive.prepare(url) }
        var manifest = LibraryBackupManifest(createdAt: Date(), snapshot: snapshot(), attachments: [])
        manifest.attachments = [.init(path: "local/../../outside.txt", bytes: 0, checksum: String(repeating: "0", count: 64))]
        let encoded = try LibrarySnapshot.encode(manifest)
        var length = UInt64(encoded.count).bigEndian
        var bytes = Data("LGBK0001".utf8)
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: SHA256.hash(data: encoded)); bytes.append(encoded)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try LibraryBackupArchive.prepare(url) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    @Test func failedDatabaseImportRollsBackTheShelf() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = try await fixture.service.snapshot()
        var handle: OpaquePointer?
        #expect(sqlite3_open(fixture.directory.appendingPathComponent("library.sqlite3").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER fail_backup BEFORE INSERT ON book_sources BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: (any Error).self) { try await fixture.service.apply(snapshot(), expected: before) }
        #expect(try await fixture.service.snapshot() == before)
    }

    @Test func staleSnapshotCannotOverwriteAConcurrentLocalWrite() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let old = try await fixture.service.snapshot()
        let newer = Book(bookUrl: "https://source.example/new", name: "刚加入的新书", origin: "https://source.example")
        try await fixture.database.replaceBooks([newer])
        await #expect(throws: LibraryBackupError.changed) { try await fixture.service.apply(snapshot(), expected: old) }
        #expect(try await fixture.database.loadBooks() == [newer])
    }

    @Test func restoreRetainsNewerProgressAndExistingAlternateSource() {
        var local = snapshot(); local.books[0].durChapterIndex = 8; local.books[0].durChapterTime = 200
        var older = snapshot(); older.books[0].durChapterIndex = 2; older.books[0].durChapterTime = 100
        #expect(local.merging(older).books[0].durChapterIndex == 8)
        older.books[0].bookUrl = "https://other.example/book"
        #expect(local.merging(older).books.count == 1)
        #expect(local.merging(older).books[0].id == local.books[0].id)
        var tied = local
        tied.books[0].durChapterIndex = 1
        #expect(local.merging(tied).books[0].durChapterIndex == 8)
        let oldDirectory = local.chapters
        older = snapshot(); older.chapters[older.books[0].id] = []
        #expect(local.merging(older).chapters == oldDirectory)
    }

    @Test func untrustedChapterPositionsAreRejectedBeforeRestoring() throws {
        var value = snapshot(); value.books[0].durChapterIndex = Int.max
        #expect(throws: (any Error).self) { try value.validated() }
        value = snapshot(); value.bookmarks[0].chapterPosition = Int.max
        #expect(throws: (any Error).self) { try value.validated() }
    }

    @Test func fullBackupRecoversMissingLocalAttachment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("LocalBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("original.txt")
        try Data("测试正文".utf8).write(to: url)
        var local = LibrarySnapshot()
        local.books = [Book(bookUrl: url.absoluteString, name: "测试 TXT", origin: "local")]
        try await fixture.service.apply(local, expected: fixture.service.snapshot())
        let archive = try await fixture.service.export(includeLocalBooks: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        try FileManager.default.removeItem(at: url)
        let prepared = try await fixture.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try await fixture.service.restore(prepared)
        let restored = try #require(try await fixture.service.snapshot().books.first)
        let restoredURL = try #require(URL(string: restored.id))
        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
        #expect(try Data(contentsOf: restoredURL) == Data("测试正文".utf8))
    }

    @Test func concurrentChapterRefreshSurvivesImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.service.apply(snapshot(), expected: fixture.service.snapshot())
        let before = try await fixture.service.snapshot()
        let id = before.books[0].id
        var directory = before.chapters[id]!
        directory.append(.init(url: "second", title: "第二章", bookUrl: id, index: 1))
        try await fixture.database.replaceChapters(directory, bookURL: id)
        do { try await fixture.service.apply(before, expected: before) } catch LibraryBackupError.changed { }
        #expect(try await fixture.database.loadChapters(bookURL: id).count == 2)
    }

    @Test(arguments: ["txt", "epub"], [true, false])
    func missingCrossDeviceLocalFileRestoresBytesAndNewestProgress(_ fileExtension: String, _ backupIsNewer: Bool) async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let file = original.directory.appendingPathComponent("LocalBooks/original.\(fileExtension)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("经备份校验的合成书籍附件".utf8)
        try bytes.write(to: file)
        var backup = LibrarySnapshot()
        backup.books = [.init(bookUrl: file.absoluteString, name: "缺失文件恢复")]
        backup.books[0].tocUrl = file.absoluteString
        backup.books[0].durChapterTime = 200; backup.books[0].durChapterPos = 12
        backup.books[0].readConfig = BookReadConfig()
        backup.books[0].readConfig?.epubLocation = fileExtension == "epub" ? "backup-location" : nil
        backup.chapters[file.absoluteString] = [.init(url: file.absoluteString + "#one", title: "第一章", bookUrl: file.absoluteString, index: 0)]
        try await original.service.apply(backup, expected: original.service.snapshot())
        let missing = target.directory.appendingPathComponent("LocalBooks/missing.\(fileExtension)").absoluteString
        var local = backup
        local.books[0].bookUrl = missing; local.books[0].tocUrl = missing
        local.books[0].durChapterTime = backupIsNewer ? 100 : 300
        local.books[0].durChapterPos = 42
        local.books[0].readConfig?.epubLocation = fileExtension == "epub" ? "local-location" : nil
        local.chapters = [missing: [.init(url: missing + "#one", title: "第一章", bookUrl: missing, index: 0)]]
        try await target.service.apply(local, expected: target.service.snapshot())
        let archive = try await original.service.export(includeLocalBooks: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let prepared = try await target.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try await target.service.restore(prepared)
        try await target.service.restore(prepared)
        let restored = try await target.service.snapshot()
        let book = try #require(restored.books.first)
        #expect(restored.books.count == 1)
        #expect(book.id != missing)
        #expect(book.tocUrl == book.id)
        #expect(book.durChapterTime == (backupIsNewer ? 200 : 300))
        #expect(book.durChapterPos == (backupIsNewer ? 12 : 42))
        #expect(book.readConfig?.epubLocation == (backupIsNewer ? backup : local).books[0].readConfig?.epubLocation)
        #expect(restored.chapters[book.id]?.first?.url == book.id + "#one")
        #expect(try Data(contentsOf: #require(URL(string: book.id))) == bytes)
    }

    @Test func missingLocalFileWithoutAttachmentFailsWithoutChangingLibrary() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var value = LibrarySnapshot()
        value.books = [.init(bookUrl: fixture.directory.appendingPathComponent("missing.txt").absoluteString, name: "无附件")]
        try await fixture.service.apply(value, expected: fixture.service.snapshot())
        let before = try await fixture.service.snapshot()
        let archive = fixture.directory.appendingPathComponent("missing.legadobackup")
        try LibraryBackupArchive.write(snapshot: value, files: [:], to: archive)
        await #expect(throws: (any Error).self) {
            let prepared = try await fixture.service.prepare(archive)
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            try await fixture.service.restore(prepared)
        }
        #expect(try await fixture.service.snapshot() == before)
    }


    @Test func portableRulesComeFromTheCurrentDatabaseAndSurviveRepeatedRestore() async throws {
        let original = try Fixture()
        let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let rule = ReplaceRule(id: 42, name: "修改后的规则", pattern: "新")
        let obsolete = ReplaceRule(id: 42, name: "旧规则", pattern: "旧")
        try JSONEncoder().encode([obsolete]).write(to: original.directory.appendingPathComponent("replace-rules.json"))
        try await original.database.storeRules([rule])
        let file = try await original.service.export(includeLocalBooks: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let backup = try await target.service.prepare(file)
        #expect(backup.manifest.snapshot.replaceRules == [rule])
        try await target.service.restore(backup)
        try await target.service.restore(backup)
        let reopened = try LegadoDatabase(url: target.directory.appendingPathComponent("library.sqlite3"))
        #expect(try await reopened.storedRules(legacyURL: target.directory.appendingPathComponent("replace-rules.json")) == [rule])
    }

    @Test func restoresGroupMembershipWhenDevicesReuseTheSameGroupBit() async throws {
        let original = try Fixture()
        let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        try await target.database.replaceBookGroups([.init(groupId: 1, groupName: "本机分组")])
        var incoming = snapshot()
        incoming.groups = [.init(groupId: 1, groupName: "科幻")]
        incoming.books[0].group = 1
        try await original.service.apply(incoming, expected: original.service.snapshot())
        let file = try await original.service.export(includeLocalBooks: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let backup = try await target.service.prepare(file)
        try await target.service.restore(backup)
        try await target.service.restore(backup)
        let result = try await target.service.snapshot()
        #expect(result.groups.count == 2)
        #expect(result.groups.first { $0.id == 1 }?.groupName == "本机分组")
        #expect(result.books.first?.group == result.groups.first { $0.groupName == "科幻" }?.id)
    }

    @Test func restoringNewerProgressUpdatesTotalChapterNumAndLatestTitle() throws {
        var local = snapshot()
        local.books[0].durChapterIndex = 0
        local.books[0].durChapterTime = 100
        local.books[0].totalChapterNum = 1
        local.books[0].latestChapterTitle = "第一章"

        var backup = local
        backup.chapters[backup.books[0].id] = [
            .init(url: "https://source.example/ch1", title: "第一章", bookUrl: backup.books[0].id, index: 0),
            .init(url: "https://source.example/ch2", title: "第二章", bookUrl: backup.books[0].id, index: 1),
            .init(url: "https://source.example/ch3", title: "第三章", bookUrl: backup.books[0].id, index: 2)
        ]
        backup.books[0].durChapterIndex = 2
        backup.books[0].durChapterTitle = "第三章"
        backup.books[0].durChapterTime = 300
        backup.books[0].totalChapterNum = 3
        backup.books[0].latestChapterTitle = "第三章"
        backup.books[0].latestChapterTime = 300

        let merged = local.merging(backup)
        let book = try #require(merged.books.first)
        #expect(book.durChapterIndex == 2)
        #expect(book.totalChapterNum == 3)
        #expect(book.latestChapterTitle == "第三章")
        #expect(merged.chapters[book.id]?.count == 3)
    }

    @Test func restoringOlderArchivePreservesLocalRSSBookmarksAndConfigRules() throws {
        var local = snapshot()
        local.bookmarks = [.init(time: 123, bookName: local.books[0].name)]
        local.bookmarks[0].content = "本机修改的笔记"
        local.rssSources = [.init(sourceUrl: "https://rss.example", sourceName: "本机RSS")]
        local.txtRules = [.init(id: 1, name: "本机目录规则", rule: "^第.+章")]
        local.tts = [.init(id: 1, name: "本机朗读")]
        local.subscriptions = [.init(id: 1, name: "本机订阅", url: "https://sub.example")]
        local.keyboardAssists = [.init(type: 0, key: "k", value: "本机")]

        var older = snapshot()
        older.bookmarks = [.init(time: 123, bookName: older.books[0].name), .init(time: 456, bookName: older.books[0].name)]
        older.bookmarks[0].content = "旧备份笔记"
        older.rssSources = [.init(sourceUrl: "https://rss.example", sourceName: "旧备份RSS"), .init(sourceUrl: "https://rss2.example", sourceName: "新增RSS")]
        older.txtRules = [.init(id: 1, name: "旧目录规则", rule: "^old")]
        older.tts = [.init(id: 1, name: "旧朗读")]
        older.subscriptions = [.init(id: 1, name: "旧订阅", url: "https://old.example")]
        older.keyboardAssists = [.init(type: 0, key: "k", value: "旧值")]

        let merged = local.merging(older)
        #expect(merged.bookmarks.count == 2)
        #expect(merged.bookmarks.first { $0.id == 123 }?.content == "本机修改的笔记")
        #expect(merged.rssSources.count == 2)
        #expect(merged.rssSources.first { $0.id == "https://rss.example" }?.sourceName == "本机RSS")
        #expect(merged.txtRules.first { $0.id == 1 }?.name == "本机目录规则")
        #expect(merged.tts.first { $0.id == 1 }?.name == "本机朗读")
        #expect(merged.subscriptions.first { $0.id == 1 }?.name == "本机订阅")
        #expect(merged.keyboardAssists.first { $0.key == "k" }?.value == "本机")
    }

    @Test func exportRecoversStaleLocalContainerPathAndSkipsMissingFiles() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let localDir = fixture.directory.appendingPathComponent("LocalBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let actualFile = localDir.appendingPathComponent("recovered.txt")
        try Data("可恢复正文".utf8).write(to: actualFile)

        var value = snapshot()
        value.books.append(Book(bookUrl: "file:///var/mobile/Containers/Data/Application/OLD-UUID/Library/Application%20Support/Legado/LocalBooks/recovered.txt", name: "旧容器书", origin: "local"))
        value.books.append(Book(bookUrl: localDir.appendingPathComponent("gone.txt").absoluteString, name: "已删除书", origin: "local"))
        try await fixture.service.apply(value, expected: fixture.service.snapshot())

        let result = try await fixture.service.exportDetailed(includeLocalBooks: true)
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(result.skippedLocalBooks == ["已删除书"])
        let prepared = try await fixture.service.prepare(result.url)
        #expect(prepared.manifest.snapshot.books.map(\.name).sorted() == ["合成测试书", "旧容器书"])
        #expect(prepared.manifest.attachments.map(\.path) == ["local/recovered.txt"])
    }
}
