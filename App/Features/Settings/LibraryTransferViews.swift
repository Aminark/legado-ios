import SwiftUI
import UniformTypeIdentifiers

struct AndroidLibraryImportView: View {
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var rules: ReplaceRuleLibraryModel
    @State private var picking = false
    @State private var preview: AndroidLibraryImport?
    @State private var selected = Set<ImportSection>()
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("选择 ZIP 备份") { picking = true }
                if busy { ProgressView() }
                if let message { Text(message) }
            } footer: { Text("从 Android 阅读导出的备份中选择要导入的数据。同一书籍保留较新的进度，已有书源和净化规则优先。") }
            if let preview {
                Section("导入内容") {
                    ForEach(ImportSection.allCases, id: \.self) { section in
                        let count = preview.count(section)
                        if count > 0 {
                            Toggle("\(section.title)（\(count)）", isOn: Binding(
                                get: { selected.contains(section) },
                                set: { if $0 { selected.insert(section) } else { selected.remove(section) } }
                            ))
                        }
                    }
                    if preview.skippedLocalBooks > 0 {
                        Text("\(preview.skippedLocalBooks) 本本地书需要另行导入原文件。")
                    }
                    Button("导入已选内容") { Task { await restore(preview) } }.disabled(selected.isEmpty)
                }
            }
        }
        .navigationTitle("导入阅读备份")
        .disabled(busy)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
            do {
                let url = try result.get()
                Task { await inspect(url) }
            } catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
        }
    }

    private func inspect(_ url: URL) async {
        busy = true
        defer { busy = false }
        preview = nil
        message = nil
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try AndroidLibraryImport(url: url)
            }.value
            selected = Set(ImportSection.allCases.filter { value.count($0) > 0 })
            preview = value
            message = selected.isEmpty ? "备份中没有可导入的数据。" : url.lastPathComponent
        } catch { message = error.localizedDescription }
    }

    private func restore(_ value: AndroidLibraryImport) async {
        busy = true
        defer { busy = false }
        do {
            await books.waitForLibraryWrites()
            await sources.waitForLibraryWrites()
            await rules.waitForLibraryWrites()
            let db = try LegadoDatabase(url: LegadoDatabase.defaultURL())
            try await db.restoreLibrary(value, sections: selected, legacyRulesURL: LibraryRuleRepository.legacyURL)
            try await db.applyImportedPreferences()
            await books.load()
            await sources.load(force: true)
            await rules.load()
            preview = nil
            message = "导入完成"
        } catch { message = error.localizedDescription }
    }
}

struct OfflineBooksView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var progress: [OfflineEditionProgress] = []
    @State private var picking = false
    @State private var loading = false
    @State private var message: String?
    @State private var removal: OfflineEditionProgress?

    var body: some View {
        List {
            Section {
                Button("选择要下载的书") { picking = true }.disabled(loading)
                if loading { ProgressView("读取目录") }
                if let message { Text(message).foregroundStyle(.secondary) }
            } footer: { Text("已下载的正文可离线阅读。重新打开应用后，进行中的下载会继续。") }
            ForEach(progress) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline)
                    ProgressView(value: Double(item.saved), total: Double(max(1, item.total)))
                    Text("\(status(item)) · 已保存 \(item.saved)/\(item.total) 章").font(.caption)
                    if let cause = item.message { Text(cause).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if item.state == .waiting {
                            Button("暂停") { perform { try await OfflineEditions.shared.pause(item.id) } }
                        } else if item.state == .paused || item.failed > 0 {
                            Button(item.failed > 0 ? "重试失败章节" : "继续") {
                                perform { try await OfflineEditions.shared.activate(sources: sources.sources); try await OfflineEditions.shared.resume(item.id) }
                            }
                        }
                        Spacer()
                        Button("移除下载", role: .destructive) { removal = item }
                    }.buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("整书离线")
        .sheet(isPresented: $picking) {
            ReadingNavigationStack {
                List {
                    let available = library.books.filter { book in
                        !progress.contains { $0.id == book.id } && sources.sources.contains { $0.id == book.origin && $0.enabled && $0.bookSourceType == 0 }
                    }
                    if available.isEmpty { Text("书架中没有可添加的在线文字书。") }
                    ForEach(available) { book in
                        Button(book.name) { picking = false; Task { await add(book) } }
                    }
                }
                .navigationTitle("选择书籍")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { picking = false } } }
            }
        }
        .alert(item: $removal) { item in
            Alert(title: Text("移除《\(item.title)》的离线下载？"), primaryButton: .destructive(Text("移除")) {
                perform { try await OfflineEditions.shared.remove(item.id) }
            }, secondaryButton: .cancel())
        }
        .task {
            do {
                try await OfflineEditions.shared.activate(sources: sources.sources)
                for await items in try await OfflineEditions.shared.observe() { progress = items }
            } catch { message = error.localizedDescription }
        }
    }

    private func status(_ item: OfflineEditionProgress) -> String {
        switch item.state {
        case .waiting: "下载队列"
        case .paused: "已暂停"
        case .finished: item.failed == 0 ? "已完成" : "\(item.failed) 章失败"
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work() } catch { message = error.localizedDescription } }
    }

    private func add(_ book: Book) async {
        guard let source = sources.sources.first(where: { $0.id == book.origin }) else { return }
        loading = true
        message = nil
        defer { loading = false }
        do {
            let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
            var chapters = try await database.loadChapters(bookURL: book.id)
            if chapters.isEmpty {
                let report = await NetworkBookService().loadChapters(book: book, source: source)
                if let problem = report.diagnostics.first(where: { $0.severity == .error }) {
                    message = problem.message
                    return
                }
                chapters = report.chapters
                guard !chapters.isEmpty else { message = "书源没有返回可下载的章节。"; return }
                try await database.replaceChapters(chapters, bookURL: book.id)
            }
            try await OfflineEditions.shared.enqueue(book: book, chapters: chapters, source: source)
        } catch { message = error.localizedDescription }
    }
}

