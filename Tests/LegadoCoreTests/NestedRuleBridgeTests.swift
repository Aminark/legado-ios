import Foundation
import Testing
@testable import LegadoCore

struct NestedRuleBridgeTests {
    @Test func exceptionsWhoseStringConversionThrowsAreReportedWithoutHandlerRecursion() async throws {
        let script = "throw {toString: function () { throw new Error('string conversion failed'); }}"
        #expect(throws: (any Error).self) {
            try JavaScriptRuleEvaluator().evaluate(script: script, result: .null, executionContext: .init())
        }
        let titles = try await JavaScriptRuleEvaluator().formatChapterTitles(script: script, chapters: [
            .init(url: "/one", title: "original", bookUrl: "book", index: 0)
        ])
        #expect(titles.chapters.first?.title == "original")
        #expect(titles.diagnostics.count == 1)
    }

    @Test func nestedStringsShareCurrentVariablesInlinePutGetAndArticleMutations() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            java.put('token', 'current');
            var before = java.getString('@js:java.get("token")');
            var stored = java.getString('@put:{copied:$.value}@get:{copied}', {value:'from-put'});
            var nested = java.getString('@js:java.put("child", "saved"); rssArticle.title = "changed"; "done"');
            [before, stored, nested, java.get('copied'), java.get('child'), rssArticle.title].join('|')
            """, result: .string("input"), executionContext: .init(variables: ["token": "old"], rssArticle: .init(title: "initial")))
        #expect(result.value.stringValue == "current|from-put|done|from-put|saved|changed")
        #expect(result.rssArticle?.title == "changed")
        #expect(result.variables["child"] == "saved")
    }

    @Test func stringListResolvesAndDeduplicatesURLsAndKeepsJavaListAccessors() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            var urls = java.getStringList('$.items', {items:['/one', '/one', '/two']}, true);
            var lines = java.getStringList('@js:"first\\\\nsecond"');
            [urls.size(), urls.get(1), lines.length, lines[0], lines[1], java.getStringList('') === null].join('|')
            """, result: .null, executionContext: .init(baseURL: "https://nested-rule.test/base/"))
        #expect(result.value.stringValue == "2|https://nested-rule.test/two|2|first|second|true")
    }

    @Test func stringListReplacesEachExtractedValueWithoutTurningTextIntoHTMLFragments() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            var html = java.getStringList('@CSS:p@text##^##X', '<p>a</p><p>b</p>');
            var json = java.getStringList('$.items[*]##^##Y', {items:['a','b']});
            html.join(',') + '|' + json.join(',')
            """, result: .null, executionContext: .init())
        #expect(result.value.stringValue == "Xa,Xb|Ya,Yb")
    }

    @Test func getStringBooleanOverloadControlsEntityUnescapingAndNullUsesOriginalContent() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            [java.getString('text', false), java.getString('text', true), java.getString('text'),
             java.getString('link', null, true), java.getString('blank', null, true)].join('|')
            """, result: .object(["text": .string("a&amp;b&#33;"), "link": .string("/article"), "blank": .string("")]),
            executionContext: .init(baseURL: "https://nested-rule.test/base/"))
        #expect(result.value.stringValue == "a&amp;b&#33;|a&b!|a&b!|https://nested-rule.test/article|https://nested-rule.test/base/")
    }

    @Test func elementsPreserveJSONObjectsRegexCapturesAndRealHTMLFragments() throws {
        let html = #"<ul><li data-id="1"><a href="/one">One</a></li><li data-id="2"><a href="/two">Two</a></li></ul>"#
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            var rows = java.getElements('@CSS:li');
            var second = rows.get(1);
            var first = java.getElement('@CSS:li').get(0);
            var json = java.getElements('$.items', {items:[{name:'JSON'}]});
            var object = java.getElement('$.book', {book:{title:'object'}});
            var captures = java.getElements(':(a)(b)', 'ab');
            [rows.size(), second.text(), second.attr('data-id'), second.select('a').get(0).attr('href'),
             java.getString('a@text', first), json[0].name, object.title, captures[0].join(',')].join('|')
            """, result: .string(html), executionContext: .init(baseURL: "https://nested-rule.test"))
        #expect(result.value.stringValue == "2|Two|2|/two|One|JSON|object|ab,a,b")
    }

    @Test func everyNestedEntryReturnsVariableAndArticleUpdates() throws {
        for method in ["getString", "getStringList", "getElement", "getElements"] {
            let result = try JavaScriptRuleEvaluator().evaluate(script: """
                java.\(method)('@js:java.put("child", "saved"); rssArticle.title = "changed"; ["value"]');
                java.get('child') + ':' + rssArticle.title
                """, result: .string("body"), executionContext: .init(rssArticle: .init(title: "initial")))
            #expect(result.value.stringValue == "saved:changed")
            #expect(result.rssArticle?.title == "changed")
        }
    }

    @Test func caughtNestedFailureKeepsOuterVariablesArticleAndLargeVariableStorageUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nested-rollback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let result = try JavaScriptRuleEvaluator(rssVariableStore: store).evaluate(script: """
            java.put('outer', 'keep');
            var caught = false;
            try {
              java.getString('@put:{temp:$.value}<js>java.put("child", "lost"); rssArticle.title="partial"; rssArticle.putBigVariable("pending", "lost"); result</js><js>throw new Error("nested fail")</js>', {value:'temporary'});
            } catch (error) { caught = String(error).indexOf('nested fail') >= 0; }
            [caught, java.get('outer'), java.get('temp'), java.get('child'), rssArticle.title,
             rssArticle.getBigVariable('pending') === null].join('|')
            """, result: .null, executionContext: .init(rssArticle: .init(origin: "source", title: "original", link: "article")))
        #expect(result.value.stringValue == "true|keep|||original|true")
        #expect(result.variables == ["outer": "keep"])
        #expect(try store.get(origin: "source", link: "article", key: "pending") == nil)
    }

    @Test func concurrentRecursiveNestedRulesCompleteWithoutWaitingOnOtherWorkers() async throws {
        var source = BookSource(bookSourceUrl: "https://nested-rule.test", bookSourceName: "nested")
        source.jsLib = "function nested(n) { return n <= 0 ? java.get('token') : java.getString('@js:nested(' + (n - 1) + ')'); }"
        let context = RuleExecutionContext(variables: ["token": "done"], source: source)
        await withTaskGroup(of: RuleEvaluation.self) { group in
            for _ in 0..<24 {
                group.addTask { await RuleEngine().evaluate("@js:nested(6)", in: .null, context: context) }
            }
            for await result in group {
                #expect(result.diagnostics.isEmpty)
                #expect(result.joinedString == "done")
            }
        }
        let tooDeep = await RuleEngine().evaluate("@js:nested(30)", in: .null, context: context)
        #expect(tooDeep.diagnostics.contains { $0.severity == .error && $0.message.contains("深度上限") })
    }

    @Test(arguments: ["nested", "put"])
    func cancellationStopsLaterRequestsAndLargeVariableCommits(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nested-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RSSVariableStore(directory: directory)
        let loader = NestedCancellationLoader()
        let first = "@js:rssArticle.putBigVariable('pending','uncommitted'); java.ajax('https://cancel.test/first'); java.put('changed','uncommitted'); 'first'"
        let second = "@js:java.ajax('https://cancel.test/second')"
        let rule: String
        if mode == "put" {
            rule = "@put:" + String(decoding: try JSONEncoder().encode(["a": first, "b": second]), as: UTF8.self) + "@get:{a}"
        } else {
            let quoted = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
            rule = "@js:java.getString(\(quoted)); java.ajax('https://cancel.test/second'); 'done'"
        }
        let engine = RuleEngine(javaScript: .init(networkLoader: loader, rssVariableStore: store))
        let context = RuleExecutionContext(variables: ["initial": "kept"], rssArticle: .init(origin: "source", title: "original", link: "article"))
        let task = Task { await engine.evaluate(rule, in: .null, context: context) }
        defer { task.cancel(); loader.release() }
        for _ in 0..<500 {
            if loader.hasStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.hasStarted)
        task.cancel()
        loader.release()
        let result = await task.value

        #expect(loader.paths == ["/first"])
        #expect(result.diagnostics.contains { $0.severity == .error })
        #expect(result.variables == ["initial": "kept"])
        #expect(result.rssArticle?.title == "original")
        #expect(try store.get(origin: "source", link: "article", key: "pending") == nil)
    }
}

private final class NestedCancellationLoader: JavaScriptNetworkLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    var hasStarted: Bool { lock.withLock { !recorded.isEmpty } }
    func release() { gate.signal() }

    func load(_ request: URLRequest) throws -> HTTPResponse {
        let first = lock.withLock {
            recorded.append(request.url?.path ?? "")
            return recorded.count == 1
        }
        if first, gate.wait(timeout: .now() + 10) != .success { throw URLError(.timedOut) }
        return .init(data: Data("response".utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
}
