import Foundation
import Testing
import ZIPFoundation
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct EPUBReadingRegressionTests {
    @Test func epubLocatorSurvivesShelfReloadAndRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(at: root)
        let repository = InMemoryBookRepository()
        let managed = root.appendingPathComponent("managed")
        let library = BookLibraryModel(repository: repository, localDirectory: managed, chapterRepository: InMemoryBookChapterRepository())
        await library.load()
        await library.importLocalFiles([url])
        let book = try #require(library.books.first)
        let chapter = try #require(LocalBookService().loadChapters(book: book).chapters.last)
        let locator = ##"{"href":"last.xhtml","type":"application/xhtml+xml","locations":{"progression":0.42,"cssSelector":"#paragraph-7"}}"##
        await library.updateProgress(for: book, chapter: chapter, epubLocation: locator)
        try await library.renameLocalFile(at: URL(string: book.bookUrl)!, to: "新名字")
        let reloaded = BookLibraryModel(repository: repository, localDirectory: managed, chapterRepository: InMemoryBookChapterRepository())
        await reloaded.load()
        let saved = try #require(reloaded.books.first)
        #expect(saved.readConfig?.epubLocation == locator)
        #expect(saved.durChapterIndex == chapter.index)
        #expect(saved.originName == "新名字.epub")
        // Choosing the existing text reader intentionally replaces the EPUB location.
        await reloaded.updateProgress(for: saved, chapter: chapter, position: 12)
        #expect(reloaded.books.first?.readConfig?.epubLocation == nil)
        #expect(reloaded.books.first?.durChapterPos == 12)
    }
    private func fixture(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("示例.epub")
        let archive = try Archive(url: url, accessMode: .create)
        let files = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", #"<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>"#),
            ("book.opf", #"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>回归书籍</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest><item id="first" href="first.xhtml" media-type="application/xhtml+xml"/><item id="last" href="last.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="first"/><itemref idref="last"/></spine></package>"#),
            ("first.xhtml", "<html><head><title>第一章</title></head><body><h1>第一章</h1><p>第一章测试正文</p></body></html>"),
            ("last.xhtml", "<html><head><title>第二章</title></head><body><h1>第二章</h1><p>第二章测试正文</p></body></html>")
        ]
        for (path, value) in files {
            let data = Data(value.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    @Test func importedEPUBReadsNavigatesAndResumesAfterRenamingAndReloadingShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(at: root)
        let repository = InMemoryBookRepository()
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let library = BookLibraryModel(repository: repository, localDirectory: managed, chapterRepository: InMemoryBookChapterRepository())
        await library.load()
        await library.importLocalFiles([url])
        #expect(library.errorMessage == nil)
        let book = try #require(library.books.first)
        let shelfReader = BookshelfReadViewModel()
        await shelfReader.load(book: book, source: nil)
        #expect(shelfReader.errorMessage == nil && shelfReader.chapters.count == 2)
        let reader = ReaderViewModel(book: book, chapters: shelfReader.chapters, initialIndex: 0, cache: .init(directory: root.appendingPathComponent("cache")))
        #expect(!reader.canEditContent && !reader.usesReplaceRules)
        await reader.load(rules: [])
        #expect(reader.content == "第一章测试正文")
        await reader.prepareContinuousReading(rules: [])
        #expect(reader.scrollChapters.map(\.content) == ["第一章测试正文", "第二章测试正文"])
        reader.goNext()
        await reader.load(rules: [])
        #expect(reader.content == "第二章测试正文")
        await library.updateProgress(for: book, chapter: try #require(reader.currentChapter), position: 4)
        try await library.renameLocalFile(at: URL(string: book.bookUrl)!, to: "改名")
        let reloaded = BookLibraryModel(repository: repository, localDirectory: managed, chapterRepository: InMemoryBookChapterRepository())
        await reloaded.load()
        let saved = try #require(reloaded.books.first)
        #expect(saved.name == "回归书籍" && saved.originName == "改名.epub")
        #expect(saved.durChapterIndex == 1 && saved.durChapterPos == 4)
        let chapters = try LocalBookService().loadChapters(book: saved).chapters
        let resumed = ReaderViewModel(book: saved, chapters: chapters, initialIndex: saved.durChapterIndex)
        await resumed.load(rules: [])
        #expect(resumed.currentIndex == 1 && resumed.requestedPosition == 4)
        #expect(resumed.content == "第二章测试正文")
        #expect(try await reloaded.localFiles.list().count == 1)
    }

    @Test func corruptEPUBImportRollsBackFileAndContinuesOtherImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try fixture(at: root)
        let bad = root.appendingPathComponent("损坏.epub")
        try Data("bad epub".utf8).write(to: bad)
        let library = BookLibraryModel(repository: InMemoryBookRepository(), localDirectory: root.appendingPathComponent("managed", isDirectory: true), chapterRepository: InMemoryBookChapterRepository())
        await library.load()
        await library.importLocalFiles([bad, good])
        #expect(library.books.count == 1)
        #expect(library.errorMessage?.contains("损坏.epub") == true)
        #expect(try await library.localFiles.list().map { $0.url.lastPathComponent } == ["示例.epub"])
    }
}
