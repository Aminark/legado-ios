import Foundation
import Testing
@testable import LegadoCore

struct RSSVariableStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rss-variables-" + UUID().uuidString, isDirectory: true)
    }

    @Test func persistsAcrossStoreInstancesAndSeparatesSourcesArticlesAndKeys() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        try store.put(origin: "source/a", link: "article/a", key: "../key", value: "正文😀")
        try store.put(origin: "source/a", link: "article/a", key: "empty", value: "")
        let reopened = RSSVariableStore(directory: directory)
        #expect(try reopened.get(origin: "source/a", link: "article/a", key: "../key") == "正文😀")
        #expect(try reopened.get(origin: "source/a", link: "article/a", key: "empty") == "")
        #expect(try reopened.get(origin: "other", link: "article/a", key: "../key") == nil)
        #expect(try reopened.get(origin: "source/a", link: "other", key: "../key") == nil)
        try store.put(origin: "source/a", link: "article/a", key: "../key", value: nil)
        #expect(try reopened.get(origin: "source/a", link: "article/a", key: "../key") == nil)
        try store.put(origin: "source/a", link: "article/a", key: "missing", value: nil)
    }

    @Test func automaticSpillUsesKotlinUTF16LengthAndReloadsWithoutInlinePayloads() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let evaluator = JavaScriptRuleEvaluator(rssVariableStore: store)
        let article = RssArticle(origin: "source", title: "article", link: "article")
        let result = try evaluator.evaluate(script: """
            java.put('small', 'x'.repeat(9999));
            java.put('large', 'x'.repeat(10000));
            rssArticle.putVariable('emoji', '😀'.repeat(5000));
            [rssArticle.variableMap.size(), rssArticle.getVariable('large').length,
             java.get('emoji').length, rssArticle.getBigVariable('small') === null].join('|')
            """, result: .null, executionContext: .init(rssArticle: article))
        #expect(result.value.stringValue == "1|10000|10000|true")
        #expect(result.variables.keys.sorted() == ["small"])
        let snapshot = try #require(result.rssArticle)
        let data = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: data, as: UTF8.self).contains("ruleVariableState"))
        let reloaded = try JSONDecoder().decode(RssArticle.self, from: data)
        let next = try JavaScriptRuleEvaluator(rssVariableStore: RSSVariableStore(directory: directory)).evaluate(
            script: "java.get('large').length + ':' + rssArticle.getBigVariable('emoji').length",
            result: .null, executionContext: .init(rssArticle: reloaded)
        )
        #expect(next.value.stringValue == "10000:10000")
    }

    @Test func failedBatchWritePreservesAllPreviouslyStoredKeys() throws {
        let directory = directory()
        let store = RSSVariableStore(directory: directory)
        try store.put(origin: "source", link: "article", key: "a", value: "old-a")
        try store.put(origin: "source", link: "article", key: "b", value: "old-b")
        let sourceDirectory = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sourceDirectory.path)
        #expect(throws: (any Error).self) {
            try store.apply(origin: "source", link: "article", changes: ["a": .value("new-a"), "b": .value("new-b")])
        }
        #expect(try store.get(origin: "source", link: "article", key: "a") == "old-a")
        #expect(try store.get(origin: "source", link: "article", key: "b") == "old-b")
    }

    @Test func inlineValuesWinAndShortReplacementOrNullClearsOldLargeValue() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let evaluator = JavaScriptRuleEvaluator(rssVariableStore: store)
        var article = RssArticle(origin: "source", link: "article")
        article.variable = #"{"key":"inline"}"#
        let first = try evaluator.evaluate(script: """
            rssArticle.putBigVariable('key', 'big');
            var precedence = java.get('key') + ':' + rssArticle.getBigVariable('key');
            rssArticle.variableMap.remove('key');
            var fallback = java.get('key');
            rssArticle.variableMap.put('key', 'inline-again');
            rssArticle.putBigVariable('empty', '');
            precedence + ':' + fallback + ':' + (rssArticle.getBigVariable('empty') === '')
            """, result: .null, executionContext: .init(rssArticle: article))
        #expect(first.value.stringValue == "inline:big:big:true")
        let second = try evaluator.evaluate(script: """
            java.put('key', 'short');
            rssArticle.putVariable('empty', null);
            java.get('key') + ':' + (rssArticle.getBigVariable('key') === null) + ':' + (rssArticle.getBigVariable('empty') === null)
            """, result: .null, executionContext: .init(rssArticle: first.rssArticle))
        #expect(second.value.stringValue == "short:true:true")
        #expect(try store.get(origin: "source", link: "article", key: "key") == nil)
        #expect(try store.get(origin: "source", link: "article", key: "empty") == nil)
    }

    @Test func failedScriptDoesNotCommitItsPendingLargeValues() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        #expect(throws: (any Error).self) {
            try JavaScriptRuleEvaluator(rssVariableStore: store).evaluate(
                script: "rssArticle.putBigVariable('key', 'partial'); throw new Error('failed')",
                result: .null, executionContext: .init(rssArticle: .init(origin: "source", link: "article"))
            )
        }
        #expect(try store.get(origin: "source", link: "article", key: "key") == nil)
    }

    @Test func successfulRuleWritesRemainWhenALaterRuleFails() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let evaluator = JavaScriptRuleEvaluator(rssVariableStore: store)
        let first = try evaluator.evaluate(script: "rssArticle.putBigVariable('key', 'committed')", result: .null,
            executionContext: .init(rssArticle: .init(origin: "source", link: "article")))
        #expect(throws: (any Error).self) {
            try evaluator.evaluate(script: "rssArticle.putBigVariable('key', 'uncommitted'); throw new Error('later failure')",
                result: .null, executionContext: .init(rssArticle: first.rssArticle))
        }
        #expect(try store.get(origin: "source", link: "article", key: "key") == "committed")
    }

    @Test func articleIdentityChangesKeepLargeVariablesBoundToTheOpenedArticle() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let source = RssSource(sourceUrl: "https://identity.test", sourceName: "identity")
        let article = RssArticle(origin: source.sourceUrl, title: "original", link:
            "@js:rssArticle.link = '/changed'; rssArticle.origin = 'changed-origin'; java.put('payload', 'x'.repeat(10000)); '/request'")
        let result = try await RSSService(
            transport: RSSVariableTestTransport(), urlBuilder: .init(rssVariableStore: store),
            engine: .init(javaScript: .init(rssVariableStore: store)), networkPolicy: .init()
        ).contentDetailed(article: article, rule: "@js:java.get('payload').length", source: source)
        #expect(result.content == "10000")
        #expect(result.article.link == "/changed")
        #expect(try store.get(origin: article.origin, link: article.link, key: "payload")?.count == 10000)
        #expect(try store.get(origin: "changed-origin", link: "/changed", key: "payload") == nil)
    }

    @Test func storageIOFailureProducesRuleDiagnostic() async throws {
        let directory = directory()
        try Data("file cannot be a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RuleEngine(javaScript: .init(rssVariableStore: .init(directory: directory)))
        let result = await engine.evaluate("@js:rssArticle.putBigVariable('key', 'value'); 'success'", in: .null,
            context: .init(rssArticle: .init(origin: "source", link: "article")))
        #expect(result.diagnostics.contains { $0.severity == .error })
        #expect(result.joinedString != "success")
    }

    @Test func listParsingStagesLargeValuesUntilEachFinalArticleURLIsKnown() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        var source = RssSource(sourceUrl: "https://list-big.test", sourceName: "source")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleDescription = "@js:java.put('payload', rssArticle.title.repeat(10000)); 'summary'"
        source.ruleLink = "@js:'/' + rssArticle.title"
        let report = try await RSSRuleParser(engine: .init(javaScript: .init(rssVariableStore: store))).parse(
            sortName: "news", sortURL: source.sourceUrl, redirectURL: source.sourceUrl,
            body: #"{"items":[{"title":"a"},{"title":"b"}]}"#, source: source
        )
        #expect(report.diagnostics.isEmpty)
        #expect(report.result.articles.count == 2)
        for article in report.result.articles {
            #expect(article.variableMap["payload"] == nil)
            #expect(try store.get(origin: article.origin, link: article.link, key: "payload") == String(repeating: article.title, count: 10000))
        }
        #expect(try store.get(origin: "", link: "", key: "payload") == nil)
    }

    @Test func putRulesSpillAndLaterJavaScriptReadsTheStoredValue() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RuleEngine(javaScript: .init(rssVariableStore: .init(directory: directory)))
        let result = await engine.evaluate("@put:{payload:$.payload}@js:java.get('payload').length", in: .object([
            "payload": .string(String(repeating: "x", count: 10000))
        ]), context: .init(rssArticle: .init(origin: "source", link: "article")))
        #expect(result.diagnostics.isEmpty)
        #expect(result.joinedString == "10000")
        #expect(result.variables["payload"] == nil)
        let get = await engine.evaluate("@js:JSON.stringify('@get:{payload}'.length)", in: .null,
            context: .init(rssArticle: result.rssArticle))
        #expect(get.diagnostics.isEmpty)
        #expect(get.joinedString == "10000")
    }
}

private struct RSSVariableTestTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        .init(data: Data("body".utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
}
