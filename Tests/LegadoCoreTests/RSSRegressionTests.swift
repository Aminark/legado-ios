import Foundation
import Testing
@testable import LegadoCore

struct RSSRegressionTests {
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
