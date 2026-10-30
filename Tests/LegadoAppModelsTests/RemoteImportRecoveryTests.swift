import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

private actor TLSImportTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let alternateFails: Bool

    init(alternateFails: Bool = false) { self.alternateFails = alternateFails }

    func data(for request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host == "raw.githubusercontent.com" { throw URLError(.secureConnectionFailed) }
        guard url.host == "api.github.com" else { throw URLError(.unsupportedURL) }
        if alternateFails { throw URLError(.cannotConnectToHost) }
        let body = #"[{"bookSourceUrl":"https://comic.test","bookSourceName":"漫画源","bookSourceType":2}]"#
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

@MainActor
struct RemoteImportRecoveryTests {
    private let link = "legado://import/bookSource?src=https://raw.githubusercontent.com/gedoor/gedoor.github.io/master/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt"

    @Test func tlsFailureRecoversIntoReviewBeforeSaving() async throws {
        let transport = TLSImportTransport()
        let repository = InMemoryBookSourceRepository()
        let model = SourceLibraryModel(repository: repository, importTransport: transport)

        await model.handleDeepLink(try #require(URL(string: link)))

        #expect(model.notice == nil)
        #expect(model.pendingImport?.validCount == 1)
        #expect(model.pendingImport?.items.first?.source.bookSourceType == 2)
        #expect(model.sources.isEmpty)
        #expect(await repository.load().isEmpty)
        #expect(await transport.requests.count == 2)
        #expect(!model.isWorking)

        let pending = try #require(model.pendingImport)
        await model.commitPendingImport(selectedIDs: Set(pending.items.map(\.id)), keepOriginalName: false,
                                        keepOriginalGroup: false, keepOriginalEnabled: false,
                                        customGroup: nil, addCustomGroup: true)
        #expect(await repository.load().count == 1)
    }

    @Test func bothEndpointsFailWithoutChangingExistingSources() async throws {
        let existing = BookSource(bookSourceUrl: "https://kept.test", bookSourceName: "保留")
        let transport = TLSImportTransport(alternateFails: true)
        let repository = InMemoryBookSourceRepository(sources: [existing])
        let model = SourceLibraryModel(repository: repository, importTransport: transport)
        await model.load()

        await model.handleDeepLink(try #require(URL(string: link)))

        #expect(model.pendingImport == nil)
        #expect(model.sources == [existing])
        #expect(await repository.load() == [existing])
        #expect(!model.isWorking)
        #expect(model.notice?.kind == .error)
        #expect(model.notice?.detail.contains("raw.githubusercontent.com") == true)
        #expect(model.notice?.detail.contains("-1200") == true)
        #expect(model.notice?.detail.contains("api.github.com") == true)
        #expect(model.notice?.detail.contains("-1004") == true)
        #expect(await transport.requests.count == 2)
    }
}
