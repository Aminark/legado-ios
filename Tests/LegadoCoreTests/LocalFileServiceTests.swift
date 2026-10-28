import Foundation
import Testing
@testable import LegadoCore

struct LocalFileServiceTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func importsSameNamedFilesWithoutOverwritingAndIgnoresSymlinks() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("书.txt")
        try "第一章\n正文".write(to: source, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("books", isDirectory: true)
        let service = LocalFileService(directory: directory)
        let first = try await service.importFile(from: source)
        let second = try await service.importFile(from: source)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.txt"), withDestinationURL: source)
        let files = try await service.list()
        #expect(files.count == 2)
        #expect(Set(files.map { $0.url.lastPathComponent }) == ["书.txt", "书 (2).txt"])
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }

    @Test func repeatedImportReservesNamesWithDifferentExtensionCase() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Book.TXT")
        try "new book".write(to: source, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Book.TXT", "Book (2).txt"] {
            try "existing book".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let result = try await LocalFileService(directory: directory).importFile(from: source)
        #expect(result.lastPathComponent == "Book (3).TXT")
        #expect(try String(contentsOf: directory.appendingPathComponent("Book (2).txt"), encoding: .utf8) == "existing book")
        #expect(try String(contentsOf: result, encoding: .utf8) == "new book")
    }

    @Test func rejectsEscapesSymlinksAndOverwriteDuringRename() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("books", isDirectory: true)
        let service = LocalFileService(directory: directory)
        let source = root.appendingPathComponent("source.txt")
        try "正文".write(to: source, atomically: true, encoding: .utf8)
        let file = try await service.importFile(from: source)
        let second = try await service.importFile(from: source)
        await #expect(throws: LocalFileError.invalidName) { try await service.rename(file, to: "../escape") }
        await #expect(throws: LocalFileError.alreadyExists) { try await service.rename(file, to: second.lastPathComponent) }
        await #expect(throws: LocalFileError.outsideLibrary) { try await service.stageRemoval(source) }
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: LocalFileError.outsideLibrary) { try await service.stageRemoval(link) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func stagedDeletionCanRestoreOriginalBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("书.txt")
        let data = Data([0xff, 0xfe, 0x61, 0x00])
        try data.write(to: source)
        let service = LocalFileService(directory: root)
        let staged = try #require(try await service.stageRemoval(source))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await service.list().isEmpty)
        try await service.restore(staged)
        #expect(try Data(contentsOf: source) == data)
        let final = try #require(try await service.stageRemoval(source))
        try await service.finishRemoval(final)
        #expect(!FileManager.default.fileExists(atPath: final.staged.path))
    }

    @Test func originalExportPreservesEncodingAndNeverMovesSource() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("书.txt")
        let data = Data([0xff, 0xfe, 0x61, 0x00])
        try data.write(to: source)
        let exporter = BookFileExporter(directory: root.appendingPathComponent("exports"))
        let result = try await exporter.originalFile(source, filename: "../书.txt")
        #expect(try Data(contentsOf: result.url) == data)
        #expect(try Data(contentsOf: source) == data)
        #expect(result.url.lastPathComponent == ".._书.txt")
        try await exporter.discard(result)
        #expect(!FileManager.default.fileExists(atPath: result.url.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cachedExportUsesDirectoryOrderAndMarksMissingChapters() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"))
        let book = Book(bookUrl: "book", name: "书", author: "作者")
        let chapters = (0..<3).map { BookChapter(url: "c\($0)", title: "第\($0 + 1)章", bookUrl: "book", index: $0) }
        try await cache.save(.init(bookURL: "book", chapterURL: "c2", content: "第三章正文", supplementalContent: "补充"))
        try await cache.save(.init(bookURL: "book", chapterURL: "c0", content: "第一章正文"))
        let exporter = BookFileExporter(directory: root.appendingPathComponent("exports"), cache: cache)
        let result = try await exporter.cachedBook(book, chapters: chapters.reversed())
        let text = try String(contentsOf: result.url, encoding: .utf8)
        #expect(result.cachedChapters == 2)
        #expect(result.totalChapters == 3)
        #expect(result.isPartial)
        #expect(text.contains("第2章\n\n【本章尚未缓存】"))
        #expect(text.contains("第三章正文\n补充"))
        #expect(try #require(text.range(of: "第一章正文")).lowerBound < #require(text.range(of: "第三章正文")).lowerBound)
    }

    @Test func emptyCacheCannotProduceMisleadingEmptyBook() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("exports")
        let exporter = BookFileExporter(directory: exports, cache: ChapterContentCache(directory: root.appendingPathComponent("cache")))
        let book = Book(bookUrl: "book", name: "书")
        let chapter = BookChapter(url: "c", title: "第一章", bookUrl: "book", index: 0)
        await #expect(throws: LocalFileError.emptyCache) { try await exporter.cachedBook(book, chapters: [chapter]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    }
}
