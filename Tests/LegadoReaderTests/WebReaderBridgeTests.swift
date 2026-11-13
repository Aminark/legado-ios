import UIKit
import WebKit
import XCTest
@testable import Legado

@MainActor
final class WebReaderBridgeTests: XCTestCase {
    private func webPrepared(script: String?, resource: String? = nil) throws -> PreparedRequest {
        let html = "<html><body><p>原始页面</p></body></html>"
        let address = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        var prepared = try LegadoURLBuilder().prepare(address)
        prepared.useWebView = true
        prepared.webJavaScript = script
        prepared.sourceRegex = resource
        return prepared
    }

    func testBackgroundWebViewUsesScriptReturnValueAndRetriesNull() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "网页正文")
        let executor = WKSourceWebViewExecutor()
        let response = try await executor.execute(webPrepared(script: "window.attempt = (window.attempt || 0) + 1; window.attempt < 3 ? null : '脚本正文' + window.attempt"), source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "脚本正文3")
        let empty = try await executor.execute(webPrepared(script: "''"), source: source, timeout: 5)
        XCTAssertEqual(empty.decodedText, "")
        var userAgent = try webPrepared(script: "navigator.userAgent")
        userAgent.headers["User-Agent"] = "Legado WK Regression/1.0"
        let identity = try await executor.execute(userAgent, source: source, timeout: 5)
        XCTAssertEqual(identity.decodedText, "Legado WK Regression/1.0")
    }

    func testBackgroundWebViewMatchesDispatchedResourceInsteadOfScriptOutput() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "资源网页")
        let prepared = try webPrepared(script: "fetch('data:text/plain,resource-match').catch(() => {}); 'ignored output'", resource: "data:text/plain,resource-match")
        let response = try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "data:text/plain,resource-match")
    }

    func testBackgroundWebViewLoadsPOSTResponseHTMLAndReportsMissingResource() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "资源网页")
        var prepared = try webPrepared(script: "document.querySelector('p').textContent")
        prepared.webViewHTML = "<p>POST 返回的正文</p>"
        prepared.url = try XCTUnwrap(URL(string: source.id + "/posted"))
        let response = try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "POST 返回的正文")
        do {
            let missing = try webPrepared(script: nil, resource: "https://never-matches.test/.*")
            _ = try await WKSourceWebViewExecutor().execute(missing, source: source, timeout: 1)
            XCTFail("Unmatched resource must not become a successful HTML result")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未找到匹配")) }
    }

    func testBackgroundWebViewCancellationStopsNullPolling() async throws {
        let prepared = try webPrepared(script: "null")
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "取消测试")
        let request = Task { try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testGeneratedRSSContentFollowsAppearanceWithoutReloading() async throws {
        let source = RssSource(sourceUrl: "https://appearance-regression.test", sourceName: "测试")
        let loaded = expectation(description: "HTML loaded")
        let surface = RSSWebReaderView(
            mode: .html(content: "<body><p>订阅正文</p><a href='#'>链接</a><button>操作</button></body>", baseURL: nil),
            source: source, onTextChange: { _ in loaded.fulfill() }
        )
        let coordinator = surface.makeCoordinator()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = coordinator
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        controller.overrideUserInterfaceStyle = .dark
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            RSSWebReaderView.dismantleUIView(webView, coordinator: coordinator)
            window.isHidden = true
        }
        coordinator.installRulesAndLoad(mode: surface.mode, in: webView)
        await fulfillment(of: [loaded], timeout: 20)
        let appearanceScript = """
        [matchMedia('(prefers-color-scheme:dark)').matches,
         getComputedStyle(document.body).backgroundColor,
         getComputedStyle(document.body).color,
         getComputedStyle(document.querySelector('a')).color,
         getComputedStyle(document.documentElement).colorScheme].map(String).join('|')
        """
        let dark = try await webView.evaluateJavaScript(appearanceScript)
        XCTAssertEqual(dark as? String, "true|rgb(17, 17, 19)|rgb(242, 242, 242)|rgb(158, 203, 255)|light dark")
        _ = try await webView.evaluateJavaScript("window.appearanceMarker = 'preserved'")
        controller.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        XCTAssertEqual(webView.traitCollection.userInterfaceStyle, .light)
        var light = try await webView.evaluateJavaScript(appearanceScript)
        for _ in 0..<50 {
            if (light as? String)?.hasPrefix("false|") == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
            light = try await webView.evaluateJavaScript(appearanceScript)
        }
        XCTAssertEqual(light as? String, "false|rgb(252, 252, 252)|rgb(23, 23, 23)|rgb(0, 0, 238)|light dark")
        let marker = try await webView.evaluateJavaScript("window.appearanceMarker")
        XCTAssertEqual(marker as? String, "preserved")
        // A source may intentionally override the generated article palette.
        _ = try await webView.evaluateJavaScript("document.head.insertAdjacentHTML('beforeend', '<style>body{color:rgb(120,30,40)}</style>')")
        let custom = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        XCTAssertEqual(custom as? String, "rgb(120, 30, 40)")
    }

    func testPageJavaScriptCanStoreVariablesAndEvaluateContentRules() async throws {
        let source = RssSource(sourceUrl: "https://bridge-regression.test/\(UUID().uuidString)", sourceName: "测试")
        let loaded = expectation(description: "HTML loaded")
        let surface = RSSWebReaderView(mode: .html(content: "<p>页面正文</p>", baseURL: source.sourceUrl), source: source,
                                       onTextChange: { _ in loaded.fulfill() })
        let coordinator = surface.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "legado")
        configuration.userContentController.addUserScript(.init(source: coordinator.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            RSSWebReaderView.dismantleUIView(webView, coordinator: coordinator)
            window.isHidden = true
        }
        coordinator.installRulesAndLoad(mode: surface.mode, in: webView)
        await fulfillment(of: [loaded], timeout: 20)

        let result = try await webView.evaluateJavaScript("""
            java.put('key', '已保存');
            java.setContent('<div><p>规则正文</p></div>');
            [java.get('key'), java.getString('tag.p@text')].join('|');
            """)
        XCTAssertEqual(result as? String, "已保存|规则正文")
    }
}

