import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct RuleSubscriptionRegressionTests {
    @Test func deletingSubscriptionsDuringAutomaticUpdateDoesNotCrashOrImportRemovedRules() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rules.sqlite3"))
        let repository = SQLiteConfigurationRepository(database: database)
        var first = RuleSub(id: 1, name: "订阅一", url: "https://subscriptions.test/one")
        first.autoUpdate = true
        first.silentUpdate = true
        first.update = 0
        var second = first
        second.id = 2
        second.url = "https://subscriptions.test/two"
        second.customOrder = 1
        try await repository.saveRuleSubs([first, second])
        let transport = PausedSubscriptionTransport()
        let model = RuleSubscriptionModel(repository: repository, transport: transport)
        let sources = SourceLibraryModel.demo(sources: [])
        let rss = RSSLibraryModel(database: database)
        let rules = ReplaceRuleLibraryModel.demo()
        await model.load()
        let update = Task { await model.checkAutomaticUpdates(bookSources: sources, rssSources: rss, replaceRules: rules) }
        try await transport.waitUntilPaused()
        await model.remove(at: IndexSet(integersIn: 0..<2))
        await transport.resume()
        await update.value
        #expect(model.values.isEmpty)
        #expect(sources.sources.isEmpty)
        #expect(model.pendingIDs.isEmpty)
        #expect(await transport.requestCount() == 1)
    }
}

private actor PausedSubscriptionTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var count = 0
    func data(for request: URLRequest) async throws -> HTTPResponse {
        count += 1
        await withCheckedContinuation { pending = $0 }
        return .init(data: Data(#"[{"bookSourceUrl":"https://new.test","bookSourceName":"已删除订阅的书源"}]"#.utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if pending != nil { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw URLError(.timedOut)
    }
    func resume() { pending?.resume(); pending = nil }
    func requestCount() -> Int { count }
}
