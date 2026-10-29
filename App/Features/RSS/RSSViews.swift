import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import UIKit
import Photos

struct RSSHomeView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @State private var section = 0
    @State private var searchText = ""
    @State private var showsFiles = false
    @State private var showsTextImport = false
    @State private var showsExport = false
    @State private var confirmsClear = false
    @State private var editingStar: RssStar?

    var body: some View {
        let content = AnyView(VStack(spacing: 0) {
            Picker("RSS页面", selection: $section) {
                Text("订阅").tag(0); Text("收藏").tag(1); Text("记录").tag(2)
            }
            .pickerStyle(.segmented).padding()
            selectedList
        })
        let navigation = AnyView(content
            .navigationTitle("RSS")
            .searchable(text: $searchText, prompt: section == 0 ? "搜索订阅源" : "搜索文章"))
        let actions = AnyView(navigation.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("RSS操作", systemImage: "ellipsis.circle") {
                    NavigationLink { RSSSourceEditorView() } label: { Label("新建RSS源", systemImage: "plus") }
                    NavigationLink { RuleSubscriptionView() } label: { Label("规则订阅", systemImage: "link") }
                    Button("导入文件", systemImage: "doc.badge.plus") { showsFiles = true }
                    Button("URL或粘贴JSON", systemImage: "link.badge.plus") { showsTextImport = true }
                    Button("导出全部RSS源", systemImage: "square.and.arrow.up") { showsExport = true }
                }
            }
            ToolbarItem(placement: .primaryAction) { if section == 0 { EditButton() } }
            ToolbarItem(placement: .primaryAction) {
                if section == 1, !library.stars.isEmpty { Button("清空收藏", systemImage: "trash", role: .destructive) { confirmsClear = true } }
                else if section == 2, !library.records.isEmpty { Button("清空记录", systemImage: "trash", role: .destructive) { confirmsClear = true } }
            }
        })
        let importing = AnyView(actions.fileImporter(isPresented: $showsFiles, allowedContentTypes: [.json, .text], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
        })
        let sheets = AnyView(importing
            .sheet(isPresented: $showsTextImport) { RSSImportSheet() }
            .sheet(item: $editingStar) { value in
                RSSStarEditSheet(star: value, save: { updated in
                    Task { await library.saveStar(updated) }
                })
            })
        let exporting = AnyView(sheets.fileExporter(isPresented: $showsExport, document: RSSExportDocument(sources: library.sources), contentType: UTType.json, defaultFilename: "rssSources") { result in
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
        })
        let status = AnyView(exporting
            .overlay { if library.isWorking { ProgressView().controlSize(.large) } }
            .alert("RSS操作失败", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") })
        return status.confirmationDialog(section == 1 ? "确定清空全部RSS收藏？" : "确定清空全部RSS阅读记录？", isPresented: $confirmsClear, titleVisibility: Visibility.visible) {
            Button("清空", role: .destructive) { Task { if section == 1 { await library.clearStars() } else { await library.clearRecords() } } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var selectedList: some View {
        switch section {
        case 1: starList
        case 2: recordList
        default: sourceList
        }
    }

    private var sourceList: some View {
        List {
            if filteredSources.isEmpty {
                ReadingUnavailableView("还没有RSS源", systemImage: "dot.radiowaves.left.and.right", description: Text("从文件、URL或剪贴板导入 RSS 源。"))
            }
            ForEach(filteredSources) { source in
                NavigationLink { RSSSourceDestinationView(sourceURL: source.sourceUrl) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(source.sourceName).font(.headline); Spacer(); if !source.enabled { Text("停用").font(.caption).foregroundStyle(.secondary) } }
                        Text(source.sourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let group = source.sourceGroup, !group.isEmpty { Text(group).font(.caption2).foregroundStyle(ReadingTheme.accent) }
                    }.padding(.vertical, 3)
                }
                .swipeActions(edge: .leading) {
                    Button(source.enabled ? "停用" : "启用") { Task { await library.setEnabled(!source.enabled, source: source) } }.tint(.orange)
                }
                .swipeActions {
                    Button("删除", role: .destructive) { Task { await library.remove(source) } }
                }
                .contextMenu {
                    NavigationLink { RSSSourceEditorView(source: source) } label: { Label("编辑", systemImage: "pencil") }
                }
                .moveDisabled(!searchText.isEmpty)
            }
            .onMove { offsets, destination in Task { await library.moveSources(from: offsets, to: destination) } }
        }.listStyle(.plain)
    }

    private var starList: some View {
        List {
            ForEach(filteredStars) { star in
                Group {
                    if let source = library.sources.first(where: { $0.sourceUrl == star.origin }) {
                        NavigationLink { RSSArticleDetailView(article: star.article, source: source) } label: { RSSArticleRow(article: star.article) }
                    } else { RSSArticleRow(article: star.article) }
                }.swipeActions(edge: .leading) { Button("编辑", systemImage: "pencil") { editingStar = star }.tint(.blue) }
            }.onDelete { offsets in
                let values = offsets.map { filteredStars[$0] }
                Task { for value in values { await library.removeStar(value) } }
            }
        }.overlay { if filteredStars.isEmpty { ReadingUnavailableView("没有收藏", systemImage: "star") } }.listStyle(.plain)
    }
    private var recordList: some View {
        List(filteredRecords) { record in
            if let source = library.sources.first(where: { $0.sourceUrl == record.origin }) {
                NavigationLink { RSSArticleDetailView(article: record.article, source: source) } label: { RSSArticleRow(article: record.article) }
            } else { RSSArticleRow(article: record.article) }
        }.overlay { if filteredRecords.isEmpty { ReadingUnavailableView("没有阅读记录", systemImage: "clock") } }.listStyle(.plain)
    }
    private var filteredSources: [RssSource] { library.sources.filter { searchText.isEmpty || $0.sourceName.localizedCaseInsensitiveContains(searchText) || $0.sourceUrl.localizedCaseInsensitiveContains(searchText) || ($0.sourceGroup ?? "").localizedCaseInsensitiveContains(searchText) } }
    private var filteredStars: [RssStar] { library.stars.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) } }
    private var filteredRecords: [RssReadRecord] { library.records.filter { searchText.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(searchText) } }
}