private actor RSSPaginationTransport: HTTPTransport {
    private var requests: [URL] = []
    private var shouldFailSecondPage = true

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try XCTUnwrap(request.url)
        requests.append(url)
        if url.host == "unavailable.test" { throw URLError(.cannotConnectToHost) }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value ?? "1"
        if page == "2", shouldFailSecondPage {
            shouldFailSecondPage = false
            throw URLError(.networkConnectionLost)
        }
        let body = "{\"items\":[{\"title\":\"Page \(page)\",\"link\":\"https://feed.test/article/\(page)\"}]}"
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func requestedPages() -> [String] {
        requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }
    }

    func requestCount() -> Int { requests.count }
}

private actor RSSDelayedTransport: HTTPTransport {
    let pausedHost: String
    let pausedPage: String
    private var requestTotal = 0
    private var pending: CheckedContinuation<Void, Never>?

    init(host: String, page: String) { pausedHost = host; pausedPage = page }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try XCTUnwrap(request.url)
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value ?? "1"
        requestTotal += 1
        if url.host == pausedHost, page == pausedPage {
            await withCheckedContinuation { continuation in
                pending = continuation
            }
        }
        let body = "{\"items\":[{\"title\":\"Page \(page)\",\"link\":\"https://feed.test/article/\(page)\"}]}"
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if pending != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }

    func resume() { pending?.resume(); pending = nil }
    func requestCount() -> Int { requestTotal }
}

@MainActor
final class RSSLibraryRegressionTests: XCTestCase {
    func testUnavailableDatabaseDoesNotCrashOrPublishUnsavedImports() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing file".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let model = RSSLibraryModel.live(databaseURL: blocked.appendingPathComponent("rss.sqlite3"))
        XCTAssertNotNil(model.errorMessage)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        let saved = await model.save(source(), replacing: nil)
        XCTAssertFalse(saved)
        await model.importText(#"{"sourceUrl":"https://feed.test","sourceName":"未保存的订阅"}"#)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("existing file".utf8))
    }

    private func source(host: String = "feed.test") -> RssSource {
        var source = RssSource(sourceUrl: "https://\(host)", sourceName: host)
        source.sortUrl = "https://\(host)/list?page={{page}}"
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        source.ruleNextPage = "PAGE"
        return source
    }

    func testFailedNextPageRetriesTheSamePageWithoutSkippingArticles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSPaginationTransport()
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let feed = source()
        await model.refresh(feed)
        XCTAssertEqual(model.articles.map(\.title), ["Page 1"])
        await model.loadMore(feed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.articles.map(\.title), ["Page 1"])
        await model.loadMore(feed)
        let pages = await transport.requestedPages()
        XCTAssertEqual(pages, ["1", "2", "2"])
        XCTAssertEqual(model.articles.map(\.title), ["Page 1", "Page 2"])
    }

    func testFailedSourceChangeDoesNotReusePreviousSourcesArticlesOrNextPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSPaginationTransport()
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        await model.refresh(source())
        let unavailable = source(host: "unavailable.test")
        await model.refresh(unavailable)
        XCTAssertTrue(model.articles.isEmpty)
        let count = await transport.requestCount()
        await model.loadMore(unavailable)
        let afterLoadMore = await transport.requestCount()
        XCTAssertEqual(afterLoadMore, count)
    }

    func testSlowPreviousSourceCannotReplaceTheCurrentFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSDelayedTransport(host: "slow.test", page: "1")
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let slow = Task { await model.refresh(source(host: "slow.test")) }
        try await transport.waitUntilPaused()
        await model.refresh(source())
        XCTAssertTrue(model.isWorking)
        await transport.resume()
        await slow.value
        XCTAssertEqual(model.articles.map(\.origin), ["https://feed.test"])
        XCTAssertFalse(model.isWorking)
    }

    func testRepeatedLoadMoreWhileWaitingRequestsOnlyOnePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSDelayedTransport(host: "feed.test", page: "2")
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let feed = source()
        await model.refresh(feed)
        let pending = Task { await model.loadMore(feed) }
        try await transport.waitUntilPaused()
        await model.loadMore(feed)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
        await transport.resume()
        await pending.value
        XCTAssertEqual(model.articles.map(\.title), ["Page 1", "Page 2"])
    }
}
