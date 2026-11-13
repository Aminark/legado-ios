import Foundation
import Testing
@testable import LegadoCore

private actor DetailFallbackTransport: HTTPTransport {
    let body: String
    let redirectedURL: URL?
    private var requests: [URLRequest] = []

    init(body: String, redirectedURL: URL? = nil) {
        self.body = body
        self.redirectedURL = redirectedURL
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let url = try #require(redirectedURL ?? request.url)
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

struct SearchDetailFallbackTests {
    private let base = "https://detail.example.test"

    private func source() -> BookSource {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "详情回退")
        source.searchUrl = "/search"
        source.ruleSearch = .init(bookList: "@CSS:li.result", name: "@CSS:a@text", bookUrl: "@CSS:a@href")
        var info = BookInfoRule()
        info.name = "@CSS:h1@text"
        info.author = "@CSS:.author@text"
        info.coverUrl = "@CSS:img@src"
        info.tocUrl = "@CSS:a.toc@href"
        source.ruleBookInfo = info
        return source
    }

    @Test func searchRedirectUsesPatternAndDetailRulesWithoutAnotherRequest() async throws {
        var source = source()
        source.ruleSearch = nil
        source.bookUrlPattern = #"https://detail\.example\.test/book/\d+"#
        let finalURL = try #require(URL(string: base + "/book/42"))
        let transport = DetailFallbackTransport(body: """
            <h1>目标小说</h1><p class='author'>作者</p><img src='/cover.jpg'><a class='toc' href='toc'>目录</a>
            """, redirectedURL: finalURL)

        let outcome = await BookSearchService(transport: transport).search(keyword: "目标", page: 1, source: source)

        let book = try #require(outcome.books.first)
        #expect(book.bookURL == finalURL.absoluteString)
        #expect(book.name == "目标小说")
        #expect(book.author == "作者")
        #expect(book.coverURL == base + "/cover.jpg")
        #expect(book.tocURL == base + "/book/toc")
        #expect(outcome.diagnostics.isEmpty)
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test func emptySearchListKeepsExpandedPostOptionsAndFieldDependencies() async throws {
        var source = source()
        source.searchUrl = #"/search,{"method":"POST","body":"query={{key}}&page={{page}}","headers":{"X-Search":"{{key}}"}}"#
        source.ruleBookInfo?.author = "@js:book.name + '-' + key + '-' + page"
        source.ruleBookInfo?.kind = "@js:book.author"
        source.ruleBookInfo?.wordCount = "@js:java.put('countRead', book.kind); '1234'"
        source.ruleBookInfo?.lastChapter = "@js:book.wordCount"
        source.ruleBookInfo?.intro = "@js:book.latestChapterTitle + ':' + java.get('countRead')"
        let transport = DetailFallbackTransport(body: "<h1>书名</h1>")

        let outcome = await BookSearchService(transport: transport).search(keyword: "needle", page: 3, source: source)

        let book = try #require(outcome.books.first)
        #expect(book.name == "书名")
        #expect(book.author == "书名-needle-3")
        #expect(book.kind == book.author)
        #expect(book.intro == "1234:书名-needle-3")
        #expect(!book.bookURL.contains("{{"))
        let replay = try LegadoURLBuilder().prepare(book.bookURL, context: .init(source: source))
        let requests = await transport.capturedRequests()
        #expect(requests.count == 1)
        #expect(replay.url == requests[0].url)
        #expect(replay.method == .post)
        #expect(replay.body == requests[0].httpBody)
        #expect(replay.headers["X-Search"] == "needle")
        #expect(book.tocURL == book.bookURL)
        #expect(outcome.diagnostics.isEmpty)
    }

    @Test func listVariablesOverrideRequestVariablesInFallback() async throws {
        var source = source()
        source.searchUrl = "@js:java.put('token', 'request'); '/search'"
        source.ruleSearch?.bookList = "@js:java.put('token', 'list'); []"
        source.ruleBookInfo?.author = "@js:java.get('token')"
        let transport = DetailFallbackTransport(body: "<h1>书名</h1>")

        let outcome = await BookSearchService(transport: transport).search(keyword: "key", page: 1, source: source)

        let book = try #require(outcome.books.first)
        #expect(book.author == "list")
        #expect(book.variables["token"] == "list")
        #expect(await transport.capturedRequests().count == 1)
        #expect(outcome.diagnostics.isEmpty)
    }

    @Test func exploreFallsBackToDetailsForEmptyListWithoutPattern() async throws {
        var source = source()
        source.ruleBookInfo?.name = "@CSS:h1@text@js:result + page"
        let transport = DetailFallbackTransport(body: "<h1>分类书籍</h1>")

        let outcome = await BookExploreService(transport: transport).explore(
            source: source, kind: .init(title: "分类", url: "/kind?page={{page}}"), page: 2
        )

        let book = try #require(outcome.books.first)
        #expect(book.name == "分类书籍2")
        #expect(book.bookURL == base + "/kind?page=2")
        #expect(outcome.diagnostics.isEmpty)
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test func unmatchedPatternDisablesEmptyListFallbackInSearchAndExplore() async {
        var source = source()
        source.bookUrlPattern = #"https://detail\.example\.test/book/\d+"#
        let transport = DetailFallbackTransport(body: "<h1>这只是网站标题</h1>")

        let search = await BookSearchService(transport: transport).search(keyword: "key", page: 1, source: source)
        let explore = await BookExploreService(transport: transport).explore(source: source, kind: .init(title: "分类", url: "/kind"))

        #expect(search.books.isEmpty)
        #expect(explore.books.isEmpty)
        #expect(search.diagnostics.isEmpty)
        #expect(explore.diagnostics.isEmpty)
    }

    @Test func malformedListRuleIsNotHiddenByDetailFallback() async {
        var source = source()
        source.ruleSearch?.bookList = "@js:throw new Error('broken list')"
        let transport = DetailFallbackTransport(body: "<h1>详情标题</h1>")

        let outcome = await BookSearchService(transport: transport).search(keyword: "key", page: 1, source: source)

        #expect(outcome.books.isEmpty)
        #expect(outcome.diagnostics.contains { $0.severity == .error })
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test func redirectedDetailWithoutTocKeepsFinalURLInsteadOfReplayingSearchPost() async throws {
        var source = source()
        source.searchUrl = #"/search,{"method":"POST","body":"query={{key}}"}"#
        source.ruleBookInfo?.tocUrl = nil
        let finalURL = try #require(URL(string: base + "/book/42"))
        let transport = DetailFallbackTransport(body: "<h1>重定向详情</h1>", redirectedURL: finalURL)
        let service = NetworkBookService(transport: transport)
        let searchBook = SearchBook(bookURL: base + #"/search,{"method":"POST","body":"query=book"}"#,
                                    origin: source.id, originName: source.bookSourceName, type: 0, name: "")

        let detail = await service.loadDetail(searchBook: searchBook, source: source)

        #expect(detail.book.tocUrl == finalURL.absoluteString)
        #expect(detail.diagnostics.isEmpty)
    }
}
