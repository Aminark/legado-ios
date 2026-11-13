import Foundation
import Testing
@testable import LegadoCore

private struct JavaScriptNetworkMock: JavaScriptNetworkLoading {
    func load(_ request: URLRequest) throws -> HTTPResponse {
        #expect(request.url?.absoluteString == "https://js-network.example.test/api?page=2")
        #expect(request.httpMethod == "POST")
        #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == #"{"id":7}"#)
        #expect(request.value(forHTTPHeaderField: "X-Source") == "source")
        #expect(request.value(forHTTPHeaderField: "X-Extra") == "extra")
        let url = try #require(request.url)
        return .init(
            data: Data(#"{"ok":true}"#.utf8),
            statusCode: 201,
            headers: ["X-Reply": "yes"],
            finalURL: url
        )
    }
}

private final class RetryingLegacyJavaScriptNetworkMock: JavaScriptNetworkLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func load(_ request: URLRequest) throws -> HTTPResponse {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 {
            return .init(
                data: Data("temporary".utf8),
                statusCode: 503,
                headers: [:],
                finalURL: try #require(request.url)
            )
        }
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("explicit=yes") == true)
        let encoding = try #require(HTTPTextDecoder.encoding(named: "gb18030"))
        return .init(
            data: try #require("旧编码辅助请求".data(using: encoding)),
            statusCode: 200,
            headers: ["Set-Cookie": "session=js-ok; Path=/"],
            finalURL: try #require(request.url)
        )
    }

    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct JavaScriptAjaxAllMock: JavaScriptNetworkLoading {
    func load(_ request: URLRequest) throws -> HTTPResponse {
        let url = try #require(request.url)
        return .init(
            data: Data("body:\(url.lastPathComponent)".utf8),
            statusCode: 200,
            headers: [:],
            finalURL: url
        )
    }
}

