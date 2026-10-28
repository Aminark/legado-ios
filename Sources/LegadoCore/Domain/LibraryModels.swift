import Foundation

public struct Book: Codable, Hashable, Identifiable, Sendable {
    public var bookUrl: String
    public var tocUrl: String
    public var origin: String
    public var originName: String
    public var name: String
    public var author: String
    public var kind: String?
    public var customTag: String?
    public var coverUrl: String?
    public var customCoverUrl: String?
    public var intro: String?
    public var customIntro: String?
    public var charset: String?
    public var type: Int
    public var group: Int64
    public var latestChapterTitle: String?
    public var latestChapterTime: Int64
    public var lastCheckTime: Int64
    public var lastCheckCount: Int
    public var totalChapterNum: Int
    public var durChapterTitle: String?
    public var durChapterIndex: Int
    public var durVolumeIndex: Int
    public var chapterInVolumeIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64
    public var wordCount: String?
    public var canUpdate: Bool
    public var order: Int
    public var originOrder: Int
    public var variable: String?
    public var readConfig: BookReadConfig?
    public var syncTime: Int64

    public var id: String { bookUrl }

    public init(bookUrl: String, name: String, author: String = "", origin: String = "local") {
        self.bookUrl = bookUrl
        tocUrl = ""
        self.origin = origin
        originName = ""
        self.name = name
        self.author = author
        kind = nil
        customTag = nil
        coverUrl = nil
        customCoverUrl = nil
        intro = nil
        customIntro = nil
        charset = nil
        type = 0
        group = 0
        latestChapterTitle = nil
        latestChapterTime = 0
        lastCheckTime = 0
        lastCheckCount = 0
        totalChapterNum = 0
        durChapterTitle = nil
        durChapterIndex = 0
        durVolumeIndex = 0
        chapterInVolumeIndex = 0
        durChapterPos = 0
        durChapterTime = 0
        wordCount = nil
        canUpdate = true
        order = 0
        originOrder = 0
        variable = nil
        readConfig = nil
        syncTime = 0
    }

    private enum CodingKeys: String, CodingKey {
        case bookUrl, tocUrl, origin, originName, name, author, kind, customTag, coverUrl, customCoverUrl
        case intro, customIntro, charset, type, group, latestChapterTitle, latestChapterTime, lastCheckTime
        case lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex, durVolumeIndex
        case chapterInVolumeIndex, durChapterPos, durChapterTime, wordCount, canUpdate, order, originOrder
        case variable, readConfig, syncTime
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        bookUrl = try value.decodeIfPresent(String.self, forKey: .bookUrl) ?? ""
        tocUrl = try value.decodeIfPresent(String.self, forKey: .tocUrl) ?? ""
        origin = try value.decodeIfPresent(String.self, forKey: .origin) ?? "local"
        originName = try value.decodeIfPresent(String.self, forKey: .originName) ?? ""
        name = try value.decodeIfPresent(String.self, forKey: .name) ?? ""
        author = try value.decodeIfPresent(String.self, forKey: .author) ?? ""
        kind = try value.decodeIfPresent(String.self, forKey: .kind)
        customTag = try value.decodeIfPresent(String.self, forKey: .customTag)
        coverUrl = try value.decodeIfPresent(String.self, forKey: .coverUrl)
        customCoverUrl = try value.decodeIfPresent(String.self, forKey: .customCoverUrl)
        intro = try value.decodeIfPresent(String.self, forKey: .intro)
        customIntro = try value.decodeIfPresent(String.self, forKey: .customIntro)
        charset = try value.decodeIfPresent(String.self, forKey: .charset)
        type = try value.decodeIfPresent(Int.self, forKey: .type) ?? 0
        group = try value.decodeIfPresent(Int64.self, forKey: .group) ?? 0
        latestChapterTitle = try value.decodeIfPresent(String.self, forKey: .latestChapterTitle)
        latestChapterTime = try value.decodeIfPresent(Int64.self, forKey: .latestChapterTime) ?? 0
        lastCheckTime = try value.decodeIfPresent(Int64.self, forKey: .lastCheckTime) ?? 0
        lastCheckCount = try value.decodeIfPresent(Int.self, forKey: .lastCheckCount) ?? 0
        totalChapterNum = try value.decodeIfPresent(Int.self, forKey: .totalChapterNum) ?? 0
        durChapterTitle = try value.decodeIfPresent(String.self, forKey: .durChapterTitle)
        durChapterIndex = try value.decodeIfPresent(Int.self, forKey: .durChapterIndex) ?? 0
        durVolumeIndex = try value.decodeIfPresent(Int.self, forKey: .durVolumeIndex) ?? 0
        chapterInVolumeIndex = try value.decodeIfPresent(Int.self, forKey: .chapterInVolumeIndex) ?? 0
        durChapterPos = try value.decodeIfPresent(Int.self, forKey: .durChapterPos) ?? 0
        durChapterTime = try value.decodeIfPresent(Int64.self, forKey: .durChapterTime) ?? 0
        wordCount = try value.decodeIfPresent(String.self, forKey: .wordCount)
        canUpdate = try value.decodeIfPresent(Bool.self, forKey: .canUpdate) ?? true
        order = try value.decodeIfPresent(Int.self, forKey: .order) ?? 0
        originOrder = try value.decodeIfPresent(Int.self, forKey: .originOrder) ?? 0
        variable = try value.decodeIfPresent(String.self, forKey: .variable)
        readConfig = try value.decodeIfPresent(BookReadConfig.self, forKey: .readConfig)
        syncTime = try value.decodeIfPresent(Int64.self, forKey: .syncTime) ?? 0
    }
}

