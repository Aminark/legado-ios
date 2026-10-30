import UIKit
import WebKit
import XCTest
@testable import Legado

private actor OnlineImportTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let failRaw: Bool

    init(failRaw: Bool = false) { self.failRaw = failRaw }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if failRaw, request.url?.host == "raw.githubusercontent.com" { throw URLError(.secureConnectionFailed) }
        let data = Data(#"[{"bookSourceUrl":"https://comic-fixture.test","bookSourceName":"漫画导入测试","bookSourceType":2}]"#.utf8)
        return HTTPResponse(data: data, statusCode: 200, headers: [:], finalURL: request.url!)
    }
}

@MainActor
final class OnlineSourceBrowserTests: XCTestCase {
    private let importURL = "legado://import/bookSource?src=https://raw.githubusercontent.com/gedoor/gedoor.github.io/master/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt"

    func testSameWindowImportLinkUsesExistingPreviewFlow() async throws {
        try await exerciseImport(target: "")
    }

    func testTargetBlankImportLinkUsesExistingPreviewFlow() async throws {
        try await exerciseImport(target: #"target="_blank" rel="noopener noreferrer""#)
    }

    func testTargetBlankImportLinkRecoversFromTLSFailure() async throws {
        try await exerciseImport(target: #"target="_blank" rel="noopener noreferrer""#, failRaw: true)
    }

    func testYueduSameWindowImportLinkUsesExistingPreviewFlow() async throws {
        try await exerciseYueduImport(target: "")
    }

    func testYueduTargetBlankImportLinkUsesExistingPreviewFlow() async throws {
        try await exerciseYueduImport(target: #"target="_blank" rel="noopener noreferrer""#)
    }

    func testOrdinaryNewWindowLinkStaysInTheSameBrowser() async throws {
        let browser = OnlineSourceBrowser(url: OnlineBookSourcesView.catalogURL)
        var didImport = false
        browser.onImport = { _ in didImport = true }
        let window = host(browser.webView)
        defer { browser.webView.stopLoading(); window.isHidden = true }
        try await load(#"<a id="import" href="about:blank" target="_blank">新页面</a>"#, in: browser.webView)

        _ = try await browser.webView.evaluateJavaScript("document.getElementById('import').click()")

        for _ in 0..<100 {
            if browser.webView.url?.absoluteString == "about:blank", !browser.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(browser.webView.url?.absoluteString, "about:blank")
        XCTAssertFalse(didImport)
        XCTAssertNil(browser.errorMessage)
    }

    private func exerciseYueduImport(target: String) async throws {
        let remoteURL = "https://cdn.mgz.la/shuyuan/250701%E6%9C%80%E5%90%8E%E4%B8%80%E7%89%88%E4%B8%80%E7%A8%8B.json"
        try await exerciseImport(target: target, importLink: "yuedu://booksource/importonline?src=" + remoteURL,
                                 expectedRemoteURL: remoteURL)
    }

    private func exerciseImport(target: String, importLink: String? = nil, expectedRemoteURL: String? = nil,
                                failRaw: Bool = false) async throws {
        let transport = OnlineImportTransport(failRaw: failRaw)
        let library = SourceLibraryModel(repository: InMemoryBookSourceRepository(), importTransport: transport)
        let browser = OnlineSourceBrowser(url: OnlineBookSourcesView.catalogURL)
        let imported = expectation(description: "Import opens the existing preview")
        browser.onImport = { url in
            await library.handleDeepLink(url)
            imported.fulfill()
        }
        let window = host(browser.webView)
        defer { browser.webView.stopLoading(); window.isHidden = true }
        try await load("<a id='import' href='\(importLink ?? importURL)' \(target)>点击此处导入</a>", in: browser.webView)
        let originalURL = browser.webView.url

        _ = try await browser.webView.evaluateJavaScript("document.getElementById('import').click()")
        await fulfillment(of: [imported], timeout: 15)

        let pending = try XCTUnwrap(library.pendingImport)
        XCTAssertEqual(pending.validCount, 1)
        XCTAssertEqual(pending.items.first?.source.bookSourceType, 2)
        XCTAssertTrue(library.sources.isEmpty, "Opening a website must not bypass import review")
        XCTAssertNil(library.notice)
        XCTAssertEqual(browser.webView.url, originalURL)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, failRaw ? 2 : 1)
        XCTAssertEqual(requests.first?.url?.absoluteString,
                       expectedRemoteURL ?? "https://raw.githubusercontent.com/gedoor/gedoor.github.io/master/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt")
        if failRaw {
            XCTAssertEqual(requests.last?.url?.absoluteString,
                           "https://api.github.com/repos/gedoor/gedoor.github.io/contents/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt?ref=master")
        }

        await library.commitPendingImport(selectedIDs: Set(pending.items.map(\.id)), keepOriginalName: false,
                                          keepOriginalGroup: false, keepOriginalEnabled: false,
                                          customGroup: nil, addCustomGroup: true)
        XCTAssertNil(library.pendingImport)
        XCTAssertEqual(library.sources.first?.bookSourceName, "漫画导入测试")
    }

    private func host(_ webView: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        webView.frame = window.bounds
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func load(_ html: String, in webView: WKWebView) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://browser-fixture.test/catalog"))
        for _ in 0..<200 {
            if let ready = try? await webView.evaluateJavaScript("!!document.getElementById('import')"), ready as? Bool == true {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The browser fixture did not load")
        throw URLError(.timedOut)
    }
}
