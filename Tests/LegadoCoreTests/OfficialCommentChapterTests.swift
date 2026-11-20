import Foundation
import Testing
@testable import LegadoCore

struct OfficialCommentChapterTests {
    private let book = Book(bookUrl: "https://www.qidian.com/book/1010868264/", name: "书", origin: "source")

    private func chapter(_ address: String) -> BookChapter {
        BookChapter(url: address, title: "第一章", bookUrl: book.bookUrl, index: 0)
    }

    @Test func resolvesRelativePublisherChaptersAndRemovesQueryAndFragment() throws {
        let result = try #require(OfficialCommentChapter.resolve(book: book, chapter: chapter("/chapter/1010868264/402812591/?from=app#reader")))
        #expect(result.url.absoluteString == "https://www.qidian.com/chapter/1010868264/402812591/")
        #expect(result.discussionName == "本章说")

        #expect(result.bookID == "1010868264")
        #expect(result.chapterID == "402812591")
        let fanqieBook = Book(bookUrl: "https://fanqienovel.com/page/7255936586997566505", name: "小说", origin: "source")
        let next = BookChapter(url: "/reader/7399337929476162072?ref=share", title: "本章", bookUrl: fanqieBook.bookUrl, index: 0)
        let fanqie = try #require(OfficialCommentChapter.resolve(book: fanqieBook, chapter: next))
        #expect(fanqie.url.absoluteString == "https://fanqienovel.com/reader/7399337929476162072")
        #expect(fanqie.discussionName == "章末讨论")
        #expect(fanqie.bookID == "7255936586997566505")
        #expect(fanqie.chapterID == "7399337929476162072")
    }

    @Test(arguments: [
        "https://www.qidian.com/book/1010868264/", "https://fanqienovel.com/page/7399337929476162072",
        "https://www.qidian.com/chapter/1010868264/", "https://fanqienovel.com/reader/123/another",
        "https://fake.fanqienovel.com/reader/123", "https://www.qidian.com.example.org/chapter/123/4/",
        "https://fanqienovel.com@other.example/reader/123", "https://user@fanqienovel.com/reader/123",
        "https://fanqienovel.com:8000/reader/123", "https://fanqienovel.com/reader/123%2F456",
        "https://fanqienovel.com/reader/１２３", "https://fanqienovel.com/reader//123",
        "https://www.qidian.com/chapter/1010868264//123", "javascript:open('https://fanqienovel.com/reader/123')", ""
    ])
    func rejectsAmbiguousOrUnrelatedLinks(_ address: String) {
        let neutralBook = Book(bookUrl: "https://books.example/book/1", name: "书", origin: "source")
        let entry = BookChapter(url: address, title: "本章", bookUrl: neutralBook.bookUrl, index: 0)
        #expect(OfficialCommentChapter.resolve(book: neutralBook, chapter: entry) == nil)
    }

    @Test func ignoresVolumeHeadersAndChaptersFromStaleBooks() {
        var entry = chapter("https://www.qidian.com/chapter/1010868264/402812591/")
        entry.isVolume = true
        #expect(OfficialCommentChapter.resolve(book: book, chapter: entry) == nil)
        #expect(OfficialCommentChapter.resolve(book: book, chapter: chapter("/chapter/42/402812591/")) == nil)
        #expect(OfficialCommentChapter.resolve(book: book, chapter: chapter("https://fanqienovel.com/reader/73")) == nil)
        entry.isVolume = false
        entry.bookUrl = "another-book"
        #expect(OfficialCommentChapter.resolve(book: book, chapter: entry) == nil)
    }
}
