import Foundation
import Testing
@testable import LegadoCore

private struct ExploreMockTransport: HTTPTransport {
    let pages: [String: String]
    var expectedHeaders: [String: String] = [:]

    func data(for request: URLRequest) async throws -> HTTPResponse {
        for (name, value) in expectedHeaders {
            #expect(request.value(forHTTPHeaderField: name) == value)
        }
        let url = try #require(request.url)
        let body = try #require(pages[url.absoluteString])
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

struct BookExploreServiceTests {
    @Test func resolvesDynamicAndLoginHeadersBeforeExploreRequest() async throws {
        var source = BookSource(bookSourceUrl: "https://explore-headers.example", bookSourceName: "登录发现")
        source.header = #"@js:JSON.stringify({'X-Static':'base','X-Dynamic':'script'})"#
        source.ruleExplore = .init(bookList: "$.books", name: "$.name", bookUrl: "$.url")
        BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginHeader", value: #"{"X-Static":"login","X-Session":"authenticated"}"#)
        defer { BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginHeader", value: "") }
        let transport = ExploreMockTransport(
            pages: ["https://explore-headers.example/hot?page=2": #"{"books":[{"name":"登录后的榜单","url":"/1"}]}"#],
            expectedHeaders: ["X-Static": "login", "X-Dynamic": "script", "X-Session": "authenticated", "X-Option": "request"]
        )
        let kind = ExploreKind(title: "热门", url: #"/hot?page={{page}},{"headers":{"X-Option":"request"}}"#)

        let outcome = await BookExploreService(transport: transport).explore(source: source, kind: kind, page: 2)

        #expect(outcome.diagnostics.isEmpty)
        #expect(outcome.books.first?.name == "登录后的榜单")
    }

    @Test func exposesEarlierBookFieldsAndVariablesToLaterExploreRules() async throws {
        var source = BookSource(bookSourceUrl: "https://explore-context.example", bookSourceName: "上下文发现")
        source.ruleExplore = .init(
            bookList: "$.books", name: "$.name", author: "@js:book.name + '-author'",
            intro: "@js:book.author + ':' + book.latestChapterTitle",
            kind: "$.kind", lastChapter: "@js:book.wordCount + '-words'",
            bookUrl: "@js:'/book/' + book.name + '?cover=' + book.coverUrl + '&token=' + java.get('token')",
            coverUrl: "@js:java.put('token', book.kind + '-' + book.wordCount); '/cover/' + book.name + '-' + page",
            wordCount: "@js:book.kind == 'fiction' ? '120' : '60'"
        )
        let transport = ExploreMockTransport(pages: [
            "https://explore-context.example/hot": #"{"books":[{"name":"first","kind":"fiction"},{"name":"second","kind":"history"}]}"#
        ])

        let outcome = await BookExploreService(transport: transport).explore(source: source, kind: .init(title: "热门", url: "/hot"), page: 2)

        #expect(outcome.diagnostics.isEmpty)
        #expect(outcome.books.map(\.intro) == ["first-author:120-words", "second-author:60-words"])
        #expect(outcome.books.map(\.variables) == [["token": "fiction-120"], ["token": "history-60"]])
        #expect(outcome.books.map(\.bookURL) == [
            "https://explore-context.example/book/first?cover=https://explore-context.example/cover/first-2&token=fiction-120",
            "https://explore-context.example/book/second?cover=https://explore-context.example/cover/second-2&token=history-60"
        ])
    }

    @Test func parsesLegacyAndJavaScriptExploreKinds() async {
        var legacy = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "传统发现")
        legacy.exploreUrl = "热门::/hot?page={{page}}&&完结::/finished?page={{page}}\n新书::/new"
        let service = BookExploreService()

        let legacyReport = await service.kinds(for: legacy)

        #expect(legacyReport.kinds.map(\.title) == ["热门", "完结", "新书"])
        #expect(legacyReport.kinds[0].url == "/hot?page={{page}}")
        #expect(legacyReport.diagnostics.isEmpty)

        var scripted = legacy
        scripted.exploreUrl = "@js:JSON.stringify([{title:'科幻',url:'/sci?page={{page}}'},{title:'文学',url:'/lit'}])"
        let scriptedReport = await service.kinds(for: scripted)

        #expect(scriptedReport.kinds.map(\.title) == ["科幻", "文学"])
        #expect(scriptedReport.diagnostics.isEmpty)
    }

    @Test func distinguishesExploreDestinationsFromDynamicControlsAndPlaceholders() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "动态发现")
        source.exploreUrl = #"[{"title":"关键词","type":"text"},{"title":"刷新","type":"button","action":"refresh()"},{"title":"占位"},{"title":"热门","url":"  /hot?page={{page}}  "}]"#

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.count == 4)
        #expect(report.kinds[0].navigableURL == nil)
        #expect(report.kinds[1].navigableURL == nil)
        #expect(report.kinds[2].navigableURL == nil)
        #expect(report.kinds[3].navigableURL == "/hot?page={{page}}")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func toleratesGsonStyleScalarValuesInExploreJSON() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "宽松分类")
        source.exploreUrl = #"[{"title":2026,"url":123,"type":true,"action":7,"chars":["全部",2,false,null],"default":0}]"#

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.count == 1)
        #expect(report.kinds[0].title == "2026")
        #expect(report.kinds[0].url == "123")
        #expect(report.kinds[0].type == "true")
        #expect(report.kinds[0].action == "7")
        #expect(report.kinds[0].chars == ["全部", "2", "false", nil])
        #expect(report.kinds[0].defaultValue == "0")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func toleratesLegacyJSON5ExploreSyntaxAcceptedByGson() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "旧式分类")
        source.exploreUrl = "[{title:'热门', url:'/hot',}, // old source comment\n]"

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.map(\.title) == ["热门"])
        #expect(report.kinds.first?.url == "/hot")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func loadsPaginatedJSONExploreBooksAndFallsBackToSearchRules() async throws {
        let transport = ExploreMockTransport(pages: [
            "https://example.test/hot?page=2": #"{"data":[{"id":2,"name":"第二页新书","author":"作者乙","cover":"/2.jpg"}]}"#
        ])
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "发现源")
        source.exploreUrl = "热门::/hot?page={{page}}"
        source.ruleSearch = SearchRule(
            bookList: "$.data",
            name: "$.name",
            author: "$.author",
            bookUrl: "$.id@js:'/book/' + result",
            coverUrl: "$.cover"
        )
        let kind = ExploreKind(title: "热门", url: "/hot?page={{page}}")

        let outcome = await BookExploreService(transport: transport).explore(source: source, kind: kind, page: 2)

        let book = try #require(outcome.books.first)
        #expect(book.name == "第二页新书")
        #expect(book.bookURL == "https://example.test/book/2")
        #expect(book.coverURL == "https://example.test/2.jpg")
        #expect(outcome.diagnostics.isEmpty)
    }
}
