import Foundation
import Testing
@testable import LegadoCore

/// The input file stays outside the repository so live book sources and reading history
/// never become fixtures. Each case pins a known comment to its publisher chapter.
struct LiveChapterCommentsTests {
    private struct Input: Decodable {
        var source: BookSource
        var book: Book
        var cases: [Sample]
    }

    private struct Sample: Decodable {
        var chapter: BookChapter
        var expectedID: String
        var expectedText: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_LIVE_CHAPTER_COMMENTS"] != nil))
    func readsKnownCommentsFromTwoDifferentChapters() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_LIVE_CHAPTER_COMMENTS"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(input.cases.count >= 2)
        try #require(Set(input.cases.map { $0.chapter.id }).count == input.cases.count)
        let service = NetworkBookService()
        for sample in input.cases {
            try #require(!sample.expectedText.isEmpty && !sample.expectedID.isEmpty)
            let comments = try await service.loadChapterComments(book: input.book, chapter: sample.chapter, source: input.source)
            let matched = comments.contains { $0.id == "source:" + sample.expectedID && $0.content == sample.expectedText }
            #expect(matched, "The expected chapter-specific comment was missing from the live response")
        }
    }
}
