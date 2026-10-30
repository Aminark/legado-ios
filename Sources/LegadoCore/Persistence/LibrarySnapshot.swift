import Foundation
import CryptoKit

public enum LibraryBackupError: Error, LocalizedError, Equatable {
    case invalid(String), changed, tooLarge, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "备份无效：\(detail)"
        case .changed: "本机数据正在变化，请稍后重试。"
        case .tooLarge: "备份超过大小限制，请减少包含的正文缓存。"
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
        try unique(books.map(\.id)); try unique(books.map { [$0.name, $0.author] })
        try unique(sources.map(\.id)); try unique(groups.map(\.id)); try unique(bookmarks.map(\.id))
        try unique(records.map(\.id)); try unique(rssSources.map(\.id)); try unique(rssStars.map(\.id))
        try unique(searchKeywords.map(\.id)); try unique(rssReadRecords.map(\.id))
        try unique(txtRules.map(\.id)); try unique(tts.map(\.id)); try unique(subscriptions.map(\.id))
        try unique(keyboardAssists.map(\.id)); try unique(replaceRules.map(\.id))
        guard books.allSatisfy({ !$0.bookUrl.isEmpty && !$0.name.isEmpty && (0...500_000).contains($0.durChapterIndex) && (0...100_000_000).contains($0.durChapterPos) }),
              bookmarks.allSatisfy({ (0...500_000).contains($0.chapterIndex) && (0...100_000_000).contains($0.chapterPosition) }),
              searchKeywords.allSatisfy({ !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.usage >= 0 }),
              rssReadRecords.allSatisfy({ !$0.record.isEmpty && (0...100_000_000).contains($0.durPos) }),
              sources.allSatisfy({ !$0.id.isEmpty }), Set(preferences.keys).isSubset(of: LibraryPreferences.keys) else {
            throw LibraryBackupError.invalid("书籍、书源或设置字段不正确")
        }
        for (bookURL, values) in chapters {
            guard books.contains(where: { $0.bookUrl == bookURL }), values.allSatisfy({ $0.bookUrl == bookURL }) else {
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
                if let index = indices[value.id] { result[index] = value }
                else { indices[value.id] = result.count; result.append(value) }
            }
            return result
        }
        var result = incoming
        result.books = books
        for var book in incoming.books {
            if let index = result.books.firstIndex(where: { $0.id == book.id }) {
                if result.books[index].durChapterTime > book.durChapterTime { book.copyProgress(from: result.books[index]) }
                result.books[index] = book
            } else if !result.books.contains(where: { $0.name == book.name && $0.author == book.author }) {
                result.books.append(book)
            }
        }
        result.sources = union(sources, incoming.sources); result.groups = union(groups, incoming.groups)
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
        result.rssSources = union(rssSources, incoming.rssSources); result.rssStars = union(rssStars, incoming.rssStars)
        let localRSS = Dictionary(uniqueKeysWithValues: rssReadRecords.map { ($0.id, $0) })
        result.rssReadRecords = union(rssReadRecords, incoming.rssReadRecords).map { record in
            guard let local = localRSS[record.id], (local.readTime ?? 0) > (record.readTime ?? 0) else { return record }
            return local
        }
        result.txtRules = union(txtRules, incoming.txtRules); result.tts = union(tts, incoming.tts)
        result.subscriptions = union(subscriptions, incoming.subscriptions)
        result.keyboardAssists = union(keyboardAssists, incoming.keyboardAssists)
        result.replaceRules = union(replaceRules, incoming.replaceRules)
        result.chapters = chapters.merging(incoming.chapters) { old, new in old.isEmpty ? new : old }
            .filter { key, _ in result.books.contains { $0.id == key } }
        result.preferences = preferences.merging(incoming.preferences) { _, new in new }
        return result
    }

    public var databaseOnly: Self {
        var copy = self; copy.preferences = [:]; copy.replaceRules = []; copy.chapters = [:]; return copy
    }

    /// Local TXT files cannot be opened on a different device without importing their files.
    public var cloudEligible: Self {
        var copy = self; copy.chapters = [:]; copy.books.removeAll { $0.origin == "local" }; return copy
    }

    public func syncEntries() throws -> [String: Data] {
        var entries: [String: Data] = [:]
        func put<T: Encodable & Identifiable>(_ name: String, _ values: [T]) throws {
            for value in values { entries["\(name)|\(value.id)"] = try Self.encode(value) }
        }
        let copy = cloudEligible
        for book in copy.books {
            var metadata = book
            metadata.durChapterTitle = nil; metadata.durChapterIndex = 0; metadata.durChapterPos = 0
            metadata.durVolumeIndex = 0; metadata.chapterInVolumeIndex = 0; metadata.durChapterTime = 0
            entries["books|\(book.id)"] = try Self.encode(metadata)
            entries["progress|\(book.id)"] = try Self.encode(LibraryReadingProgress(book))
        }
        try put("sources", copy.sources); try put("groups", copy.groups); try put("bookmarks", copy.bookmarks)
        try put("records", copy.records); try put("searchKeywords", copy.searchKeywords)
        try put("rssSources", copy.rssSources); try put("rssReadRecords", copy.rssReadRecords); try put("rssStars", copy.rssStars)
        try put("txtRules", copy.txtRules); try put("tts", copy.tts); try put("subscriptions", copy.subscriptions)
        try put("keyboardAssists", copy.keyboardAssists); try put("replaceRules", copy.replaceRules)
        for (key, value) in copy.preferences { entries["preferences|\(key)"] = try Self.encode(value) }
        return entries
    }

    public init(syncEntries entries: [String: Data]) throws {
        self.init()
        func values<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
            try entries.filter { $0.key.hasPrefix(name + "|") }.sorted { $0.key < $1.key }
                .map { try JSONDecoder().decode(T.self, from: $0.value) }
        }
        books = try values("books", Book.self); sources = try values("sources", BookSource.self)
        groups = try values("groups", BookGroup.self); bookmarks = try values("bookmarks", Bookmark.self)
        records = try values("records", ReadRecord.self); rssSources = try values("rssSources", RssSource.self)
        searchKeywords = try values("searchKeywords", SearchKeyword.self); rssReadRecords = try values("rssReadRecords", RssReadRecord.self)
        rssStars = try values("rssStars", RssStar.self); txtRules = try values("txtRules", TxtTocRule.self)
        tts = try values("tts", HttpTTS.self); subscriptions = try values("subscriptions", RuleSub.self)
        keyboardAssists = try values("keyboardAssists", KeyboardAssist.self); replaceRules = try values("replaceRules", ReplaceRule.self)
        let progress = try values("progress", LibraryReadingProgress.self)
        for index in books.indices { if let value = progress.first(where: { $0.bookURL == books[index].id }) { value.apply(to: &books[index]) } }
        // The database permits one shelf entry per name/author, even when sources differ.
        var names: Set<[String]> = []
        books = books.sorted { $0.durChapterTime == $1.durChapterTime ? $0.id < $1.id : $0.durChapterTime > $1.durChapterTime }
            .filter { names.insert([$0.name, $0.author]).inserted }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        for (key, data) in entries where key.hasPrefix("preferences|") {
            preferences[String(key.dropFirst("preferences|".count))] = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        sources.sort { $0.customOrder == $1.customOrder ? $0.id < $1.id : $0.customOrder < $1.customOrder }
        groups.sort { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        replaceRules.sort { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        _ = try validated()
        guard try Set(syncEntries().keys).isSuperset(of: entries.keys.filter { !$0.hasPrefix("books|") && !$0.hasPrefix("progress|") }) else {
            throw LibraryBackupError.unsupportedVersion
        }
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
    mutating func copyProgress(from book: Book) { LibraryReadingProgress(book).apply(to: &self) }
}

private struct LibraryReadingProgress: Codable {
    var bookURL: String; var title: String?; var index: Int; var position: Int; var time: Int64
    var volume: Int; var inVolume: Int
    init(_ book: Book) {
        bookURL = book.id; title = book.durChapterTitle; index = book.durChapterIndex; position = book.durChapterPos
        time = book.durChapterTime; volume = book.durVolumeIndex; inVolume = book.chapterInVolumeIndex
    }
    func apply(to book: inout Book) {
        book.durChapterTitle = title; book.durChapterIndex = index; book.durChapterPos = position
        book.durChapterTime = time; book.durVolumeIndex = volume; book.chapterInVolumeIndex = inVolume
    }
}

public enum LibraryPreferences {
    // Explicit allowlist: device IDs, credentials, pending writes and sync/account state stay local.
    public static let keys: Set<String> = Set(("themeMode bookshelfLayout precisionSearch bookSourceSort bookSourceSortDescending enableReadRecord readRecordSort auto_refresh onlyUpdateRead defaultHomePage textSize letterSpacing lineSpacingExtra readerQidianLayoutVersion paragraphSpacing paragraphIndent paddingLeft paddingRight paddingTop paddingBottom textBold titleMode titleSize titleTopSpacing titleBottomSpacing underlineMode readerTheme readerPreviousDayTheme pageAnim headerPaddingBottom headerPaddingLeft headerPaddingRight headerPaddingTop footerPaddingBottom footerPaddingLeft footerPaddingRight footerPaddingTop showHeaderLine showFooterLine tipHeaderLeft tipHeaderMiddle tipHeaderRight tipFooterLeft tipFooterMiddle tipFooterRight headerMode footerMode autoReadSpeed ttsFollowSys ttsSpeechRate appTtsEngine systemTtsVoice readAloudByPage streamReadAloudAudio readAloudWakeLock ignoreAudioFocus pauseReadAloudWhilePhoneCalls mediaButtonPerNext ttsTimer readerFullJustify readerHideHomeIndicator readerHideStatusBar readerShowBrightness screenOrientation clickActionTopLeft clickActionTopCenter clickActionTopRight clickActionMiddleLeft clickActionMiddleRight clickActionBottomLeft clickActionBottomCenter clickActionBottomRight".split(separator: " ").map(String.init)) + [ApplicationSettingsStore.key])

    public static func read(_ defaults: UserDefaults) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if key == ApplicationSettingsStore.key, let data = value as? Data { result[key] = try JSONValue.decode(data: data) }
            else if JSONSerialization.isValidJSONObject([value]) {
                result[key] = try JSONValue.decode(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
            }
        }
        return result
    }

    public static func write(_ values: [String: JSONValue], to defaults: UserDefaults) throws {
        guard Set(values.keys).isSubset(of: keys) else { throw LibraryBackupError.invalid("不允许恢复此设置") }
        for (key, value) in values where key != ApplicationSettingsStore.key {
            switch value {
            case .bool: break
            case .string(let string) where string.utf8.count <= 4096: break
            case .number(let number) where number.isFinite && abs(number) < 1_000_000_000: break
            default: throw LibraryBackupError.invalid("设置值不正确：\(key)")
            }
        }
        if let value = values[ApplicationSettingsStore.key] {
            _ = try JSONDecoder().decode(ApplicationSettings.self, from: LibrarySnapshot.encode(value)).validated()
        }
        for key in keys {
            guard let value = values[key] else { defaults.removeObject(forKey: key); continue }
            let data = try LibrarySnapshot.encode(value)
            defaults.set(key == ApplicationSettingsStore.key ? data : try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), forKey: key)
        }
    }
}

