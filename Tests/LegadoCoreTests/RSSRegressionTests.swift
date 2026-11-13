import Foundation
import Testing
@testable import LegadoCore

struct RSSRegressionTests {
    @Test func contentRulesReceiveVariablesProducedByTheArticleRequest() async throws {
        let source = RssSource(sourceUrl: "https://request-variables.test", sourceName: "请求变量")
        var article = RssArticle(
            origin: source.sourceUrl, sort: "全部", title: "文章",
            link: "@js:java.put('token', 'fresh'); '/article'"
        )
        article.variable = #"{"token":"old","shared":"kept"}"#
        let service = RSSService(transport: RSSFixtureTransport(body: "<p>正文</p>"), networkPolicy: .init())

        let result = try await service.contentDetailed(
            article: article,
            rule: "@js:java.get('token') + ':' + java.get('shared')",
            source: source
        )

        #expect(result.content == "fresh:kept")
        #expect(result.requestURL == "https://request-variables.test/article")
        #expect(result.diagnostics.isEmpty)
        #expect(article.variableMap["token"] == "old")
    }

    @Test func nextPageVariablesReachEachArticleWithoutLeakingBetweenArticles() async throws {
        var source = RssSource(sourceUrl: "https://next-variables.test", sourceName: "下一页变量")
        source.ruleArticles = "$.items"
        source.ruleNextPage = "@js:java.put('token', 'page-token'); '/page/2'"
        source.ruleTitle = "$.title"
        source.ruleLink = "@js:var previous = java.get('article'); java.put('article', 'private'); '/article/' + java.get('token') + (previous || '-clean')"

        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: "/page/1", redirectURL: source.sourceUrl + "/page/1",
            body: #"{"items":[{"title":"甲"},{"title":"乙"}]}"#, source: source,
            variables: ["shared": "kept"]
        )

        #expect(report.diagnostics.isEmpty)
        #expect(report.result.articles.count == 2)
        #expect(report.result.articles.allSatisfy { $0.link == source.sourceUrl + "/article/page-token-clean" })
        #expect(report.result.articles.allSatisfy { $0.variableMap == ["token": "page-token", "shared": "kept", "article": "private"] })
    }

    @Test func regexArticleListsKeepCaptureGroupsAndReverseWholeArticles() async throws {
        var source = RssSource(sourceUrl: "https://regex-feed.test", sourceName: "正则文章")
        source.ruleArticles = #"-:title=([^;]+);url=([^\n]+)"#
        source.ruleTitle = "$1"
        source.ruleLink = "$2"

        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: source.sourceUrl, redirectURL: source.sourceUrl,
            body: "title=第一篇;url=/one\ntitle=第二篇;url=/two", source: source
        )

        #expect(report.diagnostics.isEmpty)
        #expect(report.result.articles.map(\.title) == ["第二篇", "第一篇"])
        #expect(report.result.articles.map(\.link) == [source.sourceUrl + "/two", source.sourceUrl + "/one"])
    }

    @Test func concurrentSourceTogglesDoNotOverwriteOneAnother() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let sources = (0..<20).map { RssSource(sourceUrl: "https://feed.test/\($0)", sourceName: "订阅\($0)") }
        try await database.replaceRssSources(sources)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    try await SQLiteRssSourceRepository(database: database).setEnabled(false, sourceURL: source.sourceUrl)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await database.loadRssSources().allSatisfy { !$0.enabled })
    }

    @Test func redirectedFeedResolvesLinksImagesAndNextPageAgainstResponseURL() async throws {
        var source = RssSource(sourceUrl: "https://origin.test", sourceName: "重定向订阅")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        source.ruleImage = "$.image"
        source.ruleNextPage = "$.next"
        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: "/feed?page={{page}}",
            redirectURL: "https://cdn.test/news/index.json",
            body: #"{"items":[{"title":"文章","link":"article.html","image":"cover.jpg"}],"next":"page2.json"}"#,
            source: source
        )
        let article = try #require(report.result.articles.first)
        #expect(article.origin == source.sourceUrl)
        #expect(article.link == "https://cdn.test/news/article.html")
        #expect(article.image == "https://cdn.test/news/cover.jpg")
        #expect(report.result.nextURL == "https://cdn.test/news/page2.json")
    }

    @Test func articleVariablesSurviveUntilContentRequestAndRemainIsolated() async throws {
        var source = RssSource(sourceUrl: "https://feed.test", sourceName: "文章变量")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title@put:{token:$.token}"
        source.ruleLink = "$.link"
        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: source.sourceUrl, redirectURL: source.sourceUrl,
            body: #"{"items":[{"title":"甲","link":"/a","token":"first"},{"title":"乙","link":"/b","token":"second"}]}"#,
            source: source, variables: ["shared": "kept"]
        )
        #expect(report.result.articles.map { $0.variableMap["token"] } == ["first", "second"])
        #expect(report.result.articles.allSatisfy { $0.variableMap["shared"] == "kept" })
    }

    @Test func serviceRejectsBrokenRulesInsteadOfReturningAnEmptySuccessfulFeed() async throws {
        var source = RssSource(sourceUrl: "https://feed.test", sourceName: "无效规则")
        source.ruleArticles = "@js:throw new Error('broken feed rule')"
        let service = RSSService(transport: RSSFixtureTransport(body: "{}"), networkPolicy: .init())
        await #expect(throws: RuleEngineError.self) {
            _ = try await service.articles(sortName: "全部", sortURL: source.sourceUrl, source: source, page: 1)
        }
    }

    @Test func pageSentinelKeepsTheRequestTemplateAfterRedirect() async throws {
        var source = RssSource(sourceUrl: "https://feed.test", sourceName: "分页")
        source.ruleArticles = "$.items"
        source.ruleNextPage = "PAGE"
        let template = "/feed?page={{page}}"
        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: template, redirectURL: "https://cdn.test/feed?page=1",
            body: #"{"items":[]}"#, source: source
        )
        #expect(report.result.nextURL == template)
    }
}

private struct RSSFixtureTransport: HTTPTransport {
    let body: String
    func data(for request: URLRequest) async throws -> HTTPResponse {
        .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
}
