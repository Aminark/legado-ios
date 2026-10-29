import Foundation

public protocol RssSourceRepository: Sendable {
    func all() async throws -> [RssSource]
    func enabled() async throws -> [RssSource]
    func disabled() async throws -> [RssSource]
    func groups() async throws -> [String]
    func inGroup(_ group: String) async throws -> [RssSource]
    func search(_ key: String) async throws -> [RssSource]
    func save(_ values: [RssSource]) async throws
    func setEnabled(_ value: Bool, sourceURL: String) async throws
    func remove(sourceURL: String) async throws
}

public actor SQLiteRssSourceRepository: RssSourceRepository {
    private let database: LegadoDatabase
    public init(database: LegadoDatabase) { self.database = database }

    public func all() async throws -> [RssSource] { try await database.loadRssSources() }
    public func enabled() async throws -> [RssSource] { try await all().filter(\.enabled) }
    public func disabled() async throws -> [RssSource] { try await all().filter { !$0.enabled } }
    public func groups() async throws -> [String] {
        var seen = Set<String>()
        return try await all().flatMap(\.groups).filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func inGroup(_ group: String) async throws -> [RssSource] {
        try await all().filter { $0.groups.contains(group) }
    }
    public func search(_ key: String) async throws -> [RssSource] {
        guard !key.isEmpty else { return try await all() }
        return try await all().filter {
            [$0.sourceName, $0.sourceUrl, $0.sourceGroup ?? "", $0.sourceComment ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(key) }
        }
    }
    public func enabled(search key: String) async throws -> [RssSource] {
        try await search(key).filter(\.enabled)
    }
    public func enabled(inGroup group: String) async throws -> [RssSource] {
        try await inGroup(group).filter(\.enabled)
    }
    public func loginSources() async throws -> [RssSource] {
        try await all().filter { !($0.loginUrl ?? "").isEmpty }
    }
    public func noGroup() async throws -> [RssSource] {
        try await all().filter { $0.groups.isEmpty || $0.groups.contains("未分组") }
    }
    public func contains(sourceURL: String) async throws -> Bool {
        try await all().contains { $0.sourceUrl == sourceURL }
    }
    public func source(for sourceURL: String) async throws -> RssSource? {
        try await all().first { $0.sourceUrl == sourceURL }
    }
    public func save(_ values: [RssSource]) async throws { try await database.replaceRssSources(values) }
    public func setEnabled(_ value: Bool, sourceURL: String) async throws {
        try await database.setRssSourceEnabled(value, sourceURL: sourceURL)
    }
    public func remove(sourceURL: String) async throws {
        try await database.removeRssSource(sourceURL: sourceURL)
    }
}

public protocol RssArticleRepository: Sendable {
    func articles(origin: String, sort: String) async throws -> [RssArticle]
    func replace(_ values: [RssArticle], origin: String, sort: String) async throws
    func append(_ values: [RssArticle]) async throws
    func put(_ values: [RssArticle]) async throws
    func clearOld(origin: String, sort: String, before order: Int64) async throws
    func remove(origin: String) async throws
    func article(origin: String, link: String, sort: String) async throws -> RssArticle?
    func article(origin: String, link: String) async throws -> RssArticle?
    func update(_ values: [RssArticle]) async throws
    func updateOrigin(from oldOrigin: String, to origin: String) async throws
}

public actor SQLiteRssArticleRepository: RssArticleRepository {
    private let database: LegadoDatabase
    public init(database: LegadoDatabase) { self.database = database }
    public func articles(origin: String, sort: String) async throws -> [RssArticle] {
        try await database.loadRssArticles(origin: origin, sort: sort)
    }
    public func replace(_ values: [RssArticle], origin: String, sort: String) async throws {
        try await database.replaceRssArticles(values, origin: origin, sort: sort)
    }
    public func append(_ values: [RssArticle]) async throws { try await database.appendRssArticles(values) }
    public func put(_ values: [RssArticle]) async throws { try await database.putRssArticles(values) }
    public func clearOld(origin: String, sort: String, before order: Int64) async throws {
        try await database.clearOldRssArticles(origin: origin, sort: sort, before: order)
    }
    public func remove(origin: String) async throws { try await database.removeRssArticles(origin: origin) }
    public func article(origin: String, link: String, sort: String) async throws -> RssArticle? {
        try await database.findRssArticle(origin: origin, link: link, sort: sort)
    }
    public func article(origin: String, link: String) async throws -> RssArticle? {
        try await database.findRssArticle(origin: origin, link: link)
    }
    public func update(_ values: [RssArticle]) async throws { try await database.updateRssArticles(values) }
    public func updateOrigin(from oldOrigin: String, to origin: String) async throws {
        try await database.updateRssArticleOrigin(from: oldOrigin, to: origin)
    }
}

public actor SQLiteRssReadRecordRepository {
    private let database: LegadoDatabase
    public init(database: LegadoDatabase) { self.database = database }
    public func all() async throws -> [RssReadRecord] { try await database.loadRssReadRecords() }
    public func forOrigin(_ origin: String) async throws -> [RssReadRecord] {
        try await all().filter { $0.origin == origin }
    }
    public func insertIgnoringExisting(_ value: RssReadRecord) async throws {
        try await database.appendRssReadRecords([value])
    }
    public func record(_ record: String, origin: String) async throws -> RssReadRecord? {
        try await database.findRssReadRecord(record: record, origin: origin)
    }
    public func update(_ values: [RssReadRecord]) async throws { try await database.updateRssReadRecords(values) }
    public func clear() async throws { try await database.clearRssReadRecords() }
    public func remove(origin: String) async throws { try await database.removeRssReadRecords(origin: origin) }
}

public actor SQLiteRssStarRepository {
    private let database: LegadoDatabase
    public init(database: LegadoDatabase) { self.database = database }
    public func all() async throws -> [RssStar] { try await database.loadRssStars() }
    public func groups() async throws -> [String] {
        var seen = Set<String>()
        return try await all().map(\.group).filter { seen.insert($0).inserted }.sorted()
    }
    public func inGroup(_ group: String) async throws -> [RssStar] {
        try await all().filter { $0.group == group }
    }
    public func save(_ value: RssStar) async throws {
        try await database.updateRssStars([value])
    }
    public func remove(origin: String, link: String) async throws {
        try await database.removeRssStars(origin: origin, link: link)
    }
    public func star(origin: String, link: String) async throws -> RssStar? { try await database.findRssStar(origin: origin, link: link) }
    public func remove(origin: String) async throws { try await database.removeRssStars(origin: origin) }
    public func remove(group: String) async throws { try await database.removeRssStars(group: group) }
    public func clear() async throws { try await database.clearRssStars() }
    public func updateOrigin(from oldOrigin: String, to origin: String) async throws {
        try await database.updateRssStarOrigin(from: oldOrigin, to: origin)
    }
}

public enum RSSRepositoryFactory {
    public static func database(url: URL = LegadoDatabase.defaultURL()) throws -> LegadoDatabase {
        try LegadoDatabase(url: url)
    }
}
