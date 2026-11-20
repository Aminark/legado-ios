import SafariServices
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
                ReaderCommentsBrowser(url: url, close: { showsSourcePage = false })
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

private struct ReaderCommentsBrowser: UIViewControllerRepresentable {
    let url: URL
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { close() }
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
