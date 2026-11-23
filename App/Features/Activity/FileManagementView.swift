import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
private final class FileManagementModel: ObservableObject {
    @Published var files: [LocalFileEntry] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var readyExport: BookFileExport?
    @Published var partialExport: BookFileExport?
    private var activeExport: BookFileExport?
    private let exporter = BookFileExporter()

    func reload(_ library: BookLibraryModel) async {
        do { files = try await library.localFiles.list() }
        catch { errorMessage = error.localizedDescription }
    }

    func run(_ library: BookLibraryModel, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
        await reload(library)
    }

    func importFiles(_ files: [LocalBookImportFile], library: BookLibraryModel) async {
        await run(library) {
            await library.importPickedLocalFiles(files)
            errorMessage = library.errorMessage
            library.clearError()
        }
    }

    func exportLocal(_ url: URL, filename: String, library: BookLibraryModel) async {
        await run(library) {
            let file = try await exporter.originalFile(url, filename: filename)
            activeExport = file
            readyExport = file
        }
    }

    func exportCached(_ book: Book, library: BookLibraryModel) async {
        await run(library) {
            let chapters = try await AppBookChapterRepository.live().load(bookURL: book.bookUrl)
            let file = try await exporter.cachedBook(book, chapters: chapters)
            activeExport = file
            if file.isPartial { partialExport = file }
            else { readyExport = file }
        }
    }

    func finishExport() {
        guard let file = activeExport else { return }
        activeExport = nil
        readyExport = nil
        partialExport = nil
        Task { try? await exporter.discard(file) }
    }
}

