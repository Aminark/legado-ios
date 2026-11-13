import Foundation

public struct RssSource: Codable, Hashable, Identifiable, Sendable {
    public var sourceUrl = ""
    public var sourceName = ""
    public var sourceIcon = ""
    public var sourceGroup: String?
    public var sourceComment: String?
    public var enabled = true
    public var variableComment: String?
    public var jsLib: String?
    public var enabledCookieJar: Bool? = true
    public var concurrentRate: String?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var sortUrl: String?
    public var singleUrl = false
    public var articleStyle = 0
    public var ruleArticles: String?
    public var ruleNextPage: String?
    public var ruleTitle: String?
    public var rulePubDate: String?
    public var ruleDescription: String?
    public var ruleImage: String?
    public var ruleLink: String?
    public var ruleContent: String?
    public var contentWhitelist: String?
    public var contentBlacklist: String?
    public var shouldOverrideUrlLoading: String?
    public var style: String?
    public var enableJs = true
    public var loadWithBaseUrl = true
    public var injectJs: String?
    public var preloadJs: String?
    public var startHtml: String?
    public var startStyle: String?
    public var startJs: String?
    public var showWebLog = false
    public var lastUpdateTime: Int64 = 0
    public var customOrder = 0
    public var type = 0
    public var preload = false
    public var cacheFirst = false
    public var searchUrl: String?
    public var id: String { sourceUrl }

    public init(sourceUrl: String = "", sourceName: String = "") {
        self.sourceUrl = sourceUrl
        self.sourceName = sourceName
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RSSCodingKey.self)
        sourceUrl = values.string("sourceUrl") ?? ""
        sourceName = values.string("sourceName") ?? ""
        sourceIcon = values.string("sourceIcon") ?? ""
        sourceGroup = values.string("sourceGroup")
        sourceComment = values.string("sourceComment")
        enabled = values.bool("enabled") ?? true
        variableComment = values.string("variableComment")
        jsLib = values.string("jsLib")
        enabledCookieJar = values.contains("enabledCookieJar") ? values.bool("enabledCookieJar") : true
        concurrentRate = values.string("concurrentRate")
        header = values.string("header")
        loginUrl = values.string("loginUrl")
        loginUi = values.jsonString("loginUi")
        loginCheckJs = values.string("loginCheckJs")
        coverDecodeJs = values.string("coverDecodeJs")
        sortUrl = values.string("sortUrl")
        singleUrl = values.bool("singleUrl") ?? false
        articleStyle = values.int("articleStyle") ?? 0
        ruleArticles = values.string("ruleArticles")
        ruleNextPage = values.string("ruleNextPage")
        ruleTitle = values.string("ruleTitle")
        rulePubDate = values.string("rulePubDate")
        ruleDescription = values.string("ruleDescription")
        ruleImage = values.string("ruleImage")
        ruleLink = values.string("ruleLink")
        ruleContent = values.string("ruleContent")
        contentWhitelist = values.string("contentWhitelist")
        contentBlacklist = values.string("contentBlacklist")
        shouldOverrideUrlLoading = values.string("shouldOverrideUrlLoading")
        style = values.string("style")
        enableJs = values.bool("enableJs") ?? true
        loadWithBaseUrl = values.bool("loadWithBaseUrl") ?? true
        injectJs = values.string("injectJs")
        preloadJs = values.string("preloadJs")
        startHtml = values.string("startHtml")
        startStyle = values.string("startStyle")
        startJs = values.string("startJs")
        showWebLog = values.bool("showWebLog") ?? false
        lastUpdateTime = values.int64("lastUpdateTime") ?? 0
        customOrder = values.int("customOrder") ?? 0
        type = values.int("type") ?? 0
        preload = values.bool("preload") ?? false
        cacheFirst = values.bool("cacheFirst") ?? false
        searchUrl = values.string("searchUrl")
    }

    public var groups: [String] { BookSource.parseGroups(sourceGroup) }
    public var displayNameGroup: String {
        groups.isEmpty ? sourceName : "\(sourceName) (\(sourceGroup ?? ""))"
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.sourceUrl == rhs.sourceUrl }
    public func hash(into hasher: inout Hasher) { hasher.combine(sourceUrl) }

    public mutating func addGroups(_ value: String) {
        var merged = Set(groups)
        merged.formUnion(BookSource.parseGroups(value))
        sourceGroup = merged.joined(separator: ",")
    }
    public mutating func removeGroups(_ value: String) {
        let removed = Set(BookSource.parseGroups(value))
        sourceGroup = groups.filter { !removed.contains($0) }.joined(separator: ",")
    }
    public func displayVariableComment(_ other: String) -> String {
        guard let variableComment, !variableComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return other }
        return "\(variableComment)\n\(other)"
    }
}

public struct RssArticle: Codable, Hashable, Identifiable, Sendable {
    // Evaluation-only storage identity and pending large values. Never encoded
    // into imported/exported article data or used for article equality.
    var ruleVariableState: RSSVariableState?
    private enum CodingKeys: String, CodingKey {
        case origin, sort, title, order, link, pubDate, description, content, image, group, read, variable, type, durPos
    }
    public var origin = ""
    public var sort = ""
    public var title = ""
    public var order: Int64 = 0
    public var link = ""
    public var pubDate: String?
    public var description: String?
    public var content: String?
    public var image: String?
    public var group = "默认分组"
    public var read = false
    public var variable: String?
    public var type = 0
    public var durPos = 0
    public var id: String { "\(origin)\u{0}\(link)\u{0}\(sort)" }

