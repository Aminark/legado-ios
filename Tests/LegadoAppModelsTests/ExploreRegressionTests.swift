import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ExploreRegressionTests {
    @Test func failedPageCanBeRetriedWithoutDroppingResultsOrSkippingThePage() async throws {
        let transport = ControlledExploreTransport()
        defer { Task { await transport.cancelAll() } }
        let model = model(transport)
        let initial = Task { await model.load() }
        try await waitUntil { await transport.count == 1 }
        try await transport.succeed(0, name: "first")
        await initial.value
        let first = try #require(model.books.last)

        model.loadNextPageIfNeeded(current: first)
        try await waitUntil { await transport.count == 2 }
        try await transport.fail(1)
        try await waitUntil { !model.isLoadingMore }
        #expect(model.books.map(\.name) == ["first"])
        #expect(model.paginationError != nil)
        #expect(model.state == .ready)

        model.retryNextPage()
        try await waitUntil { await transport.count == 3 }
        try await transport.succeed(2, name: "second")
        try await waitUntil { !model.isLoadingMore }

        #expect(model.books.map(\.name) == ["first", "second"])
        #expect(model.paginationError == nil)
        #expect(await transport.urls() == [
            "https://explore-model.test/a?page=1",
            "https://explore-model.test/a?page=2",
            "https://explore-model.test/a?page=2"
        ])
    }

    @Test func switchingAwayAndBackIgnoresTheEarlierRequestForTheSameKind() async throws {
        let transport = ControlledExploreTransport()
        defer { Task { await transport.cancelAll() } }
        let model = model(transport)
        let firstA = Task { await model.select(kind: kind("a")) }
        try await waitUntil { await transport.count == 1 }
        let middleB = Task { await model.select(kind: kind("b")) }
        try await waitUntil { await transport.count == 2 }
        let latestA = Task { await model.select(kind: kind("a")) }
        try await waitUntil { await transport.count == 3 }

        try await transport.succeed(2, name: "latest-a")
        await latestA.value
        try await transport.succeed(0, name: "obsolete-a")
        await firstA.value
        try await transport.succeed(1, name: "obsolete-b")
        await middleB.value

        #expect(model.selectedKind == kind("a"))
        #expect(model.books.map(\.name) == ["latest-a"])
        #expect(model.state == .ready)
    }

    @Test func cancelledOldPageCannotClearTheNewKindsLoadingState() async throws {
        let transport = ControlledExploreTransport()
        defer { Task { await transport.cancelAll() } }
        let model = model(transport)
        let initialA = Task { await model.select(kind: kind("a")) }
        try await waitUntil { await transport.count == 1 }
        try await transport.succeed(0, name: "a-first")
        await initialA.value
        model.loadNextPageIfNeeded(current: try #require(model.books.last))
        try await waitUntil { await transport.count == 2 }

        let initialB = Task { await model.select(kind: kind("b")) }
        try await waitUntil { await transport.count == 3 }
        #expect(!model.isLoadingMore)
        try await transport.succeed(2, name: "b-first")
        await initialB.value
        model.loadNextPageIfNeeded(current: try #require(model.books.last))
        try await waitUntil { await transport.count == 4 }
        try await transport.succeed(1, name: "a-obsolete-page")
        // Let the cancelled request unwind while B's next page is still held.
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isLoadingMore)
        #expect(model.books.map(\.name) == ["b-first"])

        try await transport.succeed(3, name: "b-second")
        try await waitUntil { !model.isLoadingMore }
        #expect(model.books.map(\.name) == ["b-first", "b-second"])
    }

    private func kind(_ name: String) -> ExploreKind {
        .init(title: name, url: "/\(name)?page={{page}}")
    }

    private func model(_ transport: ControlledExploreTransport) -> ExploreSourceViewModel {
        var source = BookSource(bookSourceUrl: "https://explore-model.test", bookSourceName: "发现测试")
        source.exploreUrl = "a::/a?page={{page}}&&b::/b?page={{page}}"
        source.ruleExplore = .init(bookList: "$.books", name: "$.name", bookUrl: "$.url")
        return .init(source: source, service: .init(transport: transport, networkPolicy: .init()))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await !condition() {
            try #require(ContinuousClock.now < deadline, "Explore request did not settle")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ControlledExploreTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<HTTPResponse, Error>] = [:]
    var count: Int { requests.count }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let index = requests.count
        requests.append(request)
        // Intentionally allow a response after cancellation to reproduce the
        // common case where a transport cannot stop work already in progress.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int, name: String) throws {
        let pendingContinuation = pending.removeValue(forKey: index)
        let continuation = try #require(pendingContinuation)
        let url = try #require(requests[index].url)
        continuation.resume(returning: .init(
            data: Data(#"{"books":[{"name":"\#(name)","url":"/book/\#(name)"}]}"#.utf8),
            statusCode: 200, headers: [:], finalURL: url
        ))
    }

    func fail(_ index: Int) throws {
        let pendingContinuation = pending.removeValue(forKey: index)
        let continuation = try #require(pendingContinuation)
        continuation.resume(throwing: URLError(.notConnectedToInternet))
    }

    func urls() -> [String] { requests.compactMap(\.url).map(\.absoluteString) }

    func cancelAll() {
        let values = pending.values
        pending = [:]
        for value in values { value.resume(throwing: CancellationError()) }
    }
}
