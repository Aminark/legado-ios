import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

struct SourceChapterVerificationTests {
    private let opening = "初春的细雨笼罩着整个海湾，灯塔里的人正在阅读一封久远的来信。旧码头上停着一艘白色小船，送信的人却早已不见踪影。街道尽头的钟声响了三次，窗边的猫抬起头来，凝视着窗外渐渐散去的薄雾。故事中的主人公收好那枚蓝色的邮票，穿过石桥走向远处的车站。此时东方的天空慢慢亮了起来，船上的灯也一盏接着一盏熄灭，海面上只剩下阵阵微风和划桨的声音。"

    private func reference(_ text: String) -> SourceChapterReference {
        .init(provider: "QQ 阅读", chapterTitle: "第2章 来信", url: "https://book.qq.com/book-read/1/2", content: text)
    }

    @Test func normalizationIgnoresOnlyFormattingCaseWidthAndTraditionalVariants() throws {
        let text = String(repeating: "書裡的燈塔 ABC１２３。\n", count: 20)
        let simplified = String(repeating: "书里的灯塔abc123", count: 20)
        let result = try #require(ChapterTextComparison.compare(text, reference: reference(simplified)))
        #expect(result.similarity == 100)
        #expect(!result.hasMoreContent)
        #expect(ChapterTextComparison.fingerprint(text) == ChapterTextComparison.fingerprint(simplified))
    }

    @Test func matchingOpeningWithUnrelatedContinuationDoesNotValidateThatContinuation() throws {
        let candidate = opening + String(repeating: "此处后来插入了完全不同的王宫情节。", count: 20)
        let result = try #require(ChapterTextComparison.compare(candidate, reference: reference(opening)))
        #expect(result.similarity == 100)
        #expect(result.hasMoreContent)
        #expect(result.referenceCharacters == ChapterTextComparison.normalize(opening).count)
        #expect(result.candidateCharacters > result.referenceCharacters)
    }

    @Test func shortReferencesAndShortBodiesHaveNoPercentage() {
        #expect(ChapterTextComparison.compare(opening, reference: reference("请登录后阅读")) == nil)
        #expect(ChapterTextComparison.compare("目录标题", reference: reference(opening)) == nil)
        #expect(ChapterTextComparison.fingerprint(" \n！？") == nil)
    }

    @Test func correctWordsAppendedAfterWrongTextCannotPassTheOpeningComparison() throws {
        let candidate = String(repeating: "王宫里的士兵跟随城主走进了偏殿。", count: 30) + opening
        let result = try #require(ChapterTextComparison.compare(candidate, reference: reference(opening)))
        #expect(result.similarity < 20)
        #expect(result.hasMoreContent)
    }

    @Test func reorderedParagraphsCannotReceiveAnExactMatch() throws {
        let text = ChapterTextComparison.normalize(opening)
        let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
        let reordered = String(text[midpoint...]) + String(text[..<midpoint])
        let result = try #require(ChapterTextComparison.compare(reordered, reference: reference(opening)))
        #expect(result.similarity < 80)
        #expect(ChapterTextComparison.fingerprint(reordered) != ChapterTextComparison.fingerprint(text))
    }

    @Test func redirectedNonOfficialPagesCannotBecomeOfficialReferences() async {
        var book = Book(bookUrl: "old", name: "书", author: "作者甲")
        book.durChapterTitle = "第2章 来信"
        let transport = RedirectingReferenceTransport()
        let service = PublicSourceChapterReferenceService(transport: transport)
        #expect(await service.reference(for: book) == nil)
        #expect(await transport.requests == 1)
    }

