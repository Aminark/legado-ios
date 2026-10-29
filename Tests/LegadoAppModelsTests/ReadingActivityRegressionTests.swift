import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ReadingActivityRegressionTests {
    @Test func overlappingBookmarkAddsKeepBothEntriesOnDisk() async throws {
        let repository = PausedActivityRepository(pauseBookmarks: true)
        let model = ReadingActivityModel(repository: repository, deviceID: "test")
        let book = Book(bookUrl: "https://book.test", name: "测试书")
        let chapter = BookChapter(url: "https://book.test/1", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let first = Task { await model.addBookmark(book: book, chapter: chapter, position: 10, content: "正文") }
        try await repository.waitUntilPaused()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await model.addBookmark(book: book, chapter: chapter, position: 20, content: "正文")
        }
        while !secondStarted { await Task.yield() }
        await repository.resume()
        await first.value
        await second.value
        #expect(model.bookmarks.map(\.chapterPosition) == [10, 20])
        #expect(await repository.loadBookmarks().map(\.chapterPosition).sorted() == [10, 20])
    }

    @Test func clearingHistoryDuringCheckpointDoesNotRestoreDeletedRecords() async throws {
        let repository = PausedActivityRepository(pauseBookmarks: false)
        let model = ReadingActivityModel(repository: repository, deviceID: "test")
        let book = Book(bookUrl: "https://book.test", name: "测试书")
        let start = Date(timeIntervalSince1970: 1_000)
        model.beginReading(book, now: start)
        let checkpoint = Task { await model.checkpoint(book, now: start.addingTimeInterval(20)) }
        try await repository.waitUntilPaused()
        var clearStarted = false
        let clear = Task {
            clearStarted = true
            await model.clearHistory()
        }
        while !clearStarted { await Task.yield() }
        await repository.resume()
        await checkpoint.value
        await clear.value
        #expect(model.readRecords.isEmpty)
        #expect(await repository.loadReadRecords().isEmpty)
    }

    @Test func failedBookmarkSaveRestoresPreviouslySavedEntries() async throws {
        let repository = PausedActivityRepository(pauseBookmarks: true, failSave: true)
        let model = ReadingActivityModel(repository: repository, deviceID: "test")
        let book = Book(bookUrl: "https://book.test", name: "测试书")
        let chapter = BookChapter(url: "https://book.test/1", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let save = Task { await model.addBookmark(book: book, chapter: chapter, position: 10, content: "正文") }
        try await repository.waitUntilPaused()
        await repository.resume()
        await save.value
        #expect(model.bookmarks.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(await repository.loadBookmarks().isEmpty)
    }

    @Test func nextCheckpointRetriesElapsedTimeFromAFailedSave() async throws {
        let repository = PausedActivityRepository(pauseBookmarks: false, failSave: true)
        let model = ReadingActivityModel(repository: repository, deviceID: "test")
        let book = Book(bookUrl: "https://book.test", name: "测试书")
        let start = Date(timeIntervalSince1970: 1_000)
        model.beginReading(book, now: start)
        let checkpoint = Task { await model.checkpoint(book, now: start.addingTimeInterval(20)) }
        try await repository.waitUntilPaused()
        await repository.resume()
        await checkpoint.value
        #expect(model.errorMessage != nil)
        #expect(model.readRecords.first?.readTime == 20_000)
        await model.checkpoint(book, now: start.addingTimeInterval(30))
        #expect(await repository.loadReadRecords().first?.readTime == 30_000)
    }
}

private actor PausedActivityRepository: ReadingActivityRepository {
    private var bookmarks: [Bookmark] = []
    private var records: [ReadRecord] = []
    private let pauseBookmarks: Bool
    private var failSave: Bool
    private var hasPaused = false
    private var pending: CheckedContinuation<Void, Never>?

    init(pauseBookmarks: Bool, failSave: Bool = false) {
        self.pauseBookmarks = pauseBookmarks
        self.failSave = failSave
    }
    func loadBookmarks() -> [Bookmark] { bookmarks }
    func loadReadRecords() -> [ReadRecord] { records }
    func saveBookmarks(_ values: [Bookmark]) async throws {
        if pauseBookmarks { await pauseFirstSave() }
        if failSave { failSave = false; throw CocoaError(.fileWriteUnknown) }
        bookmarks = values
    }
    func saveReadRecords(_ values: [ReadRecord]) async throws {
        if !pauseBookmarks { await pauseFirstSave() }
        if failSave { failSave = false; throw CocoaError(.fileWriteUnknown) }
        records = values
    }
    private func pauseFirstSave() async {
        guard !hasPaused else { return }
        hasPaused = true
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if pending != nil { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw URLError(.timedOut)
    }
    func resume() { pending?.resume(); pending = nil }
}