public struct BookReadConfig: Codable, Hashable, Sendable {
    /// Serialized EPUB locator, independent of the device's font size and pagination.
    public var epubLocation: String?
    public var reverseToc = false
    public var pageAnim: Int?
    public var reSegment = false
    public var imageStyle: String?
    public var useReplaceRule: Bool?
    public var delTag: Int64 = 0
    public var ttsEngine: String?
    public var splitLongChapter = true
    public var readSimulating = false
    public var startDate: String?
    public var startChapter: Int?
    public var dailyChapters = 3
    public var openCredits = 0
    public var closeCredits = 0
    public var playMode = 0
    public var playSpeed: Float = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case reverseToc, pageAnim, reSegment, imageStyle, useReplaceRule, delTag, ttsEngine
        case splitLongChapter, readSimulating, startDate, startChapter, dailyChapters
        case openCredits, closeCredits, playMode, playSpeed, epubLocation
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        epubLocation = try value.decodeIfPresent(String.self, forKey: .epubLocation)
        reverseToc = try value.decodeIfPresent(Bool.self, forKey: .reverseToc) ?? false
        pageAnim = try value.decodeIfPresent(Int.self, forKey: .pageAnim)
        reSegment = try value.decodeIfPresent(Bool.self, forKey: .reSegment) ?? false
        imageStyle = try value.decodeIfPresent(String.self, forKey: .imageStyle)
        useReplaceRule = try value.decodeIfPresent(Bool.self, forKey: .useReplaceRule)
        delTag = try value.decodeIfPresent(Int64.self, forKey: .delTag) ?? 0
        ttsEngine = try value.decodeIfPresent(String.self, forKey: .ttsEngine)
        splitLongChapter = try value.decodeIfPresent(Bool.self, forKey: .splitLongChapter) ?? true
        readSimulating = try value.decodeIfPresent(Bool.self, forKey: .readSimulating) ?? false
        startDate = try value.decodeIfPresent(String.self, forKey: .startDate)
        startChapter = try value.decodeIfPresent(Int.self, forKey: .startChapter)
        dailyChapters = try value.decodeIfPresent(Int.self, forKey: .dailyChapters) ?? 3
        openCredits = try value.decodeIfPresent(Int.self, forKey: .openCredits) ?? 0
        closeCredits = try value.decodeIfPresent(Int.self, forKey: .closeCredits) ?? 0
        playMode = try value.decodeIfPresent(Int.self, forKey: .playMode) ?? 0
        playSpeed = try value.decodeIfPresent(Float.self, forKey: .playSpeed) ?? 1
    }
}

public struct BookGroup: Codable, Hashable, Identifiable, Sendable {
    public static let idRoot: Int64 = -100
    public static let idAll: Int64 = -1
    public static let idLocal: Int64 = -2
    public static let idAudio: Int64 = -3
    public static let idNetNone: Int64 = -4
    public static let idLocalNone: Int64 = -5
    public static let idVideo: Int64 = -6
    public static let idError: Int64 = -11

    public var groupId: Int64
    public var groupName: String
    public var cover: String?
    public var order: Int
    public var enableRefresh: Bool
    public var show: Bool
    public var bookSort: Int
    public var onlyUpdateRead: Bool

    public var id: Int64 { groupId }

    public init(
        groupId: Int64,
        groupName: String,
        cover: String? = nil,
        order: Int = 0,
        enableRefresh: Bool = true,
        show: Bool = true,
        bookSort: Int = -1,
        onlyUpdateRead: Bool = false
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.cover = cover
        self.order = order
        self.enableRefresh = enableRefresh
        self.show = show
        self.bookSort = bookSort
        self.onlyUpdateRead = onlyUpdateRead
    }
}

