import SwiftUI

@MainActor
private final class CacheManagementModel: ObservableObject {
    @Published private(set) var entries = 0
    @Published private(set) var bytes = 0
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let cache: ChapterContentCache

    init(cache: ChapterContentCache = .live()) { self.cache = cache }

    func load() async {
        do {
            let statistics = try await cache.statistics()
            entries = statistics.entries
            bytes = statistics.bytes
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await cache.removeAll()
            entries = 0
            bytes = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CacheManagementView: View {
    @StateObject private var model = CacheManagementModel()

    var body: some View {
        List {
            Section("章节正文") {
                ReadingLabeledContent("已缓存章节", value: "\(model.entries)")
                ReadingLabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file))
                Text("打开网络章节后会自动缓存。阅读页目录中可缓存接下来 10 章或剩余章节。超出上限时会清掉最久没读的内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    NetworkSettingsView()
                } label: {
                    Label("缓存上限与预加载", systemImage: "slider.horizontal.3")
                }
                Button("清空章节缓存", systemImage: "trash", role: .destructive) {
                    Task { await model.clear() }
                }
                .disabled(model.entries == 0 || model.isWorking)
            }
        }
        .navigationTitle("缓存管理")
        .task { await model.load() }
        .overlay { if model.isWorking { ProgressView() } }
        .alert("缓存操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }
}
