import Foundation
import Kanna
import SwiftSoup

public struct HTMLRuleEvaluator: Sendable {
    private enum IndexItem {
        case index(Int)
        case range(Int?, Int?, Int)
    }

    private struct IndexedSelector {
        var selector: String
        var excludes: Bool
        var items: [IndexItem]
    }

    public init() {}

    public func selectCSSFragments(_ rule: String, html: String, baseURL: String = "", isFragment: Bool = false) throws -> [String] {
        do {
            let root = try parseRoot(html, baseURL: baseURL, isFragment: isFragment)
            let stages = splitChain(rule).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return try selectElements(stages: stages, from: root).map { try $0.outerHtml() }
        } catch {
            throw RuleEngineError.malformedRule(rule: rule, detail: cssFailureDetail(error))
        }
    }

    public func extractCSS(_ rule: String, html: String, baseURL: String = "", isFragment: Bool = false) throws -> [String] {
        do {
            let parsed = try parseCSSExtraction(rule)
            let root = try parseRoot(html, baseURL: baseURL, isFragment: isFragment)
            let elements = try selectElements(stages: parsed.selectors, from: root)
            if parsed.output == "html" {
                for element in elements {
                    try element.select("script").remove()
                    try element.select("style").remove()
                }
                let value = try elements.map { try $0.outerHtml() }.joined(separator: "\n")
                return value.isEmpty ? [] : [value]
            }
            if parsed.output == "all" {
                let value = try elements.map { try $0.outerHtml() }.joined(separator: "\n")
                return value.isEmpty ? [] : [value]
            }
            var seenAttributes: Set<String> = []
            return try elements.compactMap { element in
                let value: String
                switch parsed.output {
                case "text": value = try element.text()
                case "ownText": value = element.ownText()
                case "textNodes":
                    value = element.textNodes().map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                default:
                    value = try element.attr(parsed.output)
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          seenAttributes.insert(value).inserted else { return nil }
                }
                return value.isEmpty ? nil : value
            }
        } catch let error as RuleEngineError {
            throw error
        } catch {
            throw RuleEngineError.malformedRule(rule: rule, detail: cssFailureDetail(error))
        }
    }

    public func selectXPathFragments(_ rule: String, html: String, isFragment: Bool = false) throws -> [String] {
        try xpathResult(rule, html: html, isFragment: isFragment).compactMap(\.toHTML)
    }

    public func extractXPath(_ rule: String, html: String, isFragment: Bool = false) throws -> [String] {
        let result = try xpathResult(rule, html: html, isFragment: isFragment)
        switch result {
        case .none:
            return []
        case .NodeSet:
            return result.compactMap { node in
                let value = node.text ?? node.content ?? ""
                return value.isEmpty ? nil : value
            }
        case .Bool(let value):
            return [String(value)]
        case .Number(let value):
            return [value.rounded() == value ? String(format: "%.0f", value) : String(value)]
        case .String(let value):
            return value.isEmpty ? [] : [value]
        }
    }

    private func xpathResult(_ rule: String, html: String, isFragment: Bool) throws -> XPathObject {
        let document = try parseKanna(html, rule: rule)
        if isFragment, let element = document.at_xpath("/html/body/*[1]") {
            return element.xpath(rule)
        }
        return document.xpath(rule)
    }

    private func parseKanna(_ html: String, rule: String) throws -> any HTMLDocument {
        do {
            return try Kanna.HTML(html: html, encoding: .utf8)
        } catch {
            throw RuleEngineError.malformedRule(rule: rule, detail: "HTML 解析失败：\(error.localizedDescription)")
        }
    }

