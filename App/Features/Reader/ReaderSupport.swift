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

/// A seek can start anywhere on the track. The release location is authoritative
/// even if the last drag preview hasn't been rendered yet.
struct ReaderSeekSlider: UIViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    @Binding var preview: Double?
    let label: String
    var spokenValue: String?
    var identifier: String?
    let onSelect: (Double) -> Void

    func makeUIView(context: Context) -> Track { Track(self) }

    func updateUIView(_ track: Track, context: Context) {
        track.configuration = self
        track.slider.minimumValue = Float(range.lowerBound)
        track.slider.maximumValue = Float(range.upperBound)
        track.slider.value = Float(preview ?? value)
        track.slider.accessibilityLabel = label
        track.slider.accessibilityValue = spokenValue
        track.slider.accessibilityIdentifier = identifier
        track.slider.step = step.map { Float($0) }
    }

    final class Slider: UISlider {
        var step: Float?

        override func accessibilityIncrement() {
            guard let step else { super.accessibilityIncrement(); return }
            value += step
            sendActions(for: .valueChanged)
        }

        override func accessibilityDecrement() {
            guard let step else { super.accessibilityDecrement(); return }
            value -= step
            sendActions(for: .valueChanged)
        }
    }

    final class Track: UIView {
        let slider = Slider()
        var configuration: ReaderSeekSlider

        init(_ configuration: ReaderSeekSlider) {
            self.configuration = configuration
            super.init(frame: .zero)
            slider.minimumTrackTintColor = UIColor(ReadingTheme.accent)
            slider.addTarget(self, action: #selector(adjusted), for: .valueChanged)
            addSubview(slider)
            let touches = UIView()
            touches.isAccessibilityElement = false
            addSubview(touches)
            let drag = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
            drag.minimumPressDuration = 0
            touches.addGestureRecognizer(drag)
            accessibilityElements = [slider]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { slider.intrinsicContentSize }

        override func layoutSubviews() {
            super.layoutSubviews()
            for subview in subviews { subview.frame = bounds }
        }

        @objc private func adjusted() {
            configuration.onSelect(snapped(Double(slider.value)))
        }

        private func snapped(_ value: Double) -> Double {
            let range = configuration.range
            guard let step = configuration.step else { return value }
            let stops = ((value - range.lowerBound) / step).rounded()
            return min(max(range.lowerBound + stops * step, range.lowerBound), range.upperBound)
        }

        @objc private func scrub(_ drag: UILongPressGestureRecognizer) {
            let range = configuration.range
            let rect = slider.trackRect(forBounds: slider.bounds)
            let start = slider.thumbRect(forBounds: slider.bounds, trackRect: rect, value: slider.minimumValue).midX
            let end = slider.thumbRect(forBounds: slider.bounds, trackRect: rect, value: slider.maximumValue).midX
            guard start != end else { return }
            let fraction = min(max((drag.location(in: slider).x - start) / (end - start), 0), 1)
            let target = snapped(range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound))
            switch drag.state {
            case .began, .changed:
                configuration.preview = target
            case .ended:
                configuration.preview = nil
                configuration.onSelect(target)
            case .cancelled, .failed:
                configuration.preview = nil
            default:
                break
            }
        }
    }
}

struct ReaderChapterSlider: View {
    let directory: ReaderChapterDirectory
    let currentNumber: Int
    let progress: Double
    var canGoPrevious: Bool = true
    var canGoNext: Bool = true
    var isNight: Bool = false
    var isEInk: Bool = false
    var onStepChapter: ((Int) -> Void)?
    let onSelect: (Int) -> Void
    @State private var preview: Double?

