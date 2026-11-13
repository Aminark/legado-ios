import Foundation
import Testing
@testable import LegadoCore

struct SearchPerformanceTests {
    @Test func measuredSourceResponseTimeDoesNotBecomeARequestTimeout() async throws {
        let transport = PerformanceSearchTransport()
        let service = BookSearchService(transport: transport, networkPolicy: .init(), history: .init())
        var measuredFast = source("measured-fast")
        measuredFast.respondTime = 200
        let untested = source("untested")
        // Keep the user's explicit global timeout authoritative; do not mutate
        // the shared settings just to make this regression deterministic.
        let configuredTimeout = ApplicationSettingsStore.shared.settings.timeoutSeconds
        let singleAllowance = configuredTimeout > 0 ? Double(configuredTimeout) : 30
        let multiAllowance = configuredTimeout > 0 ? Double(configuredTimeout) : 8

        _ = await service.search(keyword: "书", page: 1, source: measuredFast)
        let single = try #require(await transport.requests().first)
        #expect(single.timeoutInterval == singleAllowance)

        _ = await service.search(keyword: "书", sources: [measuredFast, untested])
        let multi = await transport.requests().dropFirst()
        #expect(multi.count == 2)
        #expect(multi.allSatisfy { $0.timeoutInterval == multiAllowance })
    }

    @Test @MainActor func complexSourcesCannotOccupyEverySearchSlot() async throws {
        let webView = DelayedPerformanceWebView()
        var sources = (0..<8).map { source("web\($0)") }
        for index in sources.indices {
            sources[index].searchUrl = #"/search,{"webView":true}"#
        }
        let fast = source("fast")
        sources.append(fast)
        var outcomes: [SourceSearchOutcome] = []
        let service = BookSearchService(transport: PerformanceSearchTransport(), webViewExecutor: webView, history: .init())
        for await value in service.searchOutcomes(keyword: "书", sources: sources, maximumConcurrentSources: 8) {
            outcomes.append(value)
        }
        #expect(outcomes.first?.sourceID == fast.id)
        #expect(webView.maximumRunning == 4)
        #expect(outcomes.count == 9)
    }

    @Test func preferredSourcesRunBeforeUnknownSourcesAndDuplicateIDsRunOnce() async {
        let transport = PerformanceSearchTransport()
        let service = BookSearchService(transport: transport, history: .init())
        let sources = [source("a"), source("b"), source("a")]
        var results: [String] = []
        for await outcome in service.searchOutcomes(keyword: "书", sources: sources, maximumConcurrentSources: 1, preferredSourceIDs: [sources[1].id]) {
            results.append(outcome.sourceID)
        }
        #expect(results == [sources[1].id, sources[0].id])
        #expect(await transport.requests().count == 2)
    }

    @Test func historySurvivesRelaunchAndFailuresRemainEligibleForRecovery() async {
        let suite = "search.history.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let history = BookSearchHistory(defaults: UserDefaults(suiteName: suite)!)
        let a = source("a"), b = source("b")
        let now = Date()
        let book = SearchBook(bookURL: "book", origin: a.id, originName: "A", type: 0, name: "书")
        await history.record(.init(sourceID: a.id, books: [book], diagnostics: []), now: now)
        await history.flush()
        let reloaded = BookSearchHistory(defaults: UserDefaults(suiteName: suite)!)
        #expect(await reloaded.ordered([b, a], preferred: [], now: now).map(\.id) == [a.id, b.id])
        await reloaded.record(.init(sourceID: a.id, books: [], diagnostics: [
            .init(severity: .error, code: "search.request", message: "offline", rule: "")
        ]), now: now)
        #expect(await reloaded.ordered([a, b], preferred: [], now: now).map(\.id) == [b.id, a.id])
        #expect(await reloaded.ordered([a, b], preferred: [], now: now.addingTimeInterval(301)).map(\.id) == [a.id, b.id])
    }

    @Test func multiSourceRequestsHaveShorterTimeoutWithoutChangingSingleSourceAllowance() async {
        let transport = PerformanceSearchTransport()
        let service = BookSearchService(transport: transport, history: .init())
        let a = source("a"), b = source("b")
        _ = await service.search(keyword: "书", sources: [a, b])
        let multi = await transport.requests()
        #expect(multi.allSatisfy { $0.timeoutInterval <= 8 })
        _ = await service.search(keyword: "书", page: 1, source: a)
        #expect(await transport.requests().last?.timeoutInterval == 30)
    }

