import SwiftUI
import UIKit

struct ReaderChapterCommentsView: View {
    let target: ReaderChapterCommentsTarget

    @Environment(\.dismiss) private var dismiss
    @State private var state: StateOfComments = .loading
    @State private var attempt = 0
    @State private var showsSourcePage = false
    @State private var pages = ReaderChapterCommentPages()
    @State private var more: MoreComments = .idle

    private enum StateOfComments {
        case loading, loaded, page(URL), failed(String)
    }

    private enum MoreComments { case idle, loading(URL), failed(String) }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    if target.source.ruleReview?.supportsChapterComments == true ||
                        target.source.ruleReview?.supportsChapterCommentsPage == true {
                        sourceComments
                    }
                    if let official = target.official {
                        Link(destination: official.url) {
                            Label("在\(official.platformName)查看此章", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("reader.comments.officialChapter")
                    }
                } header: {
                    Text(target.chapter.title)
                } footer: {
                    if let official = target.official {
                        if official.platform == .fanqie {
                            Text("在官方章节页进入番茄小说 App，在章节结尾选择「\(official.discussionName)」。")
                        } else {
                            Text("打开官方章节后，在阅读页选择「\(official.discussionName)」。")
                        }
                    }
                }
            }
            .navigationTitle("本章评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("reader.comments.close")
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
        .sheet(isPresented: $showsSourcePage) {
            if case .page(let url) = state {
                ReadingWebBrowser(url: url, close: { showsSourcePage = false })
                    .ignoresSafeArea()
            }
        }
        .task(id: attempt) {
            let service = NetworkBookService()
            if case .loading(let nextURL) = more {
                do {
                    let page = try await service.loadChapterCommentsPage(
                        book: target.book, chapter: target.chapter, source: target.source, nextPageURL: nextURL
                    )
                    guard !Task.isCancelled else { return }
                    pages.append(page, requestedURL: nextURL)
                    more = .idle
                } catch {
                    guard !Task.isCancelled else { return }
                    more = .failed(error.localizedDescription)
                }
                return
            }
            guard case .loading = state else { return }
            do {
                if target.source.ruleReview?.supportsChapterComments == true {
                    let page = try await service.loadChapterCommentsPage(
                        book: target.book, chapter: target.chapter, source: target.source
                    )
                    guard !Task.isCancelled else { return }
                    pages.append(page, requestedURL: nil)
                    state = .loaded
                } else if target.source.ruleReview?.supportsChapterCommentsPage == true {
                    let url = try await service.chapterCommentsPageURL(
                        book: target.book, chapter: target.chapter, source: target.source
                    )
                    guard !Task.isCancelled else { return }
                    state = .page(url)
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var sourceComments: some View {
        switch state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加载评论")
            }
        case .page:
            Button {
                showsSourcePage = true
            } label: {
                Label("打开书源评论页", systemImage: "safari")
            }
            .accessibilityIdentifier("reader.comments.sourcePage")
        case .failed(let message):
            Text(message)
                .accessibilityIdentifier("reader.comments.error")
            Button("重试") {
                state = .loading
                attempt += 1
            }
            .accessibilityIdentifier("reader.comments.retry")
        case .loaded:
            if pages.comments.isEmpty, pages.nextPageURL == nil {
                Text("本章暂无评论")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.comments.empty")
            } else {
                ForEach(pages.comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        if let author = comment.author {
                            Text(author).font(.subheadline.weight(.semibold))
                        }
                        Text(comment.content).textSelection(.enabled)
                        if let postedAt = comment.postedAt {
                            Text(postedAt).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                if let nextURL = pages.nextPageURL {
                    switch more {
                    case .loading:
                        ProgressView("正在加载更多评论")
                    case .idle:
                        Button("加载更多") { loadMore(nextURL) }
                            .accessibilityIdentifier("reader.comments.more")
                    case .failed(let message):
                        Text(message).accessibilityIdentifier("reader.comments.moreError")
                        Button("重试加载更多") { loadMore(nextURL) }
                            .accessibilityIdentifier("reader.comments.retryMore")
                    }
                }
            }
        }
    }

    private func loadMore(_ url: URL) {
        guard pages.nextPageURL == url else { return }
        if case .loading = more { return }
        more = .loading(url)
        attempt += 1
    }
}

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

struct ReaderChapterSlider: View {
    let directory: ReaderChapterDirectory
    let currentNumber: Int
    let progress: Double
    let onSelect: (Int) -> Void
    @State private var previewNumber: Int?

    var body: some View {
        let count = directory.readableIndices.count
        let number = previewNumber ?? currentNumber
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let previewNumber, directory.readableIndices.indices.contains(previewNumber - 1) {
                    Text(directory.rows[directory.readableIndices[previewNumber - 1]].title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text("\(previewNumber)/\(count)")
                } else {
                    Text("第 \(currentNumber) 章 / 共 \(count) 章")
                    Spacer(minLength: 0)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if count > 1 {
                Slider(value: Binding(
                    get: { Double(max(number, 1)) },
                    set: { previewNumber = Int($0.rounded()) }
                ), in: 1...Double(count), step: 1) { editing in
                    if !editing, let previewNumber {
                        self.previewNumber = nil
                        select(previewNumber)
                    }
                }
                .tint(ReadingTheme.accent)
                .accessibilityLabel("章节跳转")
                .accessibilityValue("第 \(number) 章，共 \(count) 章")
                .accessibilityIdentifier("reader.chapterSlider")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(currentNumber + 1)
                    case .decrement: select(currentNumber - 1)
                    @unknown default: break
                    }
                }
            } else {
                ProgressView(value: progress).tint(ReadingTheme.accent)
            }
        }
    }

    private func select(_ number: Int) {
        guard directory.readableIndices.indices.contains(number - 1) else { return }
        onSelect(directory.readableIndices[number - 1])
    }
}

struct ReaderTableOfContents: View {
    let directory: ReaderChapterDirectory
    let currentIndex: Int
    let bookTitle: String
    let bookURL: String
    let sourceID: String?
    let cache: ChapterContentCache
    @Binding var descending: Bool
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        ReadingNavigationStack {
            ScrollViewReader { proxy in
                let rows = directory.rows(matching: search, descending: descending)
                List {
                    Section {
                        ForEach(rows) { row in
                            chapterRow(row).id(row.id)
                        }
                    } header: {
                        HStack {
                            Text(bookTitle).lineLimit(1)
                            Spacer()
                            Text("共 \(directory.readableIndices.count) 章")
                        }
                        .textCase(nil)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if rows.isEmpty && !search.isEmpty { ReadingUnavailableView.search(text: search) }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(currentIndex, anchor: .center) }
                }
                .onChange(of: descending) { _ in
                    if rows.contains(where: { $0.id == currentIndex }) { proxy.scrollTo(currentIndex, anchor: .center) }
                }
                .onChange(of: search) { query in
                    if query.isEmpty { proxy.scrollTo(currentIndex, anchor: .center) }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            if search.isEmpty { proxy.scrollTo(currentIndex, anchor: .center) }
                            else { search = "" }
                        } label: { Image(systemName: "scope") }
                        .accessibilityLabel("定位当前章节")
                        Button(descending ? "正序" : "倒序") { descending.toggle() }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索章节")
        }
    }

    @ViewBuilder private func chapterRow(_ row: ReaderChapterDirectory.Row) -> some View {
        if let number = row.number {
            let current = row.id == currentIndex
            Button { onSelect(row.id) } label: {
                HStack(spacing: 12) {
                    Text("\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(current ? ReadingTheme.accent : .secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).lineLimit(2)
                        if current {
                            Text("正在阅读")
                                .font(.caption)
                                .foregroundStyle(ReadingTheme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                    if let sourceID {
                        ChapterAvailabilityIcon(bookURL: bookURL, chapterURL: row.chapterURL, sourceID: sourceID, cache: cache)
                    }
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("reader.toc.\(row.id)")
            .listRowBackground(current ? ReadingTheme.accent.opacity(0.08) : Color.clear)
        } else {
            Label(row.title, systemImage: "books.vertical")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }
}

struct ChapterAvailabilityIcon: View {
    let bookURL: String
    let chapterURL: String
    let sourceID: String
    var cache: ChapterContentCache = .live()
    @State private var isCached: Bool?

    var body: some View {
        ZStack {
            if isCached == false {
                Image(systemName: "icloud")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("未下载")
            }
        }
        .frame(width: 24)
        .task(id: [bookURL, chapterURL, sourceID]) {
            isCached = nil
            let changes = await cache.availability(bookURL: bookURL, chapterURL: chapterURL, sourceID: sourceID)
            for await cached in changes {
                guard !Task.isCancelled else { return }
                isCached = cached
            }
        }
    }
}

struct ReaderChapterLoadingOverlay: View {
    let title: String
    let foreground: Color
    let background: Color
    @State private var showsIndicator = false

    var body: some View {
        ZStack {
            if showsIndicator {
                HStack(spacing: 12) {
                    ProgressView().tint(foreground)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在打开本章").font(.subheadline.weight(.semibold))
                        Text(title).font(.caption).lineLimit(1)
                    }
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(background.opacity(0.82))
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(foreground.opacity(0.14))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reader.chapterLoading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            showsIndicator = true
        }
    }
}
