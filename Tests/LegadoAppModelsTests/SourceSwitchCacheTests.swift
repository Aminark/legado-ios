import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct SourceSwitchCacheTests {
    private func snapshot(at date: Date = Date()) -> SourceSwitchSnapshot {
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "chapter", title: "第二章", bookUrl: book.bookUrl, index: 0)
        let report = BookSourceSwitchReport(book: book, chapters: [chapter], exactChapterMatch: true,
            verifiedContent: .init(title: chapter.title, content: "已读取的正文", supplementalContent: "附加内容", pagesVisited: 2))
        return .init(createdAt: date, candidates: [], searchComplete: true,
            reference: .init(provider: "QQ 阅读", chapterTitle: chapter.title, url: "public", content: "公开开头"),
            referenceCheckedAt: date, reports: ["source|book": report], unmatched: ["other|book"])
    }

    @Test func diskCacheSurvivesANewCacheInstanceAndPreservesPreparedContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SourceSwitchCache(directory: directory)
        first.store(snapshot(), key: "context")
        await first.flush()
        let next = SourceSwitchCache(directory: directory)
        let restored = try #require(await next.load("context"))
        #expect(restored.reference?.content == "公开开头")
        #expect(restored.searchComplete)
        #expect(restored.unmatched == ["other|book"])
        #expect(restored.reports["source|book"]?.verifiedContent?.content == "已读取的正文")
        #expect(restored.reports["source|book"]?.verifiedContent?.supplementalContent == "附加内容")
        #expect(restored.reports["source|book"]?.verifiedContent?.pagesVisited == 2)
    }

    @Test func expiredAndFutureSnapshotsAreNotReused() async {
        let now = Date()
        let cache = SourceSwitchCache(maximumAge: 60, now: { now })
        cache.store(snapshot(at: now.addingTimeInterval(-61)), key: "expired")
        cache.store(snapshot(at: now.addingTimeInterval(301)), key: "future")
        #expect(await cache.load("expired") == nil)
        #expect(await cache.load("future") == nil)
    }

    @Test func corruptOrUnknownVersionDiskEntriesBecomeCacheMisses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{incomplete".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let cache = SourceSwitchCache(directory: directory)
        #expect(await cache.load("broken") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.json").path))
        var value = snapshot()
        value.version = 99
        cache.store(value, key: "unknown")
        await cache.flush()
        let next = SourceSwitchCache(directory: directory)
        #expect(await next.load("unknown") == nil)
    }

    @Test func refreshingBeforeADebouncedWriteDoesNotResurrectTheOldDiskEntry() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SourceSwitchCache(directory: directory)
        cache.store(snapshot(), key: "context")
        cache.remove("context")
        await cache.flush()
        let next = SourceSwitchCache(directory: directory)
        #expect(await next.load("context") == nil)
        var newer = snapshot()
        newer.reference = nil
        cache.store(newer, key: "context")
        await cache.flush()
        let restarted = SourceSwitchCache(directory: directory)
        #expect(await restarted.load("context")?.reference == nil)
        #expect(await restarted.load("context")?.searchComplete == true)
    }

    @Test func keyIgnoresPositionAndResponseTimingButTracksRulesAndChapter() {
        var book = Book(bookUrl: "book", name: "书", origin: "current")
        book.durChapterTitle = "第二章"
        var source = BookSource(bookSourceUrl: "source", bookSourceName: "书源")
        source.searchUrl = "/search"
        let original = SourceSwitchCache.key(book: book, sources: [source])
        book.durChapterPos = 900
        source.respondTime = 123
        source.weight = 9
        #expect(SourceSwitchCache.key(book: book, sources: [source]) == original)
        source.searchUrl = "/new-search"
        #expect(SourceSwitchCache.key(book: book, sources: [source]) != original)
        source.searchUrl = "/search"
        book.durChapterTitle = "第三章"
        #expect(SourceSwitchCache.key(book: book, sources: [source]) != original)
        book.durChapterTitle = "第二章"
        source.enabled = false
        #expect(SourceSwitchCache.key(book: book, sources: [source]) != original)
    }

    @Test func diskStorageKeepsAtMostTwelveRecentContexts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SourceSwitchCache(directory: directory)
        for index in 0..<14 { cache.store(snapshot(), key: "context\(index)") }
        await cache.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "json" }.count == 12)
    }

    @Test func anOversizedUpdateCannotLeaveAnOlderDiskResultBehind() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SourceSwitchCache(directory: directory)
        cache.store(snapshot(), key: "context")
        await cache.flush()
        var huge = snapshot()
        huge.reports["source|book"]?.verifiedContent?.content = String(repeating: "x", count: 17 * 1_024 * 1_024)
        cache.store(huge, key: "context")
        await cache.flush()
        let restarted = SourceSwitchCache(directory: directory)
        #expect(await restarted.load("context") == nil)
    }
}
