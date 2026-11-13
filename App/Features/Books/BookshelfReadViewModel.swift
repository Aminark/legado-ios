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
                let report = try await Task.detached { [localService] in
                    try localService.loadChapters(book: book)
                }.value
                chapters = report.chapters
                resolvedBook = book
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
        if !stored.isEmpty, matchesReadingProgress(book, chapters: stored) {
            chapters = stored
            resolvedBook = book
            return
        }
        guard let source else {
            errorMessage = "目录与阅读进度不一致，且当前书籍的书源不存在。请先恢复或更换书源。"
            return
        }
        let report = await updateCoordinator.refresh(book: book, source: source, persistDirectory: commitUpdate == nil)
        if report.refreshed, matchesReadingProgress(report.book, chapters: report.chapters) {
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

    private func matchesReadingProgress(_ book: Book, chapters: [BookChapter]) -> Bool {
        guard book.totalChapterNum == 0 || book.totalChapterNum == chapters.count else { return false }
        guard let title = book.durChapterTitle, !title.isEmpty else { return true }
        return chapters.indices.contains(book.durChapterIndex)
            && chapters[book.durChapterIndex].title == title
    }
}
