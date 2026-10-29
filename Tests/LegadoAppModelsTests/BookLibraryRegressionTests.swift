import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct BookLibraryRegressionTests {
    private let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "测试源")

    private func fixture() -> (Book, [BookChapter]) {
        var book = Book(bookUrl: "https://source.test/book", name: "书", origin: source.bookSourceUrl)
        book.totalChapterNum = 2
        book.durChapterTitle = "第一章"
        let chapters = (0..<3).map {
            BookChapter(url: "https://source.test/\($0)", title: ["第一章", "第二章", "第三章"][$0], bookUrl: book.bookUrl, index: $0)
        }
        return (book, chapters)
    }

    @Test func directoryRefreshPreservesConcurrentReadingAndGroupChanges() async throws {
        let (book, chapters) = fixture()
        let repository = InMemoryBookRepository(books: [book])
        let loader = DelayedChapterLoader(chapters: chapters)
        let model = BookLibraryModel(
            repository: repository,
            updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: loader)
        )
        await model.load()
        let update = Task { await model.checkForUpdates(sources: [source]) }
        await loader.waitForRequest()
        await model.updateProgress(for: book, chapter: chapters[1], position: 123)
        await model.setBook(book, groupIDs: [8])
        await loader.finish()
        await update.value

        let stored = try #require(model.books.first)
        #expect(stored.durChapterIndex == 1)
        #expect(stored.durChapterPos == 123)
        #expect(stored.group == 8)
        #expect(stored.totalChapterNum == 3)
        #expect(stored.latestChapterTitle == "第三章")
        #expect(try await repository.load() == model.books)
    }

    @Test func directoryRefreshDoesNotResurrectRemovedBooksOrDropNewBooks() async throws {
        let (book, chapters) = fixture()
        let repository = InMemoryBookRepository(books: [book])
        let loader = DelayedChapterLoader(chapters: chapters)
        let model = BookLibraryModel(
            repository: repository,
            updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: loader),
            chapterRepository: InMemoryBookChapterRepository()
        )
        await model.load()
        let update = Task { await model.checkForUpdates(sources: [source]) }
        await loader.waitForRequest()
        await model.remove(bookURL: book.bookUrl)
        let added = Book(bookUrl: "local://new", name: "新增书")
        await model.addOrUpdate(added)
        await loader.finish()
        await update.value

        #expect(model.books == [added])
        #expect(try await repository.load() == [added])
    }

    @Test func overlappingShelfWritesKeepProgressAndGroupChanges() async throws {
        let (book, chapters) = fixture()
        let repository = SuspendedBookRepository(books: [book])
        let model = BookLibraryModel(repository: repository)
        await model.load()
        let progress = Task { await model.updateProgress(for: book, chapter: chapters[1], position: 42) }
        await repository.waitForSave()
        var groupStarted = false
        let group = Task {
            groupStarted = true
            await model.setBook(book, groupIDs: [4])
        }
        while !groupStarted { await Task.yield() }
        #expect(model.books.first?.group == 4)
        await repository.finishSave()
        await progress.value
        await group.value

        #expect(model.books.first?.durChapterPos == 42)
        #expect(model.books.first?.group == 4)
        #expect(try await repository.load() == model.books)
    }

    @Test func failedSaveRestoresLastPersistedShelf() async throws {
        let (book, _) = fixture()
        let repository = FailingBookRepository(books: [book])
        let model = BookLibraryModel(repository: repository)
        await model.load()
        await model.setBook(book, groupIDs: [4])
        #expect(model.books == [book])
        #expect(model.errorMessage != nil)
        #expect(try await repository.load() == [book])
    }

    @Test func failedRemovalKeepsStoredDirectory() async throws {
        let (book, chapters) = fixture()
        let directories = InMemoryBookChapterRepository(values: [book.bookUrl: chapters])
        let model = BookLibraryModel(repository: FailingBookRepository(books: [book]), chapterRepository: directories)
        await model.load()

        await model.remove(bookURL: book.bookUrl)

        #expect(model.books == [book])
        #expect(await directories.load(bookURL: book.bookUrl) == chapters)
    }

    @Test func failedReplacementWithExistingBookKeepsOriginalDirectory() async throws {
        let (book, chapters) = fixture()
        let replacement = Book(bookUrl: "https://other.test/book", name: book.name, origin: "other")
        let directories = InMemoryBookChapterRepository(values: [book.bookUrl: chapters])
        let model = BookLibraryModel(repository: FailingBookRepository(books: [book, replacement]), chapterRepository: directories)
        await model.load()

        await model.replace(oldBookURL: book.bookUrl, with: replacement)

        #expect(model.books == [book, replacement])
        #expect(await directories.load(bookURL: book.bookUrl) == chapters)
    }

    @Test func failedAddPreservesPendingReadingProgressForRetry() async throws {
        let book = Book(bookUrl: "pending://\(UUID().uuidString)", name: "未入架的书")
        let chapter = BookChapter(url: "chapter", title: "第二章", bookUrl: book.bookUrl, index: 1)
        let repository = FailOnceBookRepository()
        let defaultsName = "BookLibraryRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = BookLibraryModel(repository: repository, progressDefaults: defaults)
        await model.load()
        await model.updateProgress(for: book, chapter: chapter, position: 42)

        await model.addOrUpdate(book)
        #expect(model.books.isEmpty)
        // A fresh model simulates relaunching after the failed save.
        let retried = BookLibraryModel(repository: repository, progressDefaults: defaults)
        await retried.load()
        await retried.addOrUpdate(book)

        #expect(retried.books.first?.durChapterIndex == 1)
        #expect(retried.books.first?.durChapterPos == 42)
        await retried.remove(bookURL: book.bookUrl)
    }

    @Test func failedGroupSaveRestoresVisibleGroups() async {
        let groups = [BookGroup(groupId: BookGroup.idAll, groupName: "全部")]
        let model = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: FailingGroupRepository(groups: groups))
        await model.load()

        await model.createGroup(name: "没有保存成功")

        #expect(model.groups == groups)
        #expect(model.errorMessage != nil)
    }

    @Test func groupAllocationUsesAvailablePositiveBitsAndReportsExhaustion() async {
        let highest = BookGroup(groupId: Int64(1) << 62, groupName: "最高位")
        let model = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: InMemoryBookGroupRepository(groups: [highest]))
        await model.load()
        await model.createGroup(name: "新分组")
        #expect(model.groups.last?.groupId == 1)

        let full = (0..<63).map { BookGroup(groupId: Int64(1) << $0, groupName: "分组\($0)") }
        let fullModel = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: InMemoryBookGroupRepository(groups: full))
        await fullModel.load()
        await fullModel.createGroup(name: "超出上限")
        #expect(fullModel.groups == full)
        #expect(fullModel.errorMessage != nil)
    }

    @Test func failedGroupDeletionKeepsMembershipsAndDefinition() async throws {
        var book = fixture().0
        book.group = 4
        let group = BookGroup(groupId: 4, groupName: "保留的分组")
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [book]),
                                     groupRepository: FailingGroupRepository(groups: [group]))
        await model.load()
        await model.deleteGroup(group)
        #expect(model.books == [book])
        #expect(model.groups == [group])

        let groups = InMemoryBookGroupRepository(groups: [group])
        let failedShelf = BookLibraryModel(repository: FailingBookRepository(books: [book]), groupRepository: groups)
        await failedShelf.load()
        await failedShelf.deleteGroup(group)
        #expect(failedShelf.books == [book])
        #expect(failedShelf.groups == [group])
        #expect(await groups.load() == [group])
        #expect(failedShelf.errorMessage != nil)
    }

    @Test func overlappingGroupChangesPersistLatestOrder() async throws {
        let group = BookGroup(groupId: 1, groupName: "原分组")
        let repository = SuspendedGroupRepository(groups: [group])
        let model = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: repository)
        await model.load()
        let rename = Task { await model.renameGroup(group, name: "新名称") }
        await repository.waitForSave()
        let visibility = Task { await model.setGroupVisible(group, visible: false) }
        while model.groups.first?.show != false { await Task.yield() }
        await repository.finishSave()
        await rename.value
        await visibility.value

        #expect(model.groups.first?.groupName == "新名称")
        #expect(model.groups.first?.show == false)
        #expect(await repository.load() == model.groups)
    }
}

