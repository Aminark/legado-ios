import Foundation
import Testing
@testable import LegadoCore

struct RuleAndWebViewCompatibilityTests {
    @Test func compoundClassSelectorMatchesSingleElementWithMultipleClasses() throws {
        let html = """
        <div class="cate-comic-list"><span class="clearfix">Wrong descendant</span></div>
        <ul class="cate-comic-list clearfix">
            <li><a href="/book/1">目标一</a></li>
            <li><a href="/book/2">目标二</a></li>
        </ul>
        """
        let evaluator = HTMLRuleEvaluator()
        let items = try evaluator.extractCSS("class.cate-comic-list clearfix@tag.li@text", html: html)
        #expect(items == ["目标一", "目标二"])

        let indexed = try evaluator.extractCSS("class.cate-comic-list clearfix.0@tag.a.1@text", html: html)
        #expect(indexed == ["目标二"])
    }

    @Test func inlineAtJSSupportsTrailingRegexReplacementWithoutSplittingLiterals() async {
        let engine = RuleEngine()
        let html = "<div>  第1章【广告】序幕  </div>"

        // Basic trailing replacement after @js:
        let stripped = await engine.evaluate(
            "div@text@js:result.trim()##【广告】##",
            inText: html
        )
        #expect(stripped.diagnostics.isEmpty)
        #expect(stripped.strings == ["第1章序幕"])

        // Replace-all and extract-first (###) after @js:
        let replacedAll = await engine.evaluate(
            "@js:'ab-ab-ab'##ab##XY",
            inText: ""
        )
        #expect(replacedAll.diagnostics.isEmpty)
        #expect(replacedAll.strings == ["XY-XY-XY"])

        let firstOnly = await engine.evaluate(
            "@js:'id=101,id=202'##id=(\\d+)##$1###",
            inText: ""
        )
        #expect(firstOnly.diagnostics.isEmpty)
        #expect(firstOnly.strings == ["101"])

        // ## inside JS string literal and regex literal must stay inside JS
        let preservesLiterals = await engine.evaluate(
            "@js:('foo##bar').replace(/##/, '::') + '!'##!$##?",
            inText: ""
        )
        #expect(preservesLiterals.diagnostics.isEmpty)
        #expect(preservesLiterals.strings == ["foo::bar?"])

        let returnedRegex = await engine.evaluate(
            "@js:function pattern() { return /##/.source; } pattern() + 'x'##x$##!",
            inText: ""
        )
        #expect(returnedRegex.diagnostics.isEmpty)
        #expect(returnedRegex.strings == ["##!"])

        // ## inside template literal and comment must not split JS
        let preservesTemplateAndComment = await engine.evaluate(
            """
            @js:
            // comment with ## marker
            const tag = `a##b`;
            tag.replace('##', '-')##-##_
            """,
            inText: ""
        )
        #expect(preservesTemplateAndComment.diagnostics.isEmpty)
        #expect(preservesTemplateAndComment.strings == ["a_b"])
    }

    @Test func webViewChallengePolicyDetectsInterstitialsAndNormalizesScripts() {
        #expect(WebViewChallengePolicy.isChallengeStatus(202))
        #expect(WebViewChallengePolicy.isChallengeStatus(403))
        #expect(WebViewChallengePolicy.isChallengeStatus(429))
        #expect(WebViewChallengePolicy.isChallengeStatus(503))
        #expect(!WebViewChallengePolicy.isChallengeStatus(200))

        #expect(WebViewChallengePolicy.looksLikeChallengeDocument(
            statusCode: 200,
            title: "Just a moment...",
            html: "<html><body>Checking your browser</body></html>"
        ))
        #expect(WebViewChallengePolicy.looksLikeChallengeDocument(
            statusCode: 200,
            title: "站点",
            html: "<html><head><script src='/cdn-cgi/challenge-platform/h/b/orchestrate'></script></head></html>"
        ))
        #expect(WebViewChallengePolicy.looksLikeChallengeDocument(
            statusCode: 200,
            title: "",
            html: "<html><head><meta http-equiv=\"refresh\" content=\"2;url=/real\"></head></html>"
        ))
        #expect(!WebViewChallengePolicy.looksLikeChallengeDocument(
            statusCode: 200,
            title: "第一章 起点",
            html: "<html><body><article>正文内容正常展示。</article></body></html>"
        ))

        let ua = WebViewChallengePolicy.resolveUserAgent(
            requestHeaders: ["user-agent": "CustomReader/1.0"],
            applicationDefault: "AppDefault/1.0"
        )
        #expect(ua == "CustomReader/1.0")
        #expect(WebViewChallengePolicy.resolveUserAgent(requestHeaders: [:], applicationDefault: "AppDefault/1.0") == "AppDefault/1.0")
        #expect(!WebViewChallengePolicy.resolveUserAgent(requestHeaders: [:], applicationDefault: "").isEmpty)

        let wrapped = WebViewChallengePolicy.wrappedEvaluationScript("var x = 1;")
        #expect(wrapped.contains("undefined"))
        #expect(wrapped.contains("return null"))
    }
}
