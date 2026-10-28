import Foundation

public protocol ReadingActivityRepository: Sendable {
    func loadBookmarks() async throws -> [Bookmark]
    func saveBookmarks(_ bookmarks: [Bookmark]) async throws
    func loadReadRecords() async throws -> [ReadRecord]
    func saveReadRecords(_ records: [ReadRecord]) async throws
}

public actor FileReadingActivityRepository: ReadingActivityRepository {
    private let bookmarksURL: URL
    private let recordsURL: URL

    public init(bookmarksURL: URL, recordsURL: URL) {
        self.bookmarksURL = bookmarksURL
        self.recordsURL = recordsURL
    }

    public func loadBookmarks() throws -> [Bookmark] { try load([Bookmark].self, from: bookmarksURL) }
    public func saveBookmarks(_ bookmarks: [Bookmark]) throws { try save(bookmarks, to: bookmarksURL) }
    public func loadReadRecords() throws -> [ReadRecord] { try load([ReadRecord].self, from: recordsURL) }
    public func saveReadRecords(_ records: [ReadRecord]) throws { try save(records, to: recordsURL) }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T where T: ExpressibleByArrayLiteral {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public actor InMemoryReadingActivityRepository: ReadingActivityRepository {
    private var bookmarks: [Bookmark]
    private var records: [ReadRecord]

    public init(bookmarks: [Bookmark] = [], records: [ReadRecord] = []) {
        self.bookmarks = bookmarks
        self.records = records
    }

    public func loadBookmarks() -> [Bookmark] { bookmarks }
    public func saveBookmarks(_ bookmarks: [Bookmark]) { self.bookmarks = bookmarks }
    public func loadReadRecords() -> [ReadRecord] { records }
    public func saveReadRecords(_ records: [ReadRecord]) { self.records = records }
}

public struct ReadingActivityService: Sendable {
    public init() {}

    public func sortedBookmarks(_ bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.sorted {
            let name = $0.bookName.localizedStandardCompare($1.bookName)
            if name != .orderedSame { return name == .orderedAscending }
            let author = $0.bookAuthor.localizedStandardCompare($1.bookAuthor)
            if author != .orderedSame { return author == .orderedAscending }
            if $0.chapterIndex != $1.chapterIndex { return $0.chapterIndex < $1.chapterIndex }
            return $0.chapterPosition < $1.chapterPosition
        }
    }

    public func summaries(_ records: [ReadRecord]) -> [ReadRecordSummary] {
        Dictionary(grouping: records, by: \.bookName)
            .map { name, values in
                ReadRecordSummary(
                    bookName: name,
                    readTime: values.reduce(0) { $0 + max($1.readTime, 0) },
                    lastRead: values.map(\.lastRead).max() ?? 0
                )
            }
            .sorted { $0.lastRead > $1.lastRead }
    }

    public func displayedSummaries(
        _ records: [ReadRecord],
        searchKey: String,
        sortMode: Int
    ) -> [ReadRecordSummary] {
        let values = summaries(records).filter {
            searchKey.isEmpty || $0.bookName.localizedCaseInsensitiveContains(searchKey)
        }
        return values.sorted {
            switch sortMode {
            case 1:
                if $0.readTime != $1.readTime { return $0.readTime > $1.readTime }
            case 2:
                if $0.lastRead != $1.lastRead { return $0.lastRead > $1.lastRead }
            default:
                let order = $0.bookName.localizedStandardCompare($1.bookName)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return $0.bookName.localizedStandardCompare($1.bookName) == .orderedAscending
        }
    }

    public func addingReadTime(
        _ elapsedMilliseconds: Int64,
        deviceID: String,
        bookName: String,
        now: Int64,
        to records: [ReadRecord],
        calendar: Calendar = .current
    ) -> [ReadRecord] {
        guard elapsedMilliseconds > 0, !bookName.isEmpty else { return records }
        var updated = records
        let day = Self.dayKey(
            for: Date(timeIntervalSince1970: Double(now) / 1_000),
            calendar: calendar
        )
        if let index = updated.firstIndex(where: { $0.deviceId == deviceID && $0.bookName == bookName }) {
            updated[index].readTime += elapsedMilliseconds
            updated[index].lastRead = now
            updated[index].dailyReadTimes[day, default: 0] += elapsedMilliseconds
        } else {
            updated.append(.init(
                deviceId: deviceID,
                bookName: bookName,
                readTime: elapsedMilliseconds,
                lastRead: now,
                dailyReadTimes: [day: elapsedMilliseconds]
            ))
        }
        return updated
    }

    public func statistics(
        _ records: [ReadRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReadingStatistics {
        let dailyTotals = records.reduce(into: [String: Int64]()) { result, record in
            for (day, milliseconds) in record.dailyReadTimes where milliseconds > 0 {
                result[day, default: 0] += milliseconds
            }
        }
        let today = calendar.startOfDay(for: now)
        let todayKey = Self.dayKey(for: today, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor: Date?
        if dailyTotals[todayKey, default: 0] > 0 {
            cursor = today
        } else if dailyTotals[Self.dayKey(for: yesterday, calendar: calendar), default: 0] > 0 {
            cursor = yesterday
        } else {
            cursor = nil
        }
        var streak = 0
        while let day = cursor,
              dailyTotals[Self.dayKey(for: day, calendar: calendar), default: 0] > 0 {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        let recentDays = (-6...0).compactMap { offset -> DailyReadingTotal? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return DailyReadingTotal(
                date: date,
                readTime: dailyTotals[Self.dayKey(for: date, calendar: calendar), default: 0]
            )
        }
        return ReadingStatistics(
            todayReadTime: dailyTotals[todayKey, default: 0],
            currentStreak: streak,
            totalReadTime: records.reduce(0) { $0 + max($1.readTime, 0) },
            bookCount: Set(records.lazy.map(\.bookName).filter { !$0.isEmpty }).count,
            recentDays: recentDays
        )
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

public struct DailyReadingTotal: Hashable, Sendable {
    public let date: Date
    public let readTime: Int64

    public init(date: Date, readTime: Int64) {
        self.date = date
        self.readTime = readTime
    }
}

public struct ReadingStatistics: Hashable, Sendable {
    public let todayReadTime: Int64
    public let currentStreak: Int
    public let totalReadTime: Int64
    public let bookCount: Int
    public let recentDays: [DailyReadingTotal]

    public init(
        todayReadTime: Int64,
        currentStreak: Int,
        totalReadTime: Int64,
        bookCount: Int,
        recentDays: [DailyReadingTotal]
    ) {
        self.todayReadTime = todayReadTime
        self.currentStreak = currentStreak
        self.totalReadTime = totalReadTime
        self.bookCount = bookCount
        self.recentDays = recentDays
    }
}

public struct BookProgress: Codable, Hashable, Sendable {
    public var epubLocation: String?
    public var name: String
    public var author: String
    public var durChapterIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64
    public var durChapterTitle: String?

    public init(book: Book) {
        epubLocation = book.readConfig?.epubLocation
        name = book.name
        author = book.author
        durChapterIndex = book.durChapterIndex
        durChapterPos = book.durChapterPos
        durChapterTime = book.durChapterTime
        durChapterTitle = book.durChapterTitle
    }
}