    var body: some View {
        let count = directory.readableIndices.count
        let previewNumber = preview.map { Int($0) }
        let number = previewNumber ?? currentNumber
        let isScrubbing = previewNumber != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let previewNumber, directory.readableIndices.indices.contains(previewNumber - 1) {
                    Text(directory.rows[directory.readableIndices[previewNumber - 1]].title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("第 \(currentNumber) 章 · 共 \(count) 章")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Group {
                    if let previewNumber {
                        Text("\(previewNumber) / \(count)")
                    } else {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isScrubbing ? ReadingTheme.onAccent : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isScrubbing
                        ? ReadingTheme.accentFill
                        : Color.primary.opacity(isNight ? 0.10 : 0.06),
                    in: Capsule()
                )
            }
            .padding(.horizontal, 2)

            HStack(spacing: 8) {
                if let onStepChapter {
                    ReaderChromeCircleButton(
                        icon: "chevron.left",
                        label: "上一章",
                        isNight: isNight,
                        isEInk: isEInk,
                        diameter: 34,
                        iconSize: 13
                    ) {
                        onStepChapter(-1)
                    }
                    .disabled(!canGoPrevious)
                    .opacity(canGoPrevious ? 1 : 0.28)
                }

                if count > 1 {
                    ReaderSeekSlider(value: Double(max(currentNumber, 1)), range: 1...Double(count), step: 1,
                                     preview: $preview, label: "章节跳转", spokenValue: "第 \(number) 章，共 \(count) 章",
                                     identifier: "reader.chapterSlider") { target in
                        select(Int(target.rounded()))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                } else {
                    ReadingProgressLine(value: progress)
                        .padding(.vertical, 12)
                }

                if let onStepChapter {
                    ReaderChromeCircleButton(
                        icon: "chevron.right",
                        label: "下一章",
                        isNight: isNight,
                        isEInk: isEInk,
                        diameter: 34,
                        iconSize: 13
                    ) {
                        onStepChapter(1)
                    }
                    .disabled(!canGoNext)
                    .opacity(canGoNext ? 1 : 0.28)
                }
            }
        }
    }

    private func select(_ number: Int) {
        guard directory.readableIndices.indices.contains(number - 1) else { return }
        onSelect(directory.readableIndices[number - 1])
    }
}

enum ReaderChromePalette {
    static let sheetCanvas = adaptive(0xF4F3F0, dark: 0x111114)
    static let cardSurface = adaptive(0xFFFFFF, dark: 0x1C1C21)
    static let controlWell = adaptive(0xEFEEEA, dark: 0x28282E)
    static let hairline = adaptiveAlpha(0x000000, alpha: 0.065, dark: 0xFFFFFF, darkAlpha: 0.09)
    static let lightChromeTint = Color(red: 0.985, green: 0.982, blue: 0.975).opacity(0.80)
    static let nightChromeTint = Color(red: 0.105, green: 0.105, blue: 0.125).opacity(0.86)

    static func sheetBackground(isEInk: Bool) -> Color {
        isEInk ? Color(uiColor: .systemBackground) : sheetCanvas
    }

    static func cardBackground(isEInk: Bool) -> Color {
        isEInk ? Color(uiColor: .systemBackground) : cardSurface
    }

    static func controlWellColor(isEInk: Bool) -> Color {
        isEInk ? Color.primary.opacity(0.06) : controlWell
    }

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        adaptiveAlpha(light, alpha: 1, dark: dark, darkAlpha: 1)
    }

    private static func adaptiveAlpha(_ light: UInt32, alpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            let resolvedAlpha = isDark ? darkAlpha : alpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: resolvedAlpha
            )
        })
    }
}

struct ReaderTactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct ReaderFrostedChromeBackground: View {
    let isNight: Bool
    let isEInk: Bool
    var cornerRadius: CGFloat = 0

    var body: some View {
        if cornerRadius > 0 {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if isEInk {
                shape
                    .fill(Color(uiColor: .systemBackground))
                    .overlay {
                        shape.strokeBorder(Color.primary.opacity(0.24), lineWidth: 0.75)
                    }
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(isNight ? ReaderChromePalette.nightChromeTint : ReaderChromePalette.lightChromeTint)
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: isNight
                                ? [Color.white.opacity(0.18), Color.white.opacity(0.05)]
                                : [Color.white.opacity(0.82), Color.black.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                }
                .shadow(
                    color: Color.black.opacity(isNight ? 0.48 : 0.10),
                    radius: 22,
                    x: 0,
                    y: 8
                )
            }
        } else {
            if isEInk {
                Color(uiColor: .systemBackground)
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    isNight ? ReaderChromePalette.nightChromeTint : ReaderChromePalette.lightChromeTint
                }
            }
        }
    }
}

struct ReaderChromeCircleIcon: View {
    let systemName: String
    let isNight: Bool
    let isEInk: Bool
    var isAccent: Bool = false
    var diameter: CGFloat = 36
    var iconSize: CGFloat = 15

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(isAccent ? ReadingTheme.coral : Color.primary)
            .frame(width: diameter, height: diameter)
            .background {
                Circle().fill(fillColor)
            }
            .overlay {
                Circle().strokeBorder(borderColor, lineWidth: isEInk ? 0.75 : 0.5)
            }
            .frame(width: max(diameter + 6, 42), height: max(diameter + 6, 42))
            .contentShape(Rectangle())
    }

    private var fillColor: Color {
        if isEInk { return Color.clear }
        if isAccent { return ReadingTheme.coral.opacity(isNight ? 0.22 : 0.14) }
        return Color.primary.opacity(isNight ? 0.095 : 0.055)
    }

    private var borderColor: Color {
        if isEInk { return Color.primary.opacity(0.22) }
        if isAccent { return ReadingTheme.coral.opacity(0.32) }
        return Color.primary.opacity(isNight ? 0.09 : 0.06)
    }
}

struct ReaderChromeCircleButton: View {
    let icon: String
    let label: String
    let isNight: Bool
    let isEInk: Bool
    var isAccent: Bool = false
    var diameter: CGFloat = 36
    var iconSize: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReaderChromeCircleIcon(
                systemName: icon,
                isNight: isNight,
                isEInk: isEInk,
                isAccent: isAccent,
                diameter: diameter,
                iconSize: iconSize
            )
        }
        .buttonStyle(ReaderTactileButtonStyle())
        .accessibilityLabel(label)
    }
}