struct FileManagementView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @StateObject private var model = FileManagementModel()
    @State private var tab = 0
    @State private var query = ""
    @State private var sortBySize = false
    @State private var importsFile = false
    @State private var confirmsPartialExport = false
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var renameURL: URL?
    @State private var newName = ""
    @State private var pendingDeletion: [URL] = []

    private var localBooks: [Book] { library.books.filter { $0.origin == "local" } }
    private var networkBooks: [Book] {
        library.books.filter { $0.origin != "local" && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private func book(for url: URL) -> Book? { localBooks.first { $0.bookUrl == url.absoluteString } }
    private func filename(for url: URL) -> String {
        guard let book = book(for: url), !book.originName.isEmpty else { return url.lastPathComponent }
        return book.originName
    }
    private var displayedFiles: [LocalFileEntry] {
        model.files.filter { query.isEmpty || filename(for: $0.url).localizedCaseInsensitiveContains(query) }
            .sorted {
                if sortBySize, $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return filename(for: $0.url).localizedStandardCompare(filename(for: $1.url)) == .orderedAscending
            }
    }
    private var missingBooks: [Book] {
        let available = Set(model.files.map(\.url.absoluteString))
        return localBooks.filter { !available.contains($0.bookUrl) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    private var fileList: some View {
        List(selection: $selection) {
            Section {
                Picker("文件类型", selection: $tab) {
                    Text("本地文件").tag(0)
                    Text("缓存正文").tag(1)
                }
                .pickerStyle(.segmented)
                .disabled(selecting)
            }
            if tab == 0 { localFilesSection }
            else { cachedBooksSection }
            if !selecting {
                Section {
                    NavigationLink { CacheManagementView() } label: {
                        Label("章节缓存与空间清理", systemImage: "internaldrive")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .navigationTitle("文件管理")
        .searchable(text: $query, prompt: tab == 0 ? "搜索本地文件" : "搜索缓存书籍")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button("完成") { selecting = false; selection.removeAll() }
                } else {
                    Menu {
                        Button("导入 TXT / EPUB", systemImage: "square.and.arrow.down") { importsFile = true }
                        if tab == 0 {
                            Button("选择文件", systemImage: "checkmark.circle") { selecting = true }
                                .disabled(displayedFiles.isEmpty)
                            Picker("排序", selection: $sortBySize) {
                                Text("按名称").tag(false)
                                Text("按大小").tag(true)
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("更多")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button(selection.count == displayedFiles.count ? "取消全选" : "全选") {
                        selection = selection.count == displayedFiles.count ? [] : Set(displayedFiles.map(\.url))
                    }
                    Spacer()
                    Button("删除 \(selection.count) 个文件", role: .destructive) { pendingDeletion = Array(selection) }
                        .disabled(selection.isEmpty)
                }
                .padding().background(.bar)
            }
        }
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView("正在处理文件…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await model.reload(library) }
        .onChange(of: library.books) { _ in Task { await model.reload(library) } }
        .onChange(of: query) { _ in selection.removeAll() }
        .refreshable { await model.reload(library) }
    }

    private var importAndRenameView: some View {
        fileList
        .readingLocalBookFileImporter(isPresented: $importsFile) { files in
            Task { await model.importFiles(files, library: library) }
        } onError: { error in
            model.errorMessage = error.localizedDescription
        }
        .alert("重命名文件", isPresented: Binding(get: { renameURL != nil }, set: { if !$0 { renameURL = nil } }), presenting: renameURL) { url in
            TextField("文件名", text: $newName)
            Button("取消", role: .cancel) { renameURL = nil }
            Button("保存") {
                let name = newName
                renameURL = nil
                Task { await model.run(library) { try await library.renameLocalFile(at: url, to: name) } }
            }
        } message: { _ in
            Text("保留原文件格式，书架中的书名、书签和阅读进度不变。")
        }
    }

    private var deletionView: some View {
        importAndRenameView
        .confirmationDialog("删除 \(pendingDeletion.count) 个文件？", isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }), titleVisibility: .visible, presenting: pendingDeletion) { urls in
            Button("删除文件并移出书架", role: .destructive) {
                pendingDeletion = []
                Task {
                    await model.run(library) {
                        var failures: [String] = []
                        for url in urls {
                            do { try await library.deleteLocalFile(at: url) }
                            catch { failures.append("\(filename(for: url))：\(error.localizedDescription)") }
                        }
                        selection.removeAll()
                        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "\n") }
                    }
                }
            }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: { _ in
            Text("将删除应用内文件及对应书架条目，系统“文件”中用于导入的原文件保留。")
        }
    }

    var body: some View {
        deletionView
        .onChange(of: model.partialExport?.id) { value in confirmsPartialExport = value != nil }
        .onChange(of: confirmsPartialExport) { isPresented in
            if !isPresented {
                Task { @MainActor in
                    await Task.yield()
                    if !confirmsPartialExport, model.readyExport == nil { model.finishExport() }
                }
            }
        }
        .confirmationDialog("缓存正文不完整", isPresented: $confirmsPartialExport, titleVisibility: .visible, presenting: model.partialExport) { file in
            Button("导出已缓存内容") {
                model.readyExport = file
                model.partialExport = nil
            }
            Button("取消", role: .cancel) { model.finishExport() }
        } message: { file in
            Text("已缓存 \(file.cachedChapters)/\(file.totalChapters) 章。导出文件会标记未缓存章节，可先返回详情缓存完整后再导出。")
        }
        .sheet(item: $model.readyExport, onDismiss: { model.finishExport() }) { file in
            FileExportPicker(url: file.url) { model.readyExport = nil }
        }
        .alert("文件操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "未知错误") }
    }

    @ViewBuilder private var localFilesSection: some View {
        Section {
            ReadingLabeledContent("本地文件", value: "\(model.files.count) 个")
            ReadingLabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: model.files.reduce(0) { $0 + $1.bytes }, countStyle: .file))
        }
        Section("文件") {
            if displayedFiles.isEmpty {
                ReadingUnavailableView(query.isEmpty ? "还没有本地文件" : "没有匹配的文件", systemImage: "doc.text", description: Text("可从系统“文件”导入 TXT 或 EPUB，文件会复制到应用中。"))
                Button("导入 TXT / EPUB", systemImage: "plus") { importsFile = true }
            }
            ForEach(displayedFiles) { file in
                Group {
                    if selecting { fileLabel(file) }
                    else if let book = book(for: file.url) {
                        NavigationLink { BookshelfReadView(book: book, source: nil, coordinator: library.updateCoordinator) } label: { fileLabel(file) }
                    } else {
                        Button { Task { await model.run(library) { try await library.addLocalFile(at: file.url) } } } label: { fileLabel(file) }
                    }
                }
                .tag(file.url)
                .contextMenu {
                    Button("导出文件", systemImage: "square.and.arrow.up") { export(file) }
                    Button("重命名", systemImage: "pencil") { renameURL = file.url; newName = filename(for: file.url) }
                    Button("删除文件", systemImage: "trash", role: .destructive) { pendingDeletion = [file.url] }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { pendingDeletion = [file.url] }
                    Button("导出", systemImage: "square.and.arrow.up") { export(file) }.tint(.blue)
                }
            }
        }
        if !missingBooks.isEmpty {
            Section("文件已丢失") {
                ForEach(missingBooks) { book in
                    HStack {
                        Label(book.name, systemImage: "doc.badge.ellipsis")
                        Spacer()
                        Button("移出书架", role: .destructive) {
                            if let url = URL(string: book.bookUrl) { pendingDeletion = [url] }
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var cachedBooksSection: some View {
        Section {
            Text("将书架中已缓存的网络正文导出为 TXT，按目录顺序排列。导出过程不下载新章节。")
                .font(.footnote).foregroundStyle(.secondary)
            if networkBooks.isEmpty {
                ReadingUnavailableView("没有可导出的书籍", systemImage: "books.vertical", description: Text("将网络书加入书架并缓存章节后，可在这里导出。"))
            }
            ForEach(networkBooks) { book in
                Button {
                    Task { await model.exportCached(book, library: library) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name).foregroundStyle(.primary)
                            Text(book.author.isEmpty ? "导出缓存正文" : book.author).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } header: { Text("缓存正文") }
    }

    private func fileLabel(_ file: LocalFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(filename(for: file.url)).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                    if let modified = file.modified { Text(modified, style: .date) }
                }.font(.caption).foregroundStyle(.secondary)
                if let book = book(for: file.url) {
                    Text("书架：\(book.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else { Text("点按加入书架").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func export(_ file: LocalFileEntry) {
        Task { await model.exportLocal(file.url, filename: filename(for: file.url), library: library) }
    }
}

private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCompletion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(_ completion: @escaping () -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
    }
}
