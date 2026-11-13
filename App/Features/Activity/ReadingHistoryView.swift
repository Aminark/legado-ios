import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @AppStorage("readRecordSort") private var sortMode = 0
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var pendingDelete: ReadRecordSummary?

    private var displayedRecords: [ReadRecordSummary] {
        activity.summaries(searchKey: searchText, sortMode: sortMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadingPillSearchField(placeholder: "搜索", text: $searchText)
            if activity.summaries.isEmpty {
                ReadingIllustratedEmptyState(
                    artwork: "HistoryEmptyArtwork",
                    title: "还没有阅读记录",
                    message: enableReadRecord ? "翻页后会按设备累计阅读时长" : "阅读记录当前已关闭"
                ) { EmptyView() }
            } else {
                List {
                    Section {
                        ReadingLabeledContent("累计阅读", value: duration(activity.summaries.reduce(0) { $0 + $1.readTime }))
                        ReadingLabeledContent("读过", value: "\(activity.summaries.count) 本")
                    }
                    if displayedRecords.isEmpty {
                        ReadingUnavailableView.search(text: searchText)
                    } else {
                        ForEach(displayedRecords) { record in
                            NavigationLink {
                                destination(for: record)
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "book.pages.fill")
                                        .foregroundStyle(ReadingTheme.accent)
                                        .frame(width: 38, height: 38)
                                        .background(ReadingTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.bookName).font(.headline)
                                        Text(duration(record.readTime))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(date(record.lastRead)).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = record }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
            }
        }
        .navigationTitle("阅读记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .background(ReadingTheme.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("阅读记录选项", systemImage: "ellipsis") {
                    Toggle("记录阅读时长", isOn: $enableReadRecord)
                    Section("排序") {
                        sortButton("书名", value: 0)
                        sortButton("阅读时长", value: 1)
                        sortButton("最后阅读", value: 2)
                    }
                    if !activity.summaries.isEmpty {
                        Button("清空", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .alert("清空阅读记录", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await activity.clearHistory() } }
        } message: {
            Text("确定删除全部阅读记录吗？")
        }
        .alert("删除阅读记录", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let record = pendingDelete else { return }
                pendingDelete = nil
                Task { await activity.removeHistory(bookName: record.bookName) }
            }
        } message: {
            Text("确定删除“\(pendingDelete?.bookName ?? "")”的阅读记录吗？")
        }
    }

    @ViewBuilder private func destination(for record: ReadRecordSummary) -> some View {
        if let book = books.books.first(where: { $0.name == record.bookName }) {
            BookshelfReadView(
                book: book,
                source: sources.sources.first(where: { $0.bookSourceUrl == book.origin })
            )
        } else {
            SearchView(initialKeyword: record.bookName)
        }
    }

    @ViewBuilder private func sortButton(_ title: String, value: Int) -> some View {
        Button {
            sortMode = value
        } label: {
            if sortMode == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func duration(_ milliseconds: Int64) -> String {
        let value = max(milliseconds, 0)
        let days = value / 86_400_000
        let hours = value % 86_400_000 / 3_600_000
        let minutes = value % 3_600_000 / 60_000
        let seconds = value % 60_000 / 1_000
        var result = ""
        if days > 0 { result += "\(days)天" }
        if hours > 0 { result += "\(hours)小时" }
        if minutes > 0 { result += "\(minutes)分钟" }
        if seconds > 0 { result += "\(seconds)秒" }
        return result.isEmpty ? "0秒" : result
    }

    private func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        guard milliseconds > 0 else { return "" }
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
