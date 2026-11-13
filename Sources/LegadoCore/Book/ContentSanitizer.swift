import Foundation
import SwiftSoup

public struct MetadataTextSanitizer: Sendable {
    public init() {}

    public func clean(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        do {
            value = replacingBlockTagsWithNewlines(value)
            let document = try SwiftSoup.parseBodyFragment(value)
            try document.select("script,style,noscript").remove()
            value = try document.body()?.text(trimAndNormaliseWhitespace: false) ?? document.text()
        } catch {
            value = value.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            value = (try? Parser.unescapeEntities(value, false)) ?? value
        }

        value = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
        let output = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let result = output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func replacingBlockTagsWithNewlines(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)<\s*br\s*/?\s*>|<\s*/?\s*(?:p|div|li|ul|ol|section|article|blockquote|h[1-6])\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
    }
}

/// A '>' inside a quoted attribute is data, not the end of the image tag.
/// Keep the original ranges so text processing never rewrites image URLs.
enum ChapterImageMarkup {
    private static let startExpression = try? NSRegularExpression(pattern: #"(?i)<(?:img|mip-img)(?=[\s/>])"#)

    static func ranges(in content: String) -> [Range<String.Index>] {
        let starts = startExpression?.matches(in: content, range: NSRange(content.startIndex..., in: content)) ?? []
        var ranges: [Range<String.Index>] = []
        for match in starts {
            guard let opening = Range(match.range, in: content),
                  ranges.last.map({ $0.upperBound <= opening.lowerBound }) ?? true else { continue }
            var index = opening.upperBound
            var quote: Character?
            var jsonDepth = 0
            var jsonString = false
            var escaped = false
            while index < content.endIndex {
                let char = content[index]
                if jsonDepth > 0 {
                    if escaped { escaped = false }
                    else if jsonString && char == "\\" { escaped = true }
                    else if char == "\"" { jsonString.toggle() }
                    else if !jsonString && char == "{" { jsonDepth += 1 }
                    else if !jsonString && char == "}" { jsonDepth -= 1 }
                } else if char == "{", quote != nil,
                          content[opening.upperBound..<index].last(where: { !$0.isWhitespace }) == "," {
                    // Older sources concatenate JSON directly inside a quoted
                    // src. Treat its quotes and > characters as JSON data.
                    jsonDepth = 1
                } else if let current = quote {
                    if char == current { quote = nil }
                } else if char == "\"" || char == "'" { quote = char }
                else if char == ">" {
                    ranges.append(opening.lowerBound..<content.index(after: index))
                    break
                }
                index = content.index(after: index)
            }
        }
        return ranges
    }

    static func mapText(in content: String, transform: (String, Bool) -> String) -> String {
        let ranges = ranges(in: content)
        guard !ranges.isEmpty else { return transform(content, true) }
        var parts: [String] = []
        var start = content.startIndex
        for range in ranges {
            let text = transform(String(content[start..<range.lowerBound]), start == content.startIndex)
            if !text.isEmpty { parts.append(text) }
            parts.append(String(content[range]))
            start = range.upperBound
        }
        let text = transform(String(content[start...]), start == content.startIndex)
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n")
    }
}

struct ChapterHTMLFormatter {
    func format(_ html: String, baseURL: URL) -> String {
        var protected = html
        var images: [String: String] = [:]
        let token = UUID().uuidString
        for (index, range) in ChapterImageMarkup.ranges(in: html).enumerated().reversed() {
            let src = ChapterImageParser().imageSource(in: String(html[range])) ?? ""
            let marker = "LEGADO_IMAGE_\(token)_\(index)"
            let url = LegadoURLBuilder.resolve(src, against: baseURL)
            images[marker] = src.isEmpty ? "" : ChapterImageParser.markup(for: url)
            protected.replaceSubrange(range, with: "\n\(marker)\n")
        }
        var result = MetadataTextSanitizer().clean(protected) ?? ""
        for (marker, image) in images { result = result.replacingOccurrences(of: marker, with: image) }
        return result
    }
}

public struct ContentProcessingReport: Sendable {
    public var title: String
    public var content: String
    public var effectiveRuleIDs: [Int64]
    public var removedDuplicateTitle: Bool
    public var diagnostics: [RuleDiagnostic]

    public init(
        title: String,
        content: String,
        effectiveRuleIDs: [Int64] = [],
        removedDuplicateTitle: Bool = false,
        diagnostics: [RuleDiagnostic] = []
    ) {
        self.title = title
        self.content = content
        self.effectiveRuleIDs = effectiveRuleIDs
        self.removedDuplicateTitle = removedDuplicateTitle
        self.diagnostics = diagnostics
    }
}

public struct ContentSanitizer: Sendable {
    private let regex: RegexEvaluator

