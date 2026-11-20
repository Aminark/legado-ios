import Foundation
import Testing
@testable import LegadoCore

private struct CommentTransport: HTTPTransport {
    var handle: @Sendable (URLRequest) async throws -> HTTPResponse
    func data(for request: URLRequest) async throws -> HTTPResponse { try await handle(request) }
}

struct ChapterCommentsTests {
    private let base = "https://comments.example.test"

    private func fixture() -> (BookSource, Book, BookChapter) {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "测试书源")
        var rule = ReviewRule()
        rule.reviewUrl = "/reviews/{{bookId}}/{{chapterId}}?page={{page}}"
        rule.reviewList = "$.comments"
        rule.contentRule = "$.body"
        rule.idRule = "$.id"
        rule.authorRule = "$.author"
        rule.avatarRule = "$.avatar"
        rule.postTimeRule = "$.time"
        source.ruleReview = rule
        var book = Book(bookUrl: base + "/book/63", name: "测试书", origin: base)
        book.variable = #"{"bookId":"63","chapterId":"old"}"#
        var chapter = BookChapter(url: base + "/reader/91", title: "真实章号", bookUrl: book.bookUrl, index: 3)
        chapter.variable = #"{"chapterId":"91"}"#
        return (source, book, chapter)
    }

    private func service(_ body: String = "", status: Int = 200,
                         validate: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> NetworkBookService {
        NetworkBookService(transport: CommentTransport { request in
            validate(request)
            return .init(data: Data(body.utf8), statusCode: status, headers: [:],
                         finalURL: URL(string: "https://cdn.example.test/response/list")!)
        }, networkPolicy: SourceNetworkPolicy())
    }

    @Test func resolvesBookAndChapterVariablesAndExtractsRows() async throws {
        var (source, book, chapter) = fixture()
        source.header = #"{"X-Reader-Test":"requested"}"#
        let response = """
            {"comments":[
                {"id":"90071992547409932","body":" 同一句 ","avatar":"avatar.png","time":"昨天"},
                {"id":"90071992547409933","body":"同一句","author":"乙","avatar":"javascript:void(0)"},
                {"id":"90071992547409932","body":"同一句"}
            ]}
            """
        let comments = try await service(response) { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://comments.example.test/reviews/63/91?page=1")
            #expect(request.value(forHTTPHeaderField: "X-Reader-Test") == "requested")
        }.loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(comments.map(\.content) == ["同一句", "同一句"])
        #expect(comments.map(\.author) == [nil, "乙"])
        #expect(comments.map(\.postedAt) == ["昨天", nil])
        #expect(comments.map { $0.avatarURL?.absoluteString } == ["https://cdn.example.test/response/avatar.png", nil])
        #expect(Set(comments.map(\.id)).count == 2)
    }

    @Test func arrayRootWorksWithExistingFieldOnlyRuleAndLargeNumericIDs() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.reviewList = nil
        let comments = try await service("""
            [{"id":90071992547409932,"body":"第一条"},{"id":90071992547409933,"body":"第二条","time":"昨天"}]
            """).loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(comments.map(\.content) == ["第一条", "第二条"])
        #expect(comments.map(\.postedAt) == [nil, "昨天"])
        #expect(Set(comments.map(\.id)).count == 2)
    }

    @Test func htmlRowsKeepSparseMetadataOnTheCorrectComment() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.reviewList = "@CSS:.row"
        source.ruleReview?.contentRule = "@CSS:.body@text"
        source.ruleReview?.authorRule = "@CSS:.who@text"
        source.ruleReview?.idRule = nil
        source.ruleReview?.postTimeRule = nil
        source.ruleReview?.avatarRule = nil
        let html = """
            <div class="row"><p class="body">第一条</p></div>
            <div class="row"><span class="who">乙</span><p class="body">第二条</p><p class="body">续行</p></div>
            """
        let rows = try await service(html).loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(rows.map(\.content) == ["第一条", "第二条\n续行"])
        #expect(rows.map(\.author) == [nil, "乙"])
        source.ruleReview?.reviewList = nil
        let flat = try await service(html).loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(flat.map(\.content) == ["第一条", "第二条", "续行"])
        #expect(flat.allSatisfy { $0.author == nil })
    }

    @Test(arguments: ["$.comments", "$.comments[*]"])
    func explicitEmptyListIsSuccessful(listRule: String) async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.reviewList = listRule
        let rows = try await service(#"{"comments":[]}"#).loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(rows.isEmpty)
    }

    @Test(arguments: ["", #"{"message":"请登录"}"#, #"{"comments":null}"#, #"{"comments":{"body":"错误信息"}}"#,
                      #"{"comments":[{"unexpected":"字段变更"}]}"#, #"{"comments":[{"body":{"message":"错误"}}]}"#,
                      "<html>需要登录</html>"])
    func invalidResponsesAreErrors(body: String) async {
        let (source, book, chapter) = fixture()
        await #expect(throws: RuleEngineError.self) {
            try await service(body).loadChapterComments(book: book, chapter: chapter, source: source)
        }
    }

    @Test func httpFailurePropagatesAndLaterCallCanSucceed() async throws {
        let (source, book, chapter) = fixture()
        actor RetryTransport: HTTPTransport {
            var attempts = 0
            func data(for request: URLRequest) throws -> HTTPResponse {
                attempts += 1
                return .init(data: Data(), statusCode: attempts == 1 ? 503 : 204, headers: [:], finalURL: try #require(request.url))
            }
        }
        let transport = RetryTransport()
        let api = NetworkBookService(transport: transport)
        await #expect(throws: HTTPClientError.self) {
            try await api.loadChapterComments(book: book, chapter: chapter, source: source)
        }
        let empty = try await api.loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(empty.isEmpty)
        #expect(await transport.attempts == 2)
    }

    @Test func pendingRemoteProcessingIsNotAnEmptyCommentList() async {
        let (source, book, chapter) = fixture()
        await #expect(throws: RuleEngineError.self) {
            try await service(#"{"comments":[]}"#, status: 202)
                .loadChapterComments(book: book, chapter: chapter, source: source)
        }
    }

    @Test func lateResponseIsDiscardedWhenCancelled() async throws {
        let (source, book, chapter) = fixture()
        let (requests, sent) = AsyncStream<Void>.makeStream()
        let (replies, release) = AsyncStream<Void>.makeStream()
        let api = NetworkBookService(transport: CommentTransport { request in
            sent.yield(())
            for await _ in replies { break }
            return .init(data: Data(#"{"comments":[{"body":"延迟响应"}]}"#.utf8), statusCode: 200, headers: [:],
                         finalURL: try #require(request.url))
        })
        let load = Task { try await api.loadChapterComments(book: book, chapter: chapter, source: source) }
        for await _ in requests { break }
        load.cancel()
        release.yield(())
        release.finish()
        sent.finish()
        await #expect(throws: CancellationError.self) { try await load.value }
    }

    @Test func structuredPOSTReadsConfiguredEndpointWithoutCallingMutationURLs() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.reviewUrl = #"/comments,{"method":"POST","body":{"chapter":"{{chapterId}}"}}"#
        source.ruleReview?.postReviewUrl = "/write"
        source.ruleReview?.voteUpUrl = "/vote"
        source.ruleReview?.deleteUrl = "/delete"
        let comments = try await service(#"{"comments":[{"body":"已读取"}]}"#) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/comments")
            #expect(request.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } == ["chapter":"91"])
        }.loadChapterComments(book: book, chapter: chapter, source: source)
        #expect(comments.map(\.content) == ["已读取"])
    }

    @Test func nextPageUsesExplicitSameOriginGETAndKeepsIDsWithoutServerKeysDistinct() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.reviewUrl = #"/first,{"method":"POST","body":"q=one","headers":{"X-Reader":"ok"}}"#
        source.ruleReview?.nextReviewUrl = "$.next"
        let api = NetworkBookService(transport: CommentTransport { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "X-Reader") == "ok")
            let json: String
            if url.path == "/first" {
                #expect(request.httpMethod == "POST")
                json = #"{"comments":[{"body":"一样"}],"next":"second#panel"}"#
            } else {
                #expect(url.absoluteString == "https://comments.example.test/second")
                #expect(request.httpMethod == "GET")
                #expect(request.httpBody == nil)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
                #expect(!ReviewPageAddress.permitsRedirect(for: request, to: URL(string: "https://other.example.test/review")))
                json = #"{"comments":[{"body":"一样"}],"next":"https://COMMENTS.EXAMPLE.TEST:443/first#top"}"#
            }
            return .init(data: Data(json.utf8), statusCode: 200, headers: [:], finalURL: url)
        })
        let first = try await api.loadChapterCommentsPage(book: book, chapter: chapter, source: source)
        let link = try #require(first.nextPageURL)
        let second = try await api.loadChapterCommentsPage(book: book, chapter: chapter, source: source, nextPageURL: link)
        #expect(second.nextPageURL == nil)
        #expect(first.comments.map(\.content) == ["一样"])
        #expect(second.comments.map(\.content) == ["一样"])
        #expect(first.comments.first?.id != second.comments.first?.id)
    }

    @Test(arguments: ["https://external.example.test/more", "http://comments.example.test/more",
                      "https://comments.example.test:8443/more", "https://user:pass@comments.example.test/more",
                      "javascript:run()"])
    func foreignPageIsNeverOfferedOrRequested(target: String) async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.nextReviewUrl = "$.next"
        source.header = #"{"X-Secret":"only-this-origin"}"#
        let firstURL = URL(string: base + "/reviews/63/91?page=1")!
        let api = NetworkBookService(transport: CommentTransport { request in
            #expect(request.url == firstURL)
            let bytes = try JSONSerialization.data(withJSONObject: ["comments":[["body":"读到第一条"]], "next":target])
            return .init(data: bytes, statusCode: 200, headers: [:], finalURL: firstURL)
        })
        let first = try await api.loadChapterCommentsPage(book: book, chapter: chapter, source: source)
        #expect(first.nextPageURL == nil)
        #expect(first.comments.count == 1)
        let external = try #require(URL(string: target))
        await #expect(throws: RuleEngineError.self) {
            try await api.loadChapterCommentsPage(book: book, chapter: chapter, source: source, nextPageURL: external)
        }
    }

    @Test func mismatchedBookVolumeAndNonHTTPAddressNeverReachTransport() async {
        var (source, book, chapter) = fixture()
        let api = service { _ in Issue.record("不应发出请求") }
        let originalURL = chapter.bookUrl
        chapter.bookUrl = base + "/another"
        await #expect(throws: RuleEngineError.self) { try await api.loadChapterComments(book: book, chapter: chapter, source: source) }
        chapter.bookUrl = originalURL
        chapter.isVolume = true
        await #expect(throws: RuleEngineError.self) { try await api.loadChapterComments(book: book, chapter: chapter, source: source) }
        chapter.isVolume = false
        source.ruleReview?.reviewUrl = "file:///tmp/comments"
        await #expect(throws: RuleEngineError.self) { try await api.loadChapterComments(book: book, chapter: chapter, source: source) }
    }

    @Test func browserPageExpandsChapterURLWithoutLoadingIt() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.contentRule = " "
        source.ruleReview?.reviewUrl = "{{chapter.url}}/comments?book={{bookId}}"
        #expect(source.ruleReview?.supportsChapterComments == false)
        #expect(source.ruleReview?.supportsChapterCommentsPage == true)
        let url = try await service { _ in Issue.record("网页由浏览器载入") }
            .chapterCommentsPageURL(book: book, chapter: chapter, source: source)
        #expect(url.absoluteString == base + "/reader/91/comments?book=63")
    }

    @Test(arguments: ["/review,{\"method\":\"POST\"}", "/review,{\"method\":\"DELETE\"}", "/review,{\"body\":\"a=b\"}",
                      "/review,{\"headers\":{\"Cookie\":\"key=value\"}}", "/review,{\"webView\":true}",
                      "/review,{\"bodyJs\":\"result\"}", "@js:''", "javascript:alert(1)", "https://user:password@example.test/comments"])
    func browserRejectsUnreplayableRequests(template: String) async {
        var (source, book, chapter) = fixture()
        source.ruleReview?.contentRule = nil
        source.ruleReview?.reviewUrl = template
        await #expect(throws: RuleEngineError.self) {
            try await service().chapterCommentsPageURL(book: book, chapter: chapter, source: source)
        }
    }

    @Test func browserUsesOnlyTheURLWithAnIndependentLoginSession() async throws {
        var (source, book, chapter) = fixture()
        source.ruleReview?.contentRule = nil
        source.header = #"{"Authorization":"example"}"#
        let policy = SourceNetworkPolicy()
        await policy.setCookieHeader("session=sample", sourceID: source.id, url: URL(string: base)!)
        let api = NetworkBookService(networkPolicy: policy)
        let url = try await api.chapterCommentsPageURL(book: book, chapter: chapter, source: source)
        #expect(url.absoluteString == base + "/reviews/63/91?page=1")
    }

    @Test func publisherChapterIDsExpandAsExactStrings() async throws {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "章评")
        var rule = ReviewRule()
        rule.reviewUrl = "/comments/{{reviewBookId}}/{{reviewChapterId}}"
        source.ruleReview = rule
        let book = Book(bookUrl: "https://fanqienovel.com/page/7255936586997566505", name: "书", origin: source.id)
        let chapter = BookChapter(url: "/reader/7399337929476162072", title: "章", bookUrl: book.bookUrl, index: 0)
        let url = try await service().chapterCommentsPageURL(book: book, chapter: chapter, source: source)
        #expect(url.absoluteString == base + "/comments/7255936586997566505/7399337929476162072")
    }
}
