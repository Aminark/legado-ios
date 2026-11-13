import SwiftUI

@MainActor
final class SourceSwitchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, ready, empty }

    @Published private(set) var state: State = .idle
    @Published private(set) var candidates: [BookSourceCandidate] = []
    @Published private(set) var switchingID: String?
    @Published private(set) var errorMessage: String?

    private let book: Book
    var bookName: String { book.name }
    private let service: BookSourceSwitchService
    private var selectionGeneration = 0

    init(book: Book, service: BookSourceSwitchService = .init(), candidates: [BookSourceCandidate] = []) {
        self.book = book
        self.service = service
        self.candidates = candidates
        state = candidates.isEmpty ? .idle : .ready
    }

    func load(sources: [BookSource]) async {
        guard state == .idle else { return }
        state = .searching
        for await update in await service.candidateUpdates(for: book, sources: sources) {
            guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
            candidates = update
        }
        guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
        state = candidates.isEmpty ? .empty : .ready
    }

    func select(_ candidate: BookSourceCandidate, sources: [BookSource]) async -> (BookSourceSwitchReport, BookSource)? {
        guard switchingID == nil,
              let source = sources.first(where: { $0.bookSourceUrl == candidate.book.origin }) else { return nil }
        switchingID = candidate.id
        let generation = selectionGeneration
        errorMessage = nil
        defer { switchingID = nil }
        let report = await service.prepareSwitch(current: book, candidate: candidate.book, source: source)
        guard generation == selectionGeneration, !Task.isCancelled else { return nil }
        guard let report else {
            errorMessage = "候选书源的目录、正文加载或保存失败，请重试或选择其他书源。已保留当前书源和阅读位置。"
            return nil
        }
        return (report, source)
    }

    func clearError() { errorMessage = nil }
    func reportSaveFailure() { errorMessage = "换源未能保存到书架，请重试。已保留当前书源和阅读位置。" }
    func cancelSelection() { selectionGeneration &+= 1 }
}

struct SourceSwitchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceSwitchViewModel
    @State private var isSaving = false
    let sources: [BookSource]
    let onSwitched: @MainActor (BookSourceSwitchReport, BookSource) async -> Bool

    init(
        book: Book,
        sources: [BookSource],
        demoCandidates: [BookSourceCandidate] = [],
        onSwitched: @escaping @MainActor (BookSourceSwitchReport, BookSource) async -> Bool
    ) {
        self.sources = sources
        self.onSwitched = onSwitched
        _model = StateObject(wrappedValue: SourceSwitchViewModel(book: book, candidates: demoCandidates))
    }

    var body: some View {
        Group {
            if model.candidates.isEmpty && (model.state == .searching || model.state == .idle) {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在从其他书源查找同名作品…").foregroundStyle(.secondary)
                }
            } else if model.state == .empty {
                ReadingUnavailableView(
                    "没有可用换源",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("仅显示书名一致的候选，并优先匹配作者。请确认其他书源已启用且支持搜索。")
                )
            } else {
                List {
                    if model.state == .searching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("仍在查找其他书源，可直接选择已找到的结果")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.candidates) { candidate in candidateRow(candidate) }
                }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.canvas)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingTheme.canvas)
        .navigationTitle("为《\(model.bookName)》换源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isSaving) }
        }
        .interactiveDismissDisabled(isSaving)
        .task { await model.load(sources: sources) }
        .onDisappear { model.cancelSelection() }
        .alert("换源失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func candidateRow(_ candidate: BookSourceCandidate) -> some View {
        Button {
            Task {
                if let (report, source) = await model.select(candidate, sources: sources) {
                    isSaving = true
                    defer { isSaving = false }
                    if await onSwitched(report, source) {
                        dismiss()
                    } else {
                        model.reportSaveFailure()
                    }
                }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "network")
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(ReadingTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.book.originName).font(.headline).foregroundStyle(.primary)
                    Text(candidate.book.author.isEmpty ? "作者信息缺失" : candidate.book.author)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.switchingID == candidate.id {
                        Text("正在验证目录和正文…").font(.caption).foregroundStyle(.secondary)
                    } else if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                        Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if model.switchingID == candidate.id {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(ReadingTheme.coral)
                }
            }
            .padding(.vertical, 5)
        }
        .disabled(model.switchingID != nil || isSaving)
        .accessibilityIdentifier("sourceSwitch.candidate.\(candidate.id)")
    }
}