private struct RSSArticleListView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let source: RssSource
    @State private var searchKey = ""
    @State private var sorts: [RSSSort] = []
    @State private var selectedSort = 0

    var body: some View {
        VStack(spacing: 0) {
            if sorts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(Array(sorts.enumerated()), id: \.element.id) { index, sort in
                        Button(sort.name.isEmpty ? "默认" : sort.name) { selectedSort = index; Task { await refresh() } }
                            .readingChoiceButtonStyle(isSelected: selectedSort == index)
                    }}.padding(.horizontal)
                }.padding(.vertical, 6)
            }
            articleCollection
        }
        .overlay { if library.articles.isEmpty, !library.isWorking { ReadingUnavailableView("没有文章", systemImage: "newspaper") } }
        .navigationTitle(source.sourceName)
        .searchable(text: $searchKey, prompt: "源内搜索")
        .onSubmit(of: .search) { Task { await refresh() } }
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("刷新", systemImage: "arrow.clockwise") { Task { await refresh() } } }
            ToolbarItem(placement: .primaryAction) { NavigationLink { RSSSourceEditorView(source: source) } label: { Label("编辑", systemImage: "pencil") } }
            ToolbarItem(placement: .primaryAction) { NavigationLink { RSSSourceDebugView(source: source) } label: { Label("调试", systemImage: "stethoscope") } }
            ToolbarItem(placement: .bottomBar) {
                Button("加载下一页", systemImage: "arrow.down") {
                    Task { await library.loadMore(source, sortName: activeName, key: searchKey.nilIfEmpty) }
                }.disabled(library.isWorking)
            }
        }
        .task { sorts = await RSSSortResolver().resolve(source); await refresh() }
        .readingTabBarHidden()
    }

    private var activeSort: RSSSort { sorts.indices.contains(selectedSort) ? sorts[selectedSort] : .init(name: "", url: source.sourceUrl) }
    private var activeName: String { searchKey.nilIfEmpty == nil ? activeSort.name : "搜索" }
    private func refresh() async {
        let url = searchKey.nilIfEmpty == nil ? activeSort.url : (source.searchUrl?.nilIfEmpty ?? activeSort.url)
        await library.refresh(source, sortName: activeName, sortURL: url, key: searchKey.nilIfEmpty)
    }

    @ViewBuilder private var articleCollection: some View {
        if source.articleStyle == 0 {
            List(library.articles) { article in
                NavigationLink { RSSArticleDetailView(article: article, source: source) } label: { RSSArticleRow(article: article) }
            }.listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: articleColumns, spacing: source.articleStyle == 3 ? 20 : 8) {
                    ForEach(library.articles) { article in
                        NavigationLink { RSSArticleDetailView(article: article, source: source) } label: {
                            RSSArticleCard(article: article, style: source.articleStyle)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, source.articleStyle == 3 ? 20 : 8).padding(.bottom, 20)
            }.refreshable { await refresh() }
        }
    }

    private var articleColumns: [GridItem] {
        let count = source.articleStyle == 1 ? 1 : (source.articleStyle == 4 ? 3 : 2)
        return Array(repeating: GridItem(.flexible(), spacing: source.articleStyle == 3 ? 20 : 8, alignment: .top), count: count)
    }
}

