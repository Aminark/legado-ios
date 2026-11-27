import Foundation
import Testing
@testable import LegadoCore

private struct FormBrowser: SourceScriptInteraction {
    func browse(_ address: String, title: String, waitsForDismissal: Bool) -> [String: String] {
        ["status": "201", "url": address, "body": title, "headers": #"{"X-Form":"complete"}"#]
    }
    func showMessage(_ message: String) {}
    func refreshDiscovery() {}
}

struct InteractiveSourceTests {
    @Test func formAcceptsStructuredFieldsAndBrowserReply() async throws {
        let input = #"{"bookSourceUrl":"https://forms.invalid","bookSourceName":"表单","loginUi":[{"name":"站点","type":"select"}],"loginUrl":"@js:function login(){}"}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(input.utf8))
        #expect(source.offersLogin)
        #expect(source.loginScript == "function login(){}")
        var engine = JavaScriptRuleEvaluator()
        engine.interaction = FormBrowser()
        let result = try await engine.evaluateAsync(script: """
            var label = JSON.parse(source.loginUi)[0].name;
            var page = java.startBrowserAwait(source.getKey(), label);
            [page.statusCode(), page.body(), page.header('x-form')].join('/');
            """, result: .null, executionContext: .init(source: source))
        #expect(result.value.stringValue == "201/站点/complete")
    }

    @Test func blankConfigurationTakesTheJavaScriptFallback() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: """
            try { JSON.parse('  '); 'parsed'; } catch (e) { e.name; }
            """, result: .null, executionContext: .init())
        #expect(result.value.stringValue == "SyntaxError")
    }

    @Test func scriptCookiePairsReachTheNativeJar() throws {
        let store = LegadoCookieStore.shared
        let url = try #require(URL(string: "https://\(UUID().uuidString).invalid"))
        defer { store.removeCookies(for: url.absoluteString) }
        store.setScriptCookies("sid=one; device=two", for: url.absoluteString)
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        #expect(Set(cookies.map(\.name)) == ["sid", "device"])
    }


}

extension InteractiveSourceTests {
    @Test func formTokensAreScopedAndRoundTripAsBytes() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let source = BookSource(bookSourceUrl: UUID().uuidString, bookSourceName: "第一组")
        let other = BookSource(bookSourceUrl: UUID().uuidString, bookSourceName: "第二组")
        let result = try evaluator.evaluate(script: """
            var box = java.createSymmetricCrypto('AES', '0123456789abcdef');
            cache.putMemory('value', box.encryptBase64('阅读🌙'));
            box.decryptStr(cache.getFromMemory('value'));
            """, result: .null, executionContext: .init(source: source))
        #expect(result.value.stringValue == "阅读🌙")
        let isolated = try evaluator.evaluate(script: "cache.getFromMemory('value') == null", result: .null,
                                              executionContext: .init(source: other))
        #expect(isolated.value == .bool(true))
    }
}
