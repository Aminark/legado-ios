import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct LocalFileManagementTests {
    @Test func localImportUsesLatestManagedTocRulesAndPersistsTheSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("自定义标题.txt")
        let body = String(repeating: "a", count: 1_100)
        try Data("段1\n\(body)\n段2\n\(body)\n段3\n\(body)".utf8).write(to: source)
        let database = try LegadoDatabase(url: root.appendingPathComponent("rules.sqlite3"))
        let rules = SQLiteConfigurationRepository(database: database)
        let rule = TxtTocRule(id: 1, name: "自定义段落", rule: #"(?m)^段\d$"#, replacement: "result + ' 自定义'")
        try await rules.saveTxtTocRules([rule])
        let shelf = InMemoryBookRepository()
        let model = BookLibraryModel(repository: shelf, localDirectory: root.appendingPathComponent("library"),
                                     chapterRepository: InMemoryBookChapterRepository(), txtTocRuleRepository: rules)
        await model.load()
        await model.importLocalFiles([source])
        let imported = try #require(model.books.first)
        #expect(imported.tocUrl == rule.rule + TxtTocRuleSelector.separator + rule.replacement)
        #expect(imported.totalChapterNum == 3)
        #expect(try LocalBookService().loadChapters(book: imported).chapters.map(\.title) == ["段1 自定义", "段2 自定义", "段3 自定义"])
        var disabled = rule
        disabled.enable = false
        try await rules.saveTxtTocRules([disabled])
        await model.importLocalFiles([source])
        #expect(model.books.last?.totalChapterNum == 1)
        #expect(await shelf.load() == model.books)
        #expect(model.errorMessage == nil)
    }

    @Test func rebuildingCommitsSQLiteDirectoryAndKeepsFileIdentityAndUnrelatedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("目录重建.txt")
        let data = Data("第一章\n正文甲\n第二章\n正文乙".utf8)
        try data.write(to: file)
        let original = try LocalBookService().openTextFile(at: file)
        var reading = original.book
        reading.durChapterIndex = 1
        reading.durChapterTitle = original.chapters[1].title
        reading.durChapterPos = 4
        reading.group = 8
        let database = try LegadoDatabase(url: root.appendingPathComponent("shelf.sqlite3"))
        let books = SQLiteBookRepository(database: database)
        let chapters = SQLiteBookChapterRepository(database: database)
        try await books.save([reading])
        try await chapters.save(original.chapters, bookURL: reading.bookUrl)
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"))
        try await cache.save(.init(bookURL: reading.bookUrl, chapterURL: "old", content: "旧正文"))
        try await cache.save(.init(bookURL: "unrelated", chapterURL: "kept", content: "别本书正文"))
        let model = BookLibraryModel(repository: books, localDirectory: root, chapterRepository: chapters, chapterCache: cache)
        await model.load()
        #expect(await model.rebuildLocalBook(bookURL: reading.bookUrl, rule: .init(name: "无标题", rule: ""), splitLongChapter: false))
        let rebuilt = try #require(model.books.first)
        #expect(model.books.count == 1 && rebuilt.bookUrl == reading.bookUrl && rebuilt.group == 8)
        #expect(rebuilt.totalChapterNum == 1 && rebuilt.durChapterIndex == 0)
        #expect(try await books.load() == model.books)
        #expect(try await chapters.load(bookURL: rebuilt.bookUrl) == LocalBookService().loadChapters(book: rebuilt).chapters)
        #expect(try await cache.load(bookURL: reading.bookUrl, chapterURL: "old") == nil)
        #expect(try await cache.load(bookURL: "unrelated", chapterURL: "kept")?.content == "别本书正文")
        #expect(try Data(contentsOf: file) == data)
        #expect(try await model.localFiles.list().filter { $0.url.pathExtension == "txt" }.count == 1)
    }

    @Test func failedRebuildRestoresOriginalDirectoryProgressAndCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("目录失败.txt")
        let data = Data("第一章\n正文甲\n第二章\n正文乙".utf8)
        try data.write(to: file)
        let original = try LocalBookService().openTextFile(at: file)
        var reading = original.book
        reading.durChapterIndex = 1
        reading.durChapterPos = 4
        let books = FileOperationFailingRepository(books: [reading])
        let chapters = InMemoryBookChapterRepository(values: [reading.bookUrl: original.chapters])
        let cache = ChapterContentCache(directory: root.appendingPathComponent("cache"))
        try await cache.save(.init(bookURL: reading.bookUrl, chapterURL: "old", content: "旧正文"))
        let model = BookLibraryModel(repository: books, localDirectory: root, chapterRepository: chapters, chapterCache: cache)
        await model.load()
        #expect(!(await model.rebuildLocalBook(bookURL: reading.bookUrl, rule: .init(name: "无标题", rule: ""), splitLongChapter: false)))
        #expect(model.books == [reading])
        #expect(await chapters.load(bookURL: reading.bookUrl) == original.chapters)
        #expect(try await cache.load(bookURL: reading.bookUrl, chapterURL: "old")?.content == "旧正文")
        #expect(try Data(contentsOf: file) == data)
        #expect(model.errorMessage != nil)
    }

    @Test func invalidRebuildRuleAndMissingBookDoNotPersistChanges() async throws {
        let (root, book, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!(await model.rebuildLocalBook(bookURL: book.bookUrl, rule: .init(name: "错误规则", rule: "["), splitLongChapter: true)))
        #expect(model.books == [book])
        #expect(model.errorMessage != nil)
        #expect(!(await model.rebuildLocalBook(bookURL: "missing", rule: nil, splitLongChapter: true)))
        #expect(model.books == [book])
    }

    @Test func cancelledRebuildDoesNotSaveDirectoryOrReadingProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("取消重建.txt")
        try Data("第一章\n正文甲\n第二章\n正文乙".utf8).write(to: file)
        let original = try LocalBookService().openTextFile(at: file)
        let chapters = RebuildGateChapterRepository(chapters: original.chapters)
        let books = InMemoryBookRepository(books: [original.book])
        let model = BookLibraryModel(repository: books, localDirectory: root, chapterRepository: chapters)
        await model.load()
        let rebuild = Task { await model.rebuildLocalBook(bookURL: original.book.bookUrl, rule: .init(name: "无标题", rule: ""), splitLongChapter: false) }
        await chapters.waitForLoad()
        rebuild.cancel()
        await chapters.resumeLoad()
        #expect(!(await rebuild.value))
        #expect(model.books == [original.book])
        #expect(await books.load() == [original.book])
        #expect(await chapters.saveCount == 0)
    }

    @Test func pickedTXTImportsButJSONFilesCannotBecomeLocalBooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = [
            ("小说.TXT", "第一章 开始\n本地小说的正文"),
            ("书源.json", #"{"bookSourceName":"书源"}"#),
            ("大写书源.JSON", #"{"bookSourceName":"书源"}"#)
        ]
        let files = try inputs.map { name, text in
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return LocalBookImportFile(url: url)
        }
        let model = BookLibraryModel(repository: InMemoryBookRepository(),
                                     localDirectory: root.appendingPathComponent("managed"),
                                     chapterRepository: InMemoryBookChapterRepository())
        await model.load()

        await model.importPickedLocalFiles(files)

        let book = try #require(model.books.first)
        #expect(model.books.count == 1)
        #expect(book.origin == "local")
        #expect(book.originName == "小说.TXT")
        #expect(model.errorMessage?.contains("书源.json") == true)
        #expect(model.errorMessage?.contains("大写书源.JSON") == true)
        #expect(try await model.localFiles.list().count == 1)
        let imported = try #require(URL(string: book.bookUrl))
        #expect(try Data(contentsOf: imported) == Data(inputs[0].1.utf8))
    }

    private func fixture(fails: Bool = false) async throws -> (URL, Book, BookLibraryModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("原文件.txt")
        try "第一章 开始\n正文".write(to: file, atomically: true, encoding: .utf8)
        var book = Book(bookUrl: file.absoluteString, name: "原书名", origin: "local")
        book.originName = file.lastPathComponent
        book.durChapterIndex = 2
        book.durChapterTitle = "第三章"
        book.durChapterPos = 42
        book.group = 8
        let repository: any BookRepository = fails ? FileOperationFailingRepository(books: [book]) : InMemoryBookRepository(books: [book])
        let model = BookLibraryModel(repository: repository, localDirectory: root, chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        return (root, book, model)
    }

    @Test func renamingFileRetargetsShelfAndPreservesTitleAndReadingState() async throws {
        let (root, original, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.renameLocalFile(at: URL(string: original.bookUrl)!, to: "新文件")
        let book = try #require(model.books.first)
        #expect(book.bookUrl == root.appendingPathComponent("新文件.txt").absoluteString)
        #expect(book.originName == "新文件.txt")
        #expect(book.name == original.name)
        #expect(book.durChapterIndex == 2 && book.durChapterPos == 42 && book.group == 8)
        #expect(FileManager.default.fileExists(atPath: URL(string: book.bookUrl)!.path))
        #expect(!FileManager.default.fileExists(atPath: URL(string: original.bookUrl)!.path))
    }

    @Test func failedShelfSaveRestoresRenamedFileAndShelf() async throws {
        let (root, book, model) = try await fixture(fails: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await model.renameLocalFile(at: URL(string: book.bookUrl)!, to: "新文件") }
        #expect(model.books == [book])
        #expect(FileManager.default.fileExists(atPath: URL(string: book.bookUrl)!.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("新文件.txt").path))
    }

    @Test func failedShelfSaveRestoresDeletedFileBytes() async throws {
        let (root, book, model) = try await fixture(fails: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = URL(string: book.bookUrl)!
        let data = try Data(contentsOf: file)
        await #expect(throws: (any Error).self) { try await model.deleteLocalFile(at: file) }
        #expect(model.books == [book])
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func deletingFileAlsoRemovesShelfReference() async throws {
        let (root, book, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = URL(string: book.bookUrl)!
        try await model.deleteLocalFile(at: file)
        #expect(model.books.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await model.localFiles.list().isEmpty)
    }

    @Test func mixedImportKeepsSuccessfulFilesAndReportsUnsupportedOnes() async throws {
        let (root, original, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("原文件.txt")
        let unsupported = root.appendingPathComponent("unsupported.pdf")
        try Data("pdf".utf8).write(to: unsupported)
        await model.importLocalFiles([source, unsupported, source])
        #expect(model.books.count == 3)
        #expect(model.books.first == original)
        #expect(model.errorMessage?.contains("unsupported.pdf") == true)
        #expect(try await model.localFiles.list().count == 3)
    }

    @Test func missingFileFromOldContainerCanBeRemovedFromShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = root.appendingPathComponent("old-container/missing.txt")
        let book = Book(bookUrl: missing.absoluteString, name: "丢失的书", origin: "local")
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [book]), localDirectory: root.appendingPathComponent("current-container"))
        await model.load()
        try await model.deleteLocalFile(at: missing)
        #expect(model.books.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func existingFileOutsideLibraryCannotBeDeletedThroughShelf() async throws {
        let (root, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("原文件.txt")
        let bytes = try Data(contentsOf: external)
        let book = Book(bookUrl: external.absoluteString, name: "外部文件", origin: "local")
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [book]), localDirectory: root.appendingPathComponent("managed"))
        await model.load()
        await #expect(throws: LocalFileError.outsideLibrary) { try await model.deleteLocalFile(at: external) }
        #expect(model.books == [book])
        #expect(try Data(contentsOf: external) == bytes)
    }
}

private actor FileOperationFailingRepository: BookRepository {
    let books: [Book]
    init(books: [Book]) { self.books = books }
    func load() -> [Book] { books }
    func save(_ books: [Book]) throws { throw CocoaError(.fileWriteOutOfSpace) }
}


private actor RebuildGateChapterRepository: BookChapterRepository {
    let chapters: [BookChapter]
    var saveCount = 0
    private var loadStarted = false
    private var signal: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    init(chapters: [BookChapter]) { self.chapters = chapters }
    func load(bookURL: String) async -> [BookChapter] {
        loadStarted = true
        signal?.resume()
        signal = nil
        await withCheckedContinuation { continuation = $0 }
        return chapters
    }
    func waitForLoad() async {
        if !loadStarted { await withCheckedContinuation { signal = $0 } }
    }
    func resumeLoad() { continuation?.resume(); continuation = nil }
    func save(_ chapters: [BookChapter], bookURL: String) { saveCount += 1 }
    func remove(bookURL: String) {}
}
