import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: BookDetailViewModel
    @State private var showsSourceSwitch = false
    @State private var showsRemoveConfirmation = false
    @State private var showsTableOfContents = false

    init(searchBook: SearchBook, source: BookSource) {
        _model = StateObject(wrappedValue: BookDetailViewModel(searchBook: searchBook, source: source))
    }

    init(book: Book, source: BookSource) {
        _model = StateObject(wrappedValue: BookDetailViewModel(book: book, source: source))
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        _model = StateObject(wrappedValue: BookDetailViewModel(demoBook: demoBook, source: source, chapters: chapters))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                Divider()
                if let intro = MetadataTextSanitizer().clean(model.book.intro), !intro.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("简介").font(.headline)
                        Text(intro).font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    Divider()
                }
                chapterCard
                if model.isCaching || model.cacheCompleted > 0 { cacheProgressCard }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("换源", systemImage: "arrow.triangle.2.circlepath") { showsSourceSwitch = true }
                        .disabled(sourceLibrary.sources.filter(\.enabled).count < 2)
                    Button("允许更新", systemImage: model.book.canUpdate ? "checkmark" : "circle") {
                        model.toggleCanUpdate()
                        Task { await saveCurrentBook() }
                    }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task {
                            let oldURL = model.book.bookUrl
                            let wasInLibrary = library.contains(model.book)
                            await model.refresh(sources: sourceLibrary.sources)
                            if wasInLibrary, oldURL != model.book.bookUrl {
                                await library.replace(oldBookURL: oldURL, with: model.book)
                            } else if wasInLibrary {
                                await saveCurrentBook()
                            }
                        }
                    }
                    if model.source.loginUrl?.isEmpty == false {
                        NavigationLink {
                            SourceLoginView(source: model.source)
                        } label: {
                            Label("登录", systemImage: "person.badge.key")
                        }
                    }
                    ReadingShareLink(item: model.book.bookUrl) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button("缓存接下来 10 章", systemImage: "arrow.down.circle") { model.cacheNextTen() }
                        .disabled(model.chapters.isEmpty || model.isCaching)
                    Button("缓存剩余章节", systemImage: "square.and.arrow.down.on.square") { model.cacheRemaining() }
                        .disabled(model.chapters.isEmpty || model.isCaching)
                    if model.isCaching {
                        Divider()
                        Button("停止缓存", systemImage: "stop.circle", role: .destructive) { model.cancelCaching() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            model.restoreSourceAfterReading(from: library.books, sources: sourceLibrary.sources)
            let oldURL = model.book.bookUrl
            let shouldPersistUpdate = library.contains(model.book)
            if let stored = library.books.first(where: { $0.bookUrl == oldURL }) {
                model.restoreLibraryBook(from: stored, sources: sourceLibrary.sources)
            }
            await model.load(sources: sourceLibrary.sources)
            if shouldPersistUpdate {
                if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
                    model.restoreUserSettings(from: stored)
                    model.restoreReadingProgress(from: stored)
                }
                if oldURL != model.book.bookUrl {
                    await library.replace(oldBookURL: oldURL, with: model.book)
                } else {
                    await saveCurrentBook()
                }
            }
        }
        .sheet(isPresented: $showsSourceSwitch) {
            ReadingNavigationStack {
                SourceSwitchView(book: model.book, sources: sourceLibrary.sources) { report, source in
                    let oldURL = model.book.bookUrl
                    model.applySourceSwitch(report, source: source)
                    Task { await library.replace(oldBookURL: oldURL, with: report.book) }
                }
            }
        }
        .sheet(isPresented: $showsTableOfContents) {
            BookTableOfContentsView(book: model.book, chapters: model.chapters, source: model.source)
        }
        .confirmationDialog("从书架移除《\(model.book.name)》？", isPresented: $showsRemoveConfirmation) {
            Button("移出书架", role: .destructive) {
                Task { await library.remove(bookURL: model.book.bookUrl) }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var cacheProgressCard: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.isCaching ? "正在缓存章节" : "章节缓存完成", systemImage: model.isCaching ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(model.cacheCompleted)/\(model.cacheTotal)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(model.cacheCompleted), total: Double(max(model.cacheTotal, 1)))
                    .tint(ReadingTheme.accent)
                if model.isCaching {
                    Button("停止缓存", role: .destructive) { model.cancelCaching() }
                        .font(.subheadline)
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                BookCoverArtwork(
                    title: model.book.name,
                    author: model.book.author,
                    remoteURL: model.book.coverUrl,
                    width: 88,
                    height: 126
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.book.name).font(.title2.weight(.semibold)).lineLimit(3)
                    Text(model.book.author.isEmpty ? "未知作者" : model.book.author)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let kind = model.book.kind, !kind.isEmpty {
                        Text(kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.source.bookSourceName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let latest = model.book.latestChapterTitle, !latest.isEmpty {
                Text("更新至 \(latest)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { readingActions }
                } else {
                    HStack(spacing: 12) { readingActions }
                }
            }
            .controlSize(.large)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var readingActions: some View {
        NavigationLink {
            readingDestination
        } label: {
            Text(model.book.durChapterIndex > 0 || model.book.durChapterPos > 0 ? "继续阅读" : "开始阅读")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .readingProminentButtonStyle()
        .disabled(model.chapters.isEmpty)
        Button {
            if library.contains(model.book) {
                showsRemoveConfirmation = true
            } else {
                Task { await saveCurrentBook() }
            }
        } label: {
            Label(
                library.contains(model.book) ? "已在书架" : "加入书架",
                systemImage: library.contains(model.book) ? "checkmark" : "plus"
            )
            .font(.subheadline)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 28)
        }
        .readingSecondaryButtonStyle()
    }

    @ViewBuilder
    private var readingDestination: some View {
        let index = min(max(model.book.durChapterIndex, 0), max(model.chapters.count - 1, 0))
        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            ReaderView(demoBook: model.book, chapters: model.chapters, initialIndex: index, content: DemoContent.readerText)
        } else {
            ReaderView(book: model.book, chapters: model.chapters, initialIndex: index, source: model.source)
        }
    }

    private func saveCurrentBook() async {
        await library.addOrUpdate(model.book)
        if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
            model.restoreReadingProgress(from: stored)
        }
    }

    private var chapterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录").font(.headline)
                Spacer()
                Text("\(model.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            if model.state == .loading || model.state == .idle {
                HStack { Spacer(); ProgressView("正在解析目录…"); Spacer() }.padding(.vertical, 28)
            } else if model.state == .findingSource {
                HStack { Spacer(); ProgressView("当前源不可用，正在自动寻找可用源…"); Spacer() }
                    .padding(.vertical, 28)
            } else if model.state == .failed {
                ReadingUnavailableView(
                    "没有找到可用目录",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text("已自动尝试其他可搜索书源，可稍后刷新重试或手动换源。")
                )
                .padding(.vertical, 12)
            } else {
                ForEach(Array(model.chapters.filter { !$0.isVolume }.prefix(8).enumerated()), id: \.element.id) { offset, chapter in
                    if offset > 0 { Divider() }
                    if chapter.isVolume {
                        Text(chapter.title).font(.subheadline.bold()).foregroundStyle(ReadingTheme.accent)
                            .padding(.vertical, 12)
                    } else {
                        NavigationLink {
                            ReaderView(
                                book: model.book,
                                chapters: model.chapters,
                                initialIndex: chapter.index,
                                source: model.source
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", chapter.index + 1))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 28)
                                Text(chapter.title)
                                    .font(.subheadline)
                                    .foregroundStyle(model.isChapterCached(chapter) ? Color.primary : Color.secondary)
                                    .lineLimit(2)
                                Spacer()
                                if chapter.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if model.chapters.count > 8 {
                    Divider()
                    Button {
                        showsTableOfContents = true
                    } label: {
                        Label("查看全部目录", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

private struct BookTableOfContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [BookChapter]
    let source: BookSource
    @State private var searchText = ""
    @State private var descending = false
    @State private var cachedURLs: Set<String> = []

    private var displayedChapters: [BookChapter] {
        let filtered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return descending ? Array(filtered.reversed()) : filtered
    }

    var body: some View {
        ReadingNavigationStack {
            List(displayedChapters) { chapter in
                if chapter.isVolume {
                    Text(chapter.title).font(.headline).foregroundStyle(ReadingTheme.accent)
                } else {
                    NavigationLink {
                        ReaderView(book: book, chapters: chapters, initialIndex: chapter.index, source: source)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(chapter.index + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            Text(chapter.title)
                                .foregroundStyle(chapter.index == book.durChapterIndex || cachedURLs.contains(chapter.url) ? Color.primary : Color.secondary)
                                .lineLimit(2)
                            Spacer()
                            if chapter.index == book.durChapterIndex {
                                Image(systemName: "location.fill").foregroundStyle(ReadingTheme.accent)
                            }
                            if chapter.isVip { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索目录")
            .task {
                cachedURLs = (try? await ChapterContentCache.live().cachedChapterURLs(bookURL: book.bookUrl, among: chapters)) ?? []
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") {
                        descending.toggle()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(book.durChapterTitle ?? "尚未阅读").lineLimit(1)
                    Spacer()
                    Text("\(min(book.durChapterIndex + 1, chapters.count))/\(chapters.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}
