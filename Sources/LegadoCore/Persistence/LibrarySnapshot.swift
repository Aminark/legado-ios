import Foundation

public enum LibraryBackupError: Error, LocalizedError, Equatable {
    case invalid(String), changed, tooLarge, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "备份无效：\(detail)"
        case .changed: "本机数据正在变化，请稍后重试。"
        case .tooLarge: "书库记录或附件超过备份大小限制。"
        case .unsupportedVersion: "此备份由更新版本创建，请先更新应用。"
        }
    }
}

/// Portable user data. Login cookies, diagnostic logs and transient search caches are excluded.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var books: [Book] = []
    public var sources: [BookSource] = []
    public var groups: [BookGroup] = []
    public var bookmarks: [Bookmark] = []
    public var records: [ReadRecord] = []
    public var searchKeywords: [SearchKeyword] = []
    public var rssSources: [RssSource] = []
    public var rssReadRecords: [RssReadRecord] = []
    public var rssStars: [RssStar] = []
    public var txtRules: [TxtTocRule] = []
    public var tts: [HttpTTS] = []
    public var subscriptions: [RuleSub] = []
    public var keyboardAssists: [KeyboardAssist] = []
    public var replaceRules: [ReplaceRule] = []
    public var chapters: [String: [BookChapter]] = [:]
    public var preferences: [String: JSONValue] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case books, sources, groups, bookmarks, records, searchKeywords, rssSources, rssReadRecords, rssStars
        case txtRules, tts, subscriptions, keyboardAssists, replaceRules, chapters, preferences
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        books = try values.decode([Book].self, forKey: .books)
        sources = try values.decode([BookSource].self, forKey: .sources)
        groups = try values.decode([BookGroup].self, forKey: .groups)
        bookmarks = try values.decode([Bookmark].self, forKey: .bookmarks)
        records = try values.decode([ReadRecord].self, forKey: .records)
        // Archives created before history backup was added have neither of these fields.
        searchKeywords = try values.decodeIfPresent([SearchKeyword].self, forKey: .searchKeywords) ?? []
        rssReadRecords = try values.decodeIfPresent([RssReadRecord].self, forKey: .rssReadRecords) ?? []
        rssSources = try values.decode([RssSource].self, forKey: .rssSources)
        rssStars = try values.decode([RssStar].self, forKey: .rssStars)
        txtRules = try values.decode([TxtTocRule].self, forKey: .txtRules)
        tts = try values.decode([HttpTTS].self, forKey: .tts)
        subscriptions = try values.decode([RuleSub].self, forKey: .subscriptions)
        keyboardAssists = try values.decode([KeyboardAssist].self, forKey: .keyboardAssists)
        replaceRules = try values.decode([ReplaceRule].self, forKey: .replaceRules)
        chapters = try values.decode([String: [BookChapter]].self, forKey: .chapters)
        preferences = try values.decode([String: JSONValue].self, forKey: .preferences)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public func validated() throws -> Self {
        guard books.count <= 50_000, sources.count <= 50_000,
              bookmarks.count <= 100_000, records.count <= 100_000, searchKeywords.count <= 100_000,
              rssReadRecords.count <= 100_000, chapters.values.reduce(0, { $0 + $1.count }) <= 500_000 else {
            throw LibraryBackupError.tooLarge
        }
        func unique<T: Hashable>(_ ids: [T]) throws {
            guard Set(ids).count == ids.count else { throw LibraryBackupError.invalid("存在重复记录") }
        }
        try unique(books.map(\.id))
        try unique(books.map { [$0.name, $0.author] })
        try unique(sources.map(\.id))
        try unique(groups.map(\.id))
        try unique(bookmarks.map(\.id))
        try unique(records.map(\.id))
        try unique(rssSources.map(\.id))
        try unique(rssStars.map(\.id))
        try unique(searchKeywords.map(\.id))
        try unique(rssReadRecords.map(\.id))
        try unique(txtRules.map(\.id))
        try unique(tts.map(\.id))
        try unique(subscriptions.map(\.id))
        try unique(keyboardAssists.map(\.id))
        try unique(replaceRules.map(\.id))
        guard books.allSatisfy({ !$0.bookUrl.isEmpty && !$0.name.isEmpty && (0...500_000).contains($0.durChapterIndex) && (0...100_000_000).contains($0.durChapterPos) }),
              bookmarks.allSatisfy({ (0...500_000).contains($0.chapterIndex) && (0...100_000_000).contains($0.chapterPosition) }),
              searchKeywords.allSatisfy({ !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.usage >= 0 }),
              rssReadRecords.allSatisfy({ !$0.record.isEmpty && (0...100_000_000).contains($0.durPos) }),
              sources.allSatisfy({ !$0.id.isEmpty }), groups.allSatisfy({ $0.id <= 0 || $0.id.nonzeroBitCount == 1 }) else {
            throw LibraryBackupError.invalid("书籍、书源或设置字段不正确")
        }
        let bookIDs = Set(books.map(\.id))
        for (bookURL, values) in chapters {
            guard bookIDs.contains(bookURL), values.allSatisfy({ $0.bookUrl == bookURL }) else {
                throw LibraryBackupError.invalid("目录不属于备份内的书籍")
            }
            try unique(values.map(\.url))
        }
        var totalReadTime: Int64 = 0
        var totalDailyReadTime: Int64 = 0
        for record in records {
            let (total, overflow) = totalReadTime.addingReportingOverflow(record.readTime)
            guard record.readTime >= 0, !overflow else { throw LibraryBackupError.invalid("阅读统计时长不正确") }
            totalReadTime = total
            for milliseconds in record.dailyReadTimes.values {
                let (daily, overflow) = totalDailyReadTime.addingReportingOverflow(milliseconds)
                guard milliseconds >= 0, !overflow else { throw LibraryBackupError.invalid("每日阅读统计不正确") }
                totalDailyReadTime = daily
            }
        }
        return self
    }

    /// Restore merges, preserving existing books when another URL has the same name/author.
    public func merging(_ incoming: Self) -> Self {
        func union<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] {
            var result = a
            var indices = Dictionary(uniqueKeysWithValues: a.enumerated().map { ($1.id, $0) })
            for value in b {
                if let index = indices[value.id] {
                    result[index] = value
                } else {
                    indices[value.id] = result.count
                    result.append(value)
                }
            }
            return result
        }
        var result = incoming
        var positions = Dictionary(uniqueKeysWithValues: books.indices.map { (books[$0].id, $0) })
        var works = Set(books.map { [$0.name, $0.author] })
        result.books = books
        for book in incoming.books {
            if let index = positions[book.id] {
                if book.backupProgress >= result.books[index].backupProgress {
                    result.books[index].copyProgress(from: book)
                }
                result.books[index].group |= book.group
            } else if works.insert([book.name, book.author]).inserted {
                positions[book.id] = result.books.count
                result.books.append(book)
            }
        }
        let savedSources = Set(sources.map(\.id))
        result.sources = sources + incoming.sources.filter { !savedSources.contains($0.id) }
        result.groups = union(groups, incoming.groups)
        result.bookmarks = union(bookmarks, incoming.bookmarks)
        let localRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        result.records = union(records, incoming.records).map { record in
            localRecords[record.id].map { $0.mergingReadTime(record) } ?? record
        }
        let localKeywords = Dictionary(uniqueKeysWithValues: searchKeywords.map { ($0.id, $0) })
        result.searchKeywords = union(searchKeywords, incoming.searchKeywords).map { keyword in
            guard let local = localKeywords[keyword.id] else { return keyword }
            return .init(word: keyword.word, usage: max(local.usage, keyword.usage), lastUseTime: max(local.lastUseTime, keyword.lastUseTime))
        }
        result.rssSources = union(rssSources, incoming.rssSources)
        result.rssStars = union(rssStars, incoming.rssStars)
        let localRSS = Dictionary(uniqueKeysWithValues: rssReadRecords.map { ($0.id, $0) })
        result.rssReadRecords = union(rssReadRecords, incoming.rssReadRecords).map { record in
            guard let local = localRSS[record.id], (local.readTime ?? 0) > (record.readTime ?? 0) else { return record }
            return local
        }
        result.txtRules = union(txtRules, incoming.txtRules)
        result.tts = union(tts, incoming.tts)
        result.subscriptions = union(subscriptions, incoming.subscriptions)
        result.keyboardAssists = union(keyboardAssists, incoming.keyboardAssists)
        let savedRules = Set(replaceRules.map(\.id))
        result.replaceRules = replaceRules + incoming.replaceRules.filter { !savedRules.contains($0.id) }
        let localBooks = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let incomingBooks = Dictionary(uniqueKeysWithValues: incoming.books.map { ($0.id, $0) })
        result.chapters = chapters.merging(incoming.chapters) { old, _ in old }
        for book in result.books {
            let old = chapters[book.id] ?? []
            let new = incoming.chapters[book.id] ?? []
            // Select the directory from the same snapshot as the winning progress, with an empty-directory fallback.
            let incomingProgress = incomingBooks[book.id]?.backupProgress ?? (0, 0, 0)
            let localProgress = localBooks[book.id]?.backupProgress ?? (0, 0, 0)
            if !new.isEmpty && (old.isEmpty || incomingProgress >= localProgress) {
                result.chapters[book.id] = new
            }
        }
        result.chapters = result.chapters.filter { positions[$0.key] != nil }
        result.preferences = [:] // Version 1 reserves this field. Device settings stay on the device.
        return result
    }
}

private extension ReadRecord {
    func mergingReadTime(_ other: Self) -> Self {
        var result = self
        // These are cumulative counters for the same device/book, so adding snapshots would count twice.
        result.readTime = max(readTime, other.readTime)
        result.lastRead = max(lastRead, other.lastRead)
        result.dailyReadTimes = dailyReadTimes.merging(other.dailyReadTimes, uniquingKeysWith: max)
        return result
    }
}

extension Book {
    fileprivate var backupProgress: (Int64, Int, Int) { (durChapterTime, durChapterIndex, durChapterPos) }

    mutating func copyProgress(from other: Book) {
        durChapterTitle = other.durChapterTitle
        durChapterIndex = other.durChapterIndex
        durChapterPos = other.durChapterPos
        durChapterTime = other.durChapterTime
        durVolumeIndex = other.durVolumeIndex
        chapterInVolumeIndex = other.chapterInVolumeIndex
        if other.readConfig?.epubLocation != nil, readConfig == nil { readConfig = BookReadConfig() }
        readConfig?.epubLocation = other.readConfig?.epubLocation
    }
}