    @Test func incrementalMergeKeepsRelevanceOriginsAndCanReplaceCachedMetadata() {
        var accumulator = BookSearchAccumulator()
        let cached = SearchBook(bookURL: "old", origin: "a", originName: "A", type: 0, name: "书", author: "作者")
        let fresh = SearchBook(bookURL: "fresh", origin: "b", originName: "B", type: 0, name: "书", author: "作者")
        accumulator.add([.init(bookURL: "other", origin: "a", originName: "A", type: 0, name: "其他"), cached])
        accumulator.add([fresh], replacingExisting: true)
        let results = accumulator.results(keyword: "书")
        #expect(results.map(\.bookURL) == ["fresh", "other"])
        #expect(results[0].origins == ["a", "b"])
    }

    @Test func cacheQueryUsesLiteralKeywordAndDoesNotRequireDecodingSourceCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "cache.sqlite3"))
        try await database.replaceBookSources([.init(bookSourceUrl: "source", bookSourceName: "源")])
        let repository = SQLiteSearchBookRepository(database: database)
        let exact = SearchBook(bookURL: "exact", origin: "source", originName: "源", type: 0, name: "Swift")
        let literal = SearchBook(bookURL: "literal", origin: "source", originName: "源", type: 0, name: "100% 小说")
        try await repository.put([exact, literal])
        #expect(try await repository.cachedMatches(keyword: "%").map(\.bookURL) == ["literal"])
        #expect(try await repository.cachedMatches(keyword: "swift").map(\.bookURL) == ["exact"])
        #expect(try await repository.cachedMatches(keyword: "").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func blockingBodyJavaScriptDoesNotBlockOtherSourcesNetworkPolicy() async throws {
        let gate = BlockingSearchJavaScriptLoader()
        defer { gate.release() }
        let policy = SourceNetworkPolicy(javaScript: .init(networkLoader: gate))
        var prepared = try LegadoURLBuilder().prepare("https://body.example/search")
        prepared.bodyJavaScript = "java.ajax('https://gate.example/body')"
        let blockingPrepared = prepared
        let transport = PerformanceSearchTransport()
        let slow = Task {
            try await policy.execute(blockingPrepared, source: source("body"), transport: transport, timeout: 1)
        }
        var started = gate.started.makeAsyncIterator()
        _ = await started.next()
        let plain = try await policy.execute(LegadoURLBuilder().prepare("https://plain.example/search"),
                                              source: source("plain"), transport: transport, timeout: 1)
        #expect(plain.statusCode == 200)
        #expect(!gate.didTimeOut)
        gate.release()
        #expect(try await slow.value.decodedText == "released")
    }

    private func source(_ name: String) -> BookSource {
        var value = BookSource(bookSourceUrl: "https://\(name).example", bookSourceName: name)
        value.searchUrl = "/search?q={{key}}"
        value.ruleSearch = .init(bookList: "$.books", name: "$.name", author: "$.author", bookUrl: "$.url")
        return value
    }
}

@MainActor private final class DelayedPerformanceWebView: SourceWebViewRequestExecuting {
    private var running = 0
    private(set) var maximumRunning = 0
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        try await Task.sleep(for: .milliseconds(200))
        return .init(data: Data(#"{"books":[{"name":"书","author":"作者","url":"/book"}]}"#.utf8),
                     statusCode: 200, headers: [:], finalURL: prepared.url)
    }
}

private actor PerformanceSearchTransport: HTTPTransport {
    private var recorded: [URLRequest] = []
    func data(for request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        return .init(data: Data(#"{"books":[{"name":"书","author":"作者","url":"/book"}]}"#.utf8),
                     statusCode: 200, headers: [:], finalURL: request.url!)
    }
    func requests() -> [URLRequest] { recorded }
}

private final class BlockingSearchJavaScriptLoader: JavaScriptNetworkLoading, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    var didTimeOut: Bool { lock.withLock { timedOut } }
    init() {
        (started, continuation) = AsyncStream.makeStream(of: Void.self)
    }
    func load(_ request: URLRequest) throws -> HTTPResponse {
        continuation.yield(())
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            lock.withLock { timedOut = true }
            throw URLError(.timedOut)
        }
        return .init(data: Data("released".utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
    func release() { semaphore.signal() }
}
