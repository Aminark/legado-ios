import CryptoKit
import Foundation
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct SourceChapterReference: Codable, Sendable, Equatable {
    let provider: String
    let chapterTitle: String
    let url: String
    let content: String

    var characterCount: Int { ChapterTextComparison.normalize(content).count }
}

struct ChapterTextComparison: Equatable, Sendable {
    let similarity: Int
    let candidateCharacters: Int
    let referenceCharacters: Int
    var hasMoreContent: Bool { candidateCharacters > referenceCharacters }

    static let minimumCharacters = 120

    static func normalize(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return String(simplified.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func fingerprint(_ content: String) -> String? {
        let text = normalize(content)
        guard text.count >= minimumCharacters else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func compare(_ content: String, reference: SourceChapterReference) -> Self? {
        let wanted = Array(normalize(reference.content))
        let actual = Array(normalize(content))
        guard wanted.count >= minimumCharacters, actual.count >= minimumCharacters else { return nil }
        // The reference may be only a public preview. Compare its opening in
        // order, without treating additional, unseen text as verified.
        let opening = Array(actual.prefix(wanted.count + max(40, wanted.count / 6)))
        func grams(_ characters: [Character]) -> [String: Int] {
            var result: [String: Int] = [:]
            for index in 0...(characters.count - 6) {
                result[String(characters[index..<(index + 6)]), default: 0] += 1
            }
            return result
        }
        let wantedGrams = grams(wanted)
        let actualGrams = grams(opening)
        let shared = wantedGrams.reduce(0) { $0 + min($1.value, actualGrams[$1.key, default: 0]) }
        let coverage = Double(shared) / Double(wanted.count - 5)
        let openingText = String(opening)
        var position = openingText.startIndex
        var ordered = 0
        var anchors = 0
        for index in stride(from: 0, through: wanted.count - 8, by: 8) {
            anchors += 1
            let anchor = String(wanted[index..<(index + 8)])
            if let match = openingText.range(of: anchor, range: position..<openingText.endIndex) {
                ordered += 1
                position = match.upperBound
            }
        }
        let inOrder = Double(ordered) / Double(max(anchors, 1))
        return .init(similarity: Int((min(coverage, inOrder) * 100).rounded()),
                     candidateCharacters: actual.count, referenceCharacters: wanted.count)
    }
}

protocol SourceChapterReferencing: Sendable {
    func reference(for book: Book) async -> SourceChapterReference?
    func qidianReference(for book: Book, prepared: BookSourceSwitchReport) async -> SourceChapterReference?
}

extension SourceChapterReferencing {
    func qidianReference(for book: Book, prepared: BookSourceSwitchReport) async -> SourceChapterReference? { nil }
}

struct PublicSourceChapterReferenceService: SourceChapterReferencing {
    private let transport: any HTTPTransport

    init(transport: (any HTTPTransport)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        self.transport = OfficialReferenceTransport(underlying: transport ?? URLSessionHTTPTransport(configuration: configuration))
    }

    func reference(for book: Book) async -> SourceChapterReference? {
        guard !(book.durChapterTitle ?? "").isEmpty, !book.author.isEmpty else { return nil }
        let source = Self.qqSource
        let policy = SourceNetworkPolicy()
        let searcher = BookSearchService(transport: transport, networkPolicy: policy, history: BookSearchHistory())
        let network = NetworkBookService(transport: transport, networkPolicy: policy)
        let search = await searcher.search(keyword: book.name, page: 1, source: source)
        guard !Task.isCancelled, let candidate = search.books.first(where: {
            Self.sameBook(name: $0.name, author: $0.author, book: book)
                && URL(string: $0.bookURL)?.host == "book.qq.com"
        }) else { return nil }
        let detail = await network.loadDetail(searchBook: candidate, source: source)
        guard !Task.isCancelled, Self.sameBook(name: detail.book.name, author: detail.book.author, book: book) else { return nil }
        let directory = await network.loadChapters(book: detail.book, source: source, maxPages: 20)
        let mapping = BookSourceProgressMapper().migrate(current: book, replacement: detail.book,
                                                       chapters: directory.chapters, now: 0)
        guard !Task.isCancelled, mapping.exactChapterMatch,
              directory.chapters.indices.contains(mapping.book.durChapterIndex) else { return nil }
        let chapter = directory.chapters[mapping.book.durChapterIndex]
        guard let url = URL(string: chapter.url), url.scheme == "https", url.host == "book.qq.com",
              url.path.hasPrefix("/book-read/") else { return nil }
        let report = await network.loadContent(book: mapping.book, chapter: chapter, source: source,
                                              nextChapterURL: nil, maxPages: 1)
        return Self.reference(report: report, chapter: chapter, provider: "QQ 阅读", book: book)
    }

    func qidianReference(for book: Book, prepared: BookSourceSwitchReport) async -> SourceChapterReference? {
        guard prepared.exactChapterMatch, let url = URL(string: prepared.book.bookUrl),
              Self.isQidian(url), !book.author.isEmpty,
              prepared.chapters.indices.contains(prepared.book.durChapterIndex) else { return nil }
        let chapter = prepared.chapters[prepared.book.durChapterIndex]
        guard let chapterURL = URL(string: chapter.url), Self.isQidian(chapterURL) else { return nil }
        // Imported rules are not evidence of origin. Read the official pages
        // again with fixed public HTML selectors and no imported JS or cookies.
        var source = BookSource(bookSourceUrl: "https://www.qidian.com", bookSourceName: "起点")
        source.enabledCookieJar = false
        var info = BookInfoRule()
        info.name = "meta[property='og:novel:book_name']@content"
        info.author = "meta[property='og:novel:author']@content"
        source.ruleBookInfo = info
        var content = ContentRule()
        content.title = ".j_chapterName@text"
        content.content = ".read-content@p@text"
        source.ruleContent = content
        let network = NetworkBookService(transport: transport, networkPolicy: SourceNetworkPolicy())
        let candidate = SearchBook(bookURL: url.absoluteString, origin: source.id, originName: source.bookSourceName,
                                   type: 0, name: "", author: "")
        let detail = await network.loadDetail(searchBook: candidate, source: source)
        guard !Task.isCancelled, Self.sameBook(name: detail.book.name, author: detail.book.author, book: book) else { return nil }
        let report = await network.loadContent(book: detail.book, chapter: chapter, source: source,
                                              nextChapterURL: nil, maxPages: 1)
        return Self.reference(report: report, chapter: chapter, provider: "起点", book: book)
    }

    private static func isQidian(_ url: URL) -> Bool {
        url.scheme == "https" && ["www.qidian.com", "m.qidian.com", "read.qidian.com"].contains(url.host ?? "")
    }

    private static func sameBook(name: String, author: String, book: Book) -> Bool {
        func normalizedAuthor(_ value: String) -> String {
            ChapterTextComparison.normalize(value.replacingOccurrences(of: "作者", with: "").replacingOccurrences(of: "著", with: ""))
        }
        return ChapterTextComparison.normalize(name) == ChapterTextComparison.normalize(book.name)
            && normalizedAuthor(author) == normalizedAuthor(book.author)
    }

    private static func reference(report: ChapterContentReport, chapter: BookChapter,
                                  provider: String, book: Book) -> SourceChapterReference? {
        guard !Task.isCancelled, let title = report.title,
              ChapterTextComparison.normalize(report.content).count >= ChapterTextComparison.minimumCharacters,
              !report.diagnostics.contains(where: { $0.severity == .error }) else { return nil }
        let identity = BookChapter(url: chapter.url, title: title, bookUrl: chapter.bookUrl, index: 0)
        let mapping = BookSourceProgressMapper().migrate(current: book, replacement: book, chapters: [identity], now: 0)
        guard mapping.exactChapterMatch else { return nil }
        return .init(provider: provider, chapterTitle: title, url: chapter.url, content: report.content)
    }

    private static var qqSource: BookSource {
        var source = BookSource(bookSourceUrl: "https://book.qq.com", bookSourceName: "QQ 阅读")
        source.enabledCookieJar = false
        source.searchUrl = "https://book.qq.com/api/booksearch/query?keyWord={{key}}&pageNo={{page}}&pageSize=10"
        source.ruleSearch = .init(bookList: ".bookList[*]", name: ".title", author: ".author",
                                  bookUrl: "$.bid##(\\d+)##https://book.qq.com/book-detail/$1##")
        var info = BookInfoRule()
        info.name = "h1@text"
        info.author = "a.author@text"
        info.tocUrl = "text.目录@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "ul:nth-of-type(2)@li"
        toc.chapterName = "span.name@text"
        toc.chapterUrl = "a@href"
        source.ruleToc = toc
        var content = ContentRule()
        content.title = "h1@text"
        content.content = ".chapter-content@p@text"
        source.ruleContent = content
        return source
    }
}

private struct OfficialReferenceTransport: HTTPTransport {
    let underlying: any HTTPTransport

    func data(for request: URLRequest) async throws -> HTTPResponse {
        func isOfficial(_ url: URL?) -> Bool {
            guard let url, url.scheme == "https", url.user == nil, url.password == nil else { return false }
            return ["book.qq.com", "www.qidian.com", "m.qidian.com", "read.qidian.com"].contains(url.host ?? "")
        }
        // Chapter URLs may carry Legado request options. The independent
        // reference path accepts only anonymous, read-only public requests.
        let privateHeaders = ["authorization", "proxy-authorization", "cookie"]
        guard isOfficial(request.url), (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              !(request.allHTTPHeaderFields ?? [:]).keys.contains(where: { privateHeaders.contains($0.lowercased()) })
        else { throw URLError(.unsupportedURL) }
        let response = try await underlying.data(for: request)
        guard isOfficial(response.finalURL) else { throw URLError(.badServerResponse) }
        return response
    }
}