public struct LibrarySyncDocument: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var value: Data?; public var revision: Int64; public var device: String
        public init(value: Data?, revision: Int64, device: String) { self.value = value; self.revision = revision; self.device = device }
    }
    public var version = 1
    public var items: [String: Item] = [:]
    public init() {}
    public var snapshot: LibrarySnapshot { get throws {
        guard version == 1 else { throw LibraryBackupError.unsupportedVersion }
        guard items.count <= 200_000, items.values.allSatisfy({ $0.revision >= 0 && $0.revision < Int64.max && $0.device.utf8.count <= 128 }) else {
            throw LibraryBackupError.invalid("同步版本标记不正确")
        }
        return try LibrarySnapshot(syncEntries: items.compactMapValues(\.value))
    } }

    public static func reconcile(local: LibrarySnapshot, baseline: Self, remote: Self, device: String, now: Int64) throws -> Self {
        guard baseline.version == 1, remote.version == 1 else { throw LibraryBackupError.unsupportedVersion }
        _ = try baseline.snapshot; _ = try remote.snapshot
        let current = try local.syncEntries()
        var changed = baseline
        let revision = max(now, max(baseline.items.values.map(\.revision).max() ?? 0, remote.items.values.map(\.revision).max() ?? 0) + 1)
        for key in Set(current.keys).union(baseline.items.keys) {
            guard current[key] != baseline.items[key]?.value else { continue }
            if let item = remote.items[key], current[key] == item.value { changed.items[key] = item; continue }
            if key.hasPrefix("records|"), let data = current[key], let remoteItem = remote.items[key], let remoteData = remoteItem.value {
                let combined = try Self.mergeReadTime(data, remoteData)
                changed.items[key] = combined == remoteData ? remoteItem : Item(value: combined, revision: revision, device: device)
                continue
            }
            if key.hasPrefix("progress|"), let data = current[key], let item = remote.items[key], let old = item.value,
               try JSONDecoder().decode(LibraryReadingProgress.self, from: data).time < JSONDecoder().decode(LibraryReadingProgress.self, from: old).time {
                changed.items[key] = item; continue
            }
            if baseline.items.isEmpty, let remoteItem = remote.items[key] {
                // First bind imports existing cloud settings rather than overwriting them with installation defaults.
                if key.hasPrefix("progress|"), let data = current[key], let old = remoteItem.value,
                   try JSONDecoder().decode(LibraryReadingProgress.self, from: data).time > JSONDecoder().decode(LibraryReadingProgress.self, from: old).time {
                    changed.items[key] = Item(value: data, revision: revision, device: device)
                } else { changed.items[key] = remoteItem }
            } else { changed.items[key] = Item(value: current[key], revision: revision, device: device) }
        }
        for (key, value) in remote.items {
            if key.hasPrefix("records|"), let old = changed.items[key], let oldData = old.value, let remoteData = value.value {
                let combined = try Self.mergeReadTime(oldData, remoteData)
                if combined != oldData || combined != remoteData {
                    changed.items[key] = combined == oldData ? old : combined == remoteData ? value : Item(value: combined, revision: revision, device: device)
                    continue
                }
            }
            if key.hasPrefix("progress|"), let old = changed.items[key], let oldData = old.value, let remoteData = value.value {
                let localTime = try JSONDecoder().decode(LibraryReadingProgress.self, from: oldData).time
                let remoteTime = try JSONDecoder().decode(LibraryReadingProgress.self, from: remoteData).time
                if localTime != remoteTime {
                    changed.items[key] = localTime > remoteTime ? old : value; continue
                }
            }
            if let old = changed.items[key], old.revision > value.revision || (old.revision == value.revision && old.device >= value.device) { continue }
            changed.items[key] = value
        }
        _ = try changed.snapshot
        return changed
    }

    private static func mergeReadTime(_ first: Data, _ second: Data) throws -> Data {
        let decoder = JSONDecoder()
        return try LibrarySnapshot.encode(decoder.decode(ReadRecord.self, from: first)
            .mergingReadTime(decoder.decode(ReadRecord.self, from: second)))
    }
}