private actor DelayedChapterLoader: ChapterListLoading {
    let chapters: [BookChapter]
    private var requested = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(chapters: [BookChapter]) { self.chapters = chapters }
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        requested = true
        await withCheckedContinuation { continuation = $0 }
        return .init(chapters: chapters)
    }
    func waitForRequest() async { while !requested { await Task.yield() } }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor SuspendedBookRepository: BookRepository {
    private var books: [Book]
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(books: [Book]) { self.books = books }
    func load() -> [Book] { books }
    func save(_ books: [Book]) async {
        if !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        self.books = books
    }
    func waitForSave() async { while !started { await Task.yield() } }
    func finishSave() { continuation?.resume(); continuation = nil }
}

private actor FailingBookRepository: BookRepository {
    let books: [Book]
    init(books: [Book]) { self.books = books }
    func load() -> [Book] { books }
    func save(_ books: [Book]) throws { throw CocoaError(.fileWriteOutOfSpace) }
}

private actor FailOnceBookRepository: BookRepository {
    private var books: [Book] = []
    private var shouldFail = true
    func load() -> [Book] { books }
    func save(_ books: [Book]) throws {
        if shouldFail { shouldFail = false; throw CocoaError(.fileWriteOutOfSpace) }
        self.books = books
    }
}

private actor FailingGroupRepository: BookGroupRepository {
    let groups: [BookGroup]
    init(groups: [BookGroup]) { self.groups = groups }
    func load() -> [BookGroup] { groups }
    func save(_ groups: [BookGroup]) throws { throw CocoaError(.fileWriteOutOfSpace) }
}

private actor SuspendedGroupRepository: BookGroupRepository {
    private var groups: [BookGroup]
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    init(groups: [BookGroup]) { self.groups = groups }
    func load() -> [BookGroup] { groups }
    func save(_ groups: [BookGroup]) async {
        if !started {
            started = true
            await withCheckedContinuation { pending = $0 }
        }
        self.groups = groups
    }
    func waitForSave() async { while !started { await Task.yield() } }
    func finishSave() { pending?.resume(); pending = nil }
}
