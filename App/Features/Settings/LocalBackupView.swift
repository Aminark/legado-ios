import SwiftUI
import UniformTypeIdentifiers

struct LocalBackupView: View {
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var rules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var rss: RSSLibraryModel
    @EnvironmentObject private var subscriptions: RuleSubscriptionModel
    @State private var includeFiles = true
    @State private var selecting = false
    @State private var working = false
    @State private var export: ExportedBackup?
    @State private var preview: PreparedLibraryBackup?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("包含本地 TXT 和 EPUB", isOn: $includeFiles)
                Button("导出书库备份") { Task { await createBackup() } }
            } header: { Text("导出") } footer: {
                Text("保存书架、进度、目录、书源、书签、净化规则和阅读记录等数据。关闭开关会跳过本地书。网络正文缓存、整书离线下载和设备设置留在本机。")
            }
            Section {
                Button("选择备份文件") { selecting = true }
                if let preview {
                    let library = preview.manifest.snapshot
                    Text("书籍 \(library.books.count) 本 · 书源 \(library.sources.count) 个 · 净化规则 \(library.replaceRules.count) 条")
                    Button("合并到当前书库") { Task { await restore(preview) } }
                    Button("取消选择") { self.preview = nil }
                }
            } header: { Text("恢复") } footer: {
                Text("选择 .legadobackup 文件后先预览，再合并。同一本书保留较新的阅读进度，重复书源和净化规则保留本机版本。")
            }
            if working { ProgressView("正在处理书库") }
            if let message { Text(message) }
        }
        .navigationTitle("本机书库备份")
        .disabled(working)
        .fileImporter(isPresented: $selecting, allowedContentTypes: [UTType(exportedAs: "com.epiboly.legado.library-backup")]) { result in
            Task {
                do { try await inspect(result.get()) }
                catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
            }
        }
        .sheet(item: $export) { file in
            BackupSavePicker(url: file.url) { saved in
                export = nil
                if saved { message = "备份已导出" }
            }
        }
    }

    private func waitForWrites() async {
        await books.waitForLibraryWrites()
        await sources.waitForLibraryWrites()
        await rules.waitForLibraryWrites()
        await activity.waitForLibraryWrites()
        await subscriptions.waitForLibraryWrites()
    }

    private func createBackup() async {
        guard !working else { return }
        working = true
        message = nil
        defer { working = false }
        do {
            await waitForWrites()
            let url = try await LibraryBackupService.live().export(includeLocalBooks: includeFiles)
            export = ExportedBackup(url: url)
        } catch { message = error.localizedDescription }
    }

    private func inspect(_ url: URL) async throws {
        guard !working else { return }
        working = true
        message = nil
        preview = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            working = false
        }
        preview = try await LibraryBackupService.live().prepare(url)
    }

    private func restore(_ backup: PreparedLibraryBackup) async {
        guard !working else { return }
        working = true
        message = nil
        defer { working = false }
        do {
            await waitForWrites()
            try await LibraryBackupService.live().restore(backup)
            await books.load()
            await sources.load(force: true)
            await rules.load()
            await activity.load()
            await rss.load()
            await subscriptions.load()
            preview = nil
            message = "书库已恢复"
        } catch { message = error.localizedDescription }
    }
}

private final class ExportedBackup: Identifiable {
    let url: URL
    init(url: URL) { self.url = url }
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