    public init(origin: String = "", sort: String = "", title: String = "", link: String = "") {
        self.origin = origin; self.sort = sort; self.title = title; self.link = link
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RSSCodingKey.self)
        origin = values.string("origin") ?? ""; sort = values.string("sort") ?? ""
        title = values.string("title") ?? ""; order = values.int64("order") ?? 0
        link = values.string("link") ?? ""; pubDate = values.string("pubDate")
        description = values.string("description"); content = values.string("content")
        image = values.string("image"); group = values.string("group") ?? "默认分组"
        read = values.bool("read") ?? false; variable = values.string("variable")
        type = values.int("type") ?? 0; durPos = values.int("durPos") ?? 0
    }

    public func star(at time: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> RssStar {
        .init(article: self, starTime: time)
    }
    public func record(at time: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> RssReadRecord {
        .init(record: link, title: title, readTime: time, origin: origin, sort: sort, image: image, type: type, durPos: durPos, pubDate: pubDate)
    }
    public var variableMap: [String: String] { Self.decodeVariables(variable) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.origin == rhs.origin && lhs.link == rhs.link && lhs.sort == rhs.sort
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(link) }

    fileprivate static func decodeVariables(_ value: String?) -> [String: String] {
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            if let string = pair.value as? String { result[pair.key] = string }
            else if !(pair.value is NSNull) { result[pair.key] = String(describing: pair.value) }
        }
    }
}

public struct RssReadRecord: Codable, Hashable, Identifiable, Sendable {
    public var record: String
    public var title: String?
    public var readTime: Int64?
    public var read: Bool
    public var origin: String
    public var sort: String
    public var image: String?
    public var type: Int
    public var durPos: Int
    public var pubDate: String?
    public var id: String { record }
    public init(record: String, title: String? = nil, readTime: Int64? = nil, read: Bool = true, origin: String = "", sort: String = "", image: String? = nil, type: Int = 0, durPos: Int = 0, pubDate: String? = nil) {
        self.record = record; self.title = title; self.readTime = readTime; self.read = read
        self.origin = origin; self.sort = sort; self.image = image; self.type = type
        self.durPos = durPos; self.pubDate = pubDate
    }
    public var article: RssArticle {
        var value = RssArticle(origin: origin, sort: sort, title: title ?? "", link: record)
        value.image = image; value.type = type; value.durPos = durPos; value.pubDate = pubDate
        return value
    }
}

public struct RssStar: Codable, Hashable, Identifiable, Sendable {
    public var origin = ""
    public var sort = ""
    public var title = ""
    public var starTime: Int64 = 0
    public var link = ""
    public var pubDate: String?
    public var description: String?
    public var content: String?
    public var image: String?
    public var group = "默认分组"
    public var variable: String?
    public var type = 0
    public var durPos = 0
    public var id: String { "\(origin)\u{0}\(link)" }
    public init(article: RssArticle = .init(), starTime: Int64 = 0) {
        origin = article.origin; sort = article.sort; title = article.title; self.starTime = starTime
        link = article.link; pubDate = article.pubDate; description = article.description
        content = article.content; image = article.image; group = article.group
        variable = article.variable; type = article.type; durPos = article.durPos
    }
    public init(from decoder: Decoder) throws {
        let article = try RssArticle(from: decoder)
        self.init(article: article, starTime: try decoder.container(keyedBy: RSSCodingKey.self).int64("starTime") ?? 0)
    }
    public var article: RssArticle {
        var value = RssArticle(origin: origin, sort: sort, title: title, link: link)
        value.pubDate = pubDate; value.description = description; value.content = content
        value.image = image; value.group = group; value.variable = variable; value.type = type; value.durPos = durPos
        return value
    }
    public var variableMap: [String: String] { RssArticle.decodeVariables(variable) }
    public func record(at time: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> RssReadRecord {
        .init(record: link, title: title, readTime: time, origin: origin, sort: sort, image: image, type: type, durPos: durPos, pubDate: pubDate)
    }
}

private struct RSSCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == RSSCodingKey {
    func key(_ value: String) -> Key { Key(stringValue: value)! }
    func contains(_ value: String) -> Bool { contains(key(value)) }
    func string(_ name: String) -> String? {
        let key = key(name)
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }
    func bool(_ name: String) -> Bool? {
        let key = key(name)
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = string(name)?.lowercased() { return ["true", "1", "yes"].contains(value) ? true : (["false", "0", "no"].contains(value) ? false : nil) }
        return nil
    }
    func int(_ name: String) -> Int? {
        let key = key(name)
        if let value = try? decode(Int.self, forKey: key) { return value }
        return string(name).flatMap(Int.init)
    }
    func int64(_ name: String) -> Int64? {
        let key = key(name)
        if let value = try? decode(Int64.self, forKey: key) { return value }
        return string(name).flatMap(Int64.init)
    }
    func jsonString(_ name: String) -> String? {
        if let value = string(name) { return value }
        let key = key(name)
        guard let value = try? decode(JSONValue.self, forKey: key) else { return nil }
        return value.stringValue
    }
}
