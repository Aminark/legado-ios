import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

final class LocalBookImportFile: @unchecked Sendable {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

private struct BookDirectoryRestoreError: LocalizedError {
    let saveError: String
    let restoreError: String
    var errorDescription: String? {
        "书籍与目录保存失败：\(saveError)。原目录恢复也失败：\(restoreError)。请重新加载原书源目录。"
    }
}

enum AppBookChapterRepository {
    static func live() -> any BookChapterRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return FileBookChapterRepository.live()
        }
        return SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
    }
}

enum BookshelfSort: Int, CaseIterable, Identifiable {
    case recentRead = 0, recentUpdate, name, custom, recentReadOrUpdate, author

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .recentRead: "最近阅读"
        case .recentUpdate: "最近更新"
        case .name: "书名"
        case .custom: "自定义顺序"
        case .recentReadOrUpdate: "阅读或更新"
        case .author: "作者"
        }
    }
}

@MainActor
final class BookLibraryModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var groups: [BookGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var updateMessage: String?
    @Published private(set) var isCheckingUpdates = false

    private let repository: any BookRepository
    private let localDirectory: URL
    let localFiles: LocalFileService
    private let localService = LocalBookService.live()
    private let txtTocRuleRepository: SQLiteConfigurationRepository?
    private let updateCoordinator: BookUpdateCoordinator
    private let chapterRepository: any BookChapterRepository
    private let chapterCache: ChapterContentCache
    private let groupRepository: any BookGroupRepository
    private let pendingProgressKey = "pendingBookReadingProgress"
    private let progressDefaults: UserDefaults
    private var pendingProgress: [String: BookProgress]
    private var bookSaveTask: Task<Bool, Never>?
    private var bookSaveGeneration = 0
    private var persistedBooks: [Book] = []
    private var groupSaveTask: Task<Bool, Never>?
    private var groupSaveGeneration = 0
    private var persistedGroups: [BookGroup] = []
    private var deletingGroupIDs: Set<Int64> = []
    private var sourceSwitchSaveTask: Task<Bool, Never>?
    private var loadGeneration = 0

    init(
        repository: any BookRepository,
        localDirectory: URL? = nil,
        updateCoordinator: BookUpdateCoordinator = .init(),
        chapterRepository: any BookChapterRepository = FileBookChapterRepository.live(),
        groupRepository: any BookGroupRepository = InMemoryBookGroupRepository(),
        chapterCache: ChapterContentCache = .live(),
        progressDefaults: UserDefaults = .standard,
        txtTocRuleRepository: SQLiteConfigurationRepository? = nil
    ) {
        self.repository = repository
        self.localDirectory = localDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("LegadoLocalBooks")
        localFiles = LocalFileService(directory: self.localDirectory)
        self.updateCoordinator = updateCoordinator
        self.chapterRepository = chapterRepository
        self.chapterCache = chapterCache
        self.groupRepository = groupRepository
        self.progressDefaults = progressDefaults
        self.txtTocRuleRepository = txtTocRuleRepository
        pendingProgress = (progressDefaults.data(forKey: pendingProgressKey)
            .flatMap { try? JSONDecoder().decode([String: BookProgress].self, from: $0) }) ?? [:]
    }

    static func live() -> BookLibraryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        let legacyBooks = base.appendingPathComponent("books.json")
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return BookLibraryModel(
                repository: FileBookRepository(fileURL: legacyBooks),
                localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
                groupRepository: FileBookGroupRepository(fileURL: base.appendingPathComponent("book-groups.json"))
            )
        }
        let chapters = SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
        return BookLibraryModel(
            repository: SQLiteBookRepository(database: database, legacyFileURL: legacyBooks),
            localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
            updateCoordinator: BookUpdateCoordinator(repository: chapters),
            chapterRepository: chapters,
            groupRepository: SQLiteBookGroupRepository(
                database: database,
                legacyFileURL: base.appendingPathComponent("book-groups.json")
            ),
            txtTocRuleRepository: SQLiteConfigurationRepository(database: database)
        )
    }

    static func demo(books: [Book]) -> BookLibraryModel {
        BookLibraryModel(repository: InMemoryBookRepository(books: books))
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let booksGeneration = bookSaveGeneration
        let groupsGeneration = groupSaveGeneration
        await waitForSourceSwitch()
        _ = await bookSaveTask?.value
        _ = await groupSaveTask?.value
        guard generation == loadGeneration, !Task.isCancelled else { return }
        do {
            async let storedBooks = repository.load()
            async let storedGroups = groupRepository.load()
            let loadedBooks = try await storedBooks
            let loadedGroups = try await storedGroups
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if booksGeneration == bookSaveGeneration, sourceSwitchSaveTask == nil {
                books = loadedBooks
                persistedBooks = loadedBooks
            }
            if groupsGeneration == groupSaveGeneration {
                groups = loadedGroups
                persistedGroups = loadedGroups
                if groups.isEmpty {
                    await persistGroups([.init(groupId: BookGroup.idAll, groupName: "全部", order: 0)])
                }
            }
            for book in books where book.origin == "local" && book.coverUrl?.isEmpty != false {
                guard !Task.isCancelled, let url = URL(string: book.bookUrl),
                      url.isFileURL, url.pathExtension.lowercased() == "epub" else { continue }
                if let cover = try? await Task.detached(priority: .utility, operation: { [localService] in
                    try localService.loadCover(at: url)
                }).value {
                    await restoreLocalCover(for: book, dataURL: "data:image/png;base64,\(cover.base64EncodedString())")
                }
            }
        } catch {
            if generation == loadGeneration, booksGeneration == bookSaveGeneration, groupsGeneration == groupSaveGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func contains(_ book: Book) -> Bool {
        books.contains { $0.bookUrl == book.bookUrl }
    }

    /// A reader holds a snapshot. Save only the setting it changed, retaining
    /// current shelf metadata/progress and leaving unshelved previews unshelved.
    @discardableResult
    func updateReadConfig(for book: Book, _ change: (inout BookReadConfig) -> Void) async -> Bool {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl && $0.origin == book.origin }) else { return false }
        var updated = books
        var config = updated[index].readConfig ?? BookReadConfig()
        change(&config)
        updated[index].readConfig = config
        return await persist(updated)
    }

    @discardableResult
    func addOrUpdate(_ book: Book) async -> Bool {
        await waitForSourceSwitch()
        var book = book
        if let existing = books.first(where: { $0.bookUrl == book.bookUrl }),
           existing.durChapterTime > book.durChapterTime {
            applyProgress(BookProgress(book: existing), to: &book)
        }
        let pending = pendingProgress[book.bookUrl]
        if let pending {
            if pending.durChapterTime > book.durChapterTime {
                applyProgress(pending, to: &book)
            }
        }
        var updated = books
        if let index = updated.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            updated[index] = book
        } else {
            updated.append(book)
        }
        let succeeded = await persist(updated)
        if succeeded, let pending, pendingProgress[book.bookUrl] == pending {
            pendingProgress[book.bookUrl] = nil
            persistPendingProgress()
        }
        return succeeded
    }

    @discardableResult
    func replace(oldBookURL: String, with book: Book) async -> Bool {
        await waitForSourceSwitch()
        guard books.contains(where: { $0.bookUrl == oldBookURL }) else {
            return await addOrUpdate(book)
        }
        var updated = books.filter { $0.bookUrl == oldBookURL || $0.bookUrl != book.bookUrl }
        guard let index = updated.firstIndex(where: { $0.bookUrl == oldBookURL }) else { return false }
        updated[index] = book
        let succeeded = await persist(updated)
        if succeeded, oldBookURL != book.bookUrl {
            await cleanupRemovedBooks([oldBookURL])
        }
        return succeeded
    }

    /// Commit only after validation. Keep other shelf mutations outside the
    /// commit so a failed optimistic snapshot cannot leak into a later save.
    func commitSourceSwitch(oldBookURL: String, report: BookSourceSwitchReport) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard books.contains(where: { $0.bookUrl == oldBookURL }), !report.chapters.isEmpty else { return false }
            var updated = books.filter { $0.bookUrl == oldBookURL || $0.bookUrl != report.book.bookUrl }
            guard let index = updated.firstIndex(where: { $0.bookUrl == oldBookURL }) else { return false }
            updated[index] = report.book
            let snapshot = updated
            let succeeded = await persist(snapshot) {
                try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: report.book.bookUrl,
                                                     repository: repository, chapterRepository: chapterRepository)
            }
            if succeeded, oldBookURL != report.book.bookUrl { await cleanupRemovedBooks([oldBookURL]) }
            return succeeded
        }
        sourceSwitchSaveTask = save
        return await save.value
    }

    private nonisolated static func writeBooksAndChapters(
        _ books: [Book], chapters: [BookChapter], bookURL: String,
        repository: any BookRepository, chapterRepository: any BookChapterRepository
    ) async throws {
        if let atomic = repository as? any SourceSwitchBookRepository {
            try await atomic.saveSourceSwitch(books, chapters: chapters, bookURL: bookURL)
            return
        }
        let previous = try await chapterRepository.load(bookURL: bookURL)
        do {
            try await chapterRepository.save(chapters, bookURL: bookURL)
            try await repository.save(books)
        } catch {
            let saveError = error
            do {
                try await chapterRepository.save(previous, bookURL: bookURL)
            } catch {
                let failure = BookDirectoryRestoreError(saveError: saveError.localizedDescription, restoreError: error.localizedDescription)
                DiagnosticLog.shared.record(.error, category: "存储", message: failure.localizedDescription)
                throw failure
            }
            throw saveError
        }
    }

    private func waitForSourceSwitch() async {
        while let save = sourceSwitchSaveTask { _ = await save.value }
    }

    func updateProgress(for book: Book, chapter: BookChapter, position: Int = 0, epubLocation: String? = nil) async {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else {
            var reading = book
            if epubLocation != nil, reading.readConfig == nil { reading.readConfig = BookReadConfig() }
            reading.readConfig?.epubLocation = epubLocation
            reading.durChapterIndex = chapter.index
            reading.durChapterTitle = chapter.title
            reading.durChapterPos = max(position, 0)
            reading.durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
            pendingProgress[book.bookUrl] = BookProgress(book: reading)
            persistPendingProgress()
            return
        }
        var updated = books
        if epubLocation != nil, updated[index].readConfig == nil { updated[index].readConfig = BookReadConfig() }
        updated[index].readConfig?.epubLocation = epubLocation
        updated[index].durChapterIndex = chapter.index
        updated[index].durChapterTitle = chapter.title
        updated[index].durChapterPos = max(position, 0)
        updated[index].durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
        updated[index].lastCheckCount = 0
        updated[index].totalChapterNum = max(updated[index].totalChapterNum, chapter.index + 1)
        await persist(updated)
    }

    private func applyProgress(_ progress: BookProgress, to book: inout Book) {
        if progress.epubLocation != nil, book.readConfig == nil { book.readConfig = BookReadConfig() }
        book.readConfig?.epubLocation = progress.epubLocation
        book.durChapterIndex = progress.durChapterIndex
        book.durChapterTitle = progress.durChapterTitle
        book.durChapterPos = progress.durChapterPos
        book.durChapterTime = progress.durChapterTime
    }

    func restoreLocalCover(for book: Book, dataURL: String) async {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }),
              books[index].origin == "local", books[index].coverUrl?.isEmpty != false else { return }
        var updated = books
        updated[index].coverUrl = dataURL
        await persist(updated)
    }

    private func persistPendingProgress() {
        if pendingProgress.isEmpty {
            progressDefaults.removeObject(forKey: pendingProgressKey)
        } else if let data = try? JSONEncoder().encode(pendingProgress) {
            progressDefaults.set(data, forKey: pendingProgressKey)
        }
    }

    func checkForUpdates(sources: [BookSource], onlyRead: Bool = false, group: BookGroup? = nil) async {
        await waitForSourceSwitch()
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateMessage = nil
        defer { isCheckingUpdates = false }

        let sourceByURL = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, latest in latest })
        let onlyCaughtUp = group?.onlyUpdateRead ?? onlyRead
        let candidates = group.map { books(in: $0) } ?? books
        let requestedBooks = candidates.filter {
            $0.canUpdate && $0.origin != "local"
                && (!onlyCaughtUp || $0.durChapterIndex >= max($0.totalChapterNum, 1) - 1)
        }
        var checked = 0
        var added = 0
        var failed = 0
        for requestedBook in requestedBooks {
            guard !Task.isCancelled else { break }
            guard let source = sourceByURL[requestedBook.origin], source.enabled else {
                failed += 1
                continue
            }
            let report = await updateCoordinator.refresh(book: requestedBook, source: source, persistDirectory: false)
            await waitForSourceSwitch()
            guard !Task.isCancelled else { break }
            checked += 1
            if report.refreshed {
                // Network requests suspend this actor. Merge the new directory
                // into the current shelf, including any progress or edits made
                // while the request was running, and never resurrect removals.
                guard books.contains(where: {
                    $0.bookUrl == requestedBook.bookUrl && $0.origin == requestedBook.origin
                }) else { continue }
                let succeeded = await commitPreparedUpdate(requestedBook: requestedBook, report: report)
                if succeeded { added += report.addedChapterCount }
                else { failed += 1 }
            } else {
                failed += 1
            }
        }

        if Task.isCancelled {
            updateMessage = "更新已取消，已检查 \(checked) 本，发现 \(added) 个新章节。"
        } else if checked == 0 && failed == 0 {
            updateMessage = "书架里暂时没有可更新的网络书籍。"
        } else if failed > 0 {
            updateMessage = "已检查 \(checked) 本，发现 \(added) 个新章节；另有 \(failed) 本因书源不可用、解析或保存失败未更新。"
        } else {
            updateMessage = added > 0 ? "更新完成，共发现 \(added) 个新章节。" : "更新完成，已是最新目录。"
        }
    }

    func commitPreparedUpdate(requestedBook: Book, report: BookUpdateReport) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository, chapterCache] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard let index = books.firstIndex(where: {
                $0.bookUrl == requestedBook.bookUrl && $0.origin == requestedBook.origin
            }) else { return false }
            if report.book.bookUrl != requestedBook.bookUrl,
               books.contains(where: { $0.bookUrl == report.book.bookUrl }) {
                errorMessage = "更新前脚本返回的书籍地址已属于另一条书架记录，已保留原书籍。"
                return false
            }
            let merger = BookUpdateMerger()
            let prepared = merger.applyingPreparation(original: requestedBook, current: books[index], prepared: report.book)
            let oldChapters: [BookChapter]
            do { oldChapters = try await chapterRepository.load(bookURL: requestedBook.bookUrl) }
            catch { errorMessage = error.localizedDescription; return false }
            guard !Task.isCancelled else { return false }
            var updated = books
            updated[index] = merger.merge(book: prepared, oldChapters: [], newChapters: report.chapters,
                                           now: report.book.lastCheckTime).book
            let replacement = updated[index]
            let snapshot = updated
            let succeeded = await persist(snapshot) {
                if requestedBook.bookUrl != replacement.bookUrl {
                    try await chapterCache.copyContents(from: requestedBook, chapters: oldChapters,
                                                        to: replacement, chapters: report.chapters)
                }
                try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: replacement.bookUrl,
                                                     repository: repository, chapterRepository: chapterRepository)
            }
            if succeeded, requestedBook.bookUrl != replacement.bookUrl {
                await cleanupRemovedBooks([requestedBook.bookUrl])
            }
            return succeeded
        }
        sourceSwitchSaveTask = save
        return await withTaskCancellationHandler { await save.value } onCancel: { save.cancel() }
    }

    func remove(at offsets: IndexSet) async {
        await waitForSourceSwitch()
        var updated = books
        updated.remove(atOffsets: offsets)
        let removed = Set(books.map(\.bookUrl)).subtracting(updated.map(\.bookUrl))
        if await persist(updated) { await cleanupRemovedBooks(removed) }
    }

    var visibleGroups: [BookGroup] {
        groups.filter(\.show).sorted {
            $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order
        }
    }

    func books(in group: BookGroup, defaultSort: Int = BookshelfSort.recentRead.rawValue) -> [Book] {
        let filtered: [Book]
        let customMask = groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
        switch group.groupId {
        case BookGroup.idAll: filtered = books
        case BookGroup.idLocal: filtered = books.filter { $0.origin == "local" }
        case BookGroup.idNetNone: filtered = books.filter { $0.origin != "local" && $0.group & customMask == 0 }
        case BookGroup.idLocalNone: filtered = books.filter { $0.origin == "local" && $0.group & customMask == 0 }
        default:
            filtered = group.groupId > 0
                ? books.filter { ($0.group & group.groupId) != 0 }
                : books
        }
        let sort = BookshelfSort(rawValue: group.bookSort < 0 ? defaultSort : group.bookSort) ?? .recentRead
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recentRead: return lhs.durChapterTime > rhs.durChapterTime
            case .recentUpdate: return lhs.latestChapterTime > rhs.latestChapterTime
            case .name:
                return lhs.name.compare(rhs.name, locale: Locale(identifier: "zh_CN")) == .orderedAscending
            case .custom: return lhs.order < rhs.order
            case .recentReadOrUpdate:
                return max(lhs.latestChapterTime, lhs.durChapterTime) > max(rhs.latestChapterTime, rhs.durChapterTime)
            case .author:
                return lhs.author.compare(rhs.author, locale: Locale(identifier: "zh_CN")) == .orderedAscending
            }
        }
    }

    func setGroupSort(_ group: BookGroup, sort: Int) async {
        guard sort == -1 || BookshelfSort(rawValue: sort) != nil else { return }
        await updateGroup(group) { $0.bookSort = sort }
    }

    func setGroupRefreshEnabled(_ group: BookGroup, enabled: Bool) async {
        await updateGroup(group) { $0.enableRefresh = enabled }
    }

    func setGroupOnlyUpdateRead(_ group: BookGroup, enabled: Bool) async {
        await updateGroup(group) { $0.onlyUpdateRead = enabled }
    }

    private func updateGroup(_ group: BookGroup, change: (inout BookGroup) -> Void) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        change(&updated[index])
        await persistGroups(updated)
    }

    func moveBooks(in group: BookGroup, from offsets: IndexSet, to destination: Int) async {
        await waitForSourceSwitch()
        let memberIDs = Set(books(in: group).map(\.id))
        var ordered = books.sorted { $0.order < $1.order }
        let slots = ordered.indices.filter { memberIDs.contains(ordered[$0].id) }
        guard offsets.allSatisfy({ slots.indices.contains($0) }), (0...slots.count).contains(destination) else { return }
        var members = slots.map { ordered[$0] }
        members.move(fromOffsets: offsets, toOffset: destination)
        for (index, slot) in slots.enumerated() { ordered[slot] = members[index] }
        for index in ordered.indices { ordered[index].order = index }
        await persist(ordered)
    }

    func createGroup(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(where: { $0.groupName == name }) else { return }
        let used = groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
            | books.reduce(Int64(0)) { $0 | $1.group }
            | deletingGroupIDs.reduce(Int64(0), |)
        guard let nextID = (0..<63).map({ Int64(1) << $0 }).first(where: { used & $0 == 0 }) else {
            errorMessage = "自定义分组已达到上限（63 个），请先删除不再使用的分组。"
            return
        }
        await persistGroups(groups + [.init(groupId: nextID, groupName: name, order: groups.count)])
    }

    func renameGroup(_ group: BookGroup, name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].groupName = name
        await persistGroups(updated)
    }

    func setGroupVisible(_ group: BookGroup, visible: Bool) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].show = visible
        await persistGroups(updated)
    }

    func moveGroups(from offsets: IndexSet, to destination: Int) async {
        var editable = groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
        editable.move(fromOffsets: offsets, toOffset: destination)
        var updated = groups
        for (order, group) in editable.enumerated() {
            if let index = updated.firstIndex(where: { $0.id == group.id }) {
                updated[index].order = order + 1
            }
        }
        await persistGroups(updated)
    }

    func deleteGroup(_ group: BookGroup) async {
        guard group.groupId > 0, !deletingGroupIDs.contains(group.id),
              let stored = groups.first(where: { $0.id == group.id }) else { return }
        deletingGroupIDs.insert(group.id)
        defer { deletingGroupIDs.remove(group.id) }
        guard await persistGroups(groups.filter { $0.id != group.id }) else { return }
        await waitForSourceSwitch()
        var updated = books
        for index in updated.indices { updated[index].group &= ~group.groupId }
        if !(await persist(updated)) {
            let saveError = errorMessage
            await persistGroups(groups + [stored])
            errorMessage = saveError
        }
    }

    func setBook(_ book: Book, in group: BookGroup, included: Bool) async {
        await waitForSourceSwitch()
        guard group.groupId > 0, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var updated = books
        if included { updated[index].group |= group.groupId }
        else { updated[index].group &= ~group.groupId }
        await persist(updated)
    }

    func setBook(_ book: Book, groupIDs: Set<Int64>) async {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        let customMask = groups.reduce(Int64(0)) { value, group in
            group.groupId > 0 ? value | group.groupId : value
        }
        let selectedMask = groupIDs.reduce(Int64(0), |)
        var updated = books
        updated[index].group = (updated[index].group & ~customMask) | selectedMask
        await persist(updated)
    }

    func remove(bookURL: String) async {
        await waitForSourceSwitch()
        if await persist(books.filter { $0.bookUrl != bookURL }) {
            await cleanupRemovedBooks([bookURL])
        }
    }

    private func cleanupRemovedBooks(_ urls: Set<String>) async {
        for url in urls where !books.contains(where: { $0.bookUrl == url }) {
            pendingProgress[url] = nil
            try? await chapterRepository.remove(bookURL: url)
        }
        persistPendingProgress()
    }

    func importLocalFiles(_ urls: [URL]) async {
        await importPickedLocalFiles(urls.map { LocalBookImportFile(url: $0) })
    }

    func importPickedLocalFiles(_ files: [LocalBookImportFile]) async {
        // Keep the picker grants alive through the review and asynchronous copy.
        defer { withExtendedLifetime(files) {} }
        var failures: [String] = []
        for file in files {
            let url = file.url
            do {
                let stored = try await localFiles.importFile(from: url)
                do {
                    try await addLocalFile(at: stored)
                } catch {
                    if let staged = try? await localFiles.stageRemoval(stored) {
                        try? await localFiles.finishRemoval(staged)
                    }
                    throw error
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func addLocalFile(at url: URL) async throws {
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        let service: LocalBookService
        if let txtTocRuleRepository {
            service = try await localService.usingStoredTocRules(from: txtTocRuleRepository)
        } else { service = localService }
        let report = try await Task.detached { try service.openFile(at: url) }.value
        await waitForSourceSwitch()
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        guard await persist(books + [report.book]) else {
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
    }

    func localTocRules() async throws -> [TxtTocRule] {
        if let txtTocRuleRepository {
            return try await txtTocRuleRepository.loadTxtTocRules(initialDefaults: localService.tocRules)
                .filter(\.enable).sorted { $0.serialNumber < $1.serialNumber }
        }
        return localService.tocRules
    }

    /// Rebuild and commit on the same local identity. The barrier also protects
    /// reading progress and file renames while byte offsets are being mapped.
    func rebuildLocalBook(bookURL: String, rule: TxtTocRule?, splitLongChapter: Bool) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository, chapterCache] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard let index = books.firstIndex(where: { $0.bookUrl == bookURL && $0.origin == "local" }) else {
                errorMessage = "本地书已不在书架中，请重新打开。"
                return false
            }
            let current = books[index]
            do {
                try Task.checkCancellation()
                let service: LocalBookService
                if let txtTocRuleRepository {
                    service = try await localService.usingStoredTocRules(from: txtTocRuleRepository)
                } else { service = localService }
                let stored = try await chapterRepository.load(bookURL: bookURL)
                let parsing = Task.detached {
                    let previous = stored.isEmpty ? try service.loadChapters(book: current).chapters : stored
                    return try service.rebuildTextFile(book: current, rule: rule, splitLongChapter: splitLongChapter,
                                                       previousChapters: previous)
                }
                let report = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
                try Task.checkCancellation()
                var updated = books
                updated[index] = report.book
                let snapshot = updated
                let succeeded = await persist(snapshot) {
                    try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: bookURL,
                                                         repository: repository, chapterRepository: chapterRepository)
                }
                if succeeded {
                    // Only derived chapter content for this identity is stale;
                    // the original file and bookmarks are never removed.
                    do { try await chapterCache.remove(bookURL: bookURL) }
                    catch { DiagnosticLog.shared.record(.warning, category: "本地书", message: "目录已重建，旧正文缓存清理失败：\(error.localizedDescription)") }
                }
                return succeeded
            } catch is CancellationError {
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        sourceSwitchSaveTask = save
        return await withTaskCancellationHandler { await save.value } onCancel: { save.cancel() }
    }

    func renameLocalFile(at url: URL, to name: String) async throws {
        await waitForSourceSwitch()
        let target = try await localFiles.rename(url, to: name)
        guard target != url else { return }
        await waitForSourceSwitch()
        var updated = books
        for index in updated.indices where updated[index].origin == "local" && updated[index].bookUrl == url.absoluteString {
            updated[index].bookUrl = target.absoluteString
            updated[index].originName = target.lastPathComponent
        }
        guard await persist(updated) else {
            _ = try await localFiles.rename(target, to: url.lastPathComponent)
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        if let progress = pendingProgress.removeValue(forKey: url.absoluteString) {
            pendingProgress[target.absoluteString] = progress
            persistPendingProgress()
        }
        try? await chapterRepository.remove(bookURL: url.absoluteString)
    }

    func deleteLocalFile(at url: URL) async throws {
        await waitForSourceSwitch()
        let staged: StagedLocalFile?
        if url.isFileURL,
           books.contains(where: { $0.origin == "local" && $0.bookUrl == url.absoluteString }),
           !FileManager.default.fileExists(atPath: url.path) {
            // Stale shelf paths can belong to a previous app container. Only
            // remove their metadata; existing files still require containment.
            staged = nil
        } else {
            staged = try await localFiles.stageRemoval(url)
        }
        await waitForSourceSwitch()
        guard await persist(books.filter { $0.bookUrl != url.absoluteString }) else {
            if let staged { try await localFiles.restore(staged) }
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        pendingProgress[url.absoluteString] = nil
        persistPendingProgress()
        try? await chapterRepository.remove(bookURL: url.absoluteString)
        if let staged { try await localFiles.finishRemoval(staged) }
    }

    func clearError() { errorMessage = nil }

    func clearUpdateMessage() { updateMessage = nil }

    func reportError(_ error: Error) { errorMessage = error.localizedDescription }

    @discardableResult
    private func persist(_ updated: [Book], write: (@Sendable () async throws -> Void)? = nil) async -> Bool {
        // Publish before suspending so the next mutation sees the latest
        // shelf. Serialize disk writes to keep their order identical to it.
        books = updated
        bookSaveGeneration &+= 1
        let generation = bookSaveGeneration
        let previousSave = bookSaveTask
        let save = Task { @MainActor [weak self, repository] in
            _ = await previousSave?.value
            do {
                if let write { try await write() }
                else { try await repository.save(updated) }
                self?.persistedBooks = updated
                if self?.bookSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, bookSaveGeneration == generation {
                    books = persistedBooks
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        bookSaveTask = save
        let succeeded = await save.value
        if bookSaveGeneration == generation { bookSaveTask = nil }
        return succeeded
    }

    @discardableResult
    private func persistGroups(_ updated: [BookGroup]) async -> Bool {
        groups = updated
        groupSaveGeneration &+= 1
        let generation = groupSaveGeneration
        let previousSave = groupSaveTask
        let save = Task { @MainActor [weak self, groupRepository] in
            _ = await previousSave?.value
            do {
                try await groupRepository.save(updated)
                self?.persistedGroups = updated
                if self?.groupSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, groupSaveGeneration == generation {
                    groups = persistedGroups
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        groupSaveTask = save
        let succeeded = await save.value
        if groupSaveGeneration == generation { groupSaveTask = nil }
        return succeeded
    }
}
