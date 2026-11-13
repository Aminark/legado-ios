import Foundation
import SQLite3
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct RSSLibraryRegressionTests {
    @Test func databaseSaveFailureReportsErrorButDoesNotRollbackEarlierRuleFileWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("rss.sqlite3")
        let database = try LegadoDatabase(url: databaseURL)
        let store = RSSVariableStore(directory: directory.appendingPathComponent("ruleData"))
        var source = source()
        source.ruleContent = "@js:rssArticle.title = 'unsaved'; rssArticle.putBigVariable('key', 'rule-committed'); 'new content'"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        try await database.putRssArticles([article])
        var handle: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
        defer { if let handle { sqlite3_close(handle) } }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_article_save BEFORE INSERT ON rssArticles BEGIN SELECT RAISE(FAIL, 'article save failed'); END", nil, nil, nil) == SQLITE_OK)
        let model = RSSLibraryModel(database: database, service: .init(
            transport: RSSSequenceTransport(bodies: ["body"]), urlBuilder: .init(rssVariableStore: store),
            engine: .init(javaScript: .init(rssVariableStore: store)), networkPolicy: .init()
        ))

        _ = await model.readingMode(for: article, source: source)

        #expect(model.errorMessage?.contains("article save failed") == true)
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "original")
        #expect(try store.get(origin: article.origin, link: article.link, key: "key") == "rule-committed")
    }

    @Test func failedContentScriptDoesNotPersistPartialArticleMutations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.title = 'partial'; rssArticle.putVariable('token', 'partial'); throw new Error('failed content')"
        var article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        article.variable = #"{"token":"original"}"#
        try await database.putRssArticles([article])

        _ = await model.readingMode(for: article, source: source)

        #expect(model.errorMessage?.contains("failed content") == true)
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "original")
        #expect(saved?.variableMap["token"] == "original")
    }

    @Test func scriptIdentityChangesDoNotMoveCachedArticlesOrOverwriteOtherEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.origin = 'https://other.test'; rssArticle.link = '/target'; rssArticle.sort = 'other'; rssArticle.putVariable('token', 'kept'); 'fresh'"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        let other = RssArticle(origin: "https://other.test", sort: "other", title: "protected", link: "/target")
        try await database.putRssArticles([article, other])
        await model.toggleStar(article)

        #expect(await model.readingMode(for: article, source: source) == .html(content: "fresh", baseURL: article.link))
        let original = try await database.findRssArticle(origin: article.origin, link: article.link, sort: article.sort)
        let target = try await database.findRssArticle(origin: other.origin, link: other.link, sort: other.sort)
        #expect(original?.description == "fresh")
        #expect(original?.variableMap["token"] == "kept")
        #expect(target?.title == "protected")
        #expect(target?.description == nil)
        #expect(model.stars.count == 1)
        #expect(model.stars.first?.link == article.link)
    }

    @Test func contentRuleArticleMutationsPersistWithArticleAndFavoriteVariables() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.setTitle('updated'); rssArticle.putVariable('token', 'saved'); java.get('token')"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        await model.toggleStar(article)

        let mode = await model.readingMode(for: article, source: source)

        #expect(mode == .html(content: "saved", baseURL: article.link))
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "updated")
        #expect(saved?.variableMap["token"] == "saved")
        #expect(model.stars.first?.article.variableMap["token"] == "saved")
    }

    @Test func explicitContentRefreshReplacesTheExistingDescription() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [#"{"content":"更新后的正文"}"#])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleContent = "$.content"
        var article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "文章", link: source.sourceUrl + "/one")
        article.description = "旧正文"
        #expect(await model.readingMode(for: article, source: source) == .html(content: "旧正文", baseURL: article.link))
        let refreshed = await model.readingMode(for: article, source: source, forceRefresh: true)
        #expect(refreshed == .html(content: "更新后的正文", baseURL: article.link))
        #expect(try await database.findRssArticle(origin: source.sourceUrl, link: article.link)?.description == "更新后的正文")
    }

    @Test func searchesDoNotMixPreviousQueriesOrTheCachedFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"旧搜索","link":"/old"}]}"#,
            #"{"items":[{"title":"新搜索","link":"/new"}]}"#,
            #"{"items":[]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        let source = source()
        let cached = RssArticle(origin: source.sourceUrl, sort: "全部", title: "缓存文章", link: "/cached")
        try await database.putRssArticles([cached])
        await model.refresh(source, sortName: "搜索", key: "old")
        #expect(model.articles.map(\.title) == ["旧搜索"])
        await model.refresh(source, sortName: "搜索", key: "new")
        #expect(model.articles.map(\.title) == ["新搜索"])
        await model.refresh(source, sortName: "搜索", key: "missing")
        #expect(model.articles.isEmpty)
        #expect(try await database.loadRssArticles(origin: source.sourceUrl, sort: "全部") == [cached])
    }

    @Test func failedRefreshKeepsTheExistingPageAndNextPageCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"第一页","link":"/one"}],"next":"/page2"}"#,
            nil,
            #"{"items":[{"title":"第二页","link":"/two"}]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        await model.refresh(source)
        await model.refresh(source)
        #expect(model.errorMessage != nil)
        #expect(model.articles.map(\.title) == ["第一页"])
        await model.loadMore(source)
        #expect(model.articles.map(\.title) == ["第一页", "第二页"])
        #expect(await transport.requestCount() == 3)
    }

    @Test func searchPaginationDeduplicatesResultsAndPreservesReadState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"第一篇","link":"/one"}],"next":"/page2"}"#,
            #"{"items":[{"title":"第一篇","link":"/one"},{"title":"第二篇","link":"/two"}]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        await model.refresh(source, sortName: "搜索", key: "test")
        let article = try #require(model.articles.first)
        await model.read(article)
        await model.toggleStar(article)
        await model.loadMore(source, sortName: "搜索", key: "test")
        #expect(model.articles.map(\.title) == ["第一篇", "第二篇"])
        #expect(model.articles.first?.read == true)
        #expect(model.isStarred(article))
    }

    @Test func failedRuleEvaluationPreservesPersistedArticles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [#"{"items":[{"title":"已有文章","link":"/one"}]}"#, "{}"])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "PAGE"
        await model.refresh(source)
        source.ruleArticles = "@js:throw new Error('broken rule')"
        await model.refresh(source)
        #expect(model.errorMessage != nil)
        #expect(model.articles.map(\.title) == ["已有文章"])
        #expect(try await database.loadRssArticles(origin: source.sourceUrl, sort: source.sourceName).map(\.title) == ["已有文章"])
    }

    private func source() -> RssSource {
        var source = RssSource(sourceUrl: "https://rss-model.test", sourceName: "全部")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        return source
    }
}

private actor RSSSequenceTransport: HTTPTransport {
    private var bodies: [String?]
    private var count = 0
    init(bodies: [String?]) { self.bodies = bodies }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        count += 1
        guard !bodies.isEmpty, let body = bodies.removeFirst() else { throw URLError(.networkConnectionLost) }
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
    func requestCount() -> Int { count }
}