    private func parseCSSExtraction(_ rule: String) throws -> (selectors: [String], output: String) {
        let components = splitChain(rule)
        guard components.count > 1 else {
            let selector = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else {
                throw RuleEngineError.malformedRule(rule: rule, detail: "CSS selector 不能为空")
            }
            if selector.range(of: #"^[\w:-]+$"#, options: .regularExpression) != nil {
                return ([], selector)
            }
            return ([selector], "text")
        }
        var selectors = components.dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let output = components.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while selectors.first?.isEmpty == true { selectors.removeFirst() }
        guard selectors.allSatisfy({ !$0.isEmpty }), !output.isEmpty else {
            throw RuleEngineError.malformedRule(rule: rule, detail: "CSS 取值规则必须是 selector@text 或 selector@attribute")
        }
        return (selectors, output)
    }

    private func cssFailureDetail(_ error: Error) -> String {
        if case SwiftSoup.Exception.Error(_, let message) = error {
            return "CSS 规则执行失败：\(message)"
        }
        return "CSS 规则执行失败：\(error.localizedDescription)"
    }

    private func splitChain(_ rule: String) -> [String] {
        var parts: [String] = []
        var quote: Character?
        var escaped = false
        var squareDepth = 0
        var roundDepth = 0
        var start = rule.startIndex
        for index in rule.indices {
            let character = rule[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "[" { squareDepth += 1 }
            if character == "]" { squareDepth -= 1 }
            if character == "(" { roundDepth += 1 }
            if character == ")" { roundDepth -= 1 }
            if character == "@", squareDepth == 0, roundDepth == 0 {
                parts.append(String(rule[start..<index]))
                start = rule.index(after: index)
            }
        }
        parts.append(String(rule[start...]))
        return parts
    }

    private func parseRoot(_ html: String, baseURL: String, isFragment: Bool) throws -> Element {
        guard isFragment else { return try SwiftSoup.parse(html, baseURL) }
        if html.range(of: #"^\s*(?:<!doctype\b|<html\b)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return try SwiftSoup.parse(html, baseURL)
        }
        // Reconstruct the selected element, not a new document. In particular,
        // parsing a standalone tr/td as a document discards its table structure.
        let tag = html.range(of: #"^\s*<([A-Za-z][A-Za-z0-9:-]*)"#, options: .regularExpression)
            .map { String(html[$0]).trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().lowercased() } ?? ""
        let parent: String
        switch tag {
        case "tr": parent = "tbody"
        case "td", "th": parent = "tr"
        case "tbody", "thead", "tfoot", "caption", "colgroup": parent = "table"
        case "col": parent = "colgroup"
        case "option", "optgroup": parent = "select"
        default: parent = "body"
        }
        let container = try Element(Tag.valueOf(parent), baseURL)
        let nodes = try Parser.parseFragment(html, container, Array(baseURL.utf8))
        let elements = nodes.compactMap { $0 as? Element }
        if elements.count == 1, let element = elements.first { return element }
        return try SwiftSoup.parseBodyFragment(html, baseURL)
    }

    private func selectElements(stages: [String], from document: Element) throws -> [Element] {
        var current: [Element] = [document]
        for stage in stages {
            var selected: [Element] = []
            let parsed = parseIndexedSelector(stage)
            for parent in current {
                let candidates: [Element]
                switch parsed.selector {
                case "", "children": candidates = parent.children().array()
                default: candidates = try parent.select(cssSelector(parsed.selector)).array()
                }
                selected += applyIndex(parsed, to: candidates)
            }
            current = selected
        }
        return current
    }

    private func cssSelector(_ legacy: String) -> String {
        if legacy.hasPrefix("class.") {
            return compoundClassSelector(legacy.dropFirst(6))
        }
        if legacy.hasPrefix("tag.") { return String(legacy.dropFirst(4)) }
        if legacy.hasPrefix("id.") { return "#" + legacy.dropFirst(3) }
        if legacy.hasPrefix("text.") {
            let value = String(legacy.dropFirst(5)).replacingOccurrences(of: "\"", with: "\\\"")
            return ":containsOwn(\(value))"
        }
        return legacy
    }

    /// Legado's `class.a b` mirrors Jsoup's `getElementsByClass`, matching a single
    /// element carrying every listed class name rather than a CSS descendant chain.
    private func compoundClassSelector(_ raw: Substring) -> String {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "." + raw }
        return tokens.map { "." + $0 }.joined()
    }

    private func parseIndexedSelector(_ source: String) -> IndexedSelector {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("]"), let open = value.lastIndex(of: "[") {
            var content = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(charactersIn: "!-0123456789:, ")
            if !content.isEmpty, content.unicodeScalars.allSatisfy(allowed.contains) {
                let excludes = content.hasPrefix("!")
                if excludes { content.removeFirst() }
                let items = content.split(separator: ",", omittingEmptySubsequences: false).compactMap(parseIndexItem)
                if !items.isEmpty {
                    return .init(
                        selector: String(value[..<open]).trimmingCharacters(in: .whitespacesAndNewlines),
                        excludes: excludes,
                        items: items
                    )
                }
            }
        }

        for delimiter in ["!", "."] {
            guard let marker = value.lastIndex(of: Character(delimiter)) else { continue }
            let suffix = String(value[value.index(after: marker)...])
            let values = suffix.split(separator: ":", omittingEmptySubsequences: false).compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            if !suffix.isEmpty, values.count == suffix.split(separator: ":", omittingEmptySubsequences: false).count {
                return .init(
                    selector: String(value[..<marker]),
                    excludes: delimiter == "!",
                    items: values.map(IndexItem.index)
                )
            }
        }
        return .init(selector: value, excludes: false, items: [])
    }

    private func parseIndexItem(_ source: Substring) -> IndexItem? {
        let values = source.split(separator: ":", omittingEmptySubsequences: false)
        if values.count == 1, let index = Int(values[0].trimmingCharacters(in: .whitespaces)) {
            return .index(index)
        }
        guard (2...3).contains(values.count) else { return nil }
        let start = values[0].isEmpty ? nil : Int(values[0].trimmingCharacters(in: .whitespaces))
        let end = values[1].isEmpty ? nil : Int(values[1].trimmingCharacters(in: .whitespaces))
        let step = values.count == 3 ? Int(values[2].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
        return step == 0 ? nil : .range(start, end, step)
    }

    private func applyIndex(_ selector: IndexedSelector, to elements: [Element]) -> [Element] {
        guard !selector.items.isEmpty, !elements.isEmpty else { return elements }
        var indexes: [Int] = []
        func append(_ index: Int) {
            let resolved = index < 0 ? elements.count + index : index
            if elements.indices.contains(resolved), !indexes.contains(resolved) { indexes.append(resolved) }
        }
        for item in selector.items {
            switch item {
            case .index(let index): append(index)
            case .range(let rawStart, let rawEnd, let rawStep):
                var start = rawStart ?? 0
                var end = rawEnd ?? (elements.count - 1)
                if start < 0 { start += elements.count }
                if end < 0 { end += elements.count }
                if (start < 0 && end < 0) || (start >= elements.count && end >= elements.count) {
                    continue
                }
                start = min(max(start, 0), elements.count - 1)
                end = min(max(end, 0), elements.count - 1)
                let direction = end >= start ? 1 : -1
                let normalizedStep: Int
                if rawStep > 0 {
                    normalizedStep = rawStep
                } else if -rawStep < elements.count {
                    normalizedStep = rawStep + elements.count
                } else {
                    normalizedStep = 1
                }
                let step = max(normalizedStep, 1) * direction
                var cursor = start
                while direction > 0 ? cursor <= end : cursor >= end {
                    append(cursor)
                    cursor += step
                }
            }
        }
        if selector.excludes {
            let excluded = Set(indexes)
            return elements.enumerated().compactMap { excluded.contains($0.offset) ? nil : $0.element }
        }
        return indexes.map { elements[$0] }
    }
}
