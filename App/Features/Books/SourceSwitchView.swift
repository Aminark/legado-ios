import SwiftUI

struct SourceSwitchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceSwitchViewModel
    @FocusState private var isSearchFocused: Bool
    let sources: [BookSource]
    let onSwitched: @MainActor (BookSourceSwitchReport, BookSource) -> Void

    init(
        book: Book,
        sources: [BookSource],
        demoCandidates: [BookSourceCandidate] = [],
        service: BookSourceSwitchService = .init(),
        referenceService: any SourceChapterReferencing = PublicSourceChapterReferenceService(),
        cache: SourceSwitchCache = .shared,
        onSwitched: @escaping @MainActor (BookSourceSwitchReport, BookSource) -> Void
    ) {
        self.sources = sources
        self.onSwitched = onSwitched
        _model = StateObject(wrappedValue: SourceSwitchViewModel(book: book, service: service, candidates: demoCandidates,
                                                               referenceService: referenceService, cache: cache))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                previewPanel
                    .frame(height: isSearchFocused ? 76 : model.selectedCandidate == nil ? 112 : min(max(geometry.size.height * 0.30, 160), 220))
                Divider()
                sourceSearchField
                if !isSearchFocused { verificationSummary }
                candidatesContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                confirmationButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingTheme.canvas)
        .navigationTitle("为《\(model.bookName)》换源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { model.cancelSelection(); dismiss() }
                    .disabled(model.isSwitching)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh(sources: sources) }
                } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("刷新换源结果")
                .accessibilityIdentifier("sourceSwitch.refresh")
                .disabled(model.isSwitching || model.isRefreshing)
            }
        }
        .task { await model.load(sources: sources) }
        .onDisappear { model.cancelSelection() }
        .interactiveDismissDisabled(model.isSwitching)
    }

    private var sourceSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索书源名称或网址", text: $model.sourceQuery)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.done)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
                .accessibilityIdentifier("sourceSwitch.search")
            if !model.sourceQuery.isEmpty {
                Button {
                    model.sourceQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除书源搜索")
                .accessibilityIdentifier("sourceSwitch.search.clear")
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .disabled(model.isSwitching)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedCandidate?.book.originName ?? "本章预览")
                        .font(.headline)
                    Text(model.currentChapterTitle.map { "当前阅读：\($0)" } ?? "按当前阅读进度匹配章节")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let preview = model.preview {
                    Text(preview.report.exactChapterMatch ? "仅目录标题匹配" : "按进度定位")
                        .font(.caption)
                        .foregroundStyle(preview.report.exactChapterMatch ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("sourceSwitch.preview.mapping")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var verificationSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(model.verificationProgress).fontWeight(.medium)
                if model.loadedFromCache {
                    Text("已使用本地缓存")
                        .accessibilityIdentifier("sourceSwitch.cache")
                }
                if model.referenceState == .loading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            if let reference = model.reference {
                Text("参照：\(reference.provider) · \(reference.chapterTitle) · \(reference.characterCount) 字")
                    .accessibilityIdentifier("sourceSwitch.reference")
                Text("仅对照正版可见片段；字数更多不代表后续正文正确。统计忽略空白和标点。")
            } else {
                Text(model.referenceState == .loading ? "正在读取正版参照，先汇总相同正文" : "暂无可读取的正版参照；同文组只代表内容相同，不代表正确。")
                    .accessibilityIdentifier("sourceSwitch.reference.unavailable")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var previewContent: some View {
        if model.isPreviewLoading {
            ProgressView("正在获取本章正文…")
        } else if let preview = model.preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(preview.report.book.durChapterTitle ?? "章节正文")
                        .font(.headline)
                        .accessibilityIdentifier("sourceSwitch.preview.chapter")
                    Text(preview.report.verifiedContent?.content ?? "")
                        .font(.system(size: 16))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sourceSwitch.preview.content")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .id(model.selectedCandidate?.id)
        } else if let message = model.errorMessage {
            VStack(spacing: 10) {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("重试预览") {
                    if let candidate = model.selectedCandidate {
                        Task { await model.select(candidate, sources: sources) }
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        } else {
            Text("点选下方书源，先查看这一章的正文")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var candidatesContent: some View {
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
        } else if model.filteredCandidates.isEmpty {
            ReadingUnavailableView(
                "没有匹配的书源",
                systemImage: "magnifyingglass",
                description: Text(model.state == .searching ? "可更换关键词；其他书源仍在查找中。" : "试试其他书源名称或网址，或清除搜索查看全部结果。")
            )
            .accessibilityIdentifier("sourceSwitch.search.empty")
        } else {
            List {
                if model.state == .searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("仍在查找其他书源，可直接选择已找到的结果")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.candidateGroups) { group in
                    Section(group.title) {
                        ForEach(group.candidates) { candidate in candidateRow(candidate) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .readingScrollContentBackgroundHidden()
            .background(ReadingTheme.canvas)
        }
    }

    private var confirmationButton: some View {
        Button {
            Task {
                if let available = await model.confirmSelection() {
                    onSwitched(available.report, available.source)
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 10) {
                if model.isSwitching { ProgressView() }
                Text("使用此书源")
            }
            .frame(maxWidth: .infinity)
        }
        .readingProminentButtonStyle()
        .disabled(!model.canConfirm)
        .accessibilityIdentifier("sourceSwitch.confirm")
        .padding(16)
        .background(ReadingTheme.canvas)
    }

    private func candidateRow(_ candidate: BookSourceCandidate) -> some View {
        Button {
            isSearchFocused = false
            Task { await model.select(candidate, sources: sources) }
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
                    Text(model.verificationDescription(for: candidate))
                        .font(.caption)
                        .foregroundStyle(verificationColor(candidate))
                        .accessibilityIdentifier("sourceSwitch.verification.\(candidate.book.origin)")
                    if model.selectedCandidate?.id == candidate.id, model.isPreviewLoading {
                        Text("正在加载本章预览…").font(.caption).foregroundStyle(.secondary)
                    } else if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                        Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if model.selectedCandidate?.id == candidate.id, model.isPreviewLoading {
                    ProgressView()
                } else {
                    Image(systemName: model.selectedCandidate?.id == candidate.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 5)
        }
        .disabled(model.isSwitching)
        .accessibilityHint("预览当前章节，确认后换源")
        .accessibilityIdentifier("sourceSwitch.candidate.\(candidate.id)")
    }

    private func verificationColor(_ candidate: BookSourceCandidate) -> Color {
        if model.verificationStates[candidate.id] == .chapterUnmatched { return .orange }
        if let comparison = model.comparisons[candidate.id], comparison.similarity < 40 { return .red }
        return .secondary
    }
}