private struct RSSSourceDestinationView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let sourceURL: String
    var body: some View {
        // NavigationLink can retain its destination after a source is replaced
        // by an import. Resolve current rules through the shared library.
        if let source = library.sources.first(where: { $0.sourceUrl == sourceURL }) {
            if source.singleUrl {
                RSSStandaloneReaderView(source: source, mode: .web(url: source.sourceUrl))
            } else if let mode = try? RSSStartPageResolver().resolve(source) {
                RSSStandaloneReaderView(source: source, mode: mode)
            } else {
                RSSArticleListView(source: source)
            }
        } else {
            ReadingUnavailableView("订阅源已删除", systemImage: "newspaper")
        }
    }
}

private struct RSSStandaloneReaderView: View {
    let source: RssSource
    let mode: RSSReadingMode
    @State private var route: RSSNativeRoute?
    var body: some View {
        RSSWebReaderView(mode: mode, source: source, onAction: handle)
            .navigationTitle(source.sourceName).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $route) { route in
                switch route {
                case .photo(let value): RSSPhotoView(value: value, source: source)
                case .search(let value): ReadingNavigationStack { SearchView(initialKeyword: value) }
                case .rss(let article): ReadingNavigationStack { RSSArticleDetailView(article: article, source: source) }
                case .login: ReadingNavigationStack { SourceLoginView(source: source.bookSourceAdapter) }
                case .sort(let value): ReadingNavigationStack { RSSArticleListView(source: value) }
                case .addBook(let value): ReadingNavigationStack { RSSAddBookView(bookURL: value) }
                case .download(let url, let fileName): ReadingNavigationStack { RSSDownloadView(url: url, fileName: fileName, source: source) }
                case .start(let mode): ReadingNavigationStack { RSSStandaloneReaderView(source: source, mode: mode) }
                }
            }
    }
    private func handle(_ action: RSSWebAction) {
        switch action {
        case .showPhoto(let value): route = .photo(value)
        case .searchBook(let key, _): route = .search(key)
        case .addBook(let value): route = .addBook(value)
        case .download(let url, let fileName): route = .download(url: url, fileName: fileName)
        case .open(let name, let url, let title, _):
            switch name.lowercased() {
            case "login": route = .login
            case "search": if let value = title ?? url { route = .search(value) }
            case "sort": var value = source; value.sortUrl = url; route = .sort(value)
            case "rss":
                if let url { route = .rss(.init(origin: source.sourceUrl, sort: "", title: title ?? source.sourceName, link: url)) }
                else if source.singleUrl { route = .start(.web(url: source.sourceUrl)) }
                else if let mode = try? RSSStartPageResolver().resolve(source) { route = .start(mode) }
                else { route = .sort(source) }
            default: if let url, let target = URL(string: url) { UIApplication.shared.open(target) }
            }
        }
    }
}