public struct BookChapter: Codable, Hashable, Identifiable, Sendable {
    public var url: String
    public var title: String
    public var isVolume: Bool
    public var baseUrl: String
    public var bookUrl: String
    public var index: Int
    public var isVip: Bool
    public var isPay: Bool
    public var resourceUrl: String?
    public var tag: String?
    public var wordCount: String?
    public var start: Int64?
    public var end: Int64?
    public var startFragmentId: String?
    public var endFragmentId: String?
    public var variable: String?
    public var imageURL: String?

    public var id: String { "\(bookUrl)\u{0}\(url)" }

    public init(url: String, title: String, bookUrl: String, index: Int) {
        self.url = url
        self.title = title
        isVolume = false
        baseUrl = ""
        self.bookUrl = bookUrl
        self.index = index
        isVip = false
        isPay = false
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, isVolume, baseUrl, bookUrl, index, isVip, isPay, resourceUrl, tag, wordCount
        case start, end, startFragmentId, endFragmentId, variable, imgUrl, imageURL
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        url = try value.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try value.decodeIfPresent(String.self, forKey: .title) ?? ""
        isVolume = try value.decodeIfPresent(Bool.self, forKey: .isVolume) ?? false
        baseUrl = try value.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        bookUrl = try value.decodeIfPresent(String.self, forKey: .bookUrl) ?? ""
        index = try value.decodeIfPresent(Int.self, forKey: .index) ?? 0
        isVip = try value.decodeIfPresent(Bool.self, forKey: .isVip) ?? false
        isPay = try value.decodeIfPresent(Bool.self, forKey: .isPay) ?? false
        resourceUrl = try value.decodeIfPresent(String.self, forKey: .resourceUrl)
        tag = try value.decodeIfPresent(String.self, forKey: .tag)
        wordCount = try value.decodeIfPresent(String.self, forKey: .wordCount)
        start = try value.decodeIfPresent(Int64.self, forKey: .start)
        end = try value.decodeIfPresent(Int64.self, forKey: .end)
        startFragmentId = try value.decodeIfPresent(String.self, forKey: .startFragmentId)
        endFragmentId = try value.decodeIfPresent(String.self, forKey: .endFragmentId)
        variable = try value.decodeIfPresent(String.self, forKey: .variable)
        imageURL = try value.decodeIfPresent(String.self, forKey: .imgUrl)
            ?? value.decodeIfPresent(String.self, forKey: .imageURL)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(url, forKey: .url)
        try value.encode(title, forKey: .title)
        try value.encode(isVolume, forKey: .isVolume)
        try value.encode(baseUrl, forKey: .baseUrl)
        try value.encode(bookUrl, forKey: .bookUrl)
        try value.encode(index, forKey: .index)
        try value.encode(isVip, forKey: .isVip)
        try value.encode(isPay, forKey: .isPay)
        try value.encodeIfPresent(resourceUrl, forKey: .resourceUrl)
        try value.encodeIfPresent(tag, forKey: .tag)
        try value.encodeIfPresent(wordCount, forKey: .wordCount)
        try value.encodeIfPresent(start, forKey: .start)
        try value.encodeIfPresent(end, forKey: .end)
        try value.encodeIfPresent(startFragmentId, forKey: .startFragmentId)
        try value.encodeIfPresent(endFragmentId, forKey: .endFragmentId)
        try value.encodeIfPresent(variable, forKey: .variable)
        try value.encodeIfPresent(imageURL, forKey: .imgUrl)
    }
}

public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var epubLocation: String?
    public var time: Int64
    public var bookName: String
    public var bookAuthor: String
    public var chapterIndex: Int
    public var chapterPosition: Int
    public var chapterName: String
    public var bookText: String
    public var content: String

    public var id: Int64 { time }

    public init(time: Int64, bookName: String, bookAuthor: String = "") {
        self.time = time
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        chapterIndex = 0
        chapterPosition = 0
        chapterName = ""
        bookText = ""
        content = ""
    }

    private enum CodingKeys: String, CodingKey {
        case time, bookName, bookAuthor, chapterIndex, chapterPos, chapterPosition
        case chapterName, bookText, content, epubLocation
    }

    public func resolvedChapterIndex(in chapters: [BookChapter]) -> Int? {
        if !chapterName.isEmpty,
           let index = chapters.firstIndex(where: { !$0.isVolume && $0.title == chapterName }) {
            return index
        }
        return chapters.firstIndex(where: { !$0.isVolume && $0.index == chapterIndex })
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        epubLocation = try values.decodeIfPresent(String.self, forKey: .epubLocation)
        time = try values.decodeIfPresent(Int64.self, forKey: .time) ?? Int64(Date().timeIntervalSince1970 * 1_000)
        bookName = try values.decodeIfPresent(String.self, forKey: .bookName) ?? ""
        bookAuthor = try values.decodeIfPresent(String.self, forKey: .bookAuthor) ?? ""
        chapterIndex = try values.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        chapterPosition = try values.decodeIfPresent(Int.self, forKey: .chapterPos)
            ?? values.decodeIfPresent(Int.self, forKey: .chapterPosition)
            ?? 0
        chapterName = try values.decodeIfPresent(String.self, forKey: .chapterName) ?? ""
        bookText = try values.decodeIfPresent(String.self, forKey: .bookText) ?? ""
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(epubLocation, forKey: .epubLocation)
        try values.encode(time, forKey: .time)
        try values.encode(bookName, forKey: .bookName)
        try values.encode(bookAuthor, forKey: .bookAuthor)
        try values.encode(chapterIndex, forKey: .chapterIndex)
        try values.encode(chapterPosition, forKey: .chapterPos)
        try values.encode(chapterName, forKey: .chapterName)
        try values.encode(bookText, forKey: .bookText)
        try values.encode(content, forKey: .content)
    }
}

