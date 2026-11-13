import SwiftUI

@MainActor
final class ExploreSourceViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, empty, failed }

    let source: BookSource
    @Published private(set) var kinds: [ExploreKind] = []
    @Published private(set) var selectedKind: ExploreKind?
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore = false

    private let service: BookExploreService
    private var page = 1
    private var canLoadMore = false
    private var paginationTask: Task<Void, Never>?

    init(source: BookSource, service: BookExploreService = .init()) {
        self.source = source
        self.service = service
    }

    deinit { paginationTask?.cancel() }

    func load() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        paginationTask?.cancel()
        selectedKind = nil
        kinds = []
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        let report = await service.kinds(for: source)
        guard !Task.isCancelled else { return }
        kinds = report.kinds.filter { $0.navigableURL != nil }
        diagnostics = report.diagnostics
        guard let first = kinds.first else {
            state = diagnostics.contains(where: { $0.severity == .error }) ? .failed : .empty
            return
        }
        await select(kind: first)
    }

    func select(kind: ExploreKind) async {
        guard kind.navigableURL != nil else { return }
        paginationTask?.cancel()
        selectedKind = kind
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            books = DemoContent.exploreBooks
            state = .ready
            canLoadMore = true
            return
        }

        let outcome = await service.explore(source: source, kind: kind, page: page)
        guard !Task.isCancelled, selectedKind?.id == kind.id else { return }
        diagnostics = outcome.diagnostics
        books = outcome.books
        canLoadMore = !outcome.books.isEmpty
        state = books.isEmpty ? (outcome.diagnostics.isEmpty ? .empty : .failed) : .ready
    }

    func loadNextPageIfNeeded(current book: SearchBook) {
        guard book.id == books.last?.id,
              canLoadMore,
              !isLoadingMore,
              let kind = selectedKind else { return }
        isLoadingMore = true
        let nextPage = page + 1
        paginationTask = Task { [service, source] in
            if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                canLoadMore = false
                isLoadingMore = false
                return
            }
            let outcome = await service.explore(source: source, kind: kind, page: nextPage)
            guard !Task.isCancelled, selectedKind?.id == kind.id else {
                isLoadingMore = false
                return
            }
            let knownURLs = Set(books.map(\.bookURL))
            books.append(contentsOf: outcome.books.filter { !knownURLs.contains($0.bookURL) })
            diagnostics += outcome.diagnostics
            page = nextPage
            canLoadMore = !outcome.books.isEmpty
            isLoadingMore = false
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @Environment(\.colorScheme) private var colorScheme

    private var sources: [BookSource] {
        sourceLibrary.sources
            .filter { $0.enabled && $0.enabledExplore && !($0.exploreUrl?.isEmpty ?? true) }
            .sorted {
                if $0.customOrder != $1.customOrder { return $0.customOrder < $1.customOrder }
                return $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(spacing: 0) {
                    introduction
                    sectionHeading
                        .padding(.top, 24)
                        .padding(.bottom, sources.isEmpty ? 0 : 10)
                    if sources.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                                NavigationLink { ExploreSourceView(source: source) } label: {
                                    ExploreSourceRow(source: source, position: index)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, sources.isEmpty ? 24 : 20)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("explore.scroll")
        .background {
            ReadingTheme.canvas.ignoresSafeArea()
                .overlay(alignment: .top) {
                    if !sources.isEmpty {
                        ExploreHeaderWave()
                            .fill(ReadingTheme.groupedCanvas.opacity(0.6))
                            .frame(height: 160)
                            .padding(.top, 46)
                            .accessibilityHidden(true)
                    }
                }
        }
        .navigationBarHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("发现")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink { SearchView() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(ReadingTheme.groupedCanvas.opacity(0.75))
                                .shadow(color: .black.opacity(0.06), radius: 4, y: 3)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("explore.search")
            }
            Text("下一本好书，在这里遇见")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 26)
    }

    private var introduction: some View {
        NavigationLink { SourceManagementView() } label: {
            HStack(spacing: 11) {
                Image(systemName: "safari")
                    .font(.system(size: 27, weight: .light))
                    .frame(width: 46, height: 46)
                    .background(ReadingTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 5)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(ReadingTheme.ink.opacity(0.28))
                    .frame(width: 0.5, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("从喜欢的书源开始")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("浏览分类与榜单，发现更多故事")
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(ReadingTheme.surface.opacity(sources.isEmpty ? 0 : 0.9), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, sources.isEmpty ? 20 : 23)
            .background(alignment: .trailing) {
                Image("ExploreBookStack")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 86)
                    .opacity(colorScheme == .dark ? 0.16 : 0.55)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [ReadingTheme.groupedCanvas.opacity(0.8), ReadingTheme.groupedCanvas],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityHint("添加与管理书源")
        .accessibilityIdentifier("explore.manageSources")
    }

    private var sectionHeading: some View {
        HStack(spacing: 10) {
            if !sources.isEmpty {
                Capsule()
                    .fill(ReadingTheme.ink)
                    .frame(width: 4, height: 18)
                    .accessibilityHidden(true)
            }
            Text("分类与榜单")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            NavigationLink { SourceManagementView() } label: {
                HStack(spacing: 5) {
                    Text("\(sources.count)个书源")
                        .font(.footnote)
                    if !sources.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("explore.sourceCount")
        }
        .padding(.horizontal, sources.isEmpty ? 0 : 3)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image("ExploreEmptyBook")
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 100)
                .opacity(colorScheme == .dark ? 0.75 : 1)
                .accessibilityHidden(true)
            Text("暂无发现书源")
                .font(.title3.bold())
                .padding(.top, 12)
            Text("添加带有发现分类的书源，即可在这里浏览书籍")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            NavigationLink { SourceManagementView() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                    Text("添加书源").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(ReadingTheme.onAccent)
                .frame(width: 166, height: 40)
                .background {
                    Capsule().fill(LinearGradient(
                        colors: [ReadingTheme.accentFill, ReadingTheme.emphasisSurface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                }
                .padding(.vertical, 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("explore.addSource")
            .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
    }
}

private struct ExploreSourceRow: View {
    let source: BookSource
    let position: Int
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 16) {
            ExploreSourceIcon(source: source, position: position)
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [ReadingTheme.groupedCanvas.opacity(0.65), ReadingTheme.groupedCanvas.opacity(0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.bookSourceName)
                    .font(.system(size: nameSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .padding(.trailing, 4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ReadingTheme.surface)
                .shadow(color: .black.opacity(0.035), radius: 12, y: 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct ExploreSourceIcon: View {
    let source: BookSource
    let position: Int

    var body: some View {
        Group {
            if source.bookSourceType == 1 {
                Image(systemName: "headphones")
            } else {
                switch position % 7 {
                case 0: Image(systemName: "cloud")
                case 1, 4: ExploreGem().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                case 3: Image(systemName: UIImage(systemName: "party.popper") == nil ? "sparkles" : "party.popper")
                case 6: ExploreStackIcon().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                default: Image(systemName: "book")
                }
            }
        }
        .font(.system(size: 25, weight: .light))
        .foregroundStyle(ReadingTheme.ink)
    }
}

private struct ExploreGem: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.04, 0.32))
        [point(0.23, 0.08), point(0.77, 0.08), point(0.96, 0.32), point(0.5, 0.94)].forEach { path.addLine(to: $0) }
        path.closeSubpath()
        path.move(to: point(0.04, 0.32)); path.addLine(to: point(0.96, 0.32))
        path.move(to: point(0.37, 0.08)); path.addLine(to: point(0.29, 0.32)); path.addLine(to: point(0.5, 0.94))
        path.move(to: point(0.63, 0.08)); path.addLine(to: point(0.71, 0.32)); path.addLine(to: point(0.5, 0.94))
        return path
    }
}

private struct ExploreStackIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            let y = rect.minY + rect.height * (0.12 + CGFloat(row) * 0.25)
            let spine = CGRect(x: rect.minX + rect.width * 0.1, y: y,
                               width: rect.width * 0.78, height: rect.height * 0.23)
            path.addRoundedRect(in: spine, cornerSize: CGSize(width: rect.width * 0.1, height: rect.height * 0.1))
            path.move(to: CGPoint(x: spine.maxX - rect.width * 0.14, y: spine.minY))
            path.addQuadCurve(to: CGPoint(x: spine.maxX - rect.width * 0.14, y: spine.maxY),
                              control: CGPoint(x: spine.maxX, y: spine.midY))
        }
        return path
    }
}

private struct ExploreHeaderWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.23, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.65),
                      control1: CGPoint(x: rect.width * 0.73, y: -rect.height * 0.35),
                      control2: CGPoint(x: rect.width * 0.72, y: rect.height * 0.17))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct ExploreSourceView: View {
    @StateObject private var model: ExploreSourceViewModel

    init(source: BookSource) {
        _model = StateObject(wrappedValue: ExploreSourceViewModel(source: source))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.kinds.count > 1 { kindPicker }
                content
                if model.isLoadingMore { ProgressView("继续加载…").padding(.vertical, 12) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle(model.source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.reload() }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.kinds) { kind in
                    Button(kind.title) { Task { await model.select(kind: kind) } }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(model.selectedKind?.id == kind.id ? Color.primary : .secondary)
                        .overlay(alignment: .bottom) {
                            if model.selectedKind?.id == kind.id {
                                Rectangle().fill(Color.primary).frame(height: 2)
                            }
                        }
                        .accessibilityAddTraits(model.selectedKind?.id == kind.id ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在加载小说…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        case .empty:
            ReadingUnavailableView(
                "暂无小说",
                systemImage: "books.vertical",
                description: Text("当前书源或分类暂时没有内容，可以下拉刷新。")
            )
            .padding(.vertical, 40)
        case .failed where model.books.isEmpty:
            ReadingUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(model.diagnostics.first?.message ?? "书源发现规则解析失败。")
            )
            .padding(.vertical, 40)
        default:
            ForEach(model.books) { book in
                NavigationLink {
                    BookDetailView(searchBook: book, source: model.source)
                } label: {
                    ExploreBookRow(book: book)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadNextPageIfNeeded(current: book) }
            }
        }
    }
}

private struct ExploreBookRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 52, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let kind = book.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 65)
        }
    }
}
