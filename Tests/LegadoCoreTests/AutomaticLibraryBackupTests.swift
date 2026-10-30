import Foundation
import Testing
@testable import LegadoCore

private actor AutomaticBackupStoreFixture: RemoteLibraryBackupStore {
    private var failures: Int
    private let suspend: Bool
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var attempts = 0
    private(set) var files: [Data] = []
    private(set) var lastURL: URL?
    init(failures: Int = 0, suspend: Bool = false) { self.failures = failures; self.suspend = suspend }
    func listBackups() async throws -> [RemoteLibraryBackup] { [] }
    func downloadBackup(_ backup: RemoteLibraryBackup) async throws -> URL { throw RemoteLibraryError.invalidResponse }
    func waitUntilStarted() async {
        if !hasStarted { await withCheckedContinuation { started = $0 } }
    }
    func uploadBackup(_ file: URL) async throws {
        attempts += 1; lastURL = file; hasStarted = true; started?.resume(); started = nil
        if suspend { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if failures > 0 { failures -= 1; throw URLError(.notConnectedToInternet) }
        files.append(try Data(contentsOf: file))
    }
}

@Suite struct AutomaticLibraryBackupTests {
    private struct Fixture {
        let directory: URL
        let suite: String
        let database: LegadoDatabase
        let service: LibraryBackupService
        var checkpoints: URL { directory.appendingPathComponent("automatic") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-backup-test-\(UUID().uuidString)")
            suite = "AutomaticBackupTest.\(UUID().uuidString)"
            database = try LegadoDatabase(url: directory.appendingPathComponent("library.sqlite3"))
            service = .init(database: database, support: directory, cache: directory.appendingPathComponent("cache"), defaultsSuite: suite)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    @Test func changedDataIsThrottledAndCheckpointsSurviveRestartWithAccountIsolation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var book = Book(bookUrl: "https://example.test/book", name: "自动备份测试", origin: "https://example.test")
        try await f.database.replaceBooks([book])
        let store = AutomaticBackupStoreFixture()
        let worker = AutomaticLibraryBackup(directory: f.checkpoints)
        let first = Date(timeIntervalSince1970: 100_000)
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: first) == .uploaded(first))
        book.durChapterPos = 20
        try await f.database.replaceBooks([book])
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: first.addingTimeInterval(60)) == .deferred(first))
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: first.addingTimeInterval(21599)) == .deferred(first))
        let later = first.addingTimeInterval(21600)
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: later) == .uploaded(later))
        let restarted = AutomaticLibraryBackup(directory: f.checkpoints)
        #expect(try await restarted.lastBackup(account: "google:A") == later)
        #expect(try await restarted.run(service: f.service, store: store, account: "google:A", now: later.addingTimeInterval(10)) == .deferred(later))
        #expect(try await restarted.run(service: f.service, store: store, account: "google:A", now: later.addingTimeInterval(21600)) == .unchanged(later))
        #expect(await store.files.count == 2)
        #expect(try await restarted.run(service: f.service, store: store, account: "google:B", now: later) == .uploaded(later))
        #expect(await store.files.count == 3)
    }

    @Test(arguments: [1, 30])
    func failedUploadDoesNotAdvanceSuccessAndRetriesAfterBackoff(_ minutes: Int) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let worker = AutomaticLibraryBackup(directory: f.checkpoints)
        let store = AutomaticBackupStoreFixture(failures: 1)
        let first = Date(timeIntervalSince1970: 100_000)
        await #expect(throws: URLError.self) { try await worker.run(service: f.service, store: store, account: "dav:A", now: first, intervalMinutes: minutes) }
        #expect(try await worker.lastBackup(account: "dav:A") == nil)
        let delay = TimeInterval(min(300, minutes * 60))
        #expect(try await worker.run(service: f.service, store: store, account: "dav:A", now: first.addingTimeInterval(delay - 1), intervalMinutes: minutes) == .deferred(nil))
        #expect(await store.attempts == 1)
        let retry = first.addingTimeInterval(delay)
        #expect(try await worker.run(service: f.service, store: store, account: "dav:A", now: retry, intervalMinutes: minutes) == .uploaded(retry))
        #expect(await store.attempts == 2)
        #expect(try await worker.lastBackup(account: "dav:A") == retry)
        let temporary = try #require(await store.lastURL)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test(arguments: [1, 15, 60, 1440, 10080])
    func selectedIntervalActuallyControlsUploadTiming(_ minutes: Int) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let worker = AutomaticLibraryBackup(directory: f.checkpoints)
        let store = AutomaticBackupStoreFixture()
        let first = Date(timeIntervalSince1970: 100_000)
        try await worker.run(service: f.service, store: store, account: "google:A", now: first, intervalMinutes: minutes)
        try await f.database.replaceBooks([Book(bookUrl: "https://example.test/changed", name: "间隔测试", origin: "https://example.test")])
        let delay = TimeInterval(minutes * 60)
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: first.addingTimeInterval(delay - 1), intervalMinutes: minutes) == .deferred(first))
        let due = first.addingTimeInterval(delay)
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: due, intervalMinutes: minutes) == .uploaded(due))
        #expect(await store.files.count == 2)
    }

    @Test func invalidStoredIntervalFallsBackToSixHours() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let worker = AutomaticLibraryBackup(directory: f.checkpoints)
        let store = AutomaticBackupStoreFixture()
        let first = Date(timeIntervalSince1970: 100_000)
        try await worker.run(service: f.service, store: store, account: "google:A", now: first, intervalMinutes: -1)
        try await f.database.replaceBooks([Book(bookUrl: "https://example.test/changed", name: "间隔测试", origin: "https://example.test")])
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: first.addingTimeInterval(21599), intervalMinutes: Int.max) == .deferred(first))
        let due = first.addingTimeInterval(21600)
        #expect(try await worker.run(service: f.service, store: store, account: "google:A", now: due, intervalMinutes: 0) == .uploaded(due))
    }

    @Test func cancellationCleansTemporaryFilesAndConcurrentTriggersCannotUploadTwice() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let worker = AutomaticLibraryBackup(directory: f.checkpoints)
        let store = AutomaticBackupStoreFixture(suspend: true)
        let task = Task { try await worker.run(service: f.service, store: store, account: "google:A") }
        await store.waitUntilStarted()
        await #expect(throws: LibraryCloudError.busy) { try await worker.run(service: f.service, store: store, account: "google:A") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await worker.lastBackup(account: "google:A") == nil)
        #expect(await store.attempts == 1)
        let file = try #require(await store.lastURL)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func automaticArchiveExcludesLocalBooksAndBodyFiles() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let local = Book(bookUrl: f.directory.appendingPathComponent("private.txt").absoluteString, name: "本地测试", origin: "local")
        let network = Book(bookUrl: "https://example.test/book", name: "合成网络书", origin: "https://example.test")
        try await f.database.replaceBooks([local, network])
        let store = AutomaticBackupStoreFixture()
        try await AutomaticLibraryBackup(directory: f.checkpoints).run(service: f.service, store: store, account: "google:A")
        let archive = f.directory.appendingPathComponent("download.legadobackup")
        let data = try #require(await store.files.first)
        try data.write(to: archive)
        let preview = try await f.service.prepare(archive)
        #expect(preview.manifest.attachments.isEmpty)
        #expect(preview.manifest.snapshot.books == [network])
        await f.service.cleanup(preview)
    }

    @Test func changedUserHistoryTriggersBackupAndRestoresStatistics() async throws {
        let original = try Fixture(); let target = try Fixture()
        defer { original.cleanup(); target.cleanup() }
        let worker = AutomaticLibraryBackup(directory: original.checkpoints)
        let store = AutomaticBackupStoreFixture()
        let first = Date(timeIntervalSince1970: 100_000)
        try await worker.run(service: original.service, store: store, account: "google:A", now: first)
        let record = ReadRecord(deviceId: "phone", bookName: "历史测试", readTime: 180_000, lastRead: 200,
                                dailyReadTimes: ["2026-10-28": 180_000])
        try await original.database.replaceReadRecords([record])
        _ = try await original.database.recordSearchKeyword("历史测试", at: 200)
        let rss = RssReadRecord(record: "https://example.test/article", readTime: 200, durPos: 18)
        try await original.database.appendRssReadRecords([rss])
        let due = first.addingTimeInterval(21_600)
        #expect(try await worker.run(service: original.service, store: store, account: "google:A", now: due) == .uploaded(due))
        #expect(await store.files.count == 2)
        let archive = target.directory.appendingPathComponent("automatic.legadobackup")
        let data = try #require(await store.files.last)
        try data.write(to: archive)
        let prepared = try await target.service.prepare(archive)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.manifest.attachments.isEmpty)
        try await target.service.restore(prepared)
        #expect(try await target.database.loadReadRecords() == [record])
        #expect(try await target.database.loadSearchKeywords(order: .lastUseTime).map(\.word) == ["历史测试"])
        #expect(try await target.database.loadRssReadRecords() == [rss])
    }
}
