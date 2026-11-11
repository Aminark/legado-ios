import Foundation
import SwiftSoup

public struct ChapterContentBlock: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case image(String)
    }

    public var id: Int { range.location }
    public let range: NSRange
    public let content: Content
}

/// Keeps image request options intact, including older sources that embed
/// unescaped JSON quotes inside an img src attribute.
public struct ChapterImageParser: Sendable {
    public init() {}

    public func blocks(in content: String, baseURL: URL?, allowBareURLs: Bool = false) -> [ChapterContentBlock] {
        var blocks: [ChapterContentBlock] = []
        var cursor = content.startIndex
        for range in ChapterImageMarkup.ranges(in: content) {
            appendText(content[cursor..<range.lowerBound], in: content, baseURL: baseURL,
                       allowBareURLs: allowBareURLs, to: &blocks)
            if let source = imageSource(in: String(content[range])), let address = resolve(source, baseURL: baseURL) {
                blocks.append(.init(range: NSRange(range, in: content), content: .image(address)))
            }
            cursor = range.upperBound
        }
        appendText(content[cursor...], in: content, baseURL: baseURL, allowBareURLs: allowBareURLs, to: &blocks)
        return blocks
    }

    public func normalize(_ content: String, baseURL: URL, allowBareURLs: Bool) -> String {
        let blocks = blocks(in: content, baseURL: baseURL, allowBareURLs: allowBareURLs)
        guard blocks.contains(where: { if case .image = $0.content { return true }; return false }) else { return content }
        var result = content as NSString
        for block in blocks.reversed() {
            if case .image(let address) = block.content {
                result = result.replacingCharacters(in: block.range, with: Self.markup(for: address)) as NSString
            }
        }
        return result as String
    }

    func imageSource(in rawMarkup: String) -> String? {
        let markup = rawMarkup.replacingOccurrences(of: "=\\\"", with: "=\"")
            .replacingOccurrences(of: "\\\">", with: "\">")
        for name in ["data-src", "data-original", "data-echo", "data-url", "src", "data-srcset", "srcset"] {
            let pattern = #"(?is)(?:\s)"# + name + #"\s*=\s*(["'])(.*?)\1(?=\s+[\w:-]+(?:\s*=|\s|/?>)|\s*/?>)"#
            var value: String?
            if let expression = try? NSRegularExpression(pattern: pattern),
               let match = expression.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup)),
               let range = Range(match.range(at: 2), in: markup) {
                value = try? Parser.unescapeEntities(String(markup[range]), false)
            } else if let element = try? SwiftSoup.parseBodyFragment(markup).select("img,mip-img").first() {
                value = try? element.attr(name)
            }
            if var value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if name.hasSuffix("srcset") {
                    value = String(value.split(separator: ",").first?.split(whereSeparator: { $0.isWhitespace }).first ?? "")
                }
                return value
            }
        }
        return nil
    }

    static func markup(for address: String) -> String {
        "<img src=\"" + address.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") + "\">"
    }

    private func resolve(_ value: String, baseURL: URL?) -> String? {
        let address = baseURL.map { LegadoURLBuilder.resolve(value, against: $0) } ?? value
        // Request options are interpreted by LegadoURLBuilder when loading.
        let scheme = address.prefix(while: { $0 != ":" }).lowercased()
        guard ["http", "https", "data"].contains(scheme) else { return nil }
        if scheme == "data", !address.lowercased().hasPrefix("data:image/") { return nil }
        return address
    }

    private func appendText(_ substring: Substring, in content: String, baseURL: URL?, allowBareURLs: Bool,
                            to blocks: inout [ChapterContentBlock]) {
        var start = substring.startIndex
        while start < substring.endIndex {
            let end = substring[start...].firstIndex(of: "\n") ?? substring.endIndex
            let line = String(substring[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let range = NSRange(start..<end, in: content)
                // Only complete URL lines become images. Prose containing a
                // web address remains prose, even in a mixed image chapter.
                let urlPart = line.range(of: #",\s*(?=\{)"#, options: .regularExpression).map { String(line[..<$0.lowerBound]) } ?? line
                let imageExtension = URL(string: urlPart)?.pathExtension.lowercased()
                let looksLikeImage = imageExtension.map { ["png", "jpg", "jpeg", "webp", "gif", "avif", "bmp"].contains($0) } ?? false
                if !urlPart.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }), (allowBareURLs || looksLikeImage),
                   let address = resolve(line, baseURL: baseURL),
                   line.hasPrefix("http://") || line.hasPrefix("https://") || line.hasPrefix("//")
                    || line.hasPrefix("/") || line.hasPrefix("data:image/") || looksLikeImage
                    || (allowBareURLs && urlPart.contains("/")) {
                    blocks.append(.init(range: range, content: .image(address)))
                } else if let text = MetadataTextSanitizer().clean(line) {
                    blocks.append(.init(range: range, content: .text(text)))
                }
            }
            start = end < substring.endIndex ? substring.index(after: end) : end
        }
    }
}

public enum ChapterImageError: Error, LocalizedError {
    case unsupportedURL, unsupportedDecode, emptyImage
    public var errorDescription: String? {
        switch self {
        case .unsupportedURL: "图片地址不受支持"
        case .unsupportedDecode: "此书源的图片解码脚本暂不支持"
        case .emptyImage: "图片内容为空"
        }
    }
}

public struct ChapterImageLoader: Sendable {
    private let transport: any HTTPTransport
    private let policy: SourceNetworkPolicy

    public init(transport: any HTTPTransport = URLSessionHTTPTransport.shared, policy: SourceNetworkPolicy = .shared) {
        self.transport = transport
        self.policy = policy
    }

    public func load(_ address: String, source: BookSource, book: Book, chapter: BookChapter) async throws -> Data {
        if let decode = source.ruleContent?.imageDecode, !decode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChapterImageError.unsupportedDecode
        }
        var request = try await RuleExecutionWorker.run {
            let headers = try BookSourceHeaderResolver().resolve(source)
            var variables = (book.variable.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }) ?? [:]
            variables.merge((chapter.variable.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }) ?? [:]) { _, value in value }
            var request = try LegadoURLBuilder().prepare(address,
                context: .init(variables: variables, source: source, book: book, chapter: chapter),
                baseURL: URL(string: chapter.baseUrl.isEmpty ? chapter.url : chapter.baseUrl), defaultHeaders: headers)
            // Rule-engine binary responses are normally converted to hex text.
            // The native image decoder needs the original response bytes.
            request.responseType = nil
            request.bodyJavaScript = nil
            return request
        }
        guard ["http", "https", "data"].contains(request.url.scheme?.lowercased() ?? "") else {
            throw ChapterImageError.unsupportedURL
        }
        // The source or per-image options can override the chapter Referer.
        if request.headers.keys.allSatisfy({ $0.caseInsensitiveCompare("Referer") != .orderedSame }),
           let chapterURL = URL(string: chapter.url), ["http", "https"].contains(chapterURL.scheme?.lowercased() ?? "") {
            request.headers["Referer"] = chapterURL.absoluteString
        }
        let response = try await policy.execute(request, source: source, transport: transport, timeout: 30)
        guard !response.data.isEmpty else { throw ChapterImageError.emptyImage }
        return response.data
    }
}
