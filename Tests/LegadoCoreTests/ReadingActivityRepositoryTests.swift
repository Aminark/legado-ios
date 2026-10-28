import Foundation
import Testing
@testable import LegadoCore

struct ReadingActivityRepositoryTests {
    @Test func epubBookmarkLocationRoundTripsThroughSQLite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LegadoDatabase(url: root.appendingPathComponent("library.sqlite3"))
        let repository = SQLiteReadingActivityRepository(database: database)
        var bookmark = Bookmark(time: 42, bookName: "EPUB", bookAuthor: "作者")
        bookmark.epubLocation = #"{"href":"Text/第二章.xhtml","type":"application/xhtml+xml","locations":{"progression":0.6}}"#
        bookmark.bookText = "原排版书签"
        try await repository.saveBookmarks([bookmark])
        #expect(try await repository.loadBookmarks() == [bookmark])
        let legacy = try JSONDecoder().decode(Bookmark.self, from: Data(#"{"time":1,"bookName":"旧书"}"#.utf8))
        #expect(legacy.epubLocation == nil)
    }
    @Test func decodesAndEncodesBookmarkPosition() throws {
        let data = Data(#"{"time":7,"bookName":"书","bookAuthor":"作者","chapterIndex":2,"chapterPos":88,"chapterName":"第二章","bookText":"片段","content":"备注"}"#.utf8)
        let bookmark = try JSONDecoder().decode(Bookmark.self, from: data)
        let encoded = try JSONEncoder().encode(bookmark)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(bookmark.chapterPosition == 88)
        #expect(object["chapterPos"] as? Int == 88)
        #expect(object["chapterPosition"] == nil)
    }

    @Test func accumulatesPerDeviceAndSummarizesAcrossDevices() {
        let service = ReadingActivityService()
        let now: Int64 = 2_000
        var records = [ReadRecord(deviceId: "a", bookName: "书", readTime: 1_000, lastRead: 1_000)]
        records = service.addingReadTime(500, deviceID: "a", bookName: "书", now: now, to: records)
        records = service.addingReadTime(700, deviceID: "b", bookName: "书", now: now + 1, to: records)

        let summary = service.summaries(records)
        #expect(records.count == 2)
        #expect(summary == [.init(bookName: "书", readTime: 2_200, lastRead: 2_001)])
    }

    @Test func decodesLegacyReadRecordWithoutDailyStatistics() throws {
        let data = Data(#"{"deviceId":"ios","bookName":"旧书","readTime":120000,"lastRead":7}"#.utf8)
        let record = try JSONDecoder().decode(ReadRecord.self, from: data)

        #expect(record.dailyReadTimes.isEmpty)
        #expect(record.readTime == 120_000)
    }

    @Test func calculatesTodayStreakTotalsAndUniqueBooks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        let service = ReadingActivityService()
        let records = [
            ReadRecord(
                deviceId: "a",
                bookName: "第一本",
                readTime: 9_000_000,
                lastRead: Int64(now.timeIntervalSince1970 * 1_000),
                dailyReadTimes: ["2026-08-18": 600_000, "2026-08-19": 1_200_000, "2026-08-20": 1_800_000]
            ),
            ReadRecord(
                deviceId: "b",
                bookName: "第一本",
                readTime: 3_000_000,
                dailyReadTimes: ["2026-08-20": 300_000]
            ),
            ReadRecord(
                deviceId: "a",
                bookName: "第二本",
                readTime: 4_000_000,
                dailyReadTimes: ["2026-08-17": 60_000]
            )
        ]

        let statistics = service.statistics(records, now: now, calendar: calendar)

        #expect(statistics.todayReadTime == 2_100_000)
        #expect(statistics.currentStreak == 4)
        #expect(statistics.totalReadTime == 16_000_000)
        #expect(statistics.bookCount == 2)
        #expect(statistics.recentDays.count == 7)
    }

    @Test func keepsCurrentStreakUntilTheDayAfterLastReading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 8)))
        let records = [ReadRecord(
            deviceId: "a",
            bookName: "书",
            readTime: 120_000,
            dailyReadTimes: ["2026-08-18": 60_000, "2026-08-19": 60_000]
        )]

        let statistics = ReadingActivityService().statistics(records, now: now, calendar: calendar)

        #expect(statistics.todayReadTime == 0)
        #expect(statistics.currentStreak == 2)
    }

    @Test func filtersAndSortsReadRecords() {
        let records = [
            ReadRecord(deviceId: "a", bookName: "Beta", readTime: 5_000, lastRead: 20),
            ReadRecord(deviceId: "a", bookName: "Alpha", readTime: 1_000, lastRead: 30),
            ReadRecord(deviceId: "b", bookName: "Beta", readTime: 2_000, lastRead: 40)
        ]
        let service = ReadingActivityService()

        #expect(service.displayedSummaries(records, searchKey: "", sortMode: 0).map(\.bookName) == ["Alpha", "Beta"])
        #expect(service.displayedSummaries(records, searchKey: "", sortMode: 1).map(\.bookName) == ["Beta", "Alpha"])
        #expect(service.displayedSummaries(records, searchKey: "", sortMode: 2).map(\.bookName) == ["Beta", "Alpha"])
        #expect(service.displayedSummaries(records, searchKey: "alp", sortMode: 0).map(\.bookName) == ["Alpha"])
    }

    @Test func sortsBookmarksByBookAndPosition() {
        var later = Bookmark(time: 1, bookName: "B", bookAuthor: "作者")
        later.chapterIndex = 1
        later.chapterPosition = 20
        var earlierPosition = Bookmark(time: 2, bookName: "A", bookAuthor: "作者")
        earlierPosition.chapterIndex = 2
        earlierPosition.chapterPosition = 30
        var first = Bookmark(time: 3, bookName: "A", bookAuthor: "作者")
        first.chapterIndex = 1
        first.chapterPosition = 40

        let sorted = ReadingActivityService().sortedBookmarks([later, earlierPosition, first])

        #expect(sorted.map(\.time) == [first.time, earlierPosition.time, later.time])
    }

    @Test func persistsBookmarksAndRecordsAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileReadingActivityRepository(
            bookmarksURL: directory.appending(path: "bookmarks.json"),
            recordsURL: directory.appending(path: "records.json")
        )
        var bookmark = Bookmark(time: 4, bookName: "书")
        bookmark.chapterPosition = 19
        let record = ReadRecord(deviceId: "ios", bookName: "书", readTime: 3_000, lastRead: 5)

        try await repository.saveBookmarks([bookmark])
        try await repository.saveReadRecords([record])

        #expect(try await repository.loadBookmarks() == [bookmark])
        #expect(try await repository.loadReadRecords() == [record])
    }
}
