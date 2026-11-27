import SwiftUI
import UniformTypeIdentifiers

struct LocalBackupView: View {
    var incomingURL: URL? = nil
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var rules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var rss: RSSLibraryModel
    @EnvironmentObject private var subscriptions: RuleSubscriptionModel
    @State private var includeFiles = true
    @State private var selecting = false
    @State private var working = false
    @State private var workingLabel = "正在处理书库"
    @State private var export: ExportedBackup?
    @State private var preview: PreparedLibraryBackup?
    @State private var message: String?
    @State private var messageDetail: String?
    @State private var isError = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        applyCloseToolbar(to: formContent)
            .navigationTitle("本机书库备份")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(working)
            .task(id: incomingURL) {
                guard let incomingURL else { return }
                do { try await inspect(incomingURL) }
                catch { setError(error.localizedDescription) }
            }
            .fileImporter(isPresented: $selecting, allowedContentTypes: [UTType(exportedAs: "com.epiboly.legado.library-backup")]) { result in
                Task {
                    do { try await inspect(result.get()) }
                    catch { if (error as NSError).code != NSUserCancelledError { setError(error.localizedDescription) } }
                }
            }
            .sheet(item: $export) { file in
                BackupSavePicker(url: file.url) { saved in
                    let skipped = file.skippedLocalBooks
                    export = nil
                    if saved {
                        setSuccess("备份已导出", detail: skipped.isEmpty ? nil : "已跳过 \(skipped.count) 本本地文件缺失的书籍：\(skipped.prefix(3).joined(separator: "、"))")
                    }
                }
            }
    }

    @ViewBuilder
    private func applyCloseToolbar<Content: View>(to content: Content) -> some View {
        if let onClose {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose).disabled(working)
                }
            }
        } else {
            content
        }
    }

    private var formContent: some View {
        Form {
            if incomingURL == nil {
                Section {
                    Toggle("包含本地 TXT 和 EPUB", isOn: $includeFiles)
                    Button("导出书库备份") { Task { await createBackup() } }
                } header: { Text("导出") } footer: {
                    Text("保存书架、进度、目录、书源、书签、净化规则和阅读记录等数据。关闭开关会跳过本地书。网络正文缓存、整书离线下载和设备设置留在本机。")
                }
            }
            Section {
                if incomingURL == nil {
                    Button("选择备份文件") { selecting = true }
                }
                if let preview {
                    let library = preview.manifest.snapshot
                    let localAttachments = preview.manifest.attachments.filter { $0.path.hasPrefix("local/") }
                    let totalBytes = localAttachments.reduce(Int64(0)) { $0 + $1.bytes }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("书籍 \(library.books.count) 本 · 书源 \(library.sources.count) 个 · 净化规则 \(library.replaceRules.count) 条")
                            .font(.subheadline.weight(.medium))
                        Text("书签 \(library.bookmarks.count) 条 · 阅读记录 \(library.records.count) 条 · RSS 源 \(library.rssSources.count) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !localAttachments.isEmpty {
                            Text("本地书附件 \(localAttachments.count) 个（\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if preview.manifest.createdAt.timeIntervalSince1970 > 0 {
                            Text("备份时间：\(Self.dateFormatter.string(from: preview.manifest.createdAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    Button("合并到当前书库") { Task { await restore(preview) } }
                    Button("取消选择") { self.preview = nil }
                }
            } header: { Text("恢复") } footer: {
                Text("选择 .legadobackup 文件后先预览，再合并。同一本书保留较新的阅读进度，重复书源、净化规则、RSS 与书签保留本机版本。")
            }
            if working {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(workingLabel).foregroundStyle(.secondary)
                }
            }
            if let message {
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Color.red : Color.green)
                    if let messageDetail {
                        Text(messageDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func setSuccess(_ text: String, detail: String? = nil) {
        isError = false
        message = text
        messageDetail = detail
    }

    private func setError(_ text: String) {
        isError = true
        message = text
        messageDetail = nil
    }

    private func waitForWrites() async {
        await books.waitForLibraryWrites()
        await sources.waitForLibraryWrites()
        await rules.waitForLibraryWrites()
        await activity.waitForLibraryWrites()
        await rss.waitForLibraryWrites()
        await subscriptions.waitForLibraryWrites()
    }

    private func backupService() async throws -> LibraryBackupService {
        try await Task.detached(priority: .userInitiated) {
            try LibraryBackupService.live()
        }.value
    }

    private func createBackup() async {
        guard !working else { return }
        working = true
        workingLabel = includeFiles ? "正在打包书库与本地书…" : "正在导出书库…"
        message = nil
        messageDetail = nil
        defer { working = false }
        do {
            await waitForWrites()
            let service = try await backupService()
            let result = try await service.exportDetailed(includeLocalBooks: includeFiles)
            export = ExportedBackup(url: result.url, skippedLocalBooks: result.skippedLocalBooks)
        } catch { setError(error.localizedDescription) }
    }

    private func inspect(_ url: URL) async throws {
        guard !working else { return }
        working = true
        workingLabel = "正在校验备份文件…"
        message = nil
        messageDetail = nil
        preview = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            working = false
        }
        let service = try await backupService()
        preview = try await service.prepare(url)
    }

    private func restore(_ backup: PreparedLibraryBackup) async {
        guard !working else { return }
        working = true
        workingLabel = "正在合并到当前书库…"
        message = nil
        messageDetail = nil
        defer { working = false }
        do {
            await waitForWrites()
            let service = try await backupService()
            try await service.restore(backup)
            async let loadBooks: Void = books.load()
            async let loadSources: Void = sources.load(force: true)
            async let loadRules: Void = rules.load()
            async let loadActivity: Void = activity.load()
            async let loadRSS: Void = rss.load()
            async let loadSubs: Void = subscriptions.load()
            _ = await (loadBooks, loadSources, loadRules, loadActivity, loadRSS, loadSubs)
            preview = nil
            setSuccess("书库已恢复")
        } catch { setError(error.localizedDescription) }
    }
}

private final class ExportedBackup: Identifiable {
    let url: URL
    let skippedLocalBooks: [String]
    init(url: URL, skippedLocalBooks: [String] = []) {
        self.url = url
        self.skippedLocalBooks = skippedLocalBooks
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private struct BackupSavePicker: UIViewControllerRepresentable {
    let url: URL
    let completed: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completed) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completed: (Bool) -> Void
        init(_ completed: @escaping (Bool) -> Void) { self.completed = completed }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completed(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completed(false) }
    }
}
