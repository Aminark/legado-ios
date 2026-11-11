import Foundation
import Testing
@testable import LegadoCore

private actor ComicTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let pages: [String: HTTPResponse]
    init(pages: [String: HTTPResponse] = [:]) { self.pages = pages }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let url = try #require(request.url)
        return pages[url.absoluteString] ?? .init(data: Data([0x89, 0x50, 0x4e, 0x47]), statusCode: 200, headers: [:], finalURL: url)
    }
}

struct ChapterImageTests {
    let base = URL(string: "https://comic.invalid/chapter/1")!

    // Rule shapes from https://gist.github.com/cxfksword/486d85e7e0c1e28eb78ae0fbcfa55d1f.
    // The fixture contains only synthetic URLs and generated data.
    @Test(arguments: [
        #"<img src="/pages/01.jpg">"#,
        #"<img src='/placeholder.gif' data-original='/pages/01.jpg'>"#,
        #"<img data-src='/pages/01.jpg'>"#,
        #"<mip-img data-echo='/pages/01.jpg'>"#,
        #"<IMG alt='a > b' SRC=/pages/01.jpg>"#,
        #"<img data-srcset='/pages/01.jpg 600w, /pages/02.jpg 1200w'>"#,
        #"<img src=\"/pages/01.jpg\">"#
    ]) func recognizesImageMarkup(markup: String) throws {
        let blocks = ChapterImageParser().blocks(in: markup, baseURL: base)
        #expect(blocks.map(\.content) == [.image("https://comic.invalid/pages/01.jpg")])
    }

    @Test func legacyUnescapedHeaderJSONSurvivesFormattingAndParsing() throws {
        let html = #"<img src="/pages/01.jpg,{"headers":{"Referer":"https://comic.invalid/chapter/1","X-Token":"a > b"}}">"#
        let formatted = ChapterHTMLFormatter().format(html, baseURL: base)
        let blocks = ChapterImageParser().blocks(in: formatted, baseURL: base)
        let image = try #require(blocks.first)
        guard case .image(let address) = image.content else { Issue.record("Missing image"); return }
        let request = try LegadoURLBuilder().prepare(address)
        #expect(request.url.absoluteString == "https://comic.invalid/pages/01.jpg")
        #expect(request.headers["Referer"] == base.absoluteString)
        #expect(request.headers["X-Token"] == "a > b")
    }

    @Test func mixedTextRangesRetainOriginalOffsetsAndNormalizeIsIdempotent() {
        let content = "序言😀\n<img src='/pages/01.jpg?x=1&amp;y=2'>\n后记\nhttps://comic.invalid/pages/02.png"
        let parser = ChapterImageParser()
        let blocks = parser.blocks(in: content, baseURL: base)
        #expect(blocks.count == 4)
        #expect(blocks.map(\.content) == [.text("序言😀"), .image("https://comic.invalid/pages/01.jpg?x=1&y=2"), .text("后记"), .image("https://comic.invalid/pages/02.png")])
        #expect((content as NSString).substring(with: blocks[1].range) == "<img src='/pages/01.jpg?x=1&amp;y=2'>")
        let normalized = parser.normalize(content, baseURL: base, allowBareURLs: false)
        #expect(parser.normalize(normalized, baseURL: base, allowBareURLs: false) == normalized)
    }

    @Test func bareURLsRequireImageTypeOrImageExtensionAndNeverConsumeProse() {
        let parser = ChapterImageParser()
        let content = "访问 https://comic.invalid/help\nhttps://comic.invalid/image?id=1\n/pages/02\npages/03.png"
        let normal = parser.blocks(in: content, baseURL: base)
        let comic = parser.blocks(in: content, baseURL: base, allowBareURLs: true)
        #expect(normal.filter { if case .image = $0.content { return true }; return false }.count == 1)
        #expect(comic.filter { if case .image = $0.content { return true }; return false }.count == 3)
        #expect(comic.first?.content == .text("访问 https://comic.invalid/help"))
        #expect(parser.blocks(in: "<img src='javascript:bad()'><img src='file:///tmp/a.jpg'>", baseURL: base).isEmpty)
    }