struct ReaderStyleCard<Content: View>: View {
    let title: String
    var detail: String? = nil
    var isEInk: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                content
            }
            .background(
                ReaderChromePalette.cardBackground(isEInk: isEInk),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isEInk ? Color.primary.opacity(0.22) : ReaderChromePalette.hairline,
                        lineWidth: isEInk ? 0.75 : 0.5
                    )
            }
            .shadow(
                color: isEInk ? .clear : Color.black.opacity(0.03),
                radius: 10,
                x: 0,
                y: 3
            )
        }
    }
}

struct ReaderStyleCollapsibleCard<Content: View>: View {
    let title: String
    let icon: String
    let summary: String
    var isEInk: Bool = false
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if isEInk {
                    isExpanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(
                            ReaderChromePalette.controlWellColor(isEInk: isEInk),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ReaderStyleDivider(isEInk: isEInk)
                VStack(spacing: 0) {
                    content
                }
            }
        }
        .background(
            ReaderChromePalette.cardBackground(isEInk: isEInk),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isEInk ? Color.primary.opacity(0.22) : ReaderChromePalette.hairline,
                    lineWidth: isEInk ? 0.75 : 0.5
                )
        }
        .shadow(
            color: isEInk ? .clear : Color.black.opacity(0.03),
            radius: 10,
            x: 0,
            y: 3
        )
    }
}

struct ReaderStyleDivider: View {
    var isEInk: Bool = false
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(isEInk ? Color.primary.opacity(0.18) : ReaderChromePalette.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, inset)
    }
}

struct ReaderStyleValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var isEInk: Bool = false
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(format(value))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(ReaderChromePalette.controlWellColor(isEInk: isEInk), in: Capsule())
            }
            Slider(value: $value, in: range, step: step)
                .tint(ReadingTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct ReaderStyleSegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct ReaderStyleSegmentedPill<Value: Hashable>: View {
    let options: [ReaderStyleSegmentOption<Value>]
    let selectedValue: Value
    var isEInk: Bool = false
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                let isSelected = option.value == selectedValue
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? ReadingTheme.onAccent : Color.primary.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(minWidth: 56, minHeight: 34)
                        .background(
                            isSelected ? ReadingTheme.accentFill : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            if isSelected {
                                Capsule().strokeBorder(ReadingTheme.selectionBorder, lineWidth: 0.75)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(ReaderTactileButtonStyle())
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(ReaderChromePalette.controlWellColor(isEInk: isEInk), in: Capsule())
    }
}

struct ReaderStylePresetSwatch: View {
    let preset: ReaderStylePreset
    let isSelected: Bool
    var isEInk: Bool = false
    let action: () -> Void

    var body: some View {
        let fg = Color(uiColor: preset.foreground)
        let bg = Color(uiColor: preset.background)
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(bg)
                        .frame(width: 56, height: 68)
                        .overlay {
                            VStack(spacing: 5) {
                                Text("Aa")
                                    .font(.system(size: 17, weight: .medium, design: .serif))
                                    .foregroundStyle(fg)
                                VStack(spacing: 3) {
                                    Capsule()
                                        .fill(fg.opacity(0.32))
                                        .frame(width: 26, height: 2)
                                    Capsule()
                                        .fill(fg.opacity(0.20))
                                        .frame(width: 18, height: 2)
                                }
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(fg.opacity(isSelected ? 0.25 : 0.14), lineWidth: 0.75)
                        }
                        .shadow(
                            color: isEInk ? .clear : Color.black.opacity(isSelected ? 0.12 : 0.05),
                            radius: isSelected ? 6 : 3,
                            x: 0,
                            y: 2
                        )
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(ReadingTheme.onAccent)
                                    .frame(width: 16, height: 16)
                                    .background(ReadingTheme.accentFill, in: Circle())
                                    .padding(5)
                            }
                        }
                }
                .padding(3)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(ReadingTheme.accent, lineWidth: 1.75)
                    }
                }

                Text(preset.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(ReaderTactileButtonStyle())
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ReaderStyleIconBadge: View {
    let systemName: String
    var isDestructive: Bool = false
    var isEInk: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isDestructive ? Color.red : ReadingTheme.accent)
            .frame(width: 30, height: 30)
            .background(
                isDestructive
                    ? Color.red.opacity(isEInk ? 0.08 : 0.12)
                    : ReaderChromePalette.controlWellColor(isEInk: isEInk),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func readerStyleNavigationBar(isEInk: Bool) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbarBackground(ReaderChromePalette.sheetBackground(isEInk: isEInk), for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func readerSheetAllowsInlineScrolling() -> some View {
        if #available(iOS 16.4, *), !ReadingCompatibility.usesLegacyUI {
            presentationContentInteraction(.scrolls)
        } else {
            background(ReaderSheetScrollEnabler())
        }
    }
}

private struct ReaderSheetScrollEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.configureSheet() }

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configureSheet()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configureSheet()
        }

        func configureSheet() {
            var current: UIViewController? = self
            while let candidate = current {
                if let sheet = candidate.presentationController as? UISheetPresentationController {
                    if sheet.prefersScrollingExpandsWhenScrolledToEdge {
                        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                    }
                    break
                }
                current = candidate.parent
            }
        }
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