    @Test func lookalikeQidianHostIsNotAnOfficialReference() async {
        var book = Book(bookUrl: "https://www.qidian.com.example/book/1", name: "书", author: "作者甲")
        book.durChapterTitle = "第2章 来信"
        let chapter = BookChapter(url: "https://www.qidian.com.example/chapter/1/2", title: "第2章 来信", bookUrl: book.bookUrl, index: 0)
        let report = BookSourceSwitchReport(book: book, chapters: [chapter], exactChapterMatch: true)
        let transport = RedirectingReferenceTransport()
        let service = PublicSourceChapterReferenceService(transport: transport)
        #expect(await service.qidianReference(for: book, prepared: report) == nil)
        #expect(await transport.requests == 0)
    }

    private func qidianFixture(chapterURL: String) -> (Book, BookSourceSwitchReport) {
        var book = Book(bookUrl: "https://www.qidian.com/book/1/", name: "书", author: "作者甲")
        book.durChapterTitle = "第2章 来信"
        let chapter = BookChapter(url: chapterURL, title: "第2章 来信", bookUrl: book.bookUrl, index: 0)
        return (book, BookSourceSwitchReport(book: book, chapters: [chapter], exactChapterMatch: true))
    }

    @Test func ordinaryAnonymousQidianGetCanProvideAPublicReference() async throws {
        let (book, prepared) = qidianFixture(chapterURL: "https://www.qidian.com/chapter/1/2")
        let transport = PublicQidianFixtureTransport()
        let service = PublicSourceChapterReferenceService(transport: transport)
        let result = try #require(await service.qidianReference(for: book, prepared: prepared))
        #expect(result.provider == "起点")
        #expect(result.chapterTitle == "第2章 来信")
        #expect(result.characterCount >= ChapterTextComparison.minimumCharacters)
        #expect(await transport.methods == ["GET", "GET"])
    }

    @Test func importedPostOptionsCannotBecomeAPublicReferenceRequest() async {
        let (book, prepared) = qidianFixture(chapterURL: #"https://www.qidian.com/chapter/1/2,{"method":"POST","body":"fixture"}"#)
        let transport = PublicQidianFixtureTransport()
        let service = PublicSourceChapterReferenceService(transport: transport)
        #expect(await service.qidianReference(for: book, prepared: prepared) == nil)
        #expect(await transport.methods == ["GET"])
    }

    @Test func importedPrivateHeadersCannotBecomePublicReferenceRequests() async {
        for header in ["Cookie", "Authorization", "Proxy-Authorization"] {
            let options = #",{"headers":{""# + header + #"":"fixture"}}"#
            let (book, prepared) = qidianFixture(chapterURL: "https://www.qidian.com/chapter/1/2" + options)
            let transport = PublicQidianFixtureTransport()
            let service = PublicSourceChapterReferenceService(transport: transport)
            #expect(await service.qidianReference(for: book, prepared: prepared) == nil)
            #expect(await transport.methods == ["GET"])
        }
    }

    @Test func credentialedURLsCannotBecomePublicReferenceRequests() async {
        let (book, prepared) = qidianFixture(chapterURL: "https://fixture:fixture@www.qidian.com/chapter/1/2")
        let transport = PublicQidianFixtureTransport()
        let service = PublicSourceChapterReferenceService(transport: transport)
        #expect(await service.qidianReference(for: book, prepared: prepared) == nil)
        #expect(await transport.methods == ["GET"])
    }
}

private actor PublicQidianFixtureTransport: HTTPTransport {
    private(set) var methods: [String] = []

    func data(for request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        methods.append(request.httpMethod ?? "GET")
        let html: String
        if url.path.hasPrefix("/book/") {
            html = "<meta property='og:novel:book_name' content='书'><meta property='og:novel:author' content='作者甲'>"
        } else {
            html = "<h3 class='j_chapterName'>第2章 来信</h3><div class='read-content'><p>"
                + String(repeating: "雨夜中的灯塔照亮了远处的海湾。", count: 20) + "</p></div>"
        }
        return .init(data: Data(html.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

private actor RedirectingReferenceTransport: HTTPTransport {
    private(set) var requests = 0
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests += 1
        return .init(data: Data("{}".utf8), statusCode: 200, headers: [:], finalURL: URL(string: "https://unrelated.example/reference")!)
    }
}
