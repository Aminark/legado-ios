import SwiftUI
import UIKit
// Readium 3.8 predates Swift 6 Sendable annotations; ownership stays in this
// main-actor model and publication operations are awaited before presentation.
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumNavigator

enum EPUBReadingMode: String, CaseIterable {
    case original, text
    static let preferenceKey = "defaultEPUBReadingMode"

    var title: String {
        switch self {
        case .original: "EPUB 原书排版"
        case .text: "文字阅读与朗读"
        }
    }
}

/// EPUB keeps its XHTML, CSS, SVG, images and navigation in Readium. The text
/// reader remains available for the app's existing speech and text tools.
@MainActor
final class EPUBReaderModel: ObservableObject, EPUBNavigatorDelegate {
    struct TOCEntry: Identifiable {
        let id: Int
        let link: ReadiumShared.Link
        let depth: Int
    }

    func visibleTableOfContents(collapsing collapsed: Set<Int>) -> [TOCEntry] {
        guard !collapsed.isEmpty else { return tableOfContents }
        var collapsedDepth: Int?
        return tableOfContents.filter { entry in
            if let depth = collapsedDepth, entry.depth > depth { return false }
            collapsedDepth = collapsed.contains(entry.id) ? entry.depth : nil
            return true
        }
    }

    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var location: Locator?
    @Published private(set) var currentChapter: BookChapter?
    private var visibleChapterTask: Task<Void, Never>?
    @Published private(set) var tableOfContents: [TOCEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published var showsControls = true
    var onLocationChanged: ((Locator, BookChapter) -> Void)?
    let book: Book
    let chapters: [BookChapter]
    let initialIndex: Int
    private let restoresSavedLocation: Bool
    private let httpClient = DefaultHTTPClient()
    private var navigationAdapter: DirectionalNavigationAdapter?

    init(book: Book, chapters: [BookChapter], initialIndex: Int, restoresSavedLocation: Bool = true) {
        self.book = book
        self.chapters = chapters
        self.initialIndex = initialIndex
        self.restoresSavedLocation = restoresSavedLocation
        currentChapter = chapters.first { $0.index == initialIndex } ?? chapters.first
    }

    var progress: Double { location?.locations.totalProgression ?? 0 }

    func open(preferences: EPUBPreferences) async {
        guard navigator == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let url = URL(string: book.bookUrl), url.isFileURL,
                  let file = FileURL(url: url) else { throw LocalBookError.missingFile }
            let retriever = AssetRetriever(httpClient: httpClient)
            let opener = PublicationOpener(parser: DefaultPublicationParser(
                httpClient: httpClient, assetRetriever: retriever, pdfFactory: DefaultPDFDocumentFactory()
            ))
            let asset = try await retriever.retrieve(url: file).get()
            let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
            try Task.checkCancellation()
            var initialLocation: Locator?
            if restoresSavedLocation, initialIndex == book.durChapterIndex, let saved = book.readConfig?.epubLocation {
                initialLocation = try? Locator(jsonString: saved)
            }
            if initialLocation == nil, (initialIndex > 0 || !restoresSavedLocation),
               let chapter = chapters.first(where: { $0.index == initialIndex }), let link = link(for: chapter) {
                initialLocation = await publication.locate(link)
            }
            let controller = try EPUBNavigatorViewController(
                publication: publication, initialLocation: initialLocation,
                config: .init(preferences: preferences)
            )
            controller.delegate = self
            controller.view.accessibilityIdentifier = "reader.epub"
            let adapter = DirectionalNavigationAdapter()
            adapter.bind(to: controller)
            navigationAdapter = adapter
            var entries: [TOCEntry] = []
            func append(_ links: [ReadiumShared.Link], depth: Int) {
                for link in links {
                    entries.append(.init(id: entries.count, link: link, depth: depth))
                    append(link.children, depth: depth + 1)
                }
            }
            let toc = (try? await publication.tableOfContents().get()) ?? []
            append(toc.isEmpty ? publication.readingOrder : toc, depth: 0)
            tableOfContents = entries
            navigator = controller
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ preferences: EPUBPreferences) { navigator?.submitPreferences(preferences) }

    func go(to link: ReadiumShared.Link) async {
        guard let navigator else { return }
        guard let target = await navigator.publication.locate(link) else {
            errorMessage = "无法跳转到这段内容"
            return
        }
        let changesResource = location?.href != target.href
        guard await navigator.go(to: target, options: .init(animated: changesResource)) else {
            errorMessage = "无法跳转到这段内容"
            return
        }
        // A cross-resource jump queues the spread load. Address the fragment again
        // on the now-current spread, where Readium waits for the actual navigation.
        if changesResource, !target.locations.fragments.isEmpty {
            _ = await navigator.go(to: target)
        }
    }

    func go(to bookmark: Bookmark) async {
        if let json = bookmark.epubLocation, let locator = try? Locator(jsonString: json) {
            _ = await navigator?.go(to: locator)
        } else if let index = bookmark.resolvedChapterIndex(in: chapters), let link = link(for: chapters[index]) {
            await go(to: link)
        }
    }

    func go(toProgress progress: Double) async {
        guard let navigator, let locator = await navigator.publication.locate(progression: progress) else { return }
        _ = await navigator.go(to: locator)
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        updateLocation(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        // A same-page TOC jump may never trigger locationDidChange.
        updateLocation(locator)
    }

    private func updateLocation(_ locator: Locator) {
        visibleChapterTask?.cancel()
        let path = Self.path(locator.href.string)
        let matches = chapters.filter { $0.resourceUrl == path }
        let exact = matches.first { chapter in
            chapter.startFragmentId.map(locator.locations.fragments.contains) == true
        }
        let previous = currentChapter.flatMap { $0.resourceUrl == path ? $0 : nil }
        let chapter = exact ?? previous ?? matches.first { $0.title == locator.title } ?? matches.first
        location = locator
        guard let chapter else { return }
        currentChapter = chapter
        onLocationChanged?(locator, chapter)

        // Readium's regular page updates carry the spine resource and progression.
        // Multiple text chapters can share that resource. Resolve the visible section
        // in the laid-out document, keeping an explicitly selected anchor on its page.
        guard exact == nil, matches.count > 1, let navigator else { return }
        visibleChapterTask = Task {
            guard let visible = await navigator.firstVisibleElementLocator(),
                  Self.path(visible.href.string) == path, let selector = visible.locations.cssSelector,
                  !Task.isCancelled else { return }
            let arguments = [matches.map(\.startFragmentId), [selector, chapter.startFragmentId]]
            guard let json = try? JSONEncoder().encode(arguments) else { return }
            let script = """
            (([ids, [selector, preferred]]) => {
                const first = document.querySelector(selector);
                if (!first) return -1;
                const anchor = id => id && (document.getElementById(id) || document.getElementsByName(id)[0]);
                const rect = anchor(preferred)?.getClientRects()[0];
                if (rect && rect.top >= -1 && rect.top < innerHeight && rect.left < innerWidth && rect.right > 0)
                    return ids.indexOf(preferred);
                for (let i = ids.length - 1; i >= 0; i--) {
                    const node = anchor(ids[i]);
                    if (node && (node === first || (node.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING)))
                        return i;
                }
                return 0;
            })(\(String(decoding: json, as: UTF8.self)))
            """
            guard let index = try? await navigator.evaluateJavaScript(script).get() as? Int,
                  !Task.isCancelled, matches.indices.contains(index), matches[index].index != chapter.index else { return }
            currentChapter = matches[index]
            onLocationChanged?(locator, matches[index])
        }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = error.localizedDescription
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        showsControls.toggle()
    }

    func clearError() { errorMessage = nil }

    private func link(for chapter: BookChapter) -> ReadiumShared.Link? {
        guard let path = chapter.resourceUrl else { return nil }
        var parts = URLComponents()
        parts.path = path
        parts.fragment = chapter.startFragmentId
        guard let href = parts.string, let url = AnyURL(string: href) else { return nil }
        return ReadiumShared.Link(href: url.string, mediaType: .xhtml, title: chapter.title)
    }

    static func path(_ href: String) -> String {
        (URLComponents(string: href)?.path ?? href).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct EPUBReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: EPUBReaderModel
    @State private var showsTOC = false
    @State private var showsSettings = false
    @State private var showsBookmarks = false
    let onReadText: (Int) -> Void
    @State private var switchingToText = false
    @State private var collapsedTOCEntries: Set<Int> = []
    @State private var sliderProgress = 0.0
    @State private var isScrubbing = false
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("epubFontScale") private var fontScale = 1.0
    @AppStorage("epubScroll") private var scroll = false
    @AppStorage("epubPublisherStyles") private var publisherStyles = true
    @AppStorage("epubTheme") private var theme = "system"

    init(book: Book, chapters: [BookChapter], initialIndex: Int, restoresSavedLocation: Bool,
         onReadText: @escaping (Int) -> Void) {
        self.onReadText = onReadText
        _model = StateObject(wrappedValue: EPUBReaderModel(book: book, chapters: chapters, initialIndex: initialIndex,
                                                         restoresSavedLocation: restoresSavedLocation))
    }

    private var preferences: EPUBPreferences {
        EPUBPreferences(fontSize: fontScale, publisherStyles: publisherStyles, scroll: scroll,
                        theme: theme == "sepia" ? .sepia : (theme == "dark" || (theme == "system" && colorScheme == .dark) ? .dark : .light))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsControls { topBar }
            Group {
                if let navigator = model.navigator {
                    EPUBNavigatorHost(navigator: navigator)
                } else if let error = model.errorMessage {
                    VStack(spacing: 16) {
                        Text("无法打开 EPUB").font(.headline)
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("重试") { Task { await model.open(preferences: preferences) } }
                        Button("返回书架") { dismiss() }
                    }.padding()
                } else {
                    ProgressView("正在打开 EPUB…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showsControls, model.navigator != nil { bottomBar }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarHidden(true)
        .readingTabBarHidden()
        .task {
            model.onLocationChanged = { locator, chapter in
                if !isScrubbing, let progress = locator.locations.totalProgression { sliderProgress = progress }
                saveTask?.cancel()
                saveTask = Task {
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    await library.updateProgress(for: model.book, chapter: chapter, epubLocation: locator.jsonString)
                }
            }
            activity.beginReading(model.book)
            await model.open(preferences: preferences)
        }
        .onChange(of: preferences) { model.apply($0) }
        .onChange(of: scenePhase) { phase in
            if phase != .active { saveProgress(); Task { await activity.endReading(model.book) } }
            else { activity.beginReading(model.book) }
        }
        .onDisappear {
            model.onLocationChanged = nil
            if !switchingToText {
                saveProgress()
                Task { await activity.endReading(model.book) }
            }
        }
        .sheet(isPresented: $showsTOC) { tocSheet }
        .sheet(isPresented: $showsSettings) { settingsSheet }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .alert("EPUB 阅读", isPresented: Binding(get: { model.navigator != nil && model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("好") { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { saveProgress(); dismiss() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("返回书架")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.book.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(model.currentChapter?.title ?? model.location?.title ?? "EPUB")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("添加书签", systemImage: "bookmark") {
                    guard let locator = model.location, let chapter = model.currentChapter else { return }
                    Task {
                        await activity.addBookmark(book: model.book, chapter: chapter, position: 0,
                                                   content: locator.text.highlight ?? chapter.title, epubLocation: locator.jsonString)
                    }
                }
                Button("我的书签", systemImage: "bookmark.fill") { showsBookmarks = true }
                Button(EPUBReadingMode.text.title, systemImage: "speaker.wave.2") {
                    switchingToText = true
                    model.onLocationChanged = nil
                    saveTask?.cancel()
                    onReadText(model.currentChapter?.index ?? model.initialIndex)
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .accessibilityLabel("EPUB 更多")
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Slider(value: $sliderProgress, in: 0...1) { editing in
                    isScrubbing = editing
                    if !editing { Task { await model.go(toProgress: sliderProgress) } }
                }.accessibilityLabel("阅读进度")
                Text("\(Int(sliderProgress * 100))%")
                    .font(.caption.monospacedDigit()).frame(width: 42)
            }
            HStack {
                Button { Task { _ = await model.navigator?.goBackward() } } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一页")
                Spacer()
                Button("目录", systemImage: "list.bullet") { showsTOC = true }
                Spacer()
                Button("排版", systemImage: "textformat.size") { showsSettings = true }
                Spacer()
                Button { Task { _ = await model.navigator?.goForward() } } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一页")
            }.font(.subheadline)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var tocSheet: some View {
        ReadingNavigationStack {
            List(model.visibleTableOfContents(collapsing: collapsedTOCEntries)) { entry in
                let title = entry.link.title ?? "未命名章节"
                let collapsed = collapsedTOCEntries.contains(entry.id)
                let hasChildren = !entry.link.children.isEmpty
                HStack(spacing: 4) {
                    Button {
                        if hasChildren && entry.link.href == "#" {
                            toggleTOCEntry(entry.id)
                        } else {
                            showsTOC = false
                            Task { await model.go(to: entry.link) }
                        }
                    } label: {
                        Text(title)
                            .fontWeight(hasChildren ? .semibold : .regular)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    if hasChildren {
                        Button {
                            toggleTOCEntry(entry.id)
                        } label: {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(collapsed ? "展开" : "折叠")\(title)")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.leading, CGFloat(min(entry.depth, 8)) * 16)
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showsTOC = false } } }
        }
    }

    private func toggleTOCEntry(_ id: Int) {
        if !collapsedTOCEntries.insert(id).inserted { collapsedTOCEntries.remove(id) }
    }

    private var settingsSheet: some View {
        ReadingNavigationStack {
            Form {
                Section("阅读方式") {
                    Toggle("滚动阅读", isOn: $scroll)
                    Toggle("使用原书排版", isOn: $publisherStyles)
                }
                Section("字号") {
                    Slider(value: $fontScale, in: 0.7...2.0, step: 0.1)
                    Text("\(Int(fontScale * 100))%")
                }
                Section("背景") {
                    Picker("主题", selection: $theme) {
                        Text("跟随系统").tag("system")
                        Text("白色").tag("light")
                        Text("纸色").tag("sepia")
                        Text("夜间").tag("dark")
                    }
                }
            }
            .navigationTitle("EPUB 排版").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSettings = false } } }
        }
    }

    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            List {
                if activity.bookmarks(for: model.book).isEmpty { Text("还没有书签").foregroundStyle(.secondary) }
                ForEach(activity.bookmarks(for: model.book)) { bookmark in
                    Button {
                        showsBookmarks = false
                        Task { await model.go(to: bookmark) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.chapterName)
                            Text(bookmark.bookText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } } }
                }
            }
            .navigationTitle("书签").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsBookmarks = false } } }
        }
    }

    private func saveProgress() {
        saveTask?.cancel()
        guard let locator = model.location, let chapter = model.currentChapter else { return }
        Task { await library.updateProgress(for: model.book, chapter: chapter, epubLocation: locator.jsonString) }
    }
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}
