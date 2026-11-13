import Foundation
import Testing
@testable import LegadoCore

struct RSSArticleBridgeTests {
    @Test(arguments: ["ajax", "connect", "ajaxAll"])
    func nestedRequestsCarryLatestArticleAndVariablesAndReturnResponseMutations(method: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-nested-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var article = RssArticle(origin: "https://nested.test", title: "original", link: "/article")
        article.variable = #"{"old":"remove"}"#
        let call: String
        switch method {
        case "connect": call = "java.connect(address).body"
        case "ajaxAll": call = "java.ajaxAll([address])[0].body"
        default: call = "java.ajax(address)"
        }
        let value = try JavaScriptRuleEvaluator(networkLoader: RSSNestedRequestLoader(), rssVariableStore: .init(directory: directory)).evaluate(
            script: """
            var alias = rssArticle;
            rssArticle.title = 'current'; java.put('token', 'fresh');
            var address = '/{{rssArticle.title}}?token={{java.get("token")}}&page={{page}},' + JSON.stringify({
              js: "rssArticle.title = 'url-title'; java.put('fromURL', 'url-value'); result",
              bodyJs: "rssArticle.title += '-body'; java.put('token', java.get('fromURL')); rssArticle.putVariable('old', null); result + ':' + baseUrl"
            });
            var body = \(call);
            body + '|' + alias.title + '|' + java.get('token') + '|' + java.get('old')
            """, result: .null, executionContext: .init(baseURL: article.origin, page: 3, rssArticle: article)
        )
        #expect(value.value.stringValue == "response:https://redirect.test/final|url-title-body|url-value|")
        #expect(value.rssArticle?.title == "url-title-body")
        #expect(value.variables["old"] == nil)
        #expect(value.variables["fromURL"] == "url-value")
    }