private struct RSSArticleRow: View {
    let article: RssArticle
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(article.title).font(.headline).foregroundStyle(article.read ? .secondary : .primary)
                if let description = article.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let date = article.pubDate, !date.isEmpty { Text(date).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            if article.type == 1 { Image(systemName: "photo") }
            else if article.type == 2 { Image(systemName: "play.rectangle") }
        }.padding(.vertical, 3)
    }
}

private struct RSSArticleCard: View {
    let article: RssArticle
    let style: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            articleImage
            Text(article.title)
                .font(style == 1 || style == 3 ? .subheadline.bold() : .caption)
                .foregroundStyle(article.read ? .secondary : .primary)
                .lineLimit(style == 3 ? 9 : 2)
                .padding(.horizontal, style == 1 ? 12 : 6).padding(.top, 10)
            if let date = article.pubDate, !date.isEmpty {
                Text(date).font(.caption2).foregroundStyle(.secondary).lineLimit(style == 3 ? 39 : 1)
                    .padding(.horizontal, style == 1 ? 12 : 6).padding(.top, 8).padding(.bottom, 10)
            } else { Spacer().frame(height: 10) }
        }
        .background(style == 3 ? Color(.secondarySystemBackground) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: style == 3 ? 12 : 0, style: .continuous))
        .overlay { if style == 3 { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)) } }
    }

    @ViewBuilder private var articleImage: some View {
        let height = imageHeight
        if let raw = article.image, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else if phase.error != nil { placeholder }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity).frame(height: height).clipped()
        } else { placeholder.frame(height: height) }
    }

    private var placeholder: some View {
        ZStack { Color(.tertiarySystemFill); Image(systemName: article.type == 2 ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imageHeight: CGFloat {
        switch style {
        case 1: return 220
        case 2: return 272
        case 4: return 182
        default: return 180
        }
    }
}

private struct RSSArticleDetailView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let article: RssArticle
    let source: RssSource
    @State private var mode: RSSReadingMode?
    @State private var speechText = ""
    @State private var reloadID = UUID()
    @State private var forceRefresh = false
    @StateObject private var speech = RSSSpeechController()
    @State private var nativeRoute: RSSNativeRoute?

    var body: some View {
        Group {
            if let mode {
                RSSWebReaderView(mode: mode, source: source, onTextChange: { speechText = $0 }, onAction: handleWebAction)
                    .id(reloadID)
            } else {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(library.isStarred(article) ? "取消收藏" : "收藏", systemImage: library.isStarred(article) ? "star.fill" : "star") { Task { await library.toggleStar(article) } }
            }
            ToolbarItem(placement: .primaryAction) {
                if let url = URL(string: article.link) { ReadingShareLink(item: url) }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("阅读操作", systemImage: "ellipsis.circle") {
                    Button(speech.isSpeaking ? "停止朗读" : "朗读正文", systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill") {
                        speech.isSpeaking ? speech.stop() : speech.speak(speechText)
                    }.disabled(speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("刷新", systemImage: "arrow.clockwise") { forceRefresh = true; reloadID = UUID() }
                    if let url = URL(string: article.link) { Link("浏览器打开", destination: url) }
                    if source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        NavigationLink { SourceLoginView(source: source.bookSourceAdapter) } label: { Label("源登录", systemImage: "person.badge.key") }
                    }
                    NavigationLink { RSSSourceEditorView(source: source) } label: { Label("编辑源", systemImage: "pencil") }
                    NavigationLink { RSSSourceDebugView(source: source) } label: { Label("调试源", systemImage: "stethoscope") }
                }
            }
        }
        .task(id: "\(article.id):\(reloadID)") {
            mode = nil
            speechText = ""
            speech.stop()
            await library.read(article)
            let loaded = await library.readingMode(for: article, source: source, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            mode = loaded
        }
        .sheet(item: $nativeRoute) { route in
            switch route {
            case .photo(let value): RSSPhotoView(value: value, source: source)
            case .search(let key): ReadingNavigationStack { SearchView(initialKeyword: key) }
            case .rss(let target): ReadingNavigationStack { RSSArticleDetailView(article: target, source: source) }
            case .login: ReadingNavigationStack { SourceLoginView(source: source.bookSourceAdapter) }
            case .sort(let target): ReadingNavigationStack { RSSArticleListView(source: target) }
            case .addBook(let value): ReadingNavigationStack { RSSAddBookView(bookURL: value) }
            case .download(let url, let fileName): ReadingNavigationStack { RSSDownloadView(url: url, fileName: fileName, source: source) }
            case .start(let value): ReadingNavigationStack { RSSStandaloneReaderView(source: source, mode: value) }
            }
        }
    }

    private func handleWebAction(_ action: RSSWebAction) {
        switch action {
        case .showPhoto(let value): nativeRoute = .photo(value)
        case .searchBook(let key, _): nativeRoute = .search(key)
        case .addBook(let value): nativeRoute = .addBook(value)
        case .open(let name, let url, let title, _):
            switch name.lowercased() {
            case "search": if let key = title ?? url { nativeRoute = .search(key) }
            case "login": nativeRoute = .login
            case "sort":
                var target = source
                if let url {
                    if let title, let data = try? JSONSerialization.data(withJSONObject: [title: url]) { target.sortUrl = String(decoding: data, as: UTF8.self) }
                    else { target.sortUrl = url }
                }
                nativeRoute = .sort(target)
            case "rss":
                if let url { nativeRoute = .rss(.init(origin: source.sourceUrl, sort: "", title: title ?? source.sourceName, link: url)) }
                else if source.singleUrl { nativeRoute = .start(.web(url: source.sourceUrl)) }
                else if let mode = try? RSSStartPageResolver().resolve(source) { nativeRoute = .start(mode) }
                else { nativeRoute = .sort(source) }
            default: if let url, let target = URL(string: url) { UIApplication.shared.open(target) }
            }
        case .download(let url, let fileName): nativeRoute = .download(url: url, fileName: fileName)
        }
    }
}

private enum RSSNativeRoute: Identifiable {
    case photo(String), search(String), rss(RssArticle), login, sort(RssSource), addBook(String), download(url: String, fileName: String), start(RSSReadingMode)
    var id: String {
        switch self {
        case .photo(let value): return "photo:\(value)"
        case .search(let value): return "search:\(value)"
        case .rss(let value): return "rss:\(value.id)"
        case .login: return "login"
        case .sort(let value): return "sort:\(value.sourceUrl):\(value.sortUrl ?? "")"
        case .addBook(let value): return "addBook:\(value)"
        case .download(let url, _): return "download:\(url)"
        case .start(let mode): return "start:\(String(describing: mode))"
        }
    }
}

private struct RSSDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    let url: String
    let fileName: String
    let source: RssSource
    @State private var data = Data()
    @State private var loading = true
    @State private var showsExporter = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            if loading { ProgressView("正在下载…") }
            else if let errorMessage { ReadingUnavailableView("下载失败", systemImage: "exclamationmark.arrow.triangle.2.circlepath", description: Text(errorMessage)) }
            else {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 48)).foregroundStyle(ReadingTheme.accent)
                Text(fileName).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).foregroundStyle(.secondary)
                Button("选择保存位置", systemImage: "folder") { showsExporter = true }.readingProminentButtonStyle()
            }
        }.padding().navigationTitle("文件下载").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: url) { await download() }
            .fileExporter(isPresented: $showsExporter, document: RSSBinaryDocument(data: data), contentType: .data, defaultFilename: fileName) { result in if case .failure(let error) = result { errorMessage = error.localizedDescription } }
    }

    private func download() async {
        do {
            guard let target = URL(string: url) else { throw URLError(.badURL) }
            var request = URLRequest(url: target)
            if let headers = try? BookSourceHeaderResolver().resolve(source.bookSourceAdapter) { for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) } }
            let cookie = LegadoCookieStore.shared.cookieHeader(for: url)
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (value, response) = try await URLSessionHTTPTransport.shared.download(for: request)
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) { throw URLError(.badServerResponse) }
            data = value; loading = false; showsExporter = true
        } catch { errorMessage = error.localizedDescription; loading = false }
    }
}

