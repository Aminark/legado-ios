import SwiftUI
import UIKit
// Readium 3.11 predates full Swift 6 Sendable annotations; ownership stays in this
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
    private var isJumping = false
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

    func textReaderPosition() async -> (index: Int, progression: Double?) {
        await visibleChapterTask?.value
        guard let chapter = currentChapter else { return (initialIndex, nil) }
        guard let path = chapter.resourceUrl, chapters.contains(where: { $0.index != chapter.index && $0.resourceUrl == path }) else {
            return (chapter.index, location?.locations.progression)
        }
        // Readium measures progression across the entire spine item. The text
        // reader splits that same document at TOC anchors.
        guard let navigator, let visible = await navigator.firstVisibleElementLocator(),
              Self.path(visible.href.string) == path, let selector = visible.locations.cssSelector else {
            return (chapter.index, 0)
        }
        let arguments = [chapter.startFragmentId, chapter.endFragmentId, selector]
        guard let json = try? JSONEncoder().encode(arguments) else { return (chapter.index, 0) }
        let script = """
        (([startID, endID, selector]) => {
            const anchor = id => id && (document.getElementById(id) || document.getElementsByName(id)[0]);
            const start = anchor(startID), end = anchor(endID), first = document.querySelector(selector);
            if (!first || !document.body.contains(first)) return 0;
            const chapter = document.createRange();
            chapter.selectNodeContents(document.body);
            if (start) chapter.setStartBefore(start);
            if (end) chapter.setEndBefore(end);
            const length = chapter.toString().trim().length;
            if (!length || chapter.comparePoint(first, 0) < 0) return 0;
            if (chapter.comparePoint(first, 0) > 0) return 1;
            chapter.setEnd(first, 0);
            return chapter.toString().trim().length / length;
        })(\(String(decoding: json, as: UTF8.self)))
        """
        let fraction = try? await navigator.evaluateJavaScript(script).get() as? Double
        return (chapter.index, fraction ?? 0)
    }

    func open(preferences: EPUBPreferences) async {
        guard navigator == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let url = LocalBookService.resolveLocalFileURL(for: book.bookUrl),
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
        await jump(to: target)
    }

    private func jump(to target: Locator) async {
        guard let navigator, !isJumping else { return }
        isJumping = true
        defer { isJumping = false }
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
            await jump(to: locator)
        } else if let index = bookmark.resolvedChapterIndex(in: chapters), let link = link(for: chapters[index]) {
            await go(to: link)
        }
    }

    func go(toProgress progress: Double) async {
        guard let navigator, let locator = await navigator.publication.locate(progression: progress) else { return }
        await jump(to: locator)
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
    private var readingPalette = ReadingPalettePreference()
    @State private var showsTOC = false
    @State private var showsSettings = false
    @State private var showsBookmarks = false
    let onReadText: (Int, Double?, Bool) -> Void
    @State private var switchingToText = false
    @State private var textPositionTask: Task<Void, Never>?
    @State private var collapsedTOCEntries: Set<Int> = []
    @State private var sliderProgress = 0.0
    @State private var previewProgress: Double?
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("epubFontScale") private var fontScale = 1.0
    @AppStorage("epubScroll") private var scroll = false
    @AppStorage("epubPublisherStyles") private var publisherStyles = true
    @AppStorage("epubTheme") private var theme = "reader"

    init(book: Book, chapters: [BookChapter], initialIndex: Int, restoresSavedLocation: Bool,
         onReadText: @escaping (Int, Double?, Bool) -> Void) {
        self.onReadText = onReadText
        _model = StateObject(wrappedValue: EPUBReaderModel(book: book, chapters: chapters, initialIndex: initialIndex,
                                                         restoresSavedLocation: restoresSavedLocation))
    }

    private var resolvedReadiumTheme: ReadiumNavigator.Theme {
        switch theme {
        case "reader":
            let style = readingPalette.resolved
            if style.id == "night" { return .dark }
            if style.id == "preset2" { return .sepia }
            return .light
        case "sepia":
            return .sepia
        case "dark":
            return .dark
        case "light":
            return .light
        default:
            return colorScheme == .dark ? .dark : .light
        }
    }

    private var isDarkChrome: Bool {
        resolvedReadiumTheme == .dark
    }

    private var preferredChromeScheme: ColorScheme? {
        if theme == "system" || (theme == "reader" && readingPalette.linked) { return nil }
        return isDarkChrome ? .dark : .light
    }

    private var pageCanvasBackground: SwiftUI.Color {
        switch resolvedReadiumTheme {
        case .dark:
            return SwiftUI.Color(uiColor: ReaderStylePreset.resolve("night").background)
        case .sepia:
            return SwiftUI.Color(red: 0.96, green: 0.93, blue: 0.86)
        default:
            return SwiftUI.Color(uiColor: theme == "reader" ? readingPalette.resolved.background : .systemBackground)
        }
    }

    private var preferences: EPUBPreferences {
        let activeTheme = resolvedReadiumTheme
        if theme == "reader", !publisherStyles {
            let preset = readingPalette.resolved
            return EPUBPreferences(
                backgroundColor: ReadiumNavigator.Color(uiColor: preset.background),
                fontSize: fontScale,
                publisherStyles: publisherStyles,
                scroll: scroll,
                textColor: ReadiumNavigator.Color(uiColor: preset.foreground),
                theme: activeTheme
            )
        }
        return EPUBPreferences(
            fontSize: fontScale,
            publisherStyles: publisherStyles,
            scroll: scroll,
            theme: activeTheme
        )
    }

    var body: some View {
        ZStack {
            pageCanvasBackground.ignoresSafeArea()
            Group {
                if let navigator = model.navigator {
                    // Keep the Readium viewport invariant whether overlay bars
                    // are shown or hidden so toggling chrome never repaginates
                    // or clips bottom lines.
                    EPUBNavigatorHost(navigator: navigator)
                        .ignoresSafeArea(edges: .horizontal)
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
        }
        .overlay(alignment: .top) {
            if model.showsControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if model.showsControls, model.navigator != nil {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showsControls)
        .preferredColorScheme(preferredChromeScheme)
        .navigationBarHidden(true)
        .readingTabBarHidden()
        .task {
            model.onLocationChanged = { locator, chapter in
                if let progress = locator.locations.totalProgression { sliderProgress = progress }
                saveTask?.cancel()
                saveTask = Task {
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    await library.updateProgress(for: model.book, chapter: chapter, epubLocation: try? locator.jsonString())
                }
            }
            activity.beginReading(model.book)
            if model.navigator == nil { await model.open(preferences: preferences) }
        }
        .onChange(of: preferences) { model.apply($0) }
        .onChange(of: scenePhase) { phase in
            if phase != .active { saveProgress(); Task { await activity.endReading(model.book) } }
            else { activity.beginReading(model.book) }
        }
        .onDisappear {
            textPositionTask?.cancel()
            textPositionTask = nil
            guard !showsTOC else { return }
            model.onLocationChanged = nil
            if !switchingToText {
                saveProgress()
                Task { await activity.endReading(model.book) }
            }
        }
        .fullScreenCover(isPresented: $showsTOC) { tocSheet }
        .sheet(isPresented: $showsSettings) { settingsSheet }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .alert("EPUB 阅读", isPresented: Binding(get: { model.navigator != nil && model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("好") { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func switchToTextMode(autoStartSpeech: Bool) {
        guard !switchingToText, textPositionTask == nil else { return }
        textPositionTask = Task {
            let position = await model.textReaderPosition()
            guard !Task.isCancelled else { return }
            switchingToText = true
            model.onLocationChanged = nil
            saveTask?.cancel()
            onReadText(position.index, position.progression, autoStartSpeech)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            ReaderChromeCircleButton(
                icon: "chevron.backward",
                label: "返回书架",
                isNight: isDarkChrome,
                isEInk: false
            ) {
                saveProgress()
                dismiss()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.book.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(model.currentChapter?.title ?? model.location?.title ?? "EPUB")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("添加书签", systemImage: "bookmark") {
                    guard let locator = model.location, let chapter = model.currentChapter else { return }
                    Task {
                        await activity.addBookmark(book: model.book, chapter: chapter, position: 0,
                                                   content: locator.text.highlight ?? chapter.title, epubLocation: try? locator.jsonString())
                    }
                }
                Button("我的书签", systemImage: "bookmark.fill") { showsBookmarks = true }
                Button(EPUBReadingMode.text.title, systemImage: "doc.plaintext") {
                    switchToTextMode(autoStartSpeech: false)
                }
                Button("从当前位置听书", systemImage: "headphones") {
                    switchToTextMode(autoStartSpeech: true)
                }
            } label: {
                ReaderChromeCircleIcon(
                    systemName: "ellipsis",
                    isNight: isDarkChrome,
                    isEInk: false,
                    iconSize: 15
                )
            }
            .buttonStyle(ReaderTactileButtonStyle())
            .accessibilityLabel("EPUB 更多")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background {
            ReaderFrostedChromeBackground(isNight: isDarkChrome, isEInk: false)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReaderChromePalette.hairline).frame(height: 0.5)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(model.currentChapter?.title ?? "阅读进度")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int(((previewProgress ?? sliderProgress) * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(isDarkChrome ? 0.10 : 0.06), in: Capsule())
                }
                .padding(.horizontal, 2)

                HStack(spacing: 8) {
                    ReaderChromeCircleButton(
                        icon: "chevron.left",
                        label: "上一页",
                        isNight: isDarkChrome,
                        isEInk: false,
                        diameter: 34,
                        iconSize: 13
                    ) {
                        Task { _ = await model.navigator?.goBackward() }
                    }
                    ReaderSeekSlider(value: sliderProgress, range: 0...1, preview: $previewProgress, label: "阅读进度") { target in
                        sliderProgress = target
                        Task { await model.go(toProgress: target) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                    ReaderChromeCircleButton(
                        icon: "chevron.right",
                        label: "下一页",
                        isNight: isDarkChrome,
                        isEInk: false,
                        diameter: 34,
                        iconSize: 13
                    ) {
                        Task { _ = await model.navigator?.goForward() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ReaderStyleDivider(inset: 16)

            HStack(spacing: 0) {
                epubToolbarButton("list.bullet", "目录") { showsTOC = true }
                epubToolbarButton("headphones", "听书") { switchToTextMode(autoStartSpeech: true) }
                epubToolbarButton("textformat.size", "排版") { showsSettings = true }
                epubToolbarButton("bookmark", "书签") { showsBookmarks = true }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: 560)
        .background {
            ReaderFrostedChromeBackground(isNight: isDarkChrome, isEInk: false, cornerRadius: 26)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func epubToolbarButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReaderTactileButtonStyle())
        .accessibilityLabel(title)
    }

    private var tocSheet: some View {
        ReadingNavigationStack {
            List(model.visibleTableOfContents(collapsing: collapsedTOCEntries)) { entry in
                let title = entry.link.title ?? "未命名章节"
                let collapsed = collapsedTOCEntries.contains(entry.id)
                let hasChildren = !entry.link.children.isEmpty
                HStack(spacing: 4) {
                    Button {
                        let href = entry.link.href.trimmingCharacters(in: .whitespacesAndNewlines)
                        if hasChildren && (href.isEmpty || href == "#") {
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
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ReaderStyleCard(title: "字号", detail: "\(Int((fontScale * 100).rounded()))%") {
                        ReaderStyleValueSlider(title: "缩放比例", value: $fontScale, range: 0.7...2.0, step: 0.1) {
                            "\(Int(($0 * 100).rounded()))%"
                        }
                    }

                    ReaderStyleCard(title: "背景主题") {
                        HStack {
                            Spacer(minLength: 0)
                            ReaderStyleSegmentedPill(
                                options: [
                                    .init(value: "reader", title: "跟随阅读"),
                                    .init(value: "system", title: "系统"),
                                    .init(value: "light", title: "白色"),
                                    .init(value: "sepia", title: "纸色"),
                                    .init(value: "dark", title: "夜间")
                                ],
                                selectedValue: theme
                            ) { theme = $0 }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }

                    ReaderStyleCard(title: "阅读方式") {
                        HStack(spacing: 12) {
                            ReaderStyleIconBadge(systemName: "arrow.up.and.down")
                            Text("滚动阅读").font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 8)
                            Toggle("滚动阅读", isOn: $scroll).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)

                        ReaderStyleDivider()

                        HStack(spacing: 12) {
                            ReaderStyleIconBadge(systemName: "doc.richtext")
                            Text("使用原书排版").font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 8)
                            Toggle("使用原书排版", isOn: $publisherStyles).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ReaderChromePalette.sheetBackground(isEInk: false).ignoresSafeArea())
            .navigationTitle("EPUB 排版")
            .navigationBarTitleDisplayMode(.inline)
            .readerStyleNavigationBar(isEInk: false)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showsSettings = false
                    } label: {
                        Text("完成").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
        .readerSheetAllowsInlineScrolling()
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
        Task { await library.updateProgress(for: model.book, chapter: chapter, epubLocation: try? locator.jsonString()) }
    }
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}
