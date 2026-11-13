import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class SearchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, finished, empty, unavailable }

    @Published private(set) var state: State = .idle
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var isPaused = false
    @Published private(set) var searchKeywords: [SearchKeyword] = []
    @Published private(set) var completedSourceCount = 0
    @Published private(set) var totalSourceCount = 0
    @Published private(set) var submittedKeyword = ""
    @Published private(set) var isShowingCachedResults = false

    private let service: BookSearchService
    private let keywordRepository: any SearchKeywordRepository
    private let searchBookRepository: any SearchBookRepository
    private var searchTask: Task<Void, Never>?
    private var currentKeyword = ""
    private var pagedSources: [BookSource] = []
    private var currentPrecision = false
    private var page = 1
    private var activePage = 1
    private var searchGeneration = 0
    private var pendingSources: [BookSource] = []
    private var pendingSourceIDs = Set<String>()
    private var sourceNames: [String: String] = [:]
    private var accumulator = BookSearchAccumulator()
    private var cachedIdentities = Set<String>()
    private var liveIdentities = Set<String>()
    private var collectedDiagnostics: [RuleDiagnostic] = []
    private var completedCount = 0
    private var foundMoreOnActivePage = false

    init(service: BookSearchService = .init(),
         keywordRepository: any SearchKeywordRepository = SearchKeywordRepositoryFactory.live(),
         searchBookRepository: any SearchBookRepository = SearchBookRepositoryFactory.live()) {
        self.service = service
        self.keywordRepository = keywordRepository
        self.searchBookRepository = searchBookRepository
    }

    deinit { searchTask?.cancel() }

    func search(keyword: String, sources: [BookSource], precision: Bool = false) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { cancel(reset: true); return }
        searchTask?.cancel()
        searchGeneration &+= 1
        currentKeyword = keyword
        submittedKeyword = keyword
        currentPrecision = precision
        page = 1
        activePage = 1
        pendingSources = eligible(sources)
        pendingSourceIDs = Set(pendingSources.map(\.id))
        pagedSources = pendingSources.filter {
            let url = ($0.searchUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A script may use page directly or delegate pagination to jsLib;
            // its pagination support cannot be inferred from {{...}} alone.
            if url.lowercased().hasPrefix("@js:") || url.lowercased().hasPrefix("<js>") { return true }
            return url.range(of: #"\{\{[^}]*\bpage\b[^}]*\}\}"#, options: .regularExpression) != nil
                || url.contains("searchPage") || url.contains("<")
        }
        sourceNames = Dictionary(pendingSources.map { ($0.id, $0.bookSourceName) }, uniquingKeysWith: { first, _ in first })
        accumulator = .init()
        cachedIdentities = []
        liveIdentities = []
        collectedDiagnostics = []
        completedCount = 0
        foundMoreOnActivePage = false
        isShowingCachedResults = false
        hasMore = true
        isPaused = false
        isLoadingMore = false
        books = []
        diagnostics = []
        completedSourceCount = 0
        totalSourceCount = pendingSources.count
        guard totalSourceCount > 0 else { hasMore = false; state = .unavailable; return }
        state = .searching
        Task { await recordKeyword(keyword) }
        startWorker(loadCache: true)
    }

    private func eligible(_ sources: [BookSource]) -> [BookSource] {
        var seen = Set<String>()
        return sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false && seen.insert($0.id).inserted }
    }

    private func startWorker(loadCache: Bool = false) {
        let generation = searchGeneration
        let requestedPage = activePage
        let keyword = currentKeyword
        let sources = pendingSources.filter { pendingSourceIDs.contains($0.id) }
        searchTask = Task { [service, searchBookRepository] in
            var preferred = Set<String>()
            if loadCache {
                let cached = (try? await searchBookRepository.cachedMatches(keyword: keyword)) ?? []
                guard !Task.isCancelled, generation == searchGeneration else { return }
                let enabled = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let now = Date().timeIntervalSince1970 * 1_000
                let usable = cached.filter { book in
                    guard let source = enabled[book.origin] else { return false }
                    let age = now - Double(book.time)
                    return age >= 0 && age < 86_400_000 && source.lastUpdateTime <= book.time
                }
                accumulator.add(usable)
                cachedIdentities = Set(usable.map { BookSearchService.mergeIdentity(for: $0) })
                preferred = Set(usable.flatMap(\.origins)).intersection(Set(enabled.keys))
                publishResults()
            }
            var lastVisibleUpdate = ProcessInfo.processInfo.systemUptime - 1
            for await outcome in service.searchOutcomes(keyword: keyword, page: requestedPage, sources: sources, preferredSourceIDs: preferred) {
                guard !Task.isCancelled, generation == searchGeneration else { return }
                pendingSourceIDs.remove(outcome.sourceID)
                completedCount += 1
                collectedDiagnostics += namedDiagnostics(outcome)
                for book in outcome.books {
                    let identity = BookSearchService.mergeIdentity(for: book)
                    if requestedPage > 1 && !liveIdentities.contains(identity) { foundMoreOnActivePage = true }
                    liveIdentities.insert(identity)
                    accumulator.add([book], replacingExisting: cachedIdentities.remove(identity) != nil)
                }
                let now = ProcessInfo.processInfo.systemUptime
                if books.isEmpty || now - lastVisibleUpdate >= 0.25 {
                    publishResults()
                    lastVisibleUpdate = now
                }
                if !outcome.books.isEmpty { try? await searchBookRepository.put(outcome.books) }
            }
            guard !Task.isCancelled, generation == searchGeneration else { return }
            publishResults()
            page = requestedPage
            hasMore = requestedPage == 1 ? !books.isEmpty && !pagedSources.isEmpty : foundMoreOnActivePage
            isLoadingMore = false
            state = books.isEmpty ? .empty : .finished
        }
    }

    private func publishResults() {
        let values = accumulator.results(keyword: currentKeyword)
        let visible = currentPrecision ? values.filter {
            $0.name.localizedCaseInsensitiveContains(currentKeyword)
                || $0.author.localizedCaseInsensitiveContains(currentKeyword)
                || $0.kind?.localizedCaseInsensitiveContains(currentKeyword) == true
        } : values
        if books != visible { books = visible }
        if diagnostics != collectedDiagnostics { diagnostics = collectedDiagnostics }
        if completedSourceCount != completedCount { completedSourceCount = completedCount }
        let cachedOnly = !visible.isEmpty && liveIdentities.isEmpty
        if isShowingCachedResults != cachedOnly { isShowingCachedResults = cachedOnly }
    }

    func loadMore() {
        guard state == .finished, hasMore, !isLoadingMore, !isPaused, !currentKeyword.isEmpty else { return }
        isLoadingMore = true
        searchGeneration &+= 1
        activePage = page + 1
        pendingSources = eligible(pagedSources)
        pendingSourceIDs = Set(pendingSources.map(\.id))
        foundMoreOnActivePage = false
        startWorker()
    }

    func cancel(reset: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isLoadingMore = false
        if reset {
            accumulator = .init()
            cachedIdentities = []
            liveIdentities = []
            collectedDiagnostics = []
            pendingSources = []
            pendingSourceIDs = []
            isShowingCachedResults = false
            isPaused = false
            state = .idle
            books = []
            diagnostics = []
            hasMore = false
            completedSourceCount = 0
            totalSourceCount = 0
            submittedKeyword = ""
        } else {
            publishResults()
            isPaused = true
            state = books.isEmpty ? .empty : .finished
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard !pendingSourceIDs.isEmpty else { loadMore(); return }
        if activePage == 1 { state = .searching }
        else { isLoadingMore = true }
        startWorker()
    }

    private func namedDiagnostics(_ outcome: SourceSearchOutcome) -> [RuleDiagnostic] {
        guard let name = sourceNames[outcome.sourceID] else { return outcome.diagnostics }
        return outcome.diagnostics.map {
            var value = $0
            value.message = "\(name)：\(value.message)"
            return value
        }
    }

    private func addDiagnostic(_ diagnostic: RuleDiagnostic) {
        collectedDiagnostics.append(diagnostic)
        diagnostics.append(diagnostic)
    }

    func loadSearchKeywords() async {
        do { searchKeywords = try await keywordRepository.load(order: .lastUseTime) }
        catch { addDiagnostic(.init(severity: .warning, code: "search.history.load", message: error.localizedDescription, rule: "SearchKeywordDao.flowByTime")) }
    }

    func clearSearchKeywords() async {
        do {
            try await keywordRepository.deleteAll()
            searchKeywords = []
            UserDefaults.standard.removeObject(forKey: "bookSearchHistory")
        } catch { addDiagnostic(.init(severity: .warning, code: "search.history.clear", message: error.localizedDescription, rule: "SearchKeywordDao.deleteAll")) }
    }

    func deleteSearchKeyword(_ word: String) async {
        do {
            try await keywordRepository.delete(word)
            searchKeywords.removeAll { $0.word == word }
        } catch { addDiagnostic(.init(severity: .warning, code: "search.history.delete", message: error.localizedDescription, rule: "SearchKeywordDao.delete")) }
    }

    private func recordKeyword(_ word: String) async {
        do {
            _ = try await keywordRepository.record(word, at: Int64(Date().timeIntervalSince1970 * 1_000))
            searchKeywords = try await keywordRepository.load(order: .lastUseTime)
            UserDefaults.standard.removeObject(forKey: "bookSearchHistory")
        } catch { addDiagnostic(.init(severity: .warning, code: "search.history.record", message: error.localizedDescription, rule: "SearchKeywordDao.insert/update")) }
    }
}
