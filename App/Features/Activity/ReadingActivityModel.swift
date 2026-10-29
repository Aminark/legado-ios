import Foundation
import Combine
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class ReadingActivityModel: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var readRecords: [ReadRecord] = []
    @Published private(set) var errorMessage: String?

    private let repository: any ReadingActivityRepository
    private let service = ReadingActivityService()
    private let deviceID: String
    private var sessions: [String: Date] = [:]
    private var bookmarkSaveTask: Task<Void, Never>?
    private var bookmarkSaveGeneration = 0
    private var persistedBookmarks: [Bookmark] = []
    private var recordSaveTask: Task<Void, Never>?
    private var recordSaveGeneration = 0
    private var persistedRecords: [ReadRecord] = []

    init(repository: any ReadingActivityRepository, deviceID: String) {
        self.repository = repository
        self.deviceID = deviceID
    }

    static func live() -> ReadingActivityModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        let key = "legado.reading.device-id"
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(identifier, forKey: key)
        let bookmarksURL = base.appendingPathComponent("bookmarks.json")
        let recordsURL = base.appendingPathComponent("read-records.json")
        let repository: any ReadingActivityRepository
        if let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) {
            repository = SQLiteReadingActivityRepository(
                database: database,
                legacyBookmarksURL: bookmarksURL,
                legacyRecordsURL: recordsURL
            )
        } else {
            repository = FileReadingActivityRepository(bookmarksURL: bookmarksURL, recordsURL: recordsURL)
        }
        return ReadingActivityModel(repository: repository, deviceID: identifier)
    }

    static func demo(bookmarks: [Bookmark] = [], records: [ReadRecord] = []) -> ReadingActivityModel {
        ReadingActivityModel(
            repository: InMemoryReadingActivityRepository(bookmarks: bookmarks, records: records),
            deviceID: "ios-simulator"
        )
    }

    var summaries: [ReadRecordSummary] { service.summaries(readRecords) }
    var statistics: ReadingStatistics { service.statistics(readRecords) }

    func summaries(searchKey: String, sortMode: Int) -> [ReadRecordSummary] {
        service.displayedSummaries(readRecords, searchKey: searchKey, sortMode: sortMode)
    }

    func load() async {
        let bookmarkGeneration = bookmarkSaveGeneration
        let recordGeneration = recordSaveGeneration
        do {
            async let storedBookmarks = repository.loadBookmarks()
            async let storedRecords = repository.loadReadRecords()
            let loadedBookmarks = try await storedBookmarks
            let loadedRecords = try await storedRecords
            if bookmarkGeneration == bookmarkSaveGeneration, bookmarkSaveTask == nil {
                bookmarks = service.sortedBookmarks(loadedBookmarks)
                persistedBookmarks = bookmarks
            }
            if recordGeneration == recordSaveGeneration, recordSaveTask == nil {
                readRecords = loadedRecords
                persistedRecords = loadedRecords
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bookmarks(for book: Book) -> [Bookmark] {
        bookmarks.filter { $0.bookName == book.name && $0.bookAuthor == book.author }
            .sorted {
                if $0.chapterIndex == $1.chapterIndex { return $0.chapterPosition < $1.chapterPosition }
                return $0.chapterIndex < $1.chapterIndex
            }
    }

    func addBookmark(book: Book, chapter: BookChapter, position: Int, content: String, epubLocation: String? = nil) async {
        var timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        while bookmarks.contains(where: { $0.time == timestamp }) { timestamp += 1 }
        var bookmark = Bookmark(time: timestamp, bookName: book.name, bookAuthor: book.author)
        bookmark.chapterIndex = chapter.index
        bookmark.chapterPosition = max(position, 0)
        bookmark.chapterName = chapter.title
        bookmark.bookText = excerpt(content, around: position)
        bookmark.epubLocation = epubLocation
        var updated = bookmarks
        updated.append(bookmark)
        await persistBookmarks(updated)
    }

    func removeBookmark(_ bookmark: Bookmark) async {
        let updated = bookmarks.filter { $0.id != bookmark.id }
        await persistBookmarks(updated)
    }

    func updateBookmark(_ bookmark: Bookmark) async {
        var updated = bookmarks
        if let index = updated.firstIndex(where: { $0.id == bookmark.id }) {
            updated[index] = bookmark
        } else {
            updated.append(bookmark)
        }
        await persistBookmarks(updated)
    }

    func beginReading(_ book: Book, now: Date = Date()) {
        sessions[book.bookUrl] = sessions[book.bookUrl] ?? now
    }

    func checkpoint(_ book: Book, now: Date = Date()) async {
        guard let start = sessions[book.bookUrl] else {
            sessions[book.bookUrl] = now
            return
        }
        sessions[book.bookUrl] = now
        await record(book: book, elapsed: now.timeIntervalSince(start), now: now)
    }

    func endReading(_ book: Book, now: Date = Date()) async {
        guard let start = sessions.removeValue(forKey: book.bookUrl) else { return }
        await record(book: book, elapsed: now.timeIntervalSince(start), now: now)
    }

    func cancelReading(_ book: Book) {
        sessions.removeValue(forKey: book.bookUrl)
    }

    func removeHistory(bookName: String) async {
        let updated = readRecords.filter { $0.bookName != bookName }
        await persistRecords(updated)
    }

    func clearHistory() async {
        await persistRecords([])
    }

    func clearError() { errorMessage = nil }

    private func record(book: Book, elapsed: TimeInterval, now: Date) async {
        let milliseconds = Int64(max(elapsed, 0) * 1_000)
        guard milliseconds > 0 else { return }
        let updated = service.addingReadTime(
            milliseconds,
            deviceID: deviceID,
            bookName: book.name,
            now: Int64(now.timeIntervalSince1970 * 1_000),
            to: readRecords
        )
        // Keep elapsed time in memory after a failed checkpoint so the next
        // successful checkpoint can retry it instead of silently losing time.
        await persistRecords(updated, preserveOnFailure: true)
    }

    // Publish each change before suspension, and serialize full-snapshot writes
    // so rapid edits cannot overwrite one another or resurrect deleted history.
    private func persistBookmarks(_ updated: [Bookmark]) async {
        bookmarks = service.sortedBookmarks(updated)
        bookmarkSaveGeneration &+= 1
        let generation = bookmarkSaveGeneration
        let previous = bookmarkSaveTask
        let save = Task { @MainActor [weak self, repository] in
            await previous?.value
            do {
                try await repository.saveBookmarks(updated)
                self?.persistedBookmarks = updated
            } catch {
                guard let self else { return }
                if bookmarkSaveGeneration == generation { bookmarks = service.sortedBookmarks(persistedBookmarks) }
                errorMessage = error.localizedDescription
            }
        }
        bookmarkSaveTask = save
        await save.value
        if bookmarkSaveGeneration == generation { bookmarkSaveTask = nil }
    }

    private func persistRecords(_ updated: [ReadRecord], preserveOnFailure: Bool = false) async {
        readRecords = updated
        recordSaveGeneration &+= 1
        let generation = recordSaveGeneration
        let previous = recordSaveTask
        let save = Task { @MainActor [weak self, repository] in
            await previous?.value
            do {
                try await repository.saveReadRecords(updated)
                self?.persistedRecords = updated
            } catch {
                guard let self else { return }
                if recordSaveGeneration == generation, !preserveOnFailure { readRecords = persistedRecords }
                errorMessage = error.localizedDescription
            }
        }
        recordSaveTask = save
        await save.value
        if recordSaveGeneration == generation { recordSaveTask = nil }
    }

    private func excerpt(_ content: String, around position: Int) -> String {
        guard !content.isEmpty else { return "" }
        let center = min(max(position, 0), content.count)
        let start = max(center - 24, 0)
        let end = min(center + 96, content.count)
        let lower = content.index(content.startIndex, offsetBy: start)
        let upper = content.index(content.startIndex, offsetBy: end)
        return String(content[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