struct LibraryPassageView: View {
    struct Target {
        let book: Book
        let chapters: [BookChapter]
    }
    var current: Target?
    var jump: ((Int, Int) -> Void)?
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var rules: ReplaceRuleLibraryModel
    @State private var query = ""
    @State private var index: LibraryPassageSearch?
    @State private var hits: [LibraryPassageSearch.Hit] = []
    @State private var resultLimit = 200
    @State private var hasMore = false
    @State private var progress = "正在准备正文"
    @State private var issue: String?
    @State private var opening: Target?
    @State private var showReader = false

    var body: some View {
        List {
            if index == nil && issue == nil { HStack { ProgressView(); Text(progress) } }
            if let issue { Text(issue).foregroundStyle(.secondary) }
            if index != nil, !query.isEmpty, hits.isEmpty { Text("没有找到匹配的正文") }
            ForEach(hits) { hit in
                Button { Task { await open(hit) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.title).font(.headline)
                        if current == nil { Text(library.books.first { $0.id == hit.bookID }?.name ?? "").font(.caption) }
                        Text(hit.excerpt).font(.subheadline).lineLimit(3)
                    }
                }.buttonStyle(.plain)
            }
            if hasMore {
                Button("显示更多结果") { resultLimit += 200 }
            }
        }
        .onChange(of: query) { _ in resultLimit = 200 }
        .navigationTitle(current == nil ? "书架正文搜索" : "搜索全书")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本地书和已缓存正文")
        .task { await prepare() }
        .task(id: Request(text: query, session: index.map(ObjectIdentifier.init), limit: resultLimit)) {
            hasMore = false
            hits = []
            guard let index, !query.isEmpty else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let result = try await index.matches(query, limit: resultLimit + 1)
                try Task.checkCancellation()
                hasMore = result.count > resultLimit
                hits = Array(result.prefix(resultLimit))
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
        .readingNavigationDestination(isPresented: $showReader) {
            if let opening {
                if opening.book.origin == "local" {
                    ReaderView(textSearchBook: opening.book, chapters: opening.chapters)
                } else if let source = sources.sources.first(where: { $0.id == opening.book.origin }) {
                    ReaderView(book: opening.book, chapters: opening.chapters, initialIndex: opening.book.durChapterIndex, source: source)
                }
            }
        }
    }

    private struct Request: Equatable { let text: String; let session: ObjectIdentifier?; let limit: Int }

    private func prepare() async {
        index = nil
        issue = nil
        do {
            let search = try LibraryPassageSearch()
            let db = try LegadoDatabase(url: LegadoDatabase.defaultURL())
            let books = current.map { [$0.book] } ?? library.books
            var unavailable = 0
            for book in books {
                try Task.checkCancellation()
                progress = "正在读取《\(book.name)》"
                do {
                    var chapters: [BookChapter]
                    if let current { chapters = current.chapters }
                    else { chapters = try await db.loadChapters(bookURL: book.id) }
                    if chapters.isEmpty && book.origin == "local" {
                        chapters = try await Task.detached { try LocalBookService.live().loadChapters(book: book).chapters }.value
                    }
                    try await search.collect(book: book, chapters: chapters, rules: rules.rules)
                } catch { try Task.checkCancellation(); unavailable += 1 }
            }
            try Task.checkCancellation()
            issue = unavailable == 0 ? nil : "\(unavailable) 本书有正文无法读取"
            index = search
        } catch { if !Task.isCancelled { issue = error.localizedDescription; progress = "无法准备正文" } }
    }

    private func open(_ hit: LibraryPassageSearch.Hit) async {
        if let jump { jump(hit.chapterOffset, hit.position); return }
        guard let index, var book = library.books.first(where: { $0.id == hit.bookID }) else { return }
        guard book.origin == "local" || sources.sources.contains(where: { $0.id == book.origin }) else {
            issue = "此书的书源已移除。"
            return
        }
        book.durChapterIndex = hit.chapterOffset
        book.durChapterPos = hit.position
        opening = Target(book: book, chapters: await index.chapters(for: book.id))
        showReader = true
    }
}