    @Test func contentHTMLRulesResolveRelativeResourcesAgainstTheResponseURL() async throws {
        let source = RssSource(sourceUrl: "https://rss-origin.test", sourceName: "redirect")
        let article = RssArticle(origin: source.sourceUrl, title: "redirect", link: "@js:'/article'")
        let finalURL = try #require(URL(string: "https://cdn.test/redirected/page.html"))
        let result = try await RSSService(
            transport: RSSBridgeTransport(body: #"<a href="next.html">next</a>"#, finalURL: finalURL), networkPolicy: .init()
        ).contentDetailed(article: article, rule: "@CSS:a@abs:href", source: source)

        #expect(result.content == "https://cdn.test/redirected/next.html")
    }

    @Test func exposesRealFieldsAndKotlinStyleAccessorsAndReturnsMutations() throws {
        var article = RssArticle(origin: "https://rss-bridge.test", sort: "news", title: "original", link: "/article")
        article.pubDate = "today"
        article.description = "summary"
        article.content = "body"
        article.image = "/image"
        article.group = "group"
        article.order = 42
        article.type = 2
        article.durPos = 7
        let result = try JavaScriptRuleEvaluator().evaluate(
            script: """
            var fields = [rssArticle.getOrigin(), rssArticle.sort, rssArticle.getTitle(), rssArticle.link,
              rssArticle.pubDate, rssArticle.description, rssArticle.getContent(), rssArticle.image,
              rssArticle.group, rssArticle.getOrder(), rssArticle.getType(), rssArticle.durPos, rssArticle.getRead()];
            rssArticle.setTitle('updated'); rssArticle.read = true; rssArticle.setDurPos(19);
            fields.join('|')
            """,
            result: .null, executionContext: .init(rssArticle: article)
        )
        #expect(result.value.stringValue == "https://rss-bridge.test|news|original|/article|today|summary|body|/image|group|42|2|7|false")
        #expect(result.rssArticle?.title == "updated")
        #expect(result.rssArticle?.read == true)
        #expect(result.rssArticle?.durPos == 19)
        #expect(article.title == "original")
    }

    @Test func articleVariablesAndJavaHelpersShareLiveStorageIncludingDeletion() throws {
        var article = RssArticle(title: "article")
        article.variable = #"{"old":"remove-me","shared":"original"}"#
        let result = try JavaScriptRuleEvaluator().evaluate(
            script: """
            java.put('shared', 'fresh');
            rssArticle.putVariable('old', null);
            rssArticle.variableMap.put('fromMap', 'map');
            rssArticle.getVariableMap().direct = 'property';
            var before = [rssArticle.getVariable('shared'), java.get('fromMap'), java.get('direct'),
              rssArticle.variableMap.containsKey('old'), JSON.parse(rssArticle.variable).shared];
            rssArticle.setVariable(JSON.stringify({replaced:'all'}));
            java.put('after', 'next');
            before.join('|') + '|' + rssArticle.getVariableMap().size() + '|' + rssArticle.getVariable('after')
            """,
            result: .null, executionContext: .init(rssArticle: article)
        )
        #expect(result.value.stringValue == "fresh|map|property|false|fresh|2|next")
        #expect(result.variables == ["replaced": "all", "after": "next"])
        #expect(result.rssArticle?.variableMap == result.variables)
        #expect(article.variableMap["old"] == "remove-me")
    }

    @Test func absentArticleIsNullInsteadOfAnInventedEmptyArticle() throws {
        let result = try JavaScriptRuleEvaluator().evaluate(script: "rssArticle === null", result: .null, executionContext: .init())
        #expect(result.value == .bool(true))
        #expect(result.rssArticle == nil)
    }

    @Test func rulePipelinesAndTemplatesCarryArticleMutationsAndDoNotResurrectDeletedVariables() async throws {
        var article = RssArticle(title: "initial")
        article.variable = #"{"old":"remove"}"#
        let result = await RuleEngine().evaluate(
            #"@put:{token:$.token}<js>rssArticle.setTitle('changed'); rssArticle.putVariable('old', null); java.put('next', 'ok'); result</js><js>rssArticle.title + ':' + java.get('next') + ':' + rssArticle.getVariable('token')</js>"#,
            in: .object(["token": .string("value")]), context: .init(rssArticle: article)
        )
        #expect(result.diagnostics.isEmpty)
        #expect(result.joinedString == "changed:ok:value")
        #expect(result.rssArticle?.title == "changed")
        #expect(result.variables == ["token": "value", "next": "ok"])
        #expect(result.rssArticle?.variableMap == result.variables)

        let rendered = await RuleEngine().evaluate("{{rssArticle.setTitle('rendered'); rssArticle.title}}", in: .null, context: .init(rssArticle: article))
        #expect(rendered.joinedString == "rendered")
        #expect(rendered.rssArticle?.title == "rendered")
    }

    @Test func articleParsingMakesEarlierMetadataVisibleAndKeepsArticlesIsolated() async throws {
        var source = RssSource(sourceUrl: "https://rss-fields.test", sourceName: "fields")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.rulePubDate = "@js:rssArticle.getTitle() + '-date'"
        source.ruleDescription = "@js:rssArticle.putVariable('perArticle', rssArticle.title); rssArticle.pubDate"
        source.ruleImage = "@js:'/images/' + rssArticle.getVariable('perArticle')"
        source.ruleLink = "@js:rssArticle.setGroup(rssArticle.title + '-group'); '/articles/' + java.get('perArticle')"

        let result = try await RSSRuleParser().parse(
            sortName: "news", sortURL: source.sourceUrl, redirectURL: source.sourceUrl,
            body: #"{"items":[{"title":"one"},{"title":"two"}]}"#, source: source
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.result.articles.map(\.pubDate) == ["one-date", "two-date"])
        #expect(result.result.articles.map(\.description) == ["one-date", "two-date"])
        #expect(result.result.articles.map(\.group) == ["one-group", "two-group"])
        #expect(result.result.articles.map { $0.variableMap["perArticle"] } == ["one", "two"])
    }

    @Test func requestResponseAndContentRulesShareArticleState() async throws {
        let source = RssSource(sourceUrl: "https://rss-request.test", sourceName: "request")
        var article = RssArticle(origin: source.sourceUrl, title: "start")
        article.link = #"@js:rssArticle.setTitle(rssArticle.title + '-request'); rssArticle.putVariable('request', 'yes'); '/article,' + JSON.stringify({bodyJs:"rssArticle.title += '-body'; java.put('body', 'yes'); result"})"#
        article.variable = #"{"original":"kept"}"#
        let result = try await RSSService(transport: RSSBridgeTransport(), networkPolicy: .init()).contentDetailed(
            article: article,
            rule: "@js:rssArticle.setTitle(rssArticle.title + '-content'); rssArticle.putVariable('content', 'yes'); rssArticle.title + ':' + java.get('original') + ':' + java.get('request') + ':' + java.get('body')",
            source: source
        )
        #expect(result.content == "start-request-body-content:kept:yes:yes")
        #expect(result.article.title == "start-request-body-content")
        #expect(result.article.variableMap == ["original": "kept", "request": "yes", "body": "yes", "content": "yes"])
        #expect(result.requestURL == source.sourceUrl + "/article")
    }
}

private struct RSSNestedRequestLoader: JavaScriptNetworkLoading {
    func load(_ request: URLRequest) throws -> HTTPResponse {
        #expect(request.url?.absoluteString == "https://nested.test/current?token=fresh&page=3")
        return .init(data: Data("response".utf8), statusCode: 200, headers: [:], finalURL: URL(string: "https://redirect.test/final")!)
    }
}

private struct RSSBridgeTransport: HTTPTransport {
    var body = "<p>body</p>"
    var finalURL: URL?
    func data(for request: URLRequest) async throws -> HTTPResponse {
        .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: finalURL ?? request.url!)
    }
}
