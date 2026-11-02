import Foundation
import Testing
@testable import LegadoCore

struct RuleEditingCompatibilityTests {
    @Test func unknownFieldsSurviveImportFieldEditingAndRepositoryRoundTrip() async throws {
        let input = #"{"bookSourceUrl":"https://roundtrip.test","bookSourceName":"扩展源","futureOption":{"token":"keep"},"ruleSearch":"{\"bookList\":\"$.books\",\"name\":\"$.name\",\"bookUrl\":\"$.url\",\"futureRule\":{\"x\":true}}"}"#
        let original = try #require(BookSourceImporter().decode(Data(input.utf8)).first)
        var document = try BookSourceEditorDocument(source: original)
        document.set(.string("已编辑"), at: "bookSourceName")
        document.set(.string("$.title"), at: "ruleSearch.name")
        let edited = try document.source()
        let repository = InMemoryBookSourceRepository()
        try await repository.save([edited])
        let restored = try #require(await repository.load().first)
        let json = try JSONValue.decode(data: JSONEncoder().encode(restored))
        #expect(json["futureOption"]?["token"] == .string("keep"))
        #expect(json["ruleSearch"]?["futureRule"]?["x"] == .bool(true))
        #expect(restored.ruleSearch?.name == "$.title")
        #expect(restored.bookSourceName == "已编辑")
        #expect(json["additionalFields"] == nil)
    }

