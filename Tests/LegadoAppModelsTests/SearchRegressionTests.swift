import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct SearchRegressionTests {
    @Test(arguments: ["@js:'/search?q=' + key + '&page=' + page", "<js>'/search?q=' + key + '&page=' + page</js>"])
    func javaScriptURLWithoutTemplateMarkersCanLoadTheSecondPage(_ rule: String) async throws {
        let transport = GatedModelSearchTransport()
        await transport.release()
        let model = model(transport: transport, repository: InMemorySearchBookRepository())
        defer { model.cancel(reset: true) }
        var source = source("scripted")
        source.searchUrl = rule
        model.search(keyword: "book", sources: [source])
        try await waitUntil { model.state == .finished }
        #expect(model.hasMore)

        model.loadMore()
        try await waitUntil { !model.isLoadingMore }

        let requests = await transport.requests()
        #expect(requests.compactMap(\.url).map(\.absoluteString) == [
            "https://scripted.example/search?q=book&page=1",
            "https://scripted.example/search?q=book&page=2"
        ])
        #expect(!model.hasMore)
    }

    @Test func arithmeticPageExpressionCanLoadTheSecondPage() async throws {
        let transport = GatedModelSearchTransport()
        await transport.release()
        let model = model(transport: transport, repository: InMemorySearchBookRepository())
        defer { model.cancel(reset: true) }
        var source = source("formula")
        source.searchUrl = #"/search,{"method":"POST","body":"keyword={{key}}&page={{page-1}}"}"#
        model.search(keyword: "书", sources: [source])
        try await waitUntil { model.state == .finished }
        #expect(model.hasMore)
        model.loadMore()
        try await waitUntil { !model.isLoadingMore }
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) } == [
            "keyword=%E4%B9%A6&page=0", "keyword=%E4%B9%A6&page=1"
        ])
        #expect(!model.hasMore)
    }

    @Test func cachedResultsAppearBeforeNetworkAndFreshResultsReplaceTheirMetadata() async throws {
        let source = source("slow")
        let cached = SearchBook(bookURL: source.id + "/cached", origin: source.id, originName: "源", type: 0, name: "书", author: "作者")
        let transport = GatedModelSearchTransport()
        let model = model(transport: transport, repository: InMemorySearchBookRepository(values: [cached]))
        defer { model.cancel(reset: true) }
        model.search(keyword: "书", sources: [source])
        try await waitUntil { model.isShowingCachedResults }
        #expect(model.books.map(\.bookURL) == [cached.bookURL])
        #expect(model.state == .searching)
        #expect(model.completedSourceCount == 0)
        await transport.release()
        try await waitUntil { model.state == .finished }
        #expect(model.books.first?.bookURL == source.id + "/fresh")
        #expect(!model.isShowingCachedResults)
    }

    @Test func pausedSearchPersistsEarlyResultsAndResumesOnlyUnfinishedSourcesAtSamePage() async throws {
        let transport = GatedModelSearchTransport(fastHost: "fast.example")
        let repository = InMemorySearchBookRepository()
        let model = model(transport: transport, repository: repository)
        defer { model.cancel(reset: true) }
        let fast = source("fast"), slow = source("slow")
        model.search(keyword: "书", sources: [fast, slow])
        try await waitUntil("first source result") { !model.books.isEmpty }
        model.cancel()
        try await waitUntil("paused result persistence") { try await repository.cachedMatches(keyword: "书").count == 1 }
        #expect(model.isPaused)
        #expect(model.completedSourceCount == 1)
        model.resume()
        await transport.release()
        try await waitUntil("resume completion") { model.state == .finished && !model.isPaused }
        let requests = await transport.requests()
        #expect(requests.filter { $0.url?.host == "fast.example" }.count == 1)
        #expect(requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value == "1" })
        #expect(model.completedSourceCount == 2)
        #expect(model.books.first?.origins == [fast.id, slow.id])
        model.loadMore()
        try await waitUntil("second page completion") { !model.isLoadingMore }
        #expect(!model.hasMore)
    }

    @Test func disabledOutOfScopeExpiredAndEditedSourceCachesAreNotDisplayed() async throws {
        var active = source("slow")
        let other = source("other")
        var expired = SearchBook(bookURL: active.id + "/expired", origin: active.id, originName: "源", type: 0, name: "书")
        expired.time = 0
        let outOfScope = SearchBook(bookURL: other.id + "/cached", origin: other.id, originName: "源", type: 0, name: "书")
        let edited = SearchBook(bookURL: active.id + "/edited", origin: active.id, originName: "源", type: 0, name: "书")
        active.lastUpdateTime = edited.time + 1
        let transport = GatedModelSearchTransport()
        let model = model(transport: transport, repository: InMemorySearchBookRepository(values: [expired, outOfScope, edited]))
        defer { model.cancel(reset: true) }
        var started = transport.started.makeAsyncIterator()
        model.search(keyword: "书", sources: [active])
        _ = await started.next()
        #expect(model.books.isEmpty)
        #expect(!model.isShowingCachedResults)
        active.enabled = false
        model.search(keyword: "书", sources: [active])
        #expect(model.state == .unavailable)
        #expect(model.books.isEmpty)
    }

    private func source(_ name: String) -> BookSource {
        var value = BookSource(bookSourceUrl: "https://\(name).example", bookSourceName: name)
        value.searchUrl = "/search?q={{key}}&page={{page}}"
        value.ruleSearch = .init(bookList: "$.books", name: "$.name", author: "$.author", bookUrl: "$.url")
        return value
    }

    private func model(transport: GatedModelSearchTransport, repository: any SearchBookRepository) -> SearchViewModel {
        .init(service: BookSearchService(transport: transport, history: .init()),
              keywordRepository: InMemorySearchKeywordRepository(), searchBookRepository: repository)
    }

    private func waitUntil(_ reason: String = "Search state did not settle", _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try await !condition() {
            try #require(ContinuousClock.now < deadline, Comment(rawValue: reason))
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor GatedModelSearchTransport: HTTPTransport {
    nonisolated let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let fastHost: String?
    private var released = false
    private var pending: [UUID: (URLRequest, CheckedContinuation<HTTPResponse, Error>)] = [:]
    private var recorded: [URLRequest] = []
    init(fastHost: String? = nil) {
        self.fastHost = fastHost
        (started, continuation) = AsyncStream.makeStream(of: Void.self)
    }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        if released || request.url?.host == fastHost { return response(request) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                pending[id] = (request, value)
                continuation.yield(())
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
    func release() {
        released = true
        let values = pending.values
        pending = [:]
        for (request, continuation) in values { continuation.resume(returning: response(request)) }
    }
    func requests() -> [URLRequest] { recorded }
    private func response(_ request: URLRequest) -> HTTPResponse {
        .init(data: Data(#"{"books":[{"name":"书","author":"作者","url":"/fresh"}]}"#.utf8),
              statusCode: 200, headers: [:], finalURL: request.url!)
    }
}
