import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookshelfReadViewModel: ObservableObject {
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var resolvedBook: Book?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let localService: LocalBookService
    private let updateCoordinator: BookUpdateCoordinator

    init(
        localService: LocalBookService = .init(),
        updateCoordinator: BookUpdateCoordinator = .init(repository: AppBookChapterRepository.live())
    ) {
        self.localService = localService
        self.updateCoordinator = updateCoordinator
    }

    func load(book: Book, source: BookSource?, commitUpdate: (@MainActor (BookUpdateReport) async -> Bool)? = nil) async {
        guard chapters.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if book.origin == "local" {
            do {
                let parsing = Task.detached { [localService] in
                    try localService.loadChapters(book: book)
                }
                let report = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
                guard !Task.isCancelled else { return }
                chapters = report.chapters
                resolvedBook = book
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            return
        }
        let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
        guard !Task.isCancelled else { return }
        if let restored = Self.restoredBook(book, chapters: stored) {
            chapters = stored
            resolvedBook = restored
            return
        }
        guard let source else {
            errorMessage = "目录与阅读进度不一致，且当前书籍的书源不存在。请先恢复或更换书源。"
            return
        }
        let report = await updateCoordinator.refresh(book: book, source: source, persistDirectory: commitUpdate == nil)
        guard !Task.isCancelled else { return }
        if report.refreshed, Self.matchesReadingProgress(report.book, chapters: report.chapters) {
            if let commitUpdate, !(await commitUpdate(report)) {
                errorMessage = "更新后的书籍保存失败，已保留原书籍和阅读位置。"
                return
            }
            chapters = report.chapters
            resolvedBook = report.book
        } else {
            errorMessage = report.diagnostics.first?.message ?? "目录刷新后仍与阅读进度不一致，请稍后重试。"
        }
    }

    static func restoredBook(_ book: Book, chapters: [BookChapter]) -> Book? {
        if matchesReadingProgress(book, chapters: chapters) { return book }
        guard let title = book.durChapterTitle, !title.isEmpty else { return nil }
        let matches = chapters.indices.filter { !chapters[$0].isVolume && chapters[$0].title == title }
        guard matches.count == 1, let index = matches.first else { return nil }
        var restored = book
        restored.durChapterIndex = index
        restored.totalChapterNum = chapters.count
        return restored
    }

    static func matchesReadingProgress(_ book: Book, chapters: [BookChapter]) -> Bool {
        guard chapters.indices.contains(book.durChapterIndex) else { return false }
        if let title = book.durChapterTitle, !title.isEmpty {
            return chapters[book.durChapterIndex].title == title
        }
        return book.totalChapterNum == 0 || book.totalChapterNum == chapters.count
    }
}