    @Test func clearingKnownRuleDoesNotRestoreOldValueFromPreservedFields() throws {
        let source = try JSONDecoder().decode(BookSource.self, from: Data(#"{"bookSourceUrl":"https://test","bookSourceName":"书源","ruleContent":{"content":"article@text","future":42}}"#.utf8))
        var document = try BookSourceEditorDocument(source: source)
        document.set(nil, at: "ruleContent.content")
        let json = try JSONValue.decode(data: JSONEncoder().encode(document.source()))
        #expect(json["ruleContent"]?["content"] == nil)
        #expect(json["ruleContent"]?["future"] == .number(42))
    }

    @Test func emptyRuleBlocksAndExplicitCookieNullRoundTrip() throws {
        let original = try JSONDecoder().decode(BookSource.self, from: Data(#"{"bookSourceUrl":"https://test","bookSourceName":"空规则","ruleExplore":{},"enabledCookieJar":null}"#.utf8))
        let restored = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(original))
        #expect(restored.ruleExplore != nil)
        #expect(restored.enabledCookieJar == nil)
        #expect(restored == original)
    }

    @Test func partialInspectionReportsMalformedEntriesAndKeepsValidSiblings() throws {
        let input = #"[{"bookSourceUrl":"https://good","bookSourceName":"有效"},{"bookSourceUrl":"https://bad","bookSourceName":"错误","ruleSearch":{"name":12}},17,{"bookSourceName":"缺少地址"}]"#
        let inspected = try BookSourceImporter().inspect(Data(input.utf8))
        #expect(inspected.sources.map(\.bookSourceName) == ["有效"])
        #expect(inspected.rejected.count == 3)
        #expect(throws: BookSourceImportError.self) { try BookSourceImporter().decode(Data(input.utf8)) }
    }

    @Test func editorRetainsRawInvalidJSONAndRejectsIncompleteSourceAtSave() throws {
        #expect(throws: (any Error).self) { try BookSourceEditorDocument(json: "{") }
        #expect(throws: BookSourceImportError.self) { try BookSourceEditorDocument(json: "[]") }
        let draft = try BookSourceEditorDocument(json: #"{"bookSourceName":"未完成"}"#)
        #expect(throws: BookSourceImportError.self) { try draft.source() }
    }

    @Test func importInputAcceptsQRJSONDeepLinksAndWithoutUA() throws {
        let deep = "legado://import/bookSource?src=https%3A%2F%2Fexample.test%2Fsources.json%23requestWithoutUA"
        let parsed = try RuleImportInput.parse(deep)
        #expect(parsed == .remote(URL(string: "https://example.test/sources.json")!, withoutUserAgent: true))
        #expect(parsed.request()?.value(forHTTPHeaderField: "User-Agent") == "null")
        #expect(try RuleImportInput.parse("[合集](https://example.test/source.json)") == .remote(URL(string: "https://example.test/source.json")!, withoutUserAgent: false))
        #expect(try RuleImportInput.parse(#"{"bookSourceName":"测试"}"#) == .json(#"{"bookSourceName":"测试"}"#))
        #expect(throws: BookSourceImportError.self) { try RuleImportInput.parse("legado://import/replaceRule?src=https://example.test/rules") }
        #expect(throws: BookSourceImportError.self) { try RuleImportInput.parse("file:///etc/passwd") }
        #expect(throws: BookSourceImportError.self) { try RuleImportInput.parse("https://") }
    }

    @Test func purificationTestMatchesReaderScopesAndCaptures() throws {
        var rule = ReplaceRule(id: 1, name: "替换", pattern: "第([0-9]+)章", replacement: "Chapter $1")
        rule.scopeTitle = true
        rule.scopeContent = true
        rule.scope = "示例书;https://test"
        let test = try ReplaceRuleTester().test(rule: rule, title: "第12章", content: "第34章 正文", bookName: "示例书", sourceURL: "https://test")
        #expect(test.report.title == "Chapter 12")
        #expect(test.report.content == "Chapter 34 正文")
        #expect(test.report.effectiveRuleIDs == [1])
        rule.excludeScope = "示例书"
        let excluded = try ReplaceRuleTester().test(rule: rule, title: "第12章", content: "第34章 正文", bookName: "示例书", sourceURL: "https://test")
        #expect(excluded.report.title == "第12章")
        #expect(excluded.report.effectiveRuleIDs.isEmpty)
    }

    @Test func purificationLiteralReplacementKeepsDollarSignsAndWhitespace() throws {
        var rule = ReplaceRule(id: 2, name: "字面", pattern: "[广告]", replacement: "$1")
        rule.isRegex = false
        let result = try ReplaceRuleTester().test(rule: rule, title: "标题", content: "  正文\n[广告]\n", bookName: "", sourceURL: "")
        #expect(result.report.content == "  正文\n$1\n")
    }

    @Test func invalidPurificationRegexReportsErrorInsteadOfLiteralFallback() throws {
        let rule = ReplaceRule(id: 3, name: "损坏", pattern: "[")
        #expect(throws: ReplaceRuleImportError.self) { try ReplaceRuleValidator.validate(rule) }
        let book = Book(bookUrl: "test", name: "书", origin: "test")
        let chapter = BookChapter(url: "chapter", title: "标题", bookUrl: "test", index: 0)
        let report = ContentSanitizer().process(book: book, chapter: chapter, content: "[原文", rules: [rule])
        #expect(report.content == "[原文")
        #expect(report.diagnostics.first?.code == "rule.malformed")
    }

    @Test func regexDeadlineInterruptsBacktrackingAndDoesNotReturnPartialReplacement() {
        let input = String(repeating: "a", count: 100) + "!"
        #expect(throws: RuleEngineError.self) {
            try RegexEvaluator().replacingStrict(pattern: "(a|aa)+$", in: input, with: "changed", timeoutMilliseconds: 1)
        }
    }

    @Test func purificationResourceLimitsPreserveInputAndReportDiagnostic() throws {
        let rule = ReplaceRule(id: 3, name: "嵌套", pattern: "(a+)+$", replacement: "changed")
        let result = try ReplaceRuleTester().test(rule: rule, title: "标题", content: "aaaa!", bookName: "书", sourceURL: "test")
        #expect(result.report.content == "aaaa!")
        #expect(result.report.diagnostics.first?.code == "rule.resource_limit")
        let regex = RegexEvaluator(limits: .init(maximumMatches: 2))
        #expect(throws: RuleEngineError.self) { try regex.replacingStrict(pattern: "a", in: "aaa", with: "b") }
        #expect(try regex.replacingStrict(pattern: "a", in: "aa", with: "b") == "bb")
    }
}