    public init(regex: RegexEvaluator = .init()) {
        self.regex = regex
    }

    public func process(
        book: Book,
        chapter: BookChapter,
        content: String,
        rules: [ReplaceRule],
        removeDuplicateTitle: Bool = true,
        resegment: Bool = true
    ) -> ContentProcessingReport {
        let ordered = rules.filter(\.isEnabled).sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        var title = chapter.title
        var body = content
        var effective: [Int64] = []
        var diagnostics: [RuleDiagnostic] = []

        for rule in ordered where rule.scopeTitle && applies(rule, to: book) {
            let result = apply(rule, to: title, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != title, !result.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = result.value
                effective.append(rule.id)
            }
        }

        var removed = false
        if removeDuplicateTitle {
            let lines = body.components(separatedBy: .newlines)
            if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let normalizedLine = normalize(lines[firstIndex])
                let normalizedTitles = [chapter.title, title, book.name + chapter.title].map(normalize).filter { !$0.isEmpty }
                if normalizedTitles.contains(normalizedLine) {
                    var updated = lines
                    updated.remove(at: firstIndex)
                    body = updated.joined(separator: "\n")
                    removed = true
                }
            }
            if !removed, let end = duplicateTitlePrefixEnd(in: body, bookName: book.name, titles: [chapter.title, title]) {
                body = String(body[end...])
                removed = true
            }
        }

        if resegment {
            body = ChapterImageMarkup.mapText(in: body) { text, isFirstText in
                // Images are paragraph boundaries, not dialogue. Processing
                // only text also keeps the stable split seed free of random
                // protection tokens and preserves signed URLs byte-for-byte.
                let processed = book.readConfig?.reSegment == true
                    ? ChapterResegmenter().process(text, chapterName: isFirstText ? chapter.title : "") : text
                return processed.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "　"))) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
        }

        for rule in ordered where rule.scopeContent && applies(rule, to: book) {
            let result = apply(rule, to: body, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != body {
                body = result.value
                effective.append(rule.id)
            }
        }

        var seen = Set<Int64>()
        effective = effective.filter { seen.insert($0).inserted }
        return .init(
            title: title,
            content: body,
            effectiveRuleIDs: effective,
            removedDuplicateTitle: removed,
            diagnostics: diagnostics
        )
    }

    private func applies(_ rule: ReplaceRule, to book: Book) -> Bool {
        if let excluded = rule.excludeScope, !excluded.isEmpty,
           (!book.name.isEmpty && excluded.contains(book.name)) || (!book.origin.isEmpty && excluded.contains(book.origin)) { return false }
        guard let scope = rule.scope, !scope.isEmpty else { return true }
        return (!book.name.isEmpty && scope.contains(book.name)) || (!book.origin.isEmpty && scope.contains(book.origin))
    }

    private func apply(_ rule: ReplaceRule, to input: String, book: Book, chapter: BookChapter) -> (value: String, diagnostics: [RuleDiagnostic]) {
        guard !rule.pattern.isEmpty else { return (input, []) }
        do {
            if rule.isRegex {
                if rule.replacement.hasPrefix("@js:") {
                    let evaluate = JavaScriptRuleEvaluator().replacementEvaluator(
                        script: String(rule.replacement.dropFirst(4)), book: book, chapter: chapter)
                    return (try regex.replacingStrict(pattern: rule.pattern, in: input,
                        timeoutMilliseconds: rule.timeoutMillisecond, replacement: evaluate), [])
                }
                return (try regex.replacingStrict(pattern: rule.pattern, in: input, with: rule.replacement, timeoutMilliseconds: rule.timeoutMillisecond), [])
            }
            return (input.replacingOccurrences(of: rule.pattern, with: rule.replacement), [])
        } catch let error as RuleEngineError {
            return (input, [error.diagnostic])
        } catch {
            return (input, [.init(
                severity: .error,
                code: "replace.failed",
                message: "净化规则“\(rule.name)”执行失败：\(error.localizedDescription)",
                rule: rule.pattern
            )])
        }
    }

    private func normalize(_ value: String) -> String {
        value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(String.init).joined().lowercased()
    }

    private func duplicateTitlePrefixEnd(in content: String, bookName: String, titles: [String]) -> String.Index? {
        let bookPattern = bookName.isEmpty ? "" : "|" + NSRegularExpression.escapedPattern(for: bookName)
        for title in titles where !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let titlePattern = title.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s*"#)
            guard let expression = try? NSRegularExpression(pattern: "^(?:\\s|\\p{P}\(bookPattern))*\(titlePattern)\\s*"),
                  let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let range = Range(match.range, in: content) else { continue }
            return range.upperBound
        }
        return nil
    }
}
