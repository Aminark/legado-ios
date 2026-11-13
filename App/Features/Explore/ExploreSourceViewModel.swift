import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class ExploreSourceViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, empty, failed }

    let source: BookSource
    @Published private(set) var kinds: [ExploreKind] = []
    @Published private(set) var selectedKind: ExploreKind?
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var paginationError: String?

    private let service: BookExploreService
    private let demoBooks: [SearchBook]?
    private var page = 1
    private var canLoadMore = false
    private var generation = UUID()
    private var paginationTask: Task<Void, Never>?

    init(source: BookSource, service: BookExploreService = .init(), demoBooks: [SearchBook]? = nil) {
        self.source = source
        self.service = service
        self.demoBooks = demoBooks
    }

    deinit { paginationTask?.cancel() }

    func load() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        let requestID = beginRequest()
        selectedKind = nil
        kinds = []
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        let report = await service.kinds(for: source)
        guard generation == requestID else { return }
        guard !Task.isCancelled else { state = .idle; return }
        kinds = report.kinds.filter { $0.navigableURL != nil }
        diagnostics = report.diagnostics
        guard let first = kinds.first else {
            state = diagnostics.contains(where: { $0.severity == .error }) ? .failed : .empty
            return
        }
        await select(kind: first)
    }

    func select(kind: ExploreKind) async {
        guard kind.navigableURL != nil else { return }
        let requestID = beginRequest()
        selectedKind = kind
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        if let demoBooks {
            books = demoBooks
            state = .ready
            canLoadMore = true
            return
        }

        let outcome = await service.explore(source: source, kind: kind, page: page)
        guard generation == requestID else { return }
        guard !Task.isCancelled else { state = .idle; return }
        diagnostics = outcome.diagnostics
        books = outcome.books
        canLoadMore = !outcome.books.isEmpty
        state = books.isEmpty ? (outcome.diagnostics.isEmpty ? .empty : .failed) : .ready
    }

    func loadNextPageIfNeeded(current book: SearchBook) {
        guard state == .ready, book.id == books.last?.id,
              canLoadMore, !isLoadingMore, paginationError == nil,
              let kind = selectedKind else { return }
        isLoadingMore = true
        let nextPage = page + 1
        let requestID = generation
        paginationTask = Task { [service, source] in
            defer {
                // A cancelled older page must not clear a newer page's state.
                if generation == requestID {
                    isLoadingMore = false
                    paginationTask = nil
                }
            }
            if demoBooks != nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, generation == requestID else { return }
                canLoadMore = false
                return
            }
            let outcome = await service.explore(source: source, kind: kind, page: nextPage)
            guard !Task.isCancelled, generation == requestID else { return }
            diagnostics += outcome.diagnostics
            if let error = outcome.diagnostics.first(where: { $0.severity == .error }) {
                // Keep both the prior results and page number for an explicit
                // retry. A partial or failed page must never be skipped.
                paginationError = error.message
                return
            }
            var knownURLs = Set(books.map(\.bookURL))
            books.append(contentsOf: outcome.books.filter { knownURLs.insert($0.bookURL).inserted })
            page = nextPage
            canLoadMore = !outcome.books.isEmpty
        }
    }

    func retryNextPage() {
        guard paginationError != nil, let last = books.last else { return }
        paginationError = nil
        loadNextPageIfNeeded(current: last)
    }

    private func beginRequest() -> UUID {
        generation = UUID()
        paginationTask?.cancel()
        paginationTask = nil
        isLoadingMore = false
        paginationError = nil
        return generation
    }
}
