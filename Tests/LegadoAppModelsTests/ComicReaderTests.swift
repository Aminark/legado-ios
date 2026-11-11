import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ComicReaderTests {
    @Test(arguments: [0, 2]) func cachedComicSelectsImageReaderAndPreservesReadingPosition(type: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var book = Book(bookUrl: "https://comic.invalid/book", name: "漫画", origin: "https://comic.invalid")
        let chapter = BookChapter(url: "https://comic.invalid/chapter/1", title: "第一话", bookUrl: book.bookUrl, index: 0)
        let content = "<img src='/pages/1.jpg'>\n<img src='/pages/2.jpg'>"
        book.durChapterPos = 30
        var source = BookSource(bookSourceUrl: book.origin, bookSourceName: "漫画源")
        source.bookSourceType = type
        let cache = ChapterContentCache(directory: directory)
        try await cache.save(.init(bookURL: book.bookUrl, chapterURL: chapter.url, content: content, sourceID: source.id))
        let model = ReaderViewModel(book: book, chapters: [chapter], initialIndex: 0, source: source, cache: cache)
        await model.load(rules: [], prefetchNextChapter: false)
        #expect(model.hasImageContent)
        #expect(model.loadedFromCache)
        #expect(model.imageBlocks.count == 2)
        #expect(model.imageBlocks.first?.content == .image("https://comic.invalid/pages/1.jpg"))
        #expect(model.requestedPosition == 30)
        await model.prepareContinuousReading(rules: [])
        #expect(model.scrollChapters.isEmpty)
        #expect(try await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url)?.content == content)
    }
}