private struct RSSBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private struct RSSPhotoToolbar: ViewModifier {
    let canSave: Bool
    let save: () -> Void
    let close: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("保存到照片", systemImage: "square.and.arrow.down", action: save).disabled(!canSave)
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: close).buttonStyle(.plain)
                }.sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("保存到照片", systemImage: "square.and.arrow.down", action: save).disabled(!canSave)
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) }
            }
        }
    }
}

struct RSSPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let value: String
    let source: RssSource
    @State private var image: UIImage?
    @State private var loading = true
    @State private var message: String?
    var body: some View {
        ReadingNavigationStack {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if let image { Image(uiImage: image).resizable().scaledToFit() }
                        else if loading { ProgressView() }
                        else { ReadingUnavailableView("图片加载失败", systemImage: "photo.badge.exclamationmark") }
                    }.frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .background(.black)
                .environment(\.colorScheme, .dark)
                .tint(.white)
            }
            .navigationTitle(source.sourceName).navigationBarTitleDisplayMode(.inline)
            .readingNavigationBarBackground()
            .modifier(RSSPhotoToolbar(canSave: image != nil, save: save, close: { dismiss() }))
            .task(id: value) { await load() }
            .alert("图片", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
        }
        .readingTabBarHidden()
    }

    private func load() async {
        do {
            let data: Data
            if value.lowercased().hasPrefix("data:"), let comma = value.firstIndex(of: ",") {
                let metadata = value[..<comma].lowercased()
                let payload = String(value[value.index(after: comma)...])
                data = metadata.contains(";base64") ? (Data(base64Encoded: payload) ?? Data()) : Data((payload.removingPercentEncoding ?? payload).utf8)
            } else {
                guard let url = URL(string: value) else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                if let headers = try? BookSourceHeaderResolver().resolve(source.bookSourceAdapter) { for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) } }
                let cookie = LegadoCookieStore.shared.cookieHeader(for: value)
                if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                (data, _) = try await URLSessionHTTPTransport.shared.download(for: request)
            }
            guard let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            image = decoded; loading = false
        } catch { loading = false; message = "加载图片失败：\(error.localizedDescription)" }
    }

    private func save() {
        guard let image else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { message = "没有照片写入权限" }; return }
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) } completionHandler: { success, error in
                DispatchQueue.main.async { message = success ? "保存成功" : "保存失败：\(error?.localizedDescription ?? "未知错误")" }
            }
        }
    }
}

@MainActor
private final class RSSSpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
        isSpeaking = true
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate); isSpeaking = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.isSpeaking = false } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in self.isSpeaking = false } }
}

private struct RSSImportSheet: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        ReadingNavigationStack {
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding()
                .navigationTitle("导入RSS源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("导入") { Task { await library.importText(text); dismiss() } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

private struct RSSExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(sources: [RssSource]) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(sources)) ?? Data("[]".utf8)
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct RSSStarEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: RssStar
    let save: (RssStar) -> Void
    init(star: RssStar, save: @escaping (RssStar) -> Void) { _value = State(initialValue: star); self.save = save }
    var body: some View {
        ReadingNavigationStack {
            Form {
                TextField("标题", text: $value.title)
                TextField("分组", text: $value.group)
                ReadingLabeledContent("链接", value: value.link).textSelection(.enabled)
            }.navigationTitle("编辑RSS收藏").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(value); dismiss() }.disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
