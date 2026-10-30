import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class SourceSwitchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, ready, empty }
    enum VerificationState: Equatable { case waiting, loading, ready, chapterUnmatched, failed }
    enum ReferenceState: Equatable { case idle, loading, ready, unavailable }

    struct CandidateGroup: Identifiable {
        let id: String
        let title: String
        let candidates: [BookSourceCandidate]
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var candidates: [BookSourceCandidate] = []
    @Published private(set) var selectedCandidate: BookSourceCandidate?
    @Published private(set) var preview: AvailableBookSource?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var isSwitching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var verificationStates: [String: VerificationState] = [:]
    @Published private(set) var comparisons: [String: ChapterTextComparison] = [:]
    @Published private(set) var reference: SourceChapterReference?
    @Published private(set) var referenceState: ReferenceState = .idle
    @Published private(set) var loadedFromCache = false
    @Published private(set) var isRefreshing = false
    @Published var sourceQuery = ""

    private let book: Book
    private let service: BookSourceSwitchService
    private let referenceService: any SourceChapterReferencing
    private let cache: SourceSwitchCache
    private let initialCandidates: [BookSourceCandidate]
    private var cacheKey: String?
    private var cacheCreatedAt: Date?
    private var referenceCheckedAt: Date?
    private var searchComplete = false
    private var searchedSourceIDs = Set<String>()
    private var selectionGeneration = 0
    private var verificationGeneration = 0
    private struct Preparation {
        let token: UUID
        let task: Task<BookSourceSwitchReport?, Never>
    }
    private var preparations: [String: Preparation] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var queue: [BookSourceCandidate] = []
    private var sourcesByID: [String: BookSource] = [:]
    private var referenceTask: Task<Void, Never>?
    private var referenceProbeURLs = Set<String>()
    private var previews: [String: AvailableBookSource] = [:]
    private var fingerprints: [String: String] = [:]
    private var characterCounts: [String: Int] = [:]
    private var hasConfirmedSelection = false
    private var hasLoaded = false

    var bookName: String { book.name }
    var currentChapterTitle: String? { book.durChapterTitle }
    var filteredCandidates: [BookSourceCandidate] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.book.originName.localizedStandardContains(query) || $0.book.origin.localizedStandardContains(query)
        }
    }
    var canConfirm: Bool {
        preview?.report.verifiedContent?.content.isEmpty == false && !isPreviewLoading && !isSwitching && !hasConfirmedSelection
    }

    var verificationProgress: String {
        let finished = verificationStates.values.filter { $0 != .waiting && $0 != .loading }.count
        return "已核对 \(finished)/\(candidates.count) 个源"
    }

    var candidateGroups: [CandidateGroup] {
        if reference != nil {
            let allComparisons = comparisons
            let originalOrder = Dictionary(candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ranked = filteredCandidates.sorted {
                func rank(_ candidate: BookSourceCandidate) -> Int {
                    guard let comparison = allComparisons[candidate.id] else { return -1 }
                    return comparison.similarity + (comparison.similarity >= 80 && comparison.hasMoreContent ? 110 : 0)
                }
                let lhs = rank($0), rhs = rank($1)
                return lhs == rhs ? originalOrder[$0.id, default: 0] < originalOrder[$1.id, default: 0] : lhs > rhs
            }
            return [.init(id: "reference", title: "按本章可见正文对照排序", candidates: ranked)]
        }
        let grouped = Dictionary(grouping: candidates.filter { fingerprints[$0.id] != nil }) { fingerprints[$0.id]! }
            .filter { $0.value.count > 1 }
        let ordered = grouped.keys.sorted {
            let lhs = grouped[$0]!, rhs = grouped[$1]!
            return lhs.count == rhs.count ? lhs[0].book.originName < rhs[0].book.originName : lhs.count > rhs.count
        }
        var groups = ordered.enumerated().compactMap { index, key -> CandidateGroup? in
            let all = grouped[key]!
            let visible = filteredCandidates.filter { fingerprints[$0.id] == key }
            guard !visible.isEmpty else { return nil }
            return .init(id: key, title: "同文组 \(index + 1) · \(all.count) 个书源 · 未验证", candidates: visible)
        }
        let remaining = filteredCandidates.filter { candidate in
            guard let fingerprint = fingerprints[candidate.id] else { return true }
            return grouped[fingerprint] == nil
        }
        if !remaining.isEmpty { groups.append(.init(id: "unverified", title: "其他书源 · 正文未验证", candidates: remaining)) }
        return groups
    }

    func verificationDescription(for candidate: BookSourceCandidate) -> String {
        switch verificationStates[candidate.id] {
        case .waiting, .none: return "等待获取本章正文"
        case .loading: return "正在核对本章…"
        case .failed: return "正文获取失败，可点选重试"
        case .chapterUnmatched: return "目录未匹配本章，正文未对照"
        case .ready:
            guard let comparison = comparisons[candidate.id] else {
                if reference != nil { return "正文过短，无法对照" }
                return "正文 \(characterCounts[candidate.id, default: 0]) 字 · 尚未验证正确性"
            }
            let length = comparison.hasMoreContent ? "正文多于参照" : "正文未多于参照"
            return "可见片段相似 \(comparison.similarity)% · \(length)"
        }
    }

    init(book: Book, service: BookSourceSwitchService = .init(), candidates: [BookSourceCandidate] = [],
         referenceService: any SourceChapterReferencing = PublicSourceChapterReferenceService(),
         cache: SourceSwitchCache = .shared) {
        self.book = book
        self.service = service
        self.referenceService = referenceService
        self.cache = cache
        initialCandidates = candidates
        self.candidates = candidates
        state = candidates.isEmpty ? .idle : .ready
    }

    func load(sources: [BookSource]) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        verificationGeneration &+= 1
        let generation = verificationGeneration
        cacheKey = SourceSwitchCache.key(book: book, sources: sources)
        if let cacheKey, let stored = await cache.load(cacheKey) {
            guard !Task.isCancelled, generation == verificationGeneration else { return }
            restore(stored)
        }
        guard !Task.isCancelled, generation == verificationGeneration else { return }
        if cacheCreatedAt == nil { cacheCreatedAt = Date() }
        let recentlyUnavailable = referenceCheckedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
        if reference == nil && !recentlyUnavailable {
            referenceState = .loading
            referenceTask = Task {
                let loaded = await referenceService.reference(for: book)
                guard !Task.isCancelled, generation == verificationGeneration else { return }
                if reference?.provider != "起点", let loaded { applyReference(loaded) }
                referenceCheckedAt = Date()
                referenceState = reference == nil ? .unavailable : .ready
                saveSnapshot()
            }
        }
        if !searchComplete && (initialCandidates.isEmpty || loadedFromCache) {
            state = .searching
            let remaining = sources.filter { !searchedSourceIDs.contains($0.id) }
            for await result in await service.candidateSearchUpdates(for: book, sources: remaining) {
                guard !Task.isCancelled, generation == verificationGeneration else { return }
                let update = result.candidates
                searchedSourceIDs.formUnion(result.searchedSourceIDs)
                let incomingIDs = Set(update.map(\.id))
                candidates = (update + candidates.filter { !incomingIDs.contains($0.id) }).sorted { $0.score > $1.score }
                enqueue(update, generation: generation)
                saveSnapshot()
            }
        }
        guard !Task.isCancelled, generation == verificationGeneration else { return }
        searchComplete = true
        enqueue(candidates, generation: generation)
        state = candidates.isEmpty ? .empty : .ready
        saveSnapshot()
        while let worker = workers.values.first {
            await worker.value
            guard !Task.isCancelled, generation == verificationGeneration else { return }
        }
        await referenceTask?.value
    }

    func refresh(sources: [BookSource]) async {
        guard !isSwitching, !isRefreshing else { return }
        cancelSelection()
        if let cacheKey { cache.remove(cacheKey) }
        hasLoaded = false
        hasConfirmedSelection = false
        cacheCreatedAt = nil
        searchComplete = false
        searchedSourceIDs.removeAll()
        loadedFromCache = false
        reference = nil
        referenceState = .idle
        referenceCheckedAt = nil
        referenceTask = nil
        referenceProbeURLs.removeAll()
        previews.removeAll()
        fingerprints.removeAll()
        characterCounts.removeAll()
        comparisons.removeAll()
        verificationStates.removeAll()
        candidates = initialCandidates
        state = candidates.isEmpty ? .idle : .ready
        isRefreshing = true
        defer { isRefreshing = false }
        await load(sources: sources)
    }

    private func enqueue(_ candidates: [BookSourceCandidate], generation: Int) {
        for candidate in candidates where verificationStates[candidate.id] == nil {
            verificationStates[candidate.id] = .waiting
            queue.append(candidate)
        }
        startWorkers(generation: generation)
    }

    func select(_ candidate: BookSourceCandidate, sources: [BookSource]) async {
        guard !isSwitching, !hasConfirmedSelection else { return }
        if selectedCandidate?.id == candidate.id, preview != nil || isPreviewLoading { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectedCandidate = candidate
        preview = nil
        errorMessage = nil
        isPreviewLoading = false
        guard let source = sources.first(where: { $0.bookSourceUrl == candidate.book.origin }) else {
            errorMessage = "该书源已不可用，请选择其他书源。"
            return
        }
        if let cached = previews[candidate.id] {
            preview = cached
            return
        }
        isPreviewLoading = true
        let report = await prepare(candidate, source: source, exactOnly: false)
        guard generation == selectionGeneration else { return }
        isPreviewLoading = false
        guard !Task.isCancelled else { return }
        guard let report else {
            errorMessage = "无法读取这个书源的目录或本章正文，请重试或选择其他书源。"
            return
        }
        let available = AvailableBookSource(report: report, source: source)
        remember(available, candidateID: candidate.id)
        preview = available
    }

    func confirmSelection() async -> AvailableBookSource? {
        guard canConfirm, let preview else { return nil }
        isSwitching = true
        let generation = selectionGeneration
        defer { isSwitching = false }
        let report = await service.persistPreparedSwitch(preview.report)
        guard generation == selectionGeneration, !Task.isCancelled else { return nil }
        hasConfirmedSelection = true
        return AvailableBookSource(report: report, source: preview.source)
    }

    func cancelSelection() {
        saveSnapshot()
        selectionGeneration &+= 1
        verificationGeneration &+= 1
        referenceTask?.cancel()
        for preparation in preparations.values { preparation.task.cancel() }
        for worker in workers.values { worker.cancel() }
        preparations.removeAll()
        workers.removeAll()
        queue.removeAll()
        selectedCandidate = nil
        preview = nil
        errorMessage = nil
        isPreviewLoading = false
    }

    private func restore(_ value: SourceSwitchSnapshot) {
        loadedFromCache = true
        cacheCreatedAt = value.createdAt
        candidates = value.candidates
        searchComplete = value.searchComplete
        searchedSourceIDs = value.searchedSourceIDs
        reference = value.reference
        referenceCheckedAt = value.referenceCheckedAt
        referenceState = reference == nil ? .unavailable : .ready
        for id in value.unmatched { verificationStates[id] = .chapterUnmatched }
        for (id, report) in value.reports {
            guard let source = sourcesByID[report.book.origin],
                  let content = report.verifiedContent,
                  !content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  report.chapters.indices.contains(report.book.durChapterIndex) else { continue }
            // Progress/settings may change while the sheet is closed. Re-map
            // with the current book before allowing a cached preview to confirm.
            var mapped = BookSourceProgressMapper().migrate(current: book, replacement: report.book,
                                                            chapters: report.chapters, now: Int64(Date().timeIntervalSince1970 * 1_000))
            guard mapped.chapters.indices.contains(mapped.book.durChapterIndex),
                  mapped.chapters[mapped.book.durChapterIndex].url == report.chapters[report.book.durChapterIndex].url else { continue }
            mapped.diagnostics = report.diagnostics
            mapped.verifiedContent = report.verifiedContent
            remember(.init(report: mapped, source: source), candidateID: id, persist: false)
        }
    }

    private func saveSnapshot() {
        guard let cacheKey, let createdAt = cacheCreatedAt else { return }
        cache.store(.init(createdAt: createdAt, candidates: candidates, searchComplete: searchComplete,
            reference: reference, referenceCheckedAt: referenceCheckedAt, reports: previews.mapValues(\.report),
            unmatched: verificationStates.compactMap { $0.value == .chapterUnmatched ? $0.key : nil },
            searchedSourceIDs: searchedSourceIDs), key: cacheKey)
    }

    private func prepare(_ candidate: BookSourceCandidate, source: BookSource, exactOnly: Bool) async -> BookSourceSwitchReport? {
        if let cached = previews[candidate.id] { return cached.report }
        if !exactOnly, let automatic = preparations[candidate.id + "|exact"] {
            let report = await automatic.task.value
            if report?.verifiedContent != nil { return report }
        }
        let key = candidate.id + (exactOnly ? "|exact" : "|manual")
        let request: Preparation
        if let existing = preparations[key] { request = existing }
        else {
            let task = Task {
                await service.prepareSwitch(current: book, candidate: candidate.book, source: source,
                                            persistChapters: false, requireExactChapterMatch: exactOnly)
            }
            request = Preparation(token: UUID(), task: task)
            preparations[key] = request
        }
        let report = await request.task.value
        if preparations[key]?.token == request.token { preparations.removeValue(forKey: key) }
        return report
    }

    private func startWorkers(generation: Int) {
        while workers.count < 3, !queue.isEmpty {
            let candidate = queue.removeFirst()
            verificationStates[candidate.id] = .loading
            workers[candidate.id] = Task {
                let source = sourcesByID[candidate.book.origin]
                let report: BookSourceSwitchReport?
                if let source { report = await prepare(candidate, source: source, exactOnly: true) }
                else { report = nil }
                guard !Task.isCancelled, generation == verificationGeneration else { return }
                if let report, let source {
                    if report.exactChapterMatch, report.verifiedContent != nil {
                        remember(.init(report: report, source: source), candidateID: candidate.id)
                        if reference?.provider != "起点", referenceProbeURLs.insert(report.book.bookUrl).inserted,
                           let official = await referenceService.qidianReference(for: book, prepared: report),
                           !Task.isCancelled, generation == verificationGeneration {
                            applyReference(official)
                            referenceState = .ready
                        }
                    } else { verificationStates[candidate.id] = .chapterUnmatched; saveSnapshot() }
                } else { verificationStates[candidate.id] = .failed }
                guard !Task.isCancelled, generation == verificationGeneration else { return }
                workers.removeValue(forKey: candidate.id)
                startWorkers(generation: generation)
            }
        }
    }

    private func remember(_ available: AvailableBookSource, candidateID: String, persist: Bool = true) {
        previews[candidateID] = available
        let body = available.report.verifiedContent?.content ?? ""
        characterCounts[candidateID] = ChapterTextComparison.normalize(body).count
        if available.report.exactChapterMatch {
            fingerprints[candidateID] = ChapterTextComparison.fingerprint(body)
            verificationStates[candidateID] = .ready
            if let reference { comparisons[candidateID] = ChapterTextComparison.compare(body, reference: reference) }
        } else { verificationStates[candidateID] = .chapterUnmatched }
        if persist { saveSnapshot() }
    }

    private func applyReference(_ loaded: SourceChapterReference) {
        reference = loaded
        comparisons = previews.reduce(into: [:]) { result, entry in
            if entry.value.report.exactChapterMatch, let body = entry.value.report.verifiedContent?.content {
                result[entry.key] = ChapterTextComparison.compare(body, reference: loaded)
            }
        }
        saveSnapshot()
    }
}