public struct ReadRecord: Codable, Hashable, Identifiable, Sendable {
    public var deviceId: String
    public var bookName: String
    public var readTime: Int64
    public var lastRead: Int64
    public var dailyReadTimes: [String: Int64]

    public var id: String { "\(deviceId)\u{0}\(bookName)" }

    public init(
        deviceId: String,
        bookName: String,
        readTime: Int64 = 0,
        lastRead: Int64? = nil,
        dailyReadTimes: [String: Int64] = [:]
    ) {
        self.deviceId = deviceId
        self.bookName = bookName
        self.readTime = readTime
        self.lastRead = lastRead ?? Int64(Date().timeIntervalSince1970 * 1_000)
        self.dailyReadTimes = dailyReadTimes
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, bookName, readTime, lastRead, dailyReadTimes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        bookName = try values.decodeIfPresent(String.self, forKey: .bookName) ?? ""
        readTime = try values.decodeIfPresent(Int64.self, forKey: .readTime) ?? 0
        lastRead = try values.decodeIfPresent(Int64.self, forKey: .lastRead) ?? 0
        dailyReadTimes = try values.decodeIfPresent([String: Int64].self, forKey: .dailyReadTimes) ?? [:]
    }
}

public struct ReadRecordSummary: Hashable, Identifiable, Sendable {
    public var bookName: String
    public var readTime: Int64
    public var lastRead: Int64

    public var id: String { bookName }

    public init(bookName: String, readTime: Int64, lastRead: Int64) {
        self.bookName = bookName
        self.readTime = readTime
        self.lastRead = lastRead
    }
}

public struct ReplaceRule: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var group: String?
    public var pattern: String
    public var replacement: String
    public var scope: String?
    public var scopeTitle: Bool
    public var scopeContent: Bool
    public var excludeScope: String?
    public var isEnabled: Bool
    public var isRegex: Bool
    public var timeoutMillisecond: Int64
    public var sortOrder: Int

    public init(id: Int64, name: String, pattern: String, replacement: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        scopeTitle = false
        scopeContent = true
        isEnabled = true
        isRegex = true
        timeoutMillisecond = 3_000
        sortOrder = Int.min
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, group, pattern, replacement, scope, scopeTitle, scopeContent
        case excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder, order
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(Int64.self, forKey: .id) ?? Int64(Date().timeIntervalSince1970 * 1_000)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        group = try values.decodeIfPresent(String.self, forKey: .group)
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        replacement = try values.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        scopeTitle = try values.decodeIfPresent(Bool.self, forKey: .scopeTitle) ?? false
        scopeContent = try values.decodeIfPresent(Bool.self, forKey: .scopeContent) ?? true
        excludeScope = try values.decodeIfPresent(String.self, forKey: .excludeScope)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isRegex = try values.decodeIfPresent(Bool.self, forKey: .isRegex) ?? true
        timeoutMillisecond = try values.decodeIfPresent(Int64.self, forKey: .timeoutMillisecond) ?? 3_000
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder)
            ?? values.decodeIfPresent(Int.self, forKey: .order)
            ?? Int.min
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(group, forKey: .group)
        try values.encode(pattern, forKey: .pattern)
        try values.encode(replacement, forKey: .replacement)
        try values.encodeIfPresent(scope, forKey: .scope)
        try values.encode(scopeTitle, forKey: .scopeTitle)
        try values.encode(scopeContent, forKey: .scopeContent)
        try values.encodeIfPresent(excludeScope, forKey: .excludeScope)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(isRegex, forKey: .isRegex)
        try values.encode(timeoutMillisecond, forKey: .timeoutMillisecond)
        try values.encode(sortOrder, forKey: .order)
    }
}
