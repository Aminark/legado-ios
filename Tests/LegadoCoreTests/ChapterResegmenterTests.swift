import Foundation
import Testing
@testable import LegadoCore

struct ChapterResegmenterTests {
    private struct ReferenceCase: Decodable {
        var title: String
        var content: String
        var expected: String
    }

    @Test func matchesOriginalAndroidForBrokenLinesDialogueAndQuoteBoundaries() throws {
        let url = try #require(Bundle.module.url(forResource: "resegment-android", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([ReferenceCase].self, from: Data(contentsOf: url))
        #expect(cases.count == 128)
        for item in cases {
            #expect(ChapterResegmenter().process(item.content, chapterName: item.title) == item.expected,
                    "Android fixture: \(item.content)")
        }
    }

    @Test func longParagraphSplittingIsRepeatableAndPreservesText() {
        let content = (0..<200).map { "第\($0)句话包含😀和中文，继续向前。" }.joined()
        let first = ChapterResegmenter().process(content, chapterName: "标题")
        #expect(first.components(separatedBy: "\n").count > 10)
        #expect(first.replacingOccurrences(of: "\n", with: "") == content)
        for _ in 0..<5 {
            #expect(ChapterResegmenter().process(content, chapterName: "标题") == first)
        }
    }

    @Test func sanitizerRespectsPerBookSettingAndExplicitBypassBeforeReplacement() {
        var book = Book(bookUrl: "book", name: "测试书")
        let chapter = BookChapter(url: "1", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let original = "这是一段被错\n误断开的正文。\n下一段。"
        let sanitizer = ContentSanitizer()
        #expect(sanitizer.process(book: book, chapter: chapter, content: original, rules: []).content == original)
        book.readConfig = BookReadConfig()
        book.readConfig?.reSegment = true
        #expect(sanitizer.process(book: book, chapter: chapter, content: original, rules: []).content == "这是一段被错误断开的正文。\n下一段。")
        #expect(sanitizer.process(book: book, chapter: chapter, content: original, rules: [], resegment: false).content == original)
        let rule = ReplaceRule(id: 1, name: "断行恢复后净化", pattern: "错误断开", replacement: "修复")
        #expect(sanitizer.process(book: book, chapter: chapter, content: original, rules: [rule]).content == "这是一段被修复的正文。\n下一段。")
    }
}