    @Test(arguments: [0, 2, 3]) func ruleOutputAndNextPageUseEachFinalURL(type: Int) async throws {
        var source = BookSource(bookSourceUrl: "https://comic.invalid", bookSourceName: "漫画测试")
        source.bookSourceType = type
        var rule = ContentRule()
        rule.content = ".page@img@data-original"
        rule.nextContentUrl = ".next@href"
        rule.imageStyle = "FULL"
        source.ruleContent = rule
        let second = "https://comic.invalid/redirected/next"
        let transport = ComicTransport(pages: [
            base.absoluteString: .init(data: Data("<div class='page'><img data-original='01'></div><a class='next' href='next'>下一页</a>".utf8), statusCode: 200, headers: [:], finalURL: URL(string: "https://comic.invalid/redirected/first")!),
            second: .init(data: Data("<div class='page'><img data-original='/pages/02.jpg'></div>".utf8), statusCode: 200, headers: [:], finalURL: URL(string: second)!)
        ])
        // A relative extensionless address is deliberately emitted as ./01.
        rule.content = ".page@img@data-original\n@js:result == '01' ? './01' : result"
        source.ruleContent = rule
        let book = Book(bookUrl: "https://comic.invalid/book", name: "测试漫画", origin: source.id)
        let chapter = BookChapter(url: base.absoluteString, title: "第一话", bookUrl: book.bookUrl, index: 0)
        let report = await NetworkBookService(transport: transport).loadContent(book: book, chapter: chapter, source: source)
        #expect(report.diagnostics.isEmpty)
        #expect(ChapterImageParser().blocks(in: report.content, baseURL: base).map(\.content) == [
            .image("https://comic.invalid/redirected/01"), .image("https://comic.invalid/pages/02.jpg")
        ])
    }

    @Test(arguments: [
        ".page@img@data-original\n@js:result.split('\\n').map(x=>'<img src=\\\"'+x+'\\\">').join('\\n')",
        ".page@img@html",
        "$.results..contents[*].url\n@js:result.split('\\n').map(x=>'<img src=\"'+x+','+JSON.stringify({headers:{Referer:baseUrl}})+'\">').join('\\n')"
    ]) func importsPublicRuleShapesAndLoadsImageChapters(rule: String) async throws {
        let document: [String: Any] = ["bookSourceUrl": "https://comic.invalid", "bookSourceName": "合成漫画源", "bookSourceType": 0,
            "ruleContent": ["content": rule, "imageStyle": "FULL"]]
        let imported = try BookSourceImporter().inspect(JSONSerialization.data(withJSONObject: document))
        #expect(imported.rejected.isEmpty)
        let source = try #require(imported.sources.first)
        let response = rule.hasPrefix("$.")
            ? #"{"results":[{"contents":[{"url":"/01.jpg"},{"url":"/02.jpg"}]}]}"#
            : "<div class='page'><img data-original='/01.jpg'><img data-original='/02.jpg'></div>"
        let transport = ComicTransport(pages: [base.absoluteString:
            .init(data: Data(response.utf8), statusCode: 200, headers: [:], finalURL: base)])
        let book = Book(bookUrl: "https://comic.invalid/book", name: "漫画", origin: source.id)
        let chapter = BookChapter(url: base.absoluteString, title: "第一话", bookUrl: book.bookUrl, index: 0)
        let report = await NetworkBookService(transport: transport).loadContent(book: book, chapter: chapter, source: source)
        #expect(report.diagnostics.isEmpty)
        let blocks = ChapterImageParser().blocks(in: report.content, baseURL: base)
        #expect(blocks.count == 2)
        for (index, block) in blocks.enumerated() {
            guard case .image(let address) = block.content else { Issue.record("Not an image"); continue }
            let request = try LegadoURLBuilder().prepare(address)
            #expect(request.url.absoluteString == "https://comic.invalid/0\(index + 1).jpg")
            if rule.hasPrefix("$.") { #expect(request.headers["Referer"] == base.absoluteString) }
        }
    }

    @Test func htmlWrapperDoesNotBecomeAnExtraImage() {
        let parser = ChapterImageParser()
        let html = "<div>\n<img data-original='/page.jpg'>\n</div>"
        let normalized = parser.normalize(html, baseURL: base, allowBareURLs: true)
        #expect(parser.blocks(in: normalized, baseURL: base, allowBareURLs: true).map(\.content) == [.image("https://comic.invalid/page.jpg")])
    }

    @Test func imageRequestsUseSourceHeadersCookiesAndImageOverrides() async throws {
        var source = BookSource(bookSourceUrl: "https://comic.invalid", bookSourceName: "漫画测试")
        source.header = #"{"User-Agent":"Comic Test","Referer":"https://comic.invalid/source","X-Source":"yes"}"#
        source.enabledCookieJar = true
        let policy = SourceNetworkPolicy()
        await policy.setCookieHeader("session=fixture", sourceID: source.id, url: base)
        let transport = ComicTransport()
        let loader = ChapterImageLoader(transport: transport, policy: policy)
        let book = Book(bookUrl: "https://comic.invalid/book", name: "测试漫画", origin: source.id)
        let chapter = BookChapter(url: base.absoluteString, title: "第一话", bookUrl: book.bookUrl, index: 0)
        _ = try await loader.load(#"/pages/01.jpg, {"headers":{"referer":"https://comic.invalid/override"}}"#, source: source, book: book, chapter: chapter)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://comic.invalid/pages/01.jpg")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://comic.invalid/override")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Comic Test")
        #expect(request.value(forHTTPHeaderField: "X-Source") == "yes")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture") == true)
    }

    @Test func defaultRefererAndDataImages() async throws {
        let source = BookSource(bookSourceUrl: "https://comic.invalid", bookSourceName: "漫画测试")
        let book = Book(bookUrl: "https://comic.invalid/book", name: "测试漫画", origin: source.id)
        let chapter = BookChapter(url: base.absoluteString, title: "第一话", bookUrl: book.bookUrl, index: 0)
        let transport = ComicTransport()
        let loader = ChapterImageLoader(transport: transport, policy: SourceNetworkPolicy())
        _ = try await loader.load("/page.jpg", source: source, book: book, chapter: chapter)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Referer") == base.absoluteString)
        let data = try await loader.load("data:image/png;base64,iVBORw==", source: source, book: book, chapter: chapter)
        #expect(data == Data([0x89, 0x50, 0x4e, 0x47]))
        #expect(await transport.requests.count == 1)
    }
}
