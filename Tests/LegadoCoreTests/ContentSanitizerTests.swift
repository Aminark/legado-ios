import Foundation
import Testing
@testable import LegadoCore

struct ContentSanitizerTests {
    @Test(arguments: [false, true]) func paragraphResegmentationPreservesImageMarkupAndSignedURL(enabled: Bool) {
        var book = Book(bookUrl: "book", name: "书")
        book.readConfig = BookReadConfig()
        book.readConfig?.reSegment = enabled
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let image = #"<img src="https://images.example.test/formula~large.png?token=one&amp;size=2">"#
        let input = "图片前正文。\n" + image + "\n图片后正文。"

        let report = ContentSanitizer().process(book: book, chapter: chapter, content: input, rules: [])

        #expect(report.content.contains(image))
        #expect(report.content.contains("图片前正文。"))
        #expect(report.content.contains("图片后正文。"))
        #expect(!report.content.contains("formula-large"))
        #expect(report.diagnostics.isEmpty)
    }

    @Test func imageBoundariesKeepMarkupOrderAndFollowingTitleLikeText() {
        var book = Book(bookUrl: "book", name: "书")
        book.readConfig = BookReadConfig()
        book.readConfig?.reSegment = true
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let first = #"<img src="https://images.test/a~small.png">"#
        let second = "<IMG\n src='https://images.test/b?x=1&amp;y=2' alt='x > y'/>"
        let input = first + "\n第一章\n她说：\"来了。\"\n" + second

        let report = ContentSanitizer().process(book: book, chapter: chapter, content: input, rules: [])
        let repeated = ContentSanitizer().process(book: book, chapter: chapter, content: input, rules: [])

        #expect(report.content.hasPrefix(first + "\n第一章"))
        #expect(report.content.hasSuffix(second))
        #expect(report.content.contains("来了。"))
        #expect(report.content == repeated.content)
    }

    @Test func explicitContentReplacementStillAppliesAfterImageProtection() {
        var book = Book(bookUrl: "book", name: "书")
        book.readConfig = BookReadConfig()
        book.readConfig?.reSegment = true
        let chapter = BookChapter(url: "chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)
        var replace = ReplaceRule(id: 999, name: "用户地址修正", pattern: "~", replacement: "-")
        replace.isRegex = false
        replace.scopeContent = true
        let report = ContentSanitizer().process(book: book, chapter: chapter,
            content: #"<img src="https://images.test/a~small.png">"#, rules: [replace])

        #expect(report.content == #"<img src="https://images.test/a-small.png">"#)
        #expect(report.effectiveRuleIDs == [999])
    }

    @Test func missingImageSourceDoesNotConsumeAdjacentBodyOrCreatePlaceholderURL() throws {
        let base = try #require(URL(string: "https://images.test/chapter"))
        let html = #"<p>前文。</p><img alt='a > b'><p>中间。</p><img src=""><p>后文。</p>"#
        let result = ChapterHTMLFormatter().format(html, baseURL: base)

        #expect(!result.contains("<img"))
        #expect(!result.contains("LEGADO_IMAGE_"))
        #expect(result.components(separatedBy: .newlines).filter { !$0.isEmpty } == ["前文。", "中间。", "后文。"])
    }

    @Test func removesDuplicateTitlePrefixWithoutDroppingFollowingBodyOnSameLine() {
        let book = Book(bookUrl: "book", name: "测试书")
        let chapter = BookChapter(url: "1", title: "第一章 开始", bookUrl: book.bookUrl, index: 0)
        let report = ContentSanitizer().process(book: book, chapter: chapter,
            content: "《测试书》第一章  开始 正文第一句。\n后续正文。", rules: [])
        #expect(report.content == "正文第一句。\n后续正文。")
        #expect(report.removedDuplicateTitle)
    }

    @Test func removesReplacedTitlePrefixAndEscapesTitleMetacharacters() {
        let book = Book(bookUrl: "book", name: "测试书")
        let chapter = BookChapter(url: "1", title: "[1] 起点+", bookUrl: book.bookUrl, index: 0)
        var rule = ReplaceRule(id: 1, name: "标题", pattern: "起点", replacement: "出发")
        rule.isRegex = false
        rule.scopeTitle = true
        rule.scopeContent = false
        let report = ContentSanitizer().process(book: book, chapter: chapter,
            content: "[1] 出发+正文仍在。", rules: [rule])
        #expect(report.content == "正文仍在。")
        #expect(report.removedDuplicateTitle)
    }

    @Test func emptyTitlesDoNotRemovePunctuationOnlyParagraphs() {
        let book = Book(bookUrl: "book", name: "书")
        let chapter = BookChapter(url: "1", title: "", bookUrl: book.bookUrl, index: 0)
        let report = ContentSanitizer().process(book: book, chapter: chapter, content: "……\n正文。", rules: [])
        #expect(report.content == "……\n正文。")
        #expect(!report.removedDuplicateTitle)
    }
    @Test func metadataCleanerRemovesHTMLDecodesEntitiesAndKeepsParagraphs() {
        let input = "<p>第一段&nbsp;文字</p><div>第二段<br>换行</div><script>bad()</script>"

        let value = MetadataTextSanitizer().clean(input)

        #expect(value == "第一段 文字\n第二段\n换行")
        #expect(MetadataTextSanitizer().clean("  纯文本简介  ") == "纯文本简介")
        #expect(MetadataTextSanitizer().clean("<br><p></p>") == nil)
    }

    @Test func appliesOrderedScopedRulesAndRemovesDuplicateTitle() {
        let book = Book(bookUrl: "https://source.test/book/1", name: "测试书", origin: "https://source.test")
        let chapter = BookChapter(url: "chapter/1", title: "第一章 开始", bookUrl: book.bookUrl, index: 0)
        var titleRule = ReplaceRule(id: 1, name: "标题", pattern: "开始", replacement: "启程")
        titleRule.scopeTitle = true
        titleRule.scopeContent = false
        titleRule.scope = "测试书"
        var adRule = ReplaceRule(id: 2, name: "广告", pattern: "广告[^\n]*", replacement: "")
        adRule.scopeContent = true
        adRule.sortOrder = 1
        var excluded = ReplaceRule(id: 3, name: "排除", pattern: "正文", replacement: "错误")
        excluded.excludeScope = "https://source.test"

        let report = ContentSanitizer().process(
            book: book,
            chapter: chapter,
            content: "第一章 开始\n 正文第一段 \n广告请访问 example.com\n正文第二段",
            rules: [excluded, adRule, titleRule]
        )

        #expect(report.title == "第一章 启程")
        #expect(report.content == "正文第一段\n\n正文第二段")
        #expect(report.removedDuplicateTitle)
        #expect(report.effectiveRuleIDs == [1, 2])
        #expect(report.diagnostics.isEmpty)
    }

    @Test func rejectsHighRiskRegexWithoutChangingContent() {
        let book = Book(bookUrl: "local", name: "书", origin: "local")
        let chapter = BookChapter(url: "1", title: "章节", bookUrl: book.bookUrl, index: 0)
        let risky = ReplaceRule(id: 7, name: "危险", pattern: "(a+)+$", replacement: "")

        let report = ContentSanitizer().process(book: book, chapter: chapter, content: "aaaa!", rules: [risky])

        #expect(report.content == "aaaa!")
        #expect(report.diagnostics.contains { $0.code == "rule.resource_limit" })
    }
}
