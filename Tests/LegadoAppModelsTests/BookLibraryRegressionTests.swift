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

    @Test func readerSettingSavesOnlyChangedFieldAndKeepsCurrentMetadataAndProgress() async {
        let (snapshot, chapters) = fixture()
        var current = snapshot
        current.name = "后台更新的名称"
        current.variable = "{\"token\":\"new\"}"
        current.readConfig = BookReadConfig()
        current.readConfig?.ttsEngine = "saved-engine"
        let repository = InMemoryBookRepository(books: [current])
        let model = BookLibraryModel(repository: repository, chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        await model.updateProgress(for: current, chapter: chapters[1], position: 42)
        let saved = await model.updateReadConfig(for: snapshot) { $0.reSegment = true }
        #expect(saved)
        #expect(model.books.first?.name == current.name)
        #expect(model.books.first?.variable == current.variable)
        #expect(model.books.first?.durChapterPos == 42)
        #expect(model.books.first?.readConfig?.ttsEngine == "saved-engine")
        #expect(model.books.first?.readConfig?.reSegment == true)
        #expect(await repository.load() == model.books)
    }

    @Test func readerSettingDoesNotInsertPreviewOrRestoreStaleSource() async {
        let (snapshot, _) = fixture()
        let repository = InMemoryBookRepository()
        let model = BookLibraryModel(repository: repository, chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        let previewSave = await model.updateReadConfig(for: snapshot) { $0.reSegment = true }
        #expect(!previewSave)
        #expect(model.books.isEmpty)
        var switched = snapshot
        switched.origin = "new-source"
        await model.addOrUpdate(switched)
        let staleSave = await model.updateReadConfig(for: snapshot) { $0.reSegment = true }
        #expect(!staleSave)
        #expect(model.books == [switched])
        #expect(await repository.load() == [switched])
    }

    @Test func readerSettingPersistenceFailureKeepsSavedConfiguration() async {
        let (book, _) = fixture()
        let model = BookLibraryModel(repository: FailingBookRepository(books: [book]), chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        let saved = await model.updateReadConfig(for: book) { $0.reSegment = true }
        #expect(!saved)
        #expect(model.books == [book])
        #expect(model.errorMessage != nil)
    }

    @Test(arguments: [false, true]) func preUpdateURLMigrationCommitsSafelyAndKeepsCacheOnFailure(fails: Bool) async throws {
        let (old, oldChapters) = fixture()
        var replacement = old
        replacement.bookUrl += "/rotated"
        replacement.name = "规则更名"
        replacement.tocUrl = replacement.bookUrl + "/toc"
        replacement.variable = "{\"token\":\"new\"}"
        let chapters = oldChapters.map { chapter in
            var value = chapter; value.bookUrl = replacement.bookUrl; value.url += "/rotated"; return value
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        try await cache.save(.init(bookURL: old.bookUrl, chapterURL: oldChapters[0].url, content: "离线正文", sourceID: old.origin))
        let repository: any BookRepository = fails ? FailingBookRepository(books: [old]) : InMemoryBookRepository(books: [old])
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: oldChapters])
        let model = BookLibraryModel(repository: repository, chapterRepository: directories, chapterCache: cache)
        await model.load()
        let succeeded = await model.commitPreparedUpdate(requestedBook: old,
            report: .init(book: replacement, chapters: chapters, addedChapterCount: 1))
        #expect(succeeded == !fails)
        #expect(model.books.first?.bookUrl == (fails ? old.bookUrl : replacement.bookUrl))
        #expect(try await repository.load() == model.books)
        #expect(await directories.load(bookURL: old.bookUrl) == (fails ? oldChapters : []))
        #expect(await directories.load(bookURL: replacement.bookUrl) == (fails ? [] : chapters))
        #expect(try await cache.load(bookURL: old.bookUrl, chapterURL: oldChapters[0].url)?.content == "离线正文")
        if !fails {
            #expect(model.books.first?.name == replacement.name)
            #expect(model.books.first?.variable == replacement.variable)
            #expect(try await cache.load(bookURL: replacement.bookUrl, chapterURL: chapters[0].url)?.content == "离线正文")
        }
    }

    @Test func preUpdateURLCollisionPreservesBothShelfRecords() async {
        let (old, chapters) = fixture()
        let other = Book(bookUrl: "occupied", name: "另一作品", origin: source.id)
        var changed = old; changed.bookUrl = other.bookUrl
        let repository = InMemoryBookRepository(books: [old, other])
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: chapters])
        let model = BookLibraryModel(repository: repository, chapterRepository: directories)
        await model.load()
        #expect(await model.commitPreparedUpdate(requestedBook: old, report: .init(book: changed, chapters: chapters, addedChapterCount: 0)) == false)
        #expect(model.books == [old, other])
        #expect(await repository.load() == [old, other])
        #expect(await directories.load(bookURL: old.bookUrl) == chapters)
        #expect(model.errorMessage?.contains("另一条书架记录") == true)
    }

    @Test func preparedMetadataRetainsLatestShelfProgressAndUserEdits() async {
        let (old, chapters) = fixture()
        let repository = InMemoryBookRepository(books: [old])
        let model = BookLibraryModel(repository: repository, chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        await model.updateProgress(for: old, chapter: chapters[1], position: 77)
        await model.setBook(old, groupIDs: [8])
        var prepared = old; prepared.name = "规则更名"; prepared.group = 4; prepared.bookUrl += "/new"
        let updated = chapters.map { chapter in var value = chapter; value.bookUrl = prepared.bookUrl; return value }
        #expect(await model.commitPreparedUpdate(requestedBook: old, report: .init(book: prepared, chapters: updated, addedChapterCount: 1)))
        #expect(model.books.first?.name == "规则更名")
        #expect(model.books.first?.group == 8)
        #expect(model.books.first?.durChapterIndex == 1)
        #expect(model.books.first?.durChapterPos == 77)
    }

    @Test func delayedOldSourceRefreshCannotOverwriteSameURLSourceSwitchDirectory() async {
        let (old, oldChapters) = fixture()
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: oldChapters])
        let repository = InMemoryBookRepository(books: [old])
        let loader = DelayedChapterLoader(chapters: oldChapters)
        let model = BookLibraryModel(repository: repository,
                                     updateCoordinator: .init(repository: directories, loader: loader),
                                     chapterRepository: directories)
        await model.load()
        let refresh = Task { await model.checkForUpdates(sources: [source]) }
        await loader.waitForRequest()
        var replacement = old
        replacement.origin = "new-source"
        replacement.durChapterPos = 42
        let newChapters = [BookChapter(url: "new/1", title: "新源章节", bookUrl: old.bookUrl, index: 0)]
        let switched = await model.commitSourceSwitch(oldBookURL: old.bookUrl,
            report: .init(book: replacement, chapters: newChapters, exactChapterMatch: true))
        #expect(switched)
        await loader.finish()
        await refresh.value
        #expect(model.books == [replacement])
        #expect(await repository.load() == [replacement])
        #expect(await directories.load(bookURL: old.bookUrl) == newChapters)
    }

    @Test(arguments: [false, true]) func failedSourceSwitchRestoresTargetDirectoryAndKeepsOriginalBook(sameURL: Bool) async {
        let (old, oldChapters) = fixture()
        var replacement = old
        replacement.origin = "new-source"
        if !sameURL { replacement.bookUrl += "/new" }
        let newChapters = [BookChapter(url: "new/1", title: "新章节", bookUrl: replacement.bookUrl, index: 0)]
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: oldChapters])
        let model = BookLibraryModel(repository: FailingBookRepository(books: [old]), chapterRepository: directories)
        await model.load()
        let succeeded = await model.commitSourceSwitch(oldBookURL: old.bookUrl,
            report: .init(book: replacement, chapters: newChapters, exactChapterMatch: true))
        #expect(!succeeded)
        #expect(model.books == [old])
        #expect(await directories.load(bookURL: old.bookUrl) == oldChapters)
        if !sameURL { #expect(await directories.load(bookURL: replacement.bookUrl).isEmpty) }
        #expect(model.errorMessage != nil)
    }

    @Test(arguments: [false, true]) func successfulSourceSwitchCommitsDirectoryBeforeRemovingOldCache(sameURL: Bool) async {
        let (old, oldChapters) = fixture()
        var replacement = old
        replacement.origin = "new-source"
        if !sameURL { replacement.bookUrl += "/new" }
        let newChapters = [BookChapter(url: "new/1", title: "新章节", bookUrl: replacement.bookUrl, index: 0)]
        let repository = InMemoryBookRepository(books: [old])
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: oldChapters])
        let model = BookLibraryModel(repository: repository, chapterRepository: directories)
        await model.load()
        let succeeded = await model.commitSourceSwitch(oldBookURL: old.bookUrl,
            report: .init(book: replacement, chapters: newChapters, exactChapterMatch: true))
        #expect(succeeded)
        #expect(await repository.load() == [replacement])
        #expect(model.books == [replacement])
        #expect(await directories.load(bookURL: replacement.bookUrl) == newChapters)
        if !sameURL { #expect(await directories.load(bookURL: old.bookUrl).isEmpty) }
    }

    @Test func failedSourceSwitchCannotLeakIntoConcurrentShelfSave() async {
        let (old, oldChapters) = fixture()
        var replacement = old
        replacement.origin = "new-source"
        let repository = SuspendedFailOnceBookRepository(books: [old])
        let directories = InMemoryBookChapterRepository(values: [old.bookUrl: oldChapters])
        let model = BookLibraryModel(repository: repository, chapterRepository: directories)
        await model.load()
        let commit = Task { await model.commitSourceSwitch(oldBookURL: old.bookUrl,
            report: .init(book: replacement, chapters: [.init(url: "new/1", title: "新章", bookUrl: old.bookUrl, index: 0)], exactChapterMatch: true)) }
        await repository.waitForSave()
        var groupStarted = false
        let group = Task { groupStarted = true; await model.setBook(old, groupIDs: [4]) }
        while !groupStarted { await Task.yield() }
        await repository.finishSave()
        #expect(await commit.value == false)
        await group.value
        #expect(model.books.first?.origin == old.origin)
        #expect(model.books.first?.group == 4)
        #expect(await repository.load() == model.books)
        #expect(await directories.load(bookURL: old.bookUrl) == oldChapters)
    }

    @Test func sourceSwitchReportsFailureWhenRollbackAlsoFails() async {
        let (old, chapters) = fixture()
        let directory = FailingSourceSwitchRestoreRepository(chapters: chapters)
        let model = BookLibraryModel(repository: FailingBookRepository(books: [old]), chapterRepository: directory)
        await model.load()
        let succeeded = await model.commitSourceSwitch(oldBookURL: old.bookUrl,
            report: .init(book: old, chapters: [.init(url: "new/1", title: "新章", bookUrl: old.bookUrl, index: 0)], exactChapterMatch: true))
        #expect(!succeeded)
        #expect(model.books == [old])
        #expect(model.errorMessage?.contains("原目录恢复也失败") == true)
    }

    @Test func staleReloadCannotOverwriteNewProgressOrGroupOptions() async {
        let (old, chapters) = fixture()
        let group = BookGroup(groupId: 4, groupName: "分组")
        let books = DelayedReloadBookRepository(books: [old])
        let groups = DelayedReloadGroupRepository(groups: [group])
        let model = BookLibraryModel(repository: books, groupRepository: groups)
        await model.load()
        let reload = Task { await model.load() }
        await books.waitForReload()
        await groups.waitForReload()
        await model.updateProgress(for: old, chapter: chapters[1], position: 84)
        await model.setGroupSort(group, sort: BookshelfSort.author.rawValue)
        await books.finishReload()
        await groups.finishReload()
        await reload.value
        #expect(model.books.first?.durChapterPos == 84)
        #expect(model.groups.first?.bookSort == BookshelfSort.author.rawValue)
        #expect(await books.load() == model.books)
        #expect(await groups.load() == model.groups)
    }

    @Test func earlierReloadCannotReplaceLaterLoadResult() async {
        let (old, _) = fixture()
        let repository = DelayedReloadBookRepository(books: [old])
        let model = BookLibraryModel(repository: repository)
        await model.load()
        let earlier = Task { await model.load() }
        await repository.waitForReload()
        var changed = old
        changed.name = "新载入的数据"
        await repository.save([changed])
        await model.load()
        await repository.finishReload()
        await earlier.value
        #expect(model.books == [changed])
    }

    @Test func onlyReadUpdateMeansNoUnreadChaptersIncludingZeroAndOneChapterBooks() async {
        var caughtUp = fixture().0
        caughtUp.bookUrl += "/caught-up"
        caughtUp.durChapterIndex = 1
        var stillReading = fixture().0
        stillReading.bookUrl += "/unread"
        stillReading.durChapterTime = 123
        var oneChapter = fixture().0
        oneChapter.bookUrl += "/one"
        oneChapter.totalChapterNum = 1
        var noChapters = fixture().0
        noChapters.bookUrl += "/empty"
        noChapters.totalChapterNum = 0
        let loader = RecordingShelfChapterLoader()
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [caughtUp, stillReading, oneChapter, noChapters]),
                                     updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: loader),
                                     chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        await model.checkForUpdates(sources: [source], onlyRead: true)
        #expect(Set(await loader.requestedURLs) == Set([caughtUp.bookUrl, oneChapter.bookUrl, noChapters.bookUrl]))
    }

    @Test func groupUpdateHonorsMembershipAndCaughtUpSetting() async {
        var caughtUp = fixture().0
        caughtUp.bookUrl += "/group"
        caughtUp.group = 4
        caughtUp.durChapterIndex = 1
        var stillReading = caughtUp
        stillReading.bookUrl += "/unread"
        stillReading.durChapterIndex = 0
        var other = caughtUp
        other.bookUrl += "/other"
        other.group = 8
        var local = caughtUp
        local.bookUrl += "/local"
        local.origin = "local"
        var disabled = caughtUp
        disabled.bookUrl += "/disabled"
        disabled.canUpdate = false
        let group = BookGroup(groupId: 4, groupName: "追更", onlyUpdateRead: true)
        let loader = RecordingShelfChapterLoader()
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [caughtUp, stillReading, other, local, disabled]),
                                     updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: loader),
                                     chapterRepository: InMemoryBookChapterRepository(),
                                     groupRepository: InMemoryBookGroupRepository(groups: [group]))
        await model.load()
        await model.checkForUpdates(sources: [source], group: group)
        #expect(await loader.requestedURLs == [caughtUp.bookUrl])
    }

    @Test func failedShelfSaveIsNotReportedAsSuccessfulUpdate() async {
        let (book, _) = fixture()
        let model = BookLibraryModel(repository: FailingBookRepository(books: [book]),
                                     updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: RecordingShelfChapterLoader()),
                                     chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        await model.checkForUpdates(sources: [source])
        #expect(model.books == [book])
        #expect(model.updateMessage?.contains("1 本因") == true)
        #expect(model.updateMessage?.contains("发现 0 个新章节") == true)
        #expect(model.errorMessage != nil)
    }

    @Test func cancelledShelfRefreshDoesNotStartRemainingBooks() async {
        let (book, chapters) = fixture()
        var other = book
        other.bookUrl += "/other"
        let loader = DelayedChapterLoader(chapters: chapters)
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [book, other]),
                                     updateCoordinator: .init(repository: InMemoryBookChapterRepository(), loader: loader),
                                     chapterRepository: InMemoryBookChapterRepository())
        await model.load()
        let update = Task { await model.checkForUpdates(sources: [source]) }
        await loader.waitForRequest()
        update.cancel()
        await loader.finish()
        await update.value
        #expect(model.books == [book, other])
        #expect(model.updateMessage?.hasPrefix("更新已取消") == true)
        #expect(!model.isCheckingUpdates)
    }

    @Test func groupSortingSupportsEveryAndroidModeAndGlobalFallback() async {
        var first = Book(bookUrl: "a", name: "乙", author: "张三")
        first.durChapterTime = 3; first.latestChapterTime = 1; first.order = 2
        var second = Book(bookUrl: "b", name: "丙", author: "李四")
        second.durChapterTime = 2; second.latestChapterTime = 4; second.order = 0
        var third = Book(bookUrl: "c", name: "甲", author: "王五")
        third.durChapterTime = 1; third.latestChapterTime = 2; third.order = 1
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [first, second, third]))
        await model.load()
        var group = BookGroup(groupId: BookGroup.idAll, groupName: "全部")
        let expected: [(BookshelfSort, [String])] = [
            (.recentRead, ["a", "b", "c"]), (.recentUpdate, ["b", "c", "a"]),
            (.name, ["b", "c", "a"]), (.custom, ["b", "c", "a"]),
            (.recentReadOrUpdate, ["b", "a", "c"]), (.author, ["b", "c", "a"])
        ]
        for (sort, ids) in expected {
            group.bookSort = sort.rawValue
            #expect(model.books(in: group).map(\.id) == ids)
        }
        group.bookSort = -1
        #expect(model.books(in: group, defaultSort: BookshelfSort.custom.rawValue).map(\.id) == ["b", "c", "a"])
    }

    @Test func groupOptionsPersistAndFailedWriteRollsBack() async {
        let group = BookGroup(groupId: 4, groupName: "分组")
        let repository = InMemoryBookGroupRepository(groups: [group])
        let model = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: repository)
        await model.load()
        await model.setGroupSort(group, sort: BookshelfSort.author.rawValue)
        await model.setGroupRefreshEnabled(group, enabled: false)
        await model.setGroupOnlyUpdateRead(group, enabled: true)
        let stored = await repository.load()
        #expect(stored.first?.bookSort == BookshelfSort.author.rawValue)
        #expect(stored.first?.enableRefresh == false)
        #expect(stored.first?.onlyUpdateRead == true)
        let reloaded = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: repository)
        await reloaded.load()
        #expect(reloaded.groups == stored)

        let failed = BookLibraryModel(repository: InMemoryBookRepository(), groupRepository: FailingGroupRepository(groups: [group]))
        await failed.load()
        await failed.setGroupSort(group, sort: 4)
        await failed.setGroupRefreshEnabled(group, enabled: false)
        await failed.setGroupOnlyUpdateRead(group, enabled: true)
        #expect(failed.groups == [group])
        #expect(failed.errorMessage != nil)
    }

    @Test func reorderWithinGroupKeepsOtherBooksAndPersistsGlobalCustomOrder() async {
        let group = BookGroup(groupId: 4, groupName: "分组", bookSort: BookshelfSort.custom.rawValue)
        let values = (0..<4).map { index in
            var book = Book(bookUrl: "\(index)", name: "书\(index)")
            book.group = index.isMultiple(of: 2) ? 4 : 8
            book.order = index
            return book
        }
        let repository = InMemoryBookRepository(books: values)
        let model = BookLibraryModel(repository: repository, groupRepository: InMemoryBookGroupRepository(groups: [group]))
        await model.load()
        await model.moveBooks(in: group, from: IndexSet(integer: 0), to: 2)
        #expect(model.books(in: group).map(\.id) == ["2", "0"])
        #expect(model.books.sorted { $0.order < $1.order }.map(\.id) == ["2", "1", "0", "3"])
        #expect(await repository.load() == model.books)
    }

    @Test func ungroupedBooksIgnoreMembershipBitsWithoutCurrentGroups() async {
        var book = fixture().0
        book.group = 8
        let current = BookGroup(groupId: 4, groupName: "当前分组")
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: [book]),
                                     groupRepository: InMemoryBookGroupRepository(groups: [current]))
        await model.load()
        #expect(model.books(in: .init(groupId: BookGroup.idNetNone, groupName: "未分组")) == [book])
    }

    @Test func directoryRefreshPreservesConcurrentReadingAndGroupChanges() async throws {
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

        let succeeded = await model.replace(oldBookURL: book.bookUrl, with: replacement)

        #expect(!succeeded)
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

private actor RecordingShelfChapterLoader: ChapterListLoading {
    private(set) var requestedURLs: [String] = []
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
        requestedURLs.append(book.bookUrl)
        return .init(chapters: (0..<3).map { BookChapter(url: "\(book.bookUrl)/\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) })
    }
}

private actor SuspendedFailOnceBookRepository: BookRepository {
    private var books: [Book]
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    init(books: [Book]) { self.books = books }
    func load() -> [Book] { books }
    func save(_ books: [Book]) async throws {
        if !started {
            started = true
            await withCheckedContinuation { pending = $0 }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        self.books = books
    }
    func waitForSave() async { while !started { await Task.yield() } }
    func finishSave() { pending?.resume(); pending = nil }
}

private actor FailingSourceSwitchRestoreRepository: BookChapterRepository {
    private var chapters: [BookChapter]
    private var saves = 0
    init(chapters: [BookChapter]) { self.chapters = chapters }
    func load(bookURL: String) -> [BookChapter] { chapters }
    func save(_ chapters: [BookChapter], bookURL: String) throws {
        saves += 1
        if saves > 1 { throw CocoaError(.fileWriteNoPermission) }
        self.chapters = chapters
    }
    func remove(bookURL: String) { chapters = [] }
}

private actor DelayedReloadBookRepository: BookRepository {
    private var books: [Book]
    private var loads = 0
    private var pending: CheckedContinuation<Void, Never>?
    init(books: [Book]) { self.books = books }
    func load() async -> [Book] {
        loads += 1
        let snapshot = books
        if loads == 2 { await withCheckedContinuation { pending = $0 } }
        return snapshot
    }
    func save(_ books: [Book]) { self.books = books }
    func waitForReload() async { while pending == nil { await Task.yield() } }
    func finishReload() { pending?.resume(); pending = nil }
}

private actor DelayedReloadGroupRepository: BookGroupRepository {
    private var groups: [BookGroup]
    private var loads = 0
    private var pending: CheckedContinuation<Void, Never>?
    init(groups: [BookGroup]) { self.groups = groups }
    func load() async -> [BookGroup] {
        loads += 1
        let snapshot = groups
        if loads == 2 { await withCheckedContinuation { pending = $0 } }
        return snapshot
    }
    func save(_ groups: [BookGroup]) { self.groups = groups }
    func waitForReload() async { while pending == nil { await Task.yield() } }
    func finishReload() { pending?.resume(); pending = nil }
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
