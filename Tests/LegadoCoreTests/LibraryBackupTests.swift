import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import LegadoCore

@Suite struct LibraryBackupTests {
    private struct Fixture {
        let directory: URL
        let suite: String
        let database: LegadoDatabase
        let service: LibraryBackupService
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID().uuidString)")
            suite = "BackupTest.\(UUID().uuidString)"
            database = try LegadoDatabase(url: directory.appendingPathComponent("library.sqlite3"))
            service = .init(database: database, support: directory, cache: directory.appendingPathComponent("cache"), defaultsSuite: suite)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
    private func snapshot() -> LibrarySnapshot {
        var value = LibrarySnapshot()
        value.sources = [.init(bookSourceUrl: "https://source.example", bookSourceName: "测试源")]
        value.books = [.init(bookUrl: "https://source.example/book", name: "合成测试书", author: "测试作者", origin: value.sources[0].id)]
        value.chapters = [value.books[0].id: [.init(url: "https://source.example/ch1", title: "第一章", bookUrl: value.books[0].id, index: 0)]]
        value.bookmarks = [.init(time: 123, bookName: value.books[0].name)]
        value.preferences = ["textSize": .number(22), "themeMode": .string("2")]
        return value
    }

    @Test func completeArchiveRestoresFilesMetadataAndPortableLocalBookPaths() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        var value = snapshot()
        let localFile = original.directory.appendingPathComponent("LocalBooks/本地测试.txt")
        try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = String(repeating: "仅用于备份测试的合成正文。", count: 100_000)
        try Data(text.utf8).write(to: localFile)
        value.books.append(Book(bookUrl: localFile.absoluteString, name: "本地测试"))
        let empty = try await original.service.snapshot()
        try await original.service.apply(value, expected: empty)
        let chapter = value.chapters[value.books[0].id]![0]
        let cache = ChapterContentCache(directory: original.directory.appendingPathComponent("cache"))
        try await cache.save(.init(bookURL: value.books[0].id, chapterURL: chapter.url, title: chapter.title, content: "缓存测试正文", sourceID: value.sources[0].id))
        let exported = try await original.service.export(includeLocalBooks: true, includeCachedChapters: true)
        defer { try? FileManager.default.removeItem(at: exported) }
        let prepared = try await target.service.prepare(exported)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.manifest.attachments.count == 2)
        try await target.service.restore(prepared)
        let restored = try await target.service.snapshot()
        #expect(restored.sources == value.sources)
        #expect(restored.bookmarks == value.bookmarks)
        #expect(restored.preferences["textSize"] == .number(22))
        let local = try #require(restored.books.first { $0.origin == "local" })
        let restoredURL = try #require(URL(string: local.id))
        #expect(restoredURL.path.hasPrefix(target.directory.path))
        #expect(try String(contentsOf: restoredURL, encoding: .utf8) == text)
        let targetCache = ChapterContentCache(directory: target.directory.appendingPathComponent("cache"))
        #expect(try await targetCache.load(bookURL: value.books[0].id, chapterURL: chapter.url)?.content == "缓存测试正文")
        try await target.service.restore(prepared)
        #expect(try await target.database.loadBooks().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.directory.appendingPathComponent("LocalBooks").path).count == 1)
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
        let url = try await original.service.export(includeLocalBooks: true, includeCachedChapters: false)
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
        let url = try await fixture.service.export(includeLocalBooks: false, includeCachedChapters: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await fixture.service.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.manifest.snapshot.books.count == 1)
        #expect(prepared.manifest.attachments.isEmpty)
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
        let url = try await original.service.export(includeLocalBooks: false, includeCachedChapters: false)
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
        let archive = try await original.service.export(includeLocalBooks: false, includeCachedChapters: false)
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
        #expect(try LibrarySnapshot(syncEntries: value.syncEntries()) == value.cloudEligible)
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

    @Test func syncKeepsCumulativeStatisticsFromBothSidesWithoutDoubleCounting() throws {
        var initial = snapshot()
        initial.records = [.init(deviceId: "phone", bookName: "统计测试", readTime: 60_000, lastRead: 100,
                                 dailyReadTimes: ["2026-10-27": 60_000])]
        let baseline = try LibrarySyncDocument.reconcile(local: initial, baseline: .init(), remote: .init(), device: "A", now: 1)
        var newer = initial
        newer.records[0].readTime = 180_000; newer.records[0].lastRead = 200
        newer.records[0].dailyReadTimes["2026-10-28"] = 120_000
        let remote = try LibrarySyncDocument.reconcile(local: newer, baseline: baseline, remote: baseline, device: "A", now: 2)
        let firstBind = try LibrarySyncDocument.reconcile(local: newer, baseline: .init(), remote: baseline, device: "B", now: 3)
        #expect(try firstBind.snapshot.records == newer.records)
        var offline = initial; offline.records[0].readTime = 90_000; offline.records[0].lastRead = 150
        offline.records[0].dailyReadTimes["2026-10-28"] = 30_000
        let merged = try LibrarySyncDocument.reconcile(local: offline, baseline: baseline, remote: remote, device: "B", now: 300)
        #expect(try merged.snapshot.records == newer.records)
        let unchanged = try LibrarySyncDocument.reconcile(local: merged.snapshot, baseline: merged, remote: merged, device: "B", now: 400)
        #expect(unchanged == merged)
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

    @Test func failedDatabaseImportRollsBackBooksPreferencesAndRules() async throws {
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
        let oldDirectory = local.chapters
        older = snapshot(); older.chapters[older.books[0].id] = []
        #expect(local.merging(older).chapters == oldDirectory)
    }

    @Test func interruptedImportRollsBackExternalFilesWhenDatabaseDidNotCommit() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let journal = LibraryImportJournal(id: "interrupted", oldPreferences: ["textSize": .number(20)],
            newPreferences: ["textSize": .number(30)], oldRules: [], newRules: [.init(id: 1, name: "测试", pattern: "x")])
        try LibrarySnapshot.encode(journal).write(to: fixture.directory.appendingPathComponent("library-import-journal.json"))
        try LibrarySnapshot.encode(journal.newRules).write(to: fixture.directory.appendingPathComponent("replace-rules.json"))
        UserDefaults(suiteName: fixture.suite)!.set(30, forKey: "textSize")
        try await fixture.service.recoverInterruptedImport()
        let recovered = try await fixture.service.snapshot()
        #expect(recovered.preferences["textSize"] == .number(20)); #expect(recovered.replaceRules.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("library-import-journal.json").path))
    }

    @Test func interruptedImportFinishesExternalFilesAfterDatabaseCommit() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let old = try await fixture.service.snapshot()
        let journal = LibraryImportJournal(id: "committed", oldPreferences: [:], newPreferences: ["textSize": .number(26)],
            oldRules: [], newRules: [.init(id: 2, name: "测试", pattern: "x")])
        try LibrarySnapshot.encode(journal).write(to: fixture.directory.appendingPathComponent("library-import-journal.json"))
        try await fixture.database.applyLibrarySnapshot(snapshot(), expected: old, transactionID: journal.id)
        try await fixture.service.recoverInterruptedImport()
        let recovered = try await fixture.service.snapshot()
        #expect(recovered.books.count == 1); #expect(recovered.preferences["textSize"] == .number(26))
        #expect(recovered.replaceRules == journal.newRules)
    }

    @Test func journalCleanupFailureCannotRemoveAlreadyCommittedBookFiles() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let source = original.directory.appendingPathComponent("LocalBooks/本地测试.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("合成正文".utf8).write(to: source)
        var value = snapshot(); value.books.append(.init(bookUrl: source.absoluteString, name: "本地测试"))
        try await original.service.apply(value, expected: original.service.snapshot())
        let archive = try await original.service.export(includeLocalBooks: true, includeCachedChapters: false)
        defer { try? FileManager.default.removeItem(at: archive) }
        let prepared = try await target.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let cannotClean = LibraryBackupService(database: target.database, support: target.directory,
            cache: target.directory.appendingPathComponent("cache"), defaultsSuite: target.suite,
            removeJournal: { _ in throw CocoaError(.fileWriteNoPermission) })
        try await cannotClean.restore(prepared)
        let book = try #require(try await target.database.loadBooks().first { $0.origin == "local" })
        #expect(FileManager.default.fileExists(atPath: try #require(URL(string: book.id)).path))
        try await target.service.recoverInterruptedImport()
        #expect(try await target.service.snapshot().books.count == 2)
    }

    @Test func invalidPreferencesAreRejectedBeforeAnyMutation() throws {
        let suite = "BackupPrefs.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(20, forKey: "textSize")
        #expect(throws: (any Error).self) { try LibraryPreferences.write(["textSize": .null], to: defaults) }
        #expect(throws: (any Error).self) { try LibraryPreferences.write(["legado.icloud.account": .string("other")], to: defaults) }
        #expect(defaults.integer(forKey: "textSize") == 20)
        defaults.set("private", forKey: "loginCookie")
        #expect(try LibraryPreferences.read(defaults)["loginCookie"] == nil)
    }

    @Test func offlineEditsMergeAndDeletedSourcesDoNotResurrect() throws {
        let initial = snapshot()
        let baseline = try LibrarySyncDocument.reconcile(local: initial, baseline: .init(), remote: .init(), device: "A", now: 1)
        var a = initial; a.books[0].durChapterIndex = 7; a.books[0].durChapterTime = 200; a.sources = []
        let changedA = try LibrarySyncDocument.reconcile(local: a, baseline: baseline, remote: baseline, device: "A", now: 2)
        var b = initial; b.preferences["textSize"] = .number(25)
        let merged = try LibrarySyncDocument.reconcile(local: b, baseline: baseline, remote: changedA, device: "B", now: 3)
        #expect(try merged.snapshot.sources.isEmpty)
        #expect(try merged.snapshot.books[0].durChapterIndex == 7)
        #expect(try merged.snapshot.preferences["textSize"] == .number(25))
        #expect(merged.items["sources|https://source.example"]?.value == nil)
    }

    @Test func firstBindUsesCloudSettingsAndRetainsNewerLocalProgress() throws {
        var remote = snapshot(); remote.books[0].durChapterTime = 100
        let document = try LibrarySyncDocument.reconcile(local: remote, baseline: .init(), remote: .init(), device: "A", now: 1)
        var local = snapshot(); local.preferences["textSize"] = .number(18)
        local.books[0].durChapterIndex = 9; local.books[0].durChapterTime = 200
        let merged = try LibrarySyncDocument.reconcile(local: local, baseline: .init(), remote: document, device: "B", now: 10)
        #expect(try merged.snapshot.preferences["textSize"] == .number(22))
        #expect(try merged.snapshot.books[0].durChapterIndex == 9)
    }

    @Test func anOlderOfflineReadSyncedLaterCannotRewindNewerReadingProgress() throws {
        let initial = snapshot()
        let baseline = try LibrarySyncDocument.reconcile(local: initial, baseline: .init(), remote: .init(), device: "A", now: 1)
        var newer = initial; newer.books[0].durChapterIndex = 9; newer.books[0].durChapterTime = 200
        let remote = try LibrarySyncDocument.reconcile(local: newer, baseline: baseline, remote: baseline, device: "A", now: 2)
        var older = initial; older.books[0].durChapterIndex = 2; older.books[0].durChapterTime = 150
        let merged = try LibrarySyncDocument.reconcile(local: older, baseline: baseline, remote: remote, device: "B", now: 300)
        #expect(try merged.snapshot.books[0].durChapterIndex == 9)
    }

    @Test func maliciousCloudVersionCannotOverflowRevisionClock() throws {
        var document = LibrarySyncDocument()
        document.items["sources|x"] = .init(value: nil, revision: Int64.max, device: "other")
        #expect(throws: (any Error).self) { try LibrarySyncDocument.reconcile(local: snapshot(), baseline: .init(), remote: document, device: "A", now: 10) }
    }

    @Test func untrustedChapterPositionsAreRejectedBeforeRestoring() throws {
        var value = snapshot(); value.books[0].durChapterIndex = Int.max
        #expect(throws: (any Error).self) { try value.validated() }
        value = snapshot(); value.bookmarks[0].chapterPosition = Int.max
        #expect(throws: (any Error).self) { try value.validated() }
    }

    @Test func cloudConflictRetriesAndNetworkFailurePreservesLocalData() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = try await fixture.service.snapshot()
        try await fixture.service.apply(snapshot(), expected: before)
        let cloud = FakeCloud(); await cloud.failOneSave()
        let sync = LibrarySyncCoordinator(service: fixture.service, cloud: cloud, directory: fixture.directory.appendingPathComponent("Sync"), device: "A")
        try await sync.synchronize(account: "account")
        #expect(await cloud.saveCount == 2)
        let saved = try await fixture.service.snapshot()
        await cloud.failFetch()
        await #expect(throws: (any Error).self) { try await sync.synchronize(account: "account") }
        #expect(try await fixture.service.snapshot() == saved)
    }

    @Test func accountSwitchStopsBeforeUploading() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.service.apply(snapshot(), expected: fixture.service.snapshot())
        let cloud = FakeCloud(); await cloud.changeAccountOnSecondCheck()
        let sync = LibrarySyncCoordinator(service: fixture.service, cloud: cloud, directory: fixture.directory.appendingPathComponent("Sync"), device: "A")
        await #expect(throws: LibraryCloudError.accountChanged) { try await sync.synchronize(account: "account") }
        #expect(await cloud.saveCount == 0)
    }

    private actor FakeCloud: LibraryCloudTransport {
        var document = LibrarySyncDocument(); var revision = 0; var saveCount = 0
        var conflict = false; var offline = false; var switchesAccount = false; var accountChecks = 0
        func failOneSave() { conflict = true }
        func failFetch() { offline = true }
        func changeAccountOnSecondCheck() { switchesAccount = true }
        func accountIdentifier() -> String { accountChecks += 1; return switchesAccount && accountChecks > 1 ? "other" : "account" }
        func fetch() throws -> LibraryCloudVersion {
            if offline { throw LibraryCloudError.unavailable("合成离线测试") }
            return .init(document: document, token: revision == 0 ? nil : Data("\(revision)".utf8))
        }
        func save(_ document: LibrarySyncDocument, replacing token: Data?) throws {
            saveCount += 1
            if conflict { conflict = false; revision += 1; throw LibraryCloudError.conflict }
            guard token == (revision == 0 ? nil : Data("\(revision)".utf8)) else { throw LibraryCloudError.conflict }
            self.document = document; revision += 1
        }
    }
}
