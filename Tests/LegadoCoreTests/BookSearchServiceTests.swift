import Foundation
import Testing
@testable import LegadoCore

private struct SearchMockTransport: HTTPTransport {
    let response: HTTPResponse
    var expectedQueryFragment: String?

    func data(for request: URLRequest) async throws -> HTTPResponse {
        if let expectedQueryFragment {
            #expect(request.url?.absoluteString.contains(expectedQueryFragment) == true)
        }
        return response
    }
}

private struct DelayedSearchTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let isSlow = request.url?.host == "slow.example.test"
        try await Task.sleep(for: isSlow ? .milliseconds(200) : .milliseconds(10))
        let name = isSlow ? "慢源结果" : "快源结果"
        let data = Data(#"{"books":[{"name":"\#(name)","author":"作者","url":"/book/1"}]}"#.utf8)
        return .init(data: data, statusCode: 200, headers: [:], finalURL: request.url!)
    }
}

struct BookSearchServiceTests {
    @Test func matchingBucketsRankBySourceCountAndKeepTiesStable() {
        func book(_ id: String, name: String, author: String, kind: String? = nil, origins: Int) -> SearchBook {
            var book = SearchBook(bookURL: id, origin: id, originName: id, type: 0, name: name, author: author)
            book.kind = kind
            book.origins = Set((0..<origins).map { "source-\($0)" })
            return book
        }
        let books = [
            book("exact-low", name: "key", author: "a", origins: 1),
            book("exact-high", name: "key", author: "b", origins: 2),
            book("exact-tie", name: "key", author: "c", origins: 2),
            book("tag-low", name: "first", author: "a", kind: "key", origins: 1),
            book("tag-high", name: "second", author: "b", kind: "key", origins: 3),
            book("contains-low", name: "key-one", author: "a", origins: 1),
            book("contains-high", name: "key-two", author: "b", origins: 2),
            book("other-low", name: "other-one", author: "a", origins: 1),
            book("other-high", name: "other-two", author: "b", origins: 4)
        ]
        var accumulator = BookSearchAccumulator()
        accumulator.add(books)

        #expect(accumulator.results(keyword: "key").map(\.bookURL) == [
            "exact-high", "exact-tie", "exact-low", "tag-high", "tag-low",
            "contains-high", "contains-low", "other-low", "other-high"
        ])
        var extraOrigin = books[0]
        extraOrigin.origins = ["source-1", "source-2", "source-3"]
        accumulator.add([extraOrigin])
        #expect(accumulator.results(keyword: "key").first?.bookURL == "exact-low")
    }

    @Test func exposesEarlierMetadataAndVariablesToLaterSearchFields() async throws {
        let finalURL = try #require(URL(string: "https://search-context.example/search"))
        let transport = SearchMockTransport(response: .init(
            data: Data(#"{"books":[{"name":"first","kind":"fiction"}]}"#.utf8),
            statusCode: 200, headers: [:], finalURL: finalURL
        ))
        var source = BookSource(bookSourceUrl: "https://search-context.example", bookSourceName: "上下文搜索")
        source.searchUrl = "/search"
        source.ruleSearch = .init(
            bookList: "$.books", name: "$.name", author: "@js:book.name + '-author'",
            intro: "@js:book.author + ':' + book.latestChapterTitle",
            kind: "$.kind", lastChapter: "@js:book.wordCount + '-words'",
            bookUrl: "@js:'/book/' + book.name + '?cover=' + book.coverUrl + '&token=' + java.get('token')",
            coverUrl: "@js:java.put('token', book.kind + '-' + book.wordCount); '/cover/' + book.name",
            wordCount: "@js:book.kind == 'fiction' ? '120' : '60'"
        )

        let outcome = await BookSearchService(transport: transport).search(keyword: "first", page: 1, source: source)

        #expect(outcome.diagnostics.isEmpty)
        #expect(outcome.books.first?.intro == "first-author:120-words")
        #expect(outcome.books.first?.bookURL == "https://search-context.example/book/first?cover=https://search-context.example/cover/first&token=fiction-120")
        #expect(outcome.books.first?.variables == ["token": "fiction-120"])
    }

    @Test func streamsFastSourceWithoutWaitingForSlowSource() async throws {
        func makeSource(host: String, name: String) -> BookSource {
            var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: name)
            source.searchUrl = "https://\(host)/search?q={{key}}"
            source.ruleSearch = SearchRule(bookList: "$.books[*]", name: "name", author: "author", bookUrl: "url")
            return source
        }
        let slow = makeSource(host: "slow.example.test", name: "慢源")
        let fast = makeSource(host: "fast.example.test", name: "快源")
        let stream = BookSearchService(transport: DelayedSearchTransport())
            .searchOutcomes(keyword: "结果", sources: [slow, fast])
        var iterator = stream.makeAsyncIterator()

        let first = try #require(await iterator.next())

        #expect(first.sourceID == fast.id)
        #expect(first.books.first?.name == "快源结果")
    }

    @Test func ordersMergedResultsBySearchRelevance() async throws {
        let finalURL = try #require(URL(string: "https://api.example.test/search"))
        let data = Data(#"{"books":[{"name":"其他","author":"甲","kind":"普通","url":"/4"},{"name":"关键词扩展","author":"乙","kind":"普通","url":"/3"},{"name":"分类书","author":"丙","kind":"关键词","url":"/2"},{"name":"关键词","author":"丁","kind":"普通","url":"/1"}]}"#.utf8)
        let transport = SearchMockTransport(
            response: .init(data: data, statusCode: 200, headers: [:], finalURL: finalURL),
            expectedQueryFragment: nil
        )
        var source = BookSource(bookSourceUrl: "https://api.example.test", bookSourceName: "排序源")
        source.searchUrl = "https://api.example.test/search?q={{key}}"
        source.ruleSearch = SearchRule(bookList: "$.books[*]", name: "name", author: "author", kind: "kind", bookUrl: "url")

        let report = await BookSearchService(transport: transport).search(keyword: "关键词", sources: [source])

        #expect(report.books.map(\.name) == ["关键词", "分类书", "关键词扩展", "其他"])
    }

    @Test func searchesJSONSourceAndResolvesRelativeURLs() async throws {
        let finalURL = try #require(URL(string: "https://api.example.test/search?q=swift"))
        let data = Data(
            """
            {"data":{"books":[
              {"name":"Swift 入门","author":"A","url":"/book/1","cover":"/cover/1.jpg","tags":["编程","Swift"]},
              {"name":"Swift 进阶","author":"B","url":"/book/2","cover":"/cover/2.jpg","tags":["编程"]}
            ]}}
            """.utf8
        )
        let transport = SearchMockTransport(response: .init(
            data: data,
            statusCode: 200,
            headers: [:],
            finalURL: finalURL
        ), expectedQueryFragment: "q=swift")
        var source = BookSource(bookSourceUrl: "https://api.example.test", bookSourceName: "JSON 源")
        source.searchUrl = "/search?q={{key}}&page=<1,2,3>"
        source.ruleSearch = SearchRule(
            bookList: "$.data.books[*]",
            name: "name",
            author: "author",
            kind: "tags[*]",
            bookUrl: "url",
            coverUrl: "cover"
        )
        let service = BookSearchService(transport: transport)

        let report = await service.search(keyword: "swift", sources: [source])

        #expect(report.books.count == 2)
        #expect(report.books.map(\.name).sorted() == ["Swift 入门", "Swift 进阶"])
        #expect(report.books.allSatisfy { $0.bookURL.hasPrefix("https://api.example.test/book/") })
        #expect(report.outcomes[0].diagnostics.isEmpty)
    }

    @Test func mergesSameBookAcrossSources() async throws {
        let finalURL = try #require(URL(string: "https://api.example.test/search"))
        let data = Data(#"{"books":[{"name":"同一本书","author":"作者","url":"/book/1"}]}"#.utf8)
        let transport = SearchMockTransport(
            response: .init(data: data, statusCode: 200, headers: [:], finalURL: finalURL),
            expectedQueryFragment: nil
        )
        func makeSource(_ id: String) -> BookSource {
            var source = BookSource(bookSourceUrl: id, bookSourceName: id)
            source.searchUrl = "https://api.example.test/search?q={{key}}"
            source.ruleSearch = SearchRule(bookList: "$.books[*]", name: "name", author: "author", bookUrl: "url")
            return source
        }
        let service = BookSearchService(transport: transport)

        let report = await service.search(keyword: "同一本书", sources: [makeSource("https://one.test"), makeSource("https://two.test")])

        #expect(report.books.count == 1)
        #expect(report.books[0].origins.count == 2)
    }

    @Test func mergesDecoratedAuthorAndPunctuatedTitleAcrossSources() {
        let plain = SearchBook(bookURL: "one", origin: "one", originName: "一源", type: 0, name: "长夜里的灯", author: "林舟")
        let decorated = SearchBook(bookURL: "two", origin: "two", originName: "二源", type: 0, name: "长夜里的灯！", author: "作者：林舟 著")
        let outcomes = [
            SourceSearchOutcome(sourceID: "one", books: [plain], diagnostics: []),
            SourceSearchOutcome(sourceID: "two", books: [decorated], diagnostics: [])
        ]

        let merged = BookSearchService().merge(outcomes: outcomes, keyword: "长夜里的灯")

        #expect(merged.count == 1)
        #expect(merged[0].origins == ["one", "two"])
    }

    @Test func distinctProgrammingTitlesKeepTheirSignificantSymbolsWhenMerging() {
        let cpp = SearchBook(bookURL: "https://one.test/cpp", origin: "one", originName: "一源", type: 0,
                             name: "C++教程", author: "同一作者")
        let csharp = SearchBook(bookURL: "https://two.test/csharp", origin: "two", originName: "二源", type: 0,
                                name: "C#教程", author: "同一作者")
        let merged = BookSearchService().merge(outcomes: [
            .init(sourceID: "one", books: [cpp], diagnostics: []),
            .init(sourceID: "two", books: [csharp], diagnostics: [])
        ], keyword: "教程")

        #expect(merged.count == 2)
        #expect(Set(merged.map(\.name)) == ["C++教程", "C#教程"])
        #expect(merged.allSatisfy { $0.origins.count == 1 })
    }

    @Test func mergingPreservesInternalPunctuationTrailingSymbolsAndSymbolOnlyTitles() {
        let titles = ["C", "C#", "C++", "A-B", "AB", "甲·乙", "甲乙", "+", "-", "!", "?"]
        let books = titles.enumerated().map { index, title in
            SearchBook(bookURL: "https://source.test/\(index)", origin: "source", originName: "源", type: 0,
                       name: title, author: "同一作者")
        }
        let merged = BookSearchService().merge(outcomes: [.init(sourceID: "source", books: books, diagnostics: [])], keyword: "")

        #expect(merged.count == titles.count)
        #expect(Set(merged.map(\.name)) == Set(titles))
    }

    @Test func mergingKeepsAuthorSymbolsAndStillNormalizesTitleAndAuthorDecoration() {
        let authors = ["甲+乙", "甲#乙", "甲乙"]
        var books = authors.enumerated().map { index, author in
            SearchBook(bookURL: "https://source.test/\(index)", origin: "source", originName: "源", type: 0,
                       name: "C++教程", author: author)
        }
        books.append(.init(bookURL: "https://other.test/decorated", origin: "other", originName: "另一源", type: 0,
                           name: "《C++教程！》", author: "作者：甲+乙 著"))
        let merged = BookSearchService().merge(outcomes: [.init(sourceID: "source", books: books, diagnostics: [])], keyword: "教程")

        #expect(merged.count == authors.count)
        #expect(merged.first(where: { $0.author == "甲+乙" })?.origins == ["source", "other"])
        #expect(merged.filter { $0.author != "甲+乙" }.allSatisfy { $0.origins == ["source"] })
    }

    @Test func searchesHTMLSourceWithCSSRules() async throws {
        let finalURL = try #require(URL(string: "https://html.example.test/search?q=ios"))
        let data = Data(
            """
            <html><body><section class="results">
              <article class="book"><a class="name" href="/book/ios">iOS 阅读</a><span class="author">作者甲</span><img src="/ios.jpg"></article>
              <article class="book"><a class="name" href="/book/swift">Swift 阅读</a><span class="author">作者乙</span><img src="/swift.jpg"></article>
            </section></body></html>
            """.utf8
        )
        let transport = SearchMockTransport(
            response: .init(data: data, statusCode: 200, headers: [:], finalURL: finalURL),
            expectedQueryFragment: "q=ios"
        )
        var source = BookSource(bookSourceUrl: "https://html.example.test", bookSourceName: "HTML 源")
        source.searchUrl = "/search?q={{key}}"
        source.ruleSearch = SearchRule(
            bookList: "@CSS:article.book",
            name: "@CSS:a.name@text",
            author: "@CSS:.author@text",
            bookUrl: "@CSS:a.name@href",
            coverUrl: "@CSS:img@src"
        )
        let service = BookSearchService(transport: transport)

        let report = await service.search(keyword: "ios", sources: [source])

        #expect(report.books.count == 2)
        #expect(report.books.first(where: { $0.name == "iOS 阅读" })?.bookURL == "https://html.example.test/book/ios")
        #expect(report.outcomes[0].diagnostics.isEmpty)
    }

    @Test func searchesLegadoStyleSourceWithJavaScriptPipelineAndVariables() async throws {
        let finalURL = try #require(URL(string: "https://audio.example.test/search"))
        let data = Data(
            #"{"content":{"content":[{"id":1001,"title":"听书测试","author":"播音员","cover":{"path":"cover/a.jpg"}}]}}"#.utf8
        )
        let transport = SearchMockTransport(
            response: .init(data: data, statusCode: 200, headers: [:], finalURL: finalURL),
            expectedQueryFragment: nil
        )
        var source = BookSource(bookSourceUrl: "https://audio.example.test", bookSourceName: "JS 源")
        source.searchUrl = "https://audio.example.test/search,{\"method\":\"POST\",\"body\":{\"title\":\"searchKey\",\"page\":{{searchPage}}}}"
        source.ruleSearch = SearchRule(
            bookList: "$.content.content",
            name: "$.title",
            author: "$.author",
            bookUrl: "$.id@js:java.put('bookId', result); '/toc?bookId=' + result",
            coverUrl: "$.cover@js:var cover = JSON.parse(result); '/file/' + cover.path"
        )

        let report = await BookSearchService(transport: transport).search(keyword: "听书", sources: [source])

        #expect(report.outcomes.flatMap(\.diagnostics).isEmpty)
        let book = try #require(report.books.first)
        #expect(book.bookURL == "https://audio.example.test/toc?bookId=1001")
        #expect(book.coverURL == "https://audio.example.test/file/cover/a.jpg")
        #expect(book.variables["bookId"] == "1001")
        #expect(report.outcomes[0].diagnostics.isEmpty)
    }

    @Test func searchesLegacyEncodedHTMLUsingURLCharsetOption() async throws {
        let finalURL = try #require(URL(string: "https://legacy.example.test/search"))
        let encoding = try #require(HTTPTextDecoder.encoding(named: "gb18030"))
        let html = #"<article class="book"><a class="name" href="/book/1">旧城故事</a><span class="author">林舟</span></article>"#
        let data = try #require(html.data(using: encoding))
        let transport = SearchMockTransport(
            response: .init(data: data, statusCode: 200, headers: [:], finalURL: finalURL),
            expectedQueryFragment: nil
        )
        var source = BookSource(bookSourceUrl: "https://legacy.example.test", bookSourceName: "旧编码源")
        source.searchUrl = #"/search?q={{key}}, {"charset":"gb18030"}"#
        source.ruleSearch = SearchRule(
            bookList: "@CSS:article.book",
            name: "@CSS:a.name@text",
            author: "@CSS:.author@text",
            bookUrl: "@CSS:a.name@href"
        )

        let report = await BookSearchService(transport: transport).search(keyword: "旧城", sources: [source])

        #expect(report.books.first?.name == "旧城故事")
        #expect(report.books.first?.author == "林舟")
    }

    @Test func evaluatesDynamicRequestJavaScriptAndPassesVariablesToRules() async throws {
        let finalURL = try #require(URL(string: "https://dynamic.example.test/search?q=DUNE"))
        let transport = SearchMockTransport(
            response: .init(
                data: Data(#"{"books":[{"name":"沙丘","author":"Frank","id":"42"}]}"#.utf8),
                statusCode: 200,
                headers: [:],
                finalURL: finalURL
            ),
            expectedQueryFragment: "q=DUNE"
        )
        var source = BookSource(bookSourceUrl: "https://dynamic.example.test", bookSourceName: "动态源")
        source.searchUrl = "@js:java.put('requestToken', key.toUpperCase()); '/search?q=' + java.get('requestToken')"
        source.ruleSearch = SearchRule(
            bookList: "$.books[*]",
            name: "name",
            author: "author",
            bookUrl: "$.id@js:'/book/' + result + '?token=' + java.get('requestToken')"
        )

        let report = await BookSearchService(transport: transport).search(keyword: "dune", sources: [source])

        #expect(report.outcomes.flatMap(\.diagnostics).isEmpty)
        #expect(report.books.first?.bookURL == "https://dynamic.example.test/book/42?token=DUNE")
        #expect(report.books.first?.variables["requestToken"] == "DUNE")
    }

    @Test func searchesRenderedWebViewHTMLThroughInjectedExecutor() async throws {
        let url = try #require(URL(string: "https://web-search.example/results"))
        let executor = await MainActor.run { SearchWebViewExecutor(response: .init(
            data: Data(#"<article class="book"><a href="/book/9">渲染后的书</a><span>网页作者</span></article>"#.utf8),
            statusCode: 200,
            headers: [:],
            finalURL: url
        )) }
        var source = BookSource(bookSourceUrl: "https://web-search.example", bookSourceName: "WebView 源")
        source.searchUrl = #"/search?q={{key}}, {"webView":true,"webJs":"document.body.dataset.loaded='yes'"}"#
        source.ruleSearch = SearchRule(
            bookList: "@CSS:article.book",
            name: "@CSS:a@text",
            author: "@CSS:span@text",
            bookUrl: "@CSS:a@href"
        )

        let report = await BookSearchService(
            transport: SearchMockTransport(response: .init(data: Data(), statusCode: 500, headers: [:], finalURL: url)),
            webViewExecutor: executor
        ).search(keyword: "网页", sources: [source])

        #expect(report.outcomes.flatMap(\.diagnostics).isEmpty)
        #expect(report.books.first?.name == "渲染后的书")
        #expect(report.books.first?.bookURL == "https://web-search.example/book/9")
        #expect(await executor.callCount == 1)
    }
}

@MainActor
private final class SearchWebViewExecutor: SourceWebViewRequestExecuting, @unchecked Sendable {
    let response: HTTPResponse
    private(set) var callCount = 0

    init(response: HTTPResponse) { self.response = response }

    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        callCount += 1
        return response
    }
}
