import Foundation
import Testing
@testable import LegadoCore

private actor ContentWebTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let url = try #require(request.url)
        return .init(data: Data("<p>HTTP 正文</p>".utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

@MainActor private final class ContentWebExecutor: SourceWebViewRequestExecuting {
    private(set) var requests: [PreparedRequest] = []
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        requests.append(prepared)
        return .init(data: Data("<p>网页正文</p>".utf8), statusCode: 200, headers: [:], finalURL: prepared.url, requestedCharset: "utf-8")
    }
}

struct ContentWebViewTests {
    @Test(arguments: [false, true]) func contentWebScriptIsAppliedOnlyToWebViewRequests(webView: Bool) async {
        let sourceID = "https://content-web.test"
        var source = BookSource(bookSourceUrl: sourceID, bookSourceName: "正文网页")
        var rule = ContentRule(); rule.content = "@CSS:p@text"; rule.webJs = "'script result'"; rule.sourceRegex = ".*resource.*"
        source.ruleContent = rule
        let book = Book(bookUrl: sourceID + "/book", name: "书", origin: source.id)
        let chapter = BookChapter(url: sourceID + "/chapter" + (webView ? #",{"webView":true,"charset":"gbk"}"# : ""), title: "章", bookUrl: book.bookUrl, index: 0)
        let transport = ContentWebTransport()
        let executor = await ContentWebExecutor()
        let service = NetworkBookService(transport: transport, networkPolicy: SourceNetworkPolicy(), webViewExecutor: executor)
        let report = await service.loadContent(book: book, chapter: chapter, source: source)
        #expect(report.diagnostics.isEmpty)
        #expect(report.content == (webView ? "网页正文" : "HTTP 正文"))
        #expect(await executor.requests.count == (webView ? 1 : 0))
        #expect(await transport.requests.count == (webView ? 0 : 1))
        if webView {
            #expect(await executor.requests.first?.webJavaScript == rule.webJs)
            #expect(await executor.requests.first?.sourceRegex == rule.sourceRegex)
        }
    }

    @Test func urlWebScriptOverridesContentScriptAndPOSTUsesConfiguredTransport() async throws {
        let sourceID = "https://content-web.test"
        var source = BookSource(bookSourceUrl: sourceID, bookSourceName: "正文网页")
        var rule = ContentRule(); rule.content = "@CSS:p@text"; rule.webJs = "'content script'"; source.ruleContent = rule
        let book = Book(bookUrl: sourceID + "/book", name: "书", origin: source.id)
        let chapter = BookChapter(url: sourceID + #"/chapter,{"webView":true,"webJs":"'URL script'","method":"POST","body":"a=1","headers":{"X-Token":"token"}}"#, title: "章", bookUrl: book.bookUrl, index: 0)
        let transport = ContentWebTransport()
        let executor = await ContentWebExecutor()
        let result = await NetworkBookService(transport: transport, networkPolicy: SourceNetworkPolicy(), webViewExecutor: executor)
            .loadContent(book: book, chapter: chapter, source: source)
        #expect(result.diagnostics.isEmpty)
        let captured = try #require(await executor.requests.first)
        #expect(captured.webJavaScript == "'URL script'")
        #expect(captured.webViewHTML == "<p>HTTP 正文</p>")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("a=1".utf8))
        #expect(request.value(forHTTPHeaderField: "X-Token") == "token")
    }

    @Test func syntheticVolumeReturnsTagWithoutNetworkAndAudioFailureIsExplicit() async {
        let sourceID = "https://content-web.test"
        var source = BookSource(bookSourceUrl: sourceID, bookSourceName: "正文网页")
        let book = Book(bookUrl: sourceID + "/book", name: "书", origin: source.id)
        var volume = BookChapter(url: "第一卷0", title: "第一卷", bookUrl: book.bookUrl, index: 0)
        volume.isVolume = true; volume.tag = "卷简介"
        let transport = ContentWebTransport()
        let service = NetworkBookService(transport: transport)
        let result = await service.loadContent(book: book, chapter: volume, source: source)
        #expect(result.content == "卷简介")
        #expect(result.diagnostics.isEmpty)
        #expect(await transport.requests.isEmpty)
        source.bookSourceType = 1
        volume.isVolume = false
        let audio = await service.loadContent(book: book, chapter: volume, source: source)
        #expect(audio.content.isEmpty)
        #expect(audio.diagnostics.contains { $0.code == "content.media_unsupported" })
    }
}