private final class JavaScriptDirectRequestMock: JavaScriptRedirectNetworkLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(URLRequest, Bool)] = []

    func load(_ request: URLRequest) throws -> HTTPResponse {
        try load(request, followRedirects: true)
    }

    func load(_ request: URLRequest, followRedirects: Bool) throws -> HTTPResponse {
        lock.lock()
        recorded.append((request, followRedirects))
        lock.unlock()
        let url = try #require(request.url)
        return .init(
            data: Data("reply-\(request.httpMethod ?? "")".utf8),
            statusCode: request.httpMethod == "GET" ? 302 : 200,
            headers: ["X-Reply": "direct"],
            finalURL: url
        )
    }

    func calls() -> [(URLRequest, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

struct JavaScriptRuleEvaluatorTests {
    @Test func nestedAJAXIgnoresWebScriptUntilWebViewIsEnabled() throws {
        let evaluator = JavaScriptRuleEvaluator(networkLoader: InactiveWebScriptNetworkMock())
        let result = try evaluator.evaluate(script: "java.ajax(result)", result: .string(
            #"https://plain-http.test/ajax,{"webJs":"throw new Error('must not run')","bodyJs":"result + '-body'"}"#), executionContext: .init())
        #expect(result.value.stringValue == "HTTP-body")
    }

    @Test func decryptsSourceContentUsingRhinoPackageImportsAndAESByteArrays() throws {
        // OpenSSL AES-128-CBC/PKCS7 fixture, with a 16-byte IV prepended.
        let script = #"""
            var javaImport = new JavaImporter();
            javaImport.importPackage(Packages.java.lang, Packages.javax.crypto.spec,
                                     Packages.javax.crypto, Packages.java.util);
            with (javaImport) {
              var encrypted = Base64.getDecoder().decode('ZmVkY2JhOTg3NjU0MzIxMLgd3vmXCW/KPKUrbea1zRjjTRawCuSDRVQflh/mHcYAv/gm12GQKUL0NhitscZMdw==');
              var key = SecretKeySpec(String('0123456789abcdef').getBytes(), 'AES');
              var iv = IvParameterSpec(Arrays.copyOfRange(encrypted, 0, 16));
              var cipher = Cipher.getInstance('AES/CBC/PKCS5Padding');
              cipher.init(Cipher.DECRYPT_MODE, key, iv);
              var decoded = String(cipher.doFinal(Arrays.copyOfRange(encrypted, 16, encrypted.length)));
              cipher.init(Cipher.ENCRYPT_MODE, key, iv);
              var encoded = Base64.getEncoder().encodeToString(cipher.doFinal(decoded.getBytes()));
              decoded + '|' + encoded;
            }
            """#
        let value = try JavaScriptRuleEvaluator().evaluate(script: script, result: .null, executionContext: .init())
        #expect(value.value.stringValue == "第一段正文\n第二段正文。|uB3e+ZcJb8o8pStt5rXNGONNFrAK5INFVB+WH+YdxgC/+CbXYZApQvQ2GK2xxkx3")
    }

    @Test func javaCipherRejectsInvalidInputsAndUnsupportedPackageImports() throws {
        for script in [
            "var i = new JavaImporter(); i.importPackage(Packages.java.io);",
            "Packages.javax.crypto.Cipher.getInstance('DES/ECB/NoPadding');",
            "var i = new JavaImporter(Packages.java.lang, Packages.javax.crypto.spec, Packages.javax.crypto); with(i) { var c = Cipher.getInstance('AES/CBC/PKCS5Padding'); c.init(2, SecretKeySpec(String('short').getBytes(), 'AES'), IvParameterSpec(String('0123456789abcdef').getBytes())); c.doFinal([1, 2, 3]); }"
        ] {
            #expect(throws: RuleEngineError.self) {
                try JavaScriptRuleEvaluator().evaluate(script: script, result: .null, executionContext: .init())
            }
        }
    }

    @Test func importedAESHelperDeclaredInsideWithRetainsJavaStringByteDecoding() throws {
        let script = #"""
            var javaImport = new JavaImporter();
            javaImport.importPackage(Packages.java.lang, Packages.javax.crypto.spec,
                                     Packages.javax.crypto, Packages.java.util);
            with (javaImport) {
              function decode(content) {
                var bytes = Base64.getDecoder().decode(String(content));
                var key = SecretKeySpec(String('0123456789abcdef').getBytes(), 'AES');
                var iv = IvParameterSpec(Arrays.copyOfRange(bytes, 0, 16));
                var cipher = Cipher.getInstance('AES/CBC/PKCS5Padding');
                cipher.init(2, key, iv);
                return String(cipher.doFinal(Arrays.copyOfRange(bytes, 16, bytes.length)));
              }
            }
            decode('ZmVkY2JhOTg3NjU0MzIxMLgd3vmXCW/KPKUrbea1zRjjTRawCuSDRVQflh/mHcYAv/gm12GQKUL0NhitscZMdw==');
            """#
        let value = try JavaScriptRuleEvaluator().evaluate(script: script, result: .null, executionContext: .init())
        #expect(value.value.stringValue == "第一段正文\n第二段正文。")
    }

    @Test func supportsBundledHttpTTSJavaImporterHmacSHA1Script() throws {
        let script = #"""
            var aly = new JavaImporter(
              Packages.javax.crypto.Mac,
              Packages.javax.crypto.spec.SecretKeySpec,
              Packages.javax.xml.bind.DatatypeConverter,
              Packages.java.net.URLEncoder,
              Packages.java.lang.String,
              Packages.android.util.Base64
            );
            with (aly) {
              var mac = Mac.getInstance('HmacSHA1');
              mac.init(new SecretKeySpec(String('key').getBytes('UTF-8'), 'HmacSHA1'));
              var signature = Base64.encodeToString(
                mac.doFinal(String('The quick brown fox jumps over the lazy dog').getBytes('UTF-8')),
                Base64.NO_WRAP
              );
              signature + ':' + URLEncoder.encode('a b*~中', 'UTF-8');
            }
            """#

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: script,
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "3nybhbi3iqa8ino29wqQcBydtNk=:a+b*%7E%E4%B8%AD")
    }

    @Test func javaImporterDoesNotExposeArbitraryNativeClasses() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "typeof Packages.java.io + ':' + typeof Packages.java.lang.Runtime + ':' + Object.isFrozen(Packages)",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "undefined:undefined:true")
    }

    @Test func exposesDollarAsCurrentJSONForLegadoInlineExpressions() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "$.book_id",
            result: .object(["book_id": .string("42")]),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "42")
    }

    @Test func exposesJavaGetStringRuleBridge() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let html = #"<article><a href="/chapter/1">第一章</a></article>"#

        let value = try evaluator.evaluate(
            script: "java.getString('a@text', result) + ':' + java.getString('a@href', result, true)",
            result: .string(html),
            executionContext: .init(baseURL: "https://reader.example/book/")
        )
        let directJSON = try evaluator.evaluate(
            script: "java.getString('name', result) + ':' + java.getString('$.id', result)",
            result: .object(["name": .string("书名"), "id": .number(42)]),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "第一章:https://reader.example/chapter/1")
        #expect(directJSON.value.stringValue == "书名:42")
    }

    @Test func jsonParseKeepsPlainTextResponsesButStillRejectsBrokenJSON() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let plain = try evaluator.evaluate(
            script: "JSON.parse(result)",
            result: .string("The server is temporarily unavailable"),
            executionContext: .init()
        )

        #expect(plain.value.stringValue == "The server is temporarily unavailable")
        #expect(throws: RuleEngineError.self) {
            _ = try evaluator.evaluate(
                script: "JSON.parse(result)",
                result: .string(#"{"broken":}"#),
                executionContext: .init()
            )
        }
    }

    @Test func directJavaGetResolvesRelativeURLAndAppliesSourceHeaders() throws {
        var source = BookSource(bookSourceUrl: "https://direct.example.test/base/", bookSourceName: "相对请求")
        source.header = #"{"X-Source":"yes"}"#
        let loader = JavaScriptDirectRequestMock()
        let evaluator = JavaScriptRuleEvaluator(networkLoader: loader)

        _ = try evaluator.evaluate(
            script: "java.get('/chapter/1').body()",
            result: .null,
            executionContext: .init(baseURL: source.bookSourceUrl, source: source)
        )

        let call = try #require(loader.calls().first)
        #expect(call.0.url?.absoluteString == "https://direct.example.test/chapter/1")
        #expect(call.0.value(forHTTPHeaderField: "X-Source") == "yes")
        #expect(call.0.value(forHTTPHeaderField: "User-Agent") != nil)
    }

    @Test func loadsSharedSourceJavaScriptLibrary() throws {
        var source = BookSource(bookSourceUrl: "https://js-lib.example.test", bookSourceName: "共享脚本源")
        source.jsLib = "function decorate(value) { return 'lib:' + value; }"

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "decorate(result)",
            result: .string("ok"),
            executionContext: .init(source: source)
        )

        #expect(value.value.stringValue == "lib:ok")
    }
    @Test func providesAjaxAndConnectWithLegadoURLOptions() throws {
        var source = BookSource(bookSourceUrl: "https://js-network.example.test", bookSourceName: "JS 网络源")
        source.header = #"{"X-Source":"source"}"#
        let evaluator = JavaScriptRuleEvaluator(networkLoader: JavaScriptNetworkMock())
        let url = #"/api?page=2,{"method":"POST","body":{"id":7},"headers":{"X-Extra":"extra"}}"#

        let ajax = try evaluator.evaluate(
            script: "java.ajax(result)",
            result: .string(url),
            executionContext: .init(baseURL: source.bookSourceUrl, source: source)
        )
        let connect = try evaluator.evaluate(
            script: "var r=java.connect(result); r.body + ':' + r.code + ':' + r.headers['X-Reply']",
            result: .string(url),
            executionContext: .init(baseURL: source.bookSourceUrl, source: source)
        )

        #expect(ajax.value.stringValue == #"{"ok":true}"#)
        #expect(connect.value.stringValue == #"{"ok":true}:201:yes"#)
    }
    @Test func ajaxUsesCharsetHTTPRetryCookieMergeAndBodyJavaScript() throws {
        let host = "https://legacy-js.example.test"
        LegadoCookieStore.shared.removeCookies(for: host)
        defer { LegadoCookieStore.shared.removeCookies(for: host) }
        LegadoCookieStore.shared.setCookie("stored=one; Path=/", for: host)
        var source = BookSource(bookSourceUrl: host, bookSourceName: "旧编码 JS 源")
        source.enabledCookieJar = true
        let loader = RetryingLegacyJavaScriptNetworkMock()
        let evaluator = JavaScriptRuleEvaluator(networkLoader: loader)
        let rule = #"/api, {"charset":"gb18030","retry":1,"headers":{"Cookie":"explicit=yes"},"bodyJs":"result.replace('辅助', '内部')"}"#

        let value = try evaluator.evaluate(
            script: "java.ajax(result) + ':' + java.getCookie('\(host)', 'session')",
            result: .string(rule),
            executionContext: .init(baseURL: host, source: source)
        )

        #expect(value.value.stringValue == "旧编码内部请求:js-ok")
        #expect(loader.calls() == 2)
    }
    @Test func readsAndWritesSharedCookies() throws {
        let host = "https://cookie-js-bridge.test"
        LegadoCookieStore.shared.removeCookies(for: host)
        defer { LegadoCookieStore.shared.removeCookies(for: host) }
        let evaluator = JavaScriptRuleEvaluator()

        let value = try evaluator.evaluate(
            script: "java.setCookie('\(host)', 'token=abc; Path=/'); java.getCookie('\(host)', 'token') + ':' + java.getCookie('\(host)').indexOf('token=abc')",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "abc:0")
        #expect(LegadoCookieStore.shared.cookieHeader(for: host).contains("token=abc"))
    }
    @Test func exposesGlobalCookieStore() throws {
        // Use a separate registrable domain because Swift Testing runs these
        // cookie-store tests concurrently.
        let host = "https://global-cookie.test"
        LegadoCookieStore.shared.removeCookies(for: host)
        defer { LegadoCookieStore.shared.removeCookies(for: host) }

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "cookie.setCookie('\(host)', 'token=abc; Path=/'); var map=cookie.cookieToMap(cookie.getCookie('\(host)')); var header=cookie.mapToCookie(map); cookie.getKey('\(host)', 'token') + ':' + header",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "abc:token=abc")

        let removed = try JavaScriptRuleEvaluator().evaluate(
            script: "cookie.removeCookie('\(host)'); cookie.getCookie('\(host)')",
            result: .null,
            executionContext: .init()
        )
        #expect(removed.value.stringValue.isEmpty)
    }
    @Test func ajaxAllReturnsResponseObjectsInInputOrder() throws {
        let evaluator = JavaScriptRuleEvaluator(networkLoader: JavaScriptAjaxAllMock())

        let value = try evaluator.evaluate(
            script: "var rows=java.ajaxAll(['https://ajax-all.test/a','https://ajax-all.test/b'], false); rows[0].body + '|' + rows[1].url",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "body:a|https://ajax-all.test/b")
    }
    @Test func getHeadPostExposeJsoupStyleResponseAndDisableRedirects() throws {
        let loader = JavaScriptDirectRequestMock()
        let evaluator = JavaScriptRuleEvaluator(networkLoader: loader)

        let value = try evaluator.evaluate(
            script: "var g=java.get('https://direct.test/get', {'X-Test':'yes'}, 5000); var h=java.head('https://direct.test/head', {}); var p=java.post('https://direct.test/post', 'raw=正文', {'Content-Type':'text/plain'}); g.statusCode() + ':' + g.header('x-reply') + ':' + h.body() + ':' + p.body()",
            result: .null,
            executionContext: .init()
        )

        let calls = loader.calls()
        #expect(value.value.stringValue == "302:direct:reply-HEAD:reply-POST")
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { !$0.1 })
        #expect(calls[0].0.value(forHTTPHeaderField: "X-Test") == "yes")
        #expect(calls[1].0.httpBody == nil)
        #expect(String(decoding: calls[2].0.httpBody ?? Data(), as: UTF8.self) == "raw=正文")
    }
    @Test func executesPureJavaScriptAndJSONPathPipeline() async throws {
        let engine = RuleEngine()
        let root = try JSONValue.decode(data: Data(#"{"id":42,"name":"测试"}"#.utf8))

        let pure = await engine.evaluate("@js:result.name + '-JS'", in: root)
        #expect(pure.firstString == "测试-JS")
        #expect(pure.diagnostics.isEmpty)

        let pipeline = await engine.evaluate(
            "$.id@js:java.put('bookId', result); '/book/' + result",
            in: root
        )
        #expect(pipeline.firstString == "/book/42")
        #expect(pipeline.variables["bookId"] == "42")
        #expect(pipeline.diagnostics.isEmpty)
    }

    @Test func carriesVariablesAndProvidesLegadoHelpers() async {
        let engine = RuleEngine()
        let context = RuleExecutionContext(variables: ["bookId": "1001"])

        let result = await engine.evaluate(
            "@js:java.md5Encode(java.get('bookId')).length + ':' + java.get('bookId')",
            in: .null,
            context: context
        )

        #expect(result.firstString == "32:1001")
        #expect(result.variables["bookId"] == "1001")
    }

    @Test func providesByteHexTimeAndUUIDHelpers() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.bytesToStr(java.strToBytes('正文')) + ':' + java.hexDecodeToString(java.hexEncodeToString('A')) + ':' + java.timeFormatUTC(0, 'yyyy-MM-dd HH:mm', 0) + ':' + java.randomUUID().length",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "正文:A:1970-01-01 00:00:36")
    }

    @Test func exposesSourceTagBase64BytesAndStableInstallationIdentifier() throws {
        let source = BookSource(bookSourceUrl: "https://bridge-source.test", bookSourceName: "桥接源")
        let evaluator = JavaScriptRuleEvaluator()

        let value = try evaluator.evaluate(
            script: "java.getSource().bookSourceName + ':' + java.getTag() + ':' + java.bytesToStr(java.base64DecodeToByteArray('b2s=')) + ':' + (java.androidId() === java.androidId())",
            result: .null,
            executionContext: .init(source: source)
        )

        #expect(value.value.stringValue == "桥接源:https://bridge-source.test:ok:true")
    }

    @Test func exposesEntityPropertiesAndFormStyleEncodeURI() throws {
        var book = Book(bookUrl: "https://book.test/1", name: "书名", author: "作者")
        book.kind = "玄幻"
        let chapter = BookChapter(url: "/chapter/1", title: "第一章", bookUrl: book.bookUrl, index: 3)

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "book.name + ':' + book.kind + ':' + chapter.title + ':' + chapter.index + ':' + java.encodeURI('a b&中')",
            result: .null,
            executionContext: .init(book: book, chapter: chapter)
        )

        #expect(value.value.stringValue == "书名:玄幻:第一章:3:a+b%26%E4%B8%AD")
    }

    @Test func keepsJavaSpecialVariablesAndSourceVariablesInSeparateScopes() throws {
        let source = BookSource(bookSourceUrl: "https://variable-source.test", bookSourceName: "变量源")
        let book = Book(bookUrl: "https://book.test/variable", name: "变量书")
        let chapter = BookChapter(url: "/one", title: "变量章", bookUrl: book.bookUrl, index: 0)
        let evaluator = JavaScriptRuleEvaluator()

        let first = try evaluator.evaluate(
            script: "source.put('token','persisted'); java.get('bookName') + ':' + java.get('title')",
            result: .null,
            executionContext: .init(source: source, book: book, chapter: chapter)
        )
        let second = try evaluator.evaluate(
            script: "source.get('token')",
            result: .null,
            executionContext: .init(source: source)
        )

        #expect(first.value.stringValue == "变量书:变量章")
        #expect(second.value.stringValue == "persisted")
    }

    @Test func resolvesDynamicLenientAndLoginHeadersByPriority() throws {
        var source = BookSource(bookSourceUrl: "https://header-source.test", bookSourceName: "Header源")
        source.header = #"@js:"{'X-Static':'base','X-Dynamic':'js'}""#
        BookSourceRuntimeStore.shared.put(
            sourceID: source.id,
            key: "loginHeader",
            value: #"{"X-Static":"login","Cookie":"token=ok"}"#
        )

        let headers = try BookSourceHeaderResolver().resolve(source)

        #expect(headers["X-Dynamic"] == "js")
        #expect(headers["X-Static"] == "login")
        #expect(headers["Cookie"] == "token=ok")
    }

    @Test func exposesSourceLoginInfoMapAndHeaderMap() throws {
        var source = BookSource(bookSourceUrl: "httpTts:99", bookSourceName: "在线朗读")
        source.header = #"{"X-Base":"one"}"#
        BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginHeader", value: #"{"X-Login":"two"}"#)

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "source.putLoginInfo(JSON.stringify({token:'abc'})); source.getLoginInfoMap().get('token') + ':' + source.getHeaderMap(true)['X-Login'] + ':' + source.getKey()",
            result: .null,
            executionContext: .init(source: source)
        )

        #expect(value.value.stringValue == "abc:two:httpTts:99")
    }

    @Test func rejectsObviousUnboundedScripts() async {
        let result = await RuleEngine().evaluate("@js:while(true){}", in: .null)

        #expect(result.values.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "rule.resource_limit" })
    }
}

private struct InactiveWebScriptNetworkMock: JavaScriptNetworkLoading {
    func load(_ request: URLRequest) throws -> HTTPResponse {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://plain-http.test/ajax")
        return .init(data: Data("HTTP".utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}
