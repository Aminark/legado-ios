import SwiftUI
import UIKit

struct ReaderTextPage {
    let offset: CGFloat
    let height: CGFloat
    let characterRange: NSRange

    /// TextKit line fragments include line/paragraph spacing and mixed fonts.
    /// A page break must fall between these fragments, never through a glyph.
    @MainActor static func layout(in view: UITextView, height: CGFloat) -> [ReaderTextPage] {
        layout(manager: view.layoutManager, container: view.textContainer, height: height)
    }

    @MainActor static func layout(manager: NSLayoutManager, container: NSTextContainer, height: CGFloat) -> [ReaderTextPage] {
        manager.ensureLayout(for: container)
        var pages: [ReaderTextPage] = []
        var startY: CGFloat = 0
        var endY: CGFloat = 0
        var startGlyph = 0
        var endGlyph = 0
        func appendPage() {
            guard endGlyph > startGlyph else { return }
            let glyphs = NSRange(location: startGlyph, length: endGlyph - startGlyph)
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            pages.append(.init(offset: startY, height: endY - startY, characterRange: characters))
        }
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            if endGlyph > startGlyph, rect.maxY - startY > height + 0.01 {
                appendPage()
                startY = rect.minY
                startGlyph = glyphs.location
            }
            endY = rect.maxY
            endGlyph = NSMaxRange(glyphs)
        }
        appendPage()
        return pages
    }
}

private final class ReaderLayoutTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero
    private var pendingLayoutFlush = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        scheduleLayoutNotification()
    }

    /// Coalesces layout notifications onto the next main run-loop turn so
    /// pagination (`ensureLayout`) and `contentInset` updates never re-enter
    /// UIKit's active `layoutSubviews` stack frame.
    private func scheduleLayoutNotification() {
        guard !pendingLayoutFlush else { return }
        pendingLayoutFlush = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLayoutFlush = false
            guard self.window != nil || self.bounds.width > 0 else { return }
            self.onLayout?(self)
        }
    }
}

struct ReaderTextView: UIViewRepresentable {
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    var fontRevision = 0
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    let isSelectable: Bool
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let clickActions: [Int]
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    let requestedPosition: Int
    let jumpPosition: Int?
    let renderRevision: Int
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Void
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    let onTapAction: (Int) -> Void
    var holdsDisplayedPage = false
    var chapterGeneration = 0

    var media = ReaderMediaPresentation()
    var chapterIndex = 0
    var hardwareInput: ReaderPageInput?
    var paperColor: UIColor?
    var paperImage: UIImage?
    var adjacentChapterIndex: (Int) -> Int? = { _ in nil }
    var chapterPreview: (Int) async -> ReaderScrollChapter? = { _ in nil }

    private var turnStyle: ReaderPageTurnStyle? {
        isEInkMode ? nil : ReaderPageTurnStyle(rawValue: pageAnimation)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view: ReaderLayoutTextView
        if #available(iOS 16.0, *) {
            view = ReaderLayoutTextView(usingTextLayoutManager: false)
        } else {
            view = ReaderLayoutTextView(frame: .zero)
        }
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator, !coordinator.parent.holdsDisplayedPage, !coordinator.isApplyingContent else { return }
            coordinator.restoreLayoutAnchor(in: view)
            coordinator.reportPage(in: view)
            coordinator.reportPageRanges(in: view)
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        hardwareInput?.turn = { [weak coordinator = context.coordinator] direction in coordinator?.turnPage(direction) }
        let wasHoldingPage = context.coordinator.parent.holdsDisplayedPage
        let chapterChanged = context.coordinator.parent.chapterGeneration != chapterGeneration
        let paperChanged = context.coordinator.parent.paperColor != paperColor || context.coordinator.parent.paperImage !== paperImage
        if paperChanged || context.coordinator.parent.turnStyle != turnStyle {
            context.coordinator.cancelTurn()
            context.coordinator.chapterTurn = nil
        }
        context.coordinator.parent = self
        if holdsDisplayedPage {
            if !wasHoldingPage { context.coordinator.holdDisplayedPage() }
            return
        }
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        if view.selectedRange.length > 0 {
            view.selectedRange = NSRange(location: 0, length: 0)
        }
        if view.isFirstResponder {
            view.resignFirstResponder()
        }
        let contentKey = text.hashValue
        var primaryHasher = Hasher()
        primaryHasher.combine(title)
        primaryHasher.combine(contentKey)
        let primaryContentKey = primaryHasher.finalize()
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        var adjacentHasher = Hasher()
        adjacentHasher.combine(showsPrevious)
        if showsPrevious {
            adjacentHasher.combine(previousTitle)
            adjacentHasher.combine(previousText)
        }
        adjacentHasher.combine(showsContinuation)
        if showsContinuation {
            adjacentHasher.combine(continuationTitle)
            adjacentHasher.combine(continuationText)
        }
        let adjacentContentKey = adjacentHasher.finalize()
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(fontRevision)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if chapterChanged || context.coordinator.styleKey != styleKey || context.coordinator.mediaRevision != media.revision
            || (viewportSizeChanged && !context.coordinator.inline.items.isEmpty) {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = chapterChanged || context.coordinator.primaryContentKey != primaryContentKey
            let position = primaryContentChanged ? requestedPosition : context.coordinator.pendingPagePosition
                ?? context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
            context.coordinator.mediaRevision = media.revision
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText,
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            let inline = media.document(text, chapter: chapterIndex)
            context.coordinator.inline = inline
            rendered.append(media.render(text, inline: inline, attributes: bodyAttributes,
                                        width: view.bounds.width - CGFloat(paddingLeft + paddingRight + 8),
                                        chapter: chapterIndex))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText,
                    attributes: bodyAttributes
                ))
            }
            context.coordinator.isApplyingContent = true
            // Changing the margins rewraps the old text immediately. Apply them
            // after capturing the visible character, together with the new text.
            view.textContainerInset = .init(
                top: CGFloat(paddingTop + headerInset), left: CGFloat(paddingLeft),
                bottom: CGFloat(paddingBottom + footerInset), right: CGFloat(paddingRight)
            )
            view.textStorage.setAttributedString(rendered)
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(to: position, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
            context.coordinator.scroll(to: context.coordinator.pendingPagePosition ?? readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition {
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        if chapterChanged { context.coordinator.animateLoadedChapter(in: view) }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )
        // SwiftUI can reset the bindings after the chapter's TextKit layout has
        // already completed. Reconcile them even when the text/style is unchanged.
        if view.bounds.width > 0, view.bounds.height > 0 {
            context.coordinator.reportPage(in: view)
            if pageRanges.isEmpty { context.coordinator.reportPageRanges(in: view) }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var mediaRevision = -1
        var inline = ChapterInlineMedia()
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        private var layoutAnchor: Int?
        var lastJumpPosition: Int?
        private(set) var pendingPagePosition: Int?
        private(set) var layoutGeneration = 0
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var secondsPerScreen = 10.0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isApplyingContent = false
        private var isTurningPage = false
        private weak var pagePan: UIPanGestureRecognizer?
        private var turnView: ReaderPageTurnView?
        private var turnOffset: CGFloat?
        private var panDirection: Int?
        private var previewTask: Task<Void, Never>?
        private var previewChapter: Int?
        private var awaitingPreviewChapter = false
        var chapterTurn: (index: Int, direction: Int, image: UIImage, touchHeight: CGFloat)?
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private weak var nextSwipe: UISwipeGestureRecognizer?
        private weak var previousSwipe: UISwipeGestureRecognizer?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false
        private var cachedPages: [ReaderTextPage] = []
        private var paginationKey = ""
        private let pageMask = CAShapeLayer()

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func syncDisplayLinkPaused() {
            let shouldRun = isAutoReading && !isAutoReadPaused && !parent.holdsDisplayedPage
            displayLink?.isPaused = !shouldRun
            if !shouldRun { lastTimestamp = 0 }
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            next.direction = .left
            view.addGestureRecognizer(next)
            let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            previous.direction = .right
            view.addGestureRecognizer(previous)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            tap.require(toFail: pan)
            pagePan = pan
            nextSwipe = next
            previousSwipe = previous
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            let interactive = !isScrollMode && parent.turnStyle != nil
            pagePan?.isEnabled = interactive
            nextSwipe?.isEnabled = !isScrollMode && !interactive
            previousSwipe?.isEnabled = !isScrollMode && !interactive
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = false
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if parent.pageAnimation != 3 {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                return
            }
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.color = parent.foregroundColor.withAlphaComponent(0.65)
                indicator.startAnimating()
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func holdDisplayedPage() {
            if !awaitingPreviewChapter { cancelTurn() }
            layoutAnchor = nil
            layoutGeneration &+= 1
            isAutoReadPaused = true
            syncDisplayLinkPaused()
        }

        func invalidate() {
            cancelTurn()
            chapterTurn = nil
            layoutGeneration &+= 1
            resetAutoPage()
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
            syncDisplayLinkPaused()
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            resetAutoPage()
        }

        func scroll(to characterPosition: Int, in view: UITextView) {
            cancelTurn()
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            if parent.pageAnimation != 3 {
                // Another layout pass may already be reading the visible page when
                // this update returns. Apply the chapter position before that pass.
                layoutAnchor = characterPosition
                pendingPagePosition = characterPosition
                restorePendingPage(in: view)
                return
            }
            let generation = layoutGeneration
            let prefix = characterPosition == 0 ? currentSectionStart : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: inline.displayedOffset(characterPosition),
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                point.y += view.textContainerInset.top
                let limits = self.scrollLimits(for: view)
                let target = min(
                    max(point.y - view.adjustedContentInset.top, limits.minimum),
                    limits.maximum
                )
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        func restoreLayoutAnchor(in view: UITextView) {
            guard parent.pageAnimation != 3, let layoutAnchor else { return }
            pendingPagePosition = layoutAnchor
            restorePendingPage(in: view)
        }

        func restorePendingPage(in view: UITextView) {
            guard let position = pendingPagePosition, !isApplyingContent,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            isApplyingContent = true
            defer {
                isApplyingContent = false
                if pendingPagePosition == nil { scrollViewDidScroll(view) }
            }
            let pages = pages(in: view)
            guard let first = pages.first, let last = pages.last else { return }
            let location = ReaderPositionResolver.renderedLocation(
                position: inline.displayedOffset(position), prefixLength: renderedPrefixLength, renderedLength: view.textStorage.length
            )
            // Chapter start includes the heading, even when it fills a page of its own.
            let page = position == 0 ? first : pages.first { NSLocationInRange(location, $0.characterRange) } ?? last
            lastViewportSize = view.bounds.size
            view.setContentOffset(CGPoint(x: 0, y: page.offset), animated: false)
            pendingPagePosition = nil
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            if parent.pageAnimation != 3 {
                return max(view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom, 1)
            }
            return max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            if parent.pageAnimation != 3 {
                return (0, pages(in: view).last?.offset ?? 0)
            }
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            if parent.pageAnimation != 3 {
                let pages = pages(in: view)
                return (pageIndex(in: view, pages: pages) + 1, max(pages.count, 1))
            }
            let pageHeight = readingViewportHeight(for: view)
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let limits = scrollLimits(for: view)
            let scrollRange = max(limits.maximum - limits.minimum, 0)
            let total = max(Int(ceil(scrollRange / pageHeight)) + 1, 1)
            guard total > 1 else { return (1, 1) }
            let position = min(max(view.contentOffset.y - limits.minimum, 0), scrollRange)
            let current = position >= scrollRange - 0.5
                ? total
                : min(Int(floor(position / pageHeight)) + 1, total)
            return (current, total)
        }

        private func pages(in view: UITextView) -> [ReaderTextPage] {
            let key = "\(mediaRevision)|\(styleKey)|\(view.bounds.size)|\(view.textContainerInset)|\(view.textContainer.size.width)"
            if paginationKey != key || cachedPages.isEmpty {
                cachedPages = ReaderTextPage.layout(in: view, height: readingViewportHeight(for: view))
                paginationKey = key
            }
            // The last page also starts at a complete line, even when it
            // contains less than a screen of text. Keep this after relayouts.
            let bottom = max(0, (cachedPages.last?.offset ?? 0) + view.bounds.height - view.contentSize.height)
            if abs(view.contentInset.bottom - bottom) > 0.01 { view.contentInset.bottom = bottom }
            return cachedPages
        }

        private func pageIndex(in view: UITextView, pages: [ReaderTextPage]) -> Int {
            pages.lastIndex { $0.offset <= view.contentOffset.y + 0.5 } ?? 0
        }

        private func nextPageOffset(in view: UITextView, direction: Int = 1) -> CGFloat {
            let pages = pages(in: view)
            guard !pages.isEmpty else { return 0 }
            return pages[min(max(pageIndex(in: view, pages: pages) + direction, 0), pages.count - 1)].offset
        }

        private func updatePageMask(in view: UITextView) {
            guard parent.pageAnimation != 3 else {
                view.layer.mask = nil
                return
            }
            let pages = pages(in: view)
            guard !pages.isEmpty else { return }
            let page = pages[pageIndex(in: view, pages: pages)]
            // UITextView lays out one continuous document. Hide neighboring
            // lines in the per-page margins instead of showing partial lines.
            let rect = CGRect(x: view.bounds.minX, y: page.offset + view.textContainerInset.top,
                              width: view.bounds.width, height: min(page.height, readingViewportHeight(for: view)))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageMask.path = UIBezierPath(rect: rect).cgPath
            view.layer.mask = pageMask
            CATransaction.commit()
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            if parent.pageAnimation != 3 {
                let pages = pages(in: view)
                return pages.isEmpty ? 0 : pages[pageIndex(in: view, pages: pages)].characterRange.location
            }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(inline.sourceOffset(character - renderedPrefixLength), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !parent.holdsDisplayedPage, !isRenderingAutoPage, !isApplyingContent, pendingPagePosition == nil else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        func reportPage(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            updatePageMask(in: view)
            let metrics = pageMetrics(for: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) frame=\(view.convert(view.bounds, to: nil)) offset=\(view.contentOffset) clip=\(view.clipsToBounds) mask=\(pageMask.path?.boundingBoxOfPath ?? .zero) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        func reportPageRanges(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if parent.pageAnimation == 3 {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            var ranges: [NSRange] = []
            for page in pages(in: view) {
                let characterRange = page.characterRange
                let start = min(inline.sourceOffset(characterRange.location - renderedPrefixLength), parent.text.utf16.count)
                let end = min(
                    inline.sourceOffset(NSMaxRange(characterRange) - renderedPrefixLength),
                    parent.text.utf16.count
                )
                ranges.append(NSRange(location: start, length: max(end - start, 0)))
            }
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            layoutAnchor = nil
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let (minimum, maximum) = scrollLimits(for: view)
            let atEnd = view.contentOffset.y >= maximum - 0.5
            let atStart = view.contentOffset.y <= minimum + 0.5
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended, turnView == nil else { return }
            let point = gesture.location(in: view)
            let local = CGPoint(x: point.x - view.textContainerInset.left, y: point.y - view.textContainerInset.top)
            if parent.media.activate(at: local, manager: view.layoutManager, container: view.textContainer) { return }
            // UIScrollView changes its bounds origin as content scrolls, and
            // gesture locations use that content coordinate space. Convert
            // back to viewport coordinates before dividing the visible screen
            // into the 3×3 tap grid.
            let viewportX = point.x - view.bounds.minX
            let viewportY = point.y - view.bounds.minY
            let column = min(max(Int(viewportX / max(view.bounds.width / 3, 1)), 0), 2)
            let row = min(max(Int(viewportY / max(view.bounds.height / 3, 1)), 0), 2)
            let index = row * 3 + column
            let action = index == 4
                ? 0
                : (parent.clickActions.indices.contains(index) ? parent.clickActions[index] : 0)

            if parent.pageAnimation == 3, action == 1 || action == 2 {
                return
            }
            switch action {
            case 1: turnPage(1, touchHeight: viewportY / view.bounds.height)
            case 2: turnPage(-1, touchHeight: viewportY / view.bounds.height)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard gesture === pagePan, let pan = pagePan else { return true }
            let velocity = pan.velocity(in: textView)
            return !parent.holdsDisplayedPage && turnView == nil && abs(velocity.x) > abs(velocity.y)
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = textView, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let translation = gesture.translation(in: view)
            let touchHeight = (gesture.location(in: view).y - view.bounds.minY) / view.bounds.height
            switch gesture.state {
            case .began:
                beginPageDrag(direction: gesture.velocity(in: view).x < 0 ? 1 : -1, touchHeight: touchHeight)
                fallthrough
            case .changed:
                guard let direction = panDirection else { return }
                turnView?.update(progress: -CGFloat(direction) * translation.x / view.bounds.width, touchHeight: touchHeight)
            case .ended, .cancelled, .failed:
                guard let direction = panDirection else { return }
                panDirection = nil
                previewTask?.cancel()
                previewTask = nil
                let velocity = gesture.velocity(in: view).x
                let distance = -CGFloat(direction) * translation.x
                let projected = distance - CGFloat(direction) * velocity * 0.16
                let complete = gesture.state == .ended && distance > 6 && projected > view.bounds.width * 0.32
                if turnView != nil {
                    settleTurn(commit: complete, velocity: velocity)
                } else if complete {
                    turnPage(direction, touchHeight: touchHeight)
                }
            default: break
            }
        }

        private func beginPageDrag(direction: Int, touchHeight: CGFloat) {
            guard !parent.holdsDisplayedPage, turnView == nil, let view = textView, let style = parent.turnStyle else { return }
            panDirection = direction
            if isAutoReading { resetAutoReadForPageChange() }
            prepareTurn(in: view, direction: direction, style: style, touchHeight: touchHeight)
        }

        func turnPage(_ direction: Int, touchHeight: CGFloat = 0.84) {
            guard !isTurningPage, turnView == nil, !parent.holdsDisplayedPage, let view = textView else { return }
            layoutAnchor = nil
            if isAutoReading { resetAutoReadForPageChange() }
            let (minimum, maximum) = scrollLimits(for: view)
            if (direction < 0 && view.contentOffset.y <= minimum + 0.5) ||
                (direction > 0 && view.contentOffset.y >= maximum - 0.5) {
                if parent.turnStyle != nil, let index = parent.adjacentChapterIndex(direction) {
                    let pages = pages(in: view)
                    if !pages.isEmpty {
                        let image = pageImage(pages[pageIndex(in: view, pages: pages)], in: view)
                        chapterTurn = (index, direction, image, touchHeight)
                    }
                }
                navigateToAdjacentChapter(direction: direction, in: view)
                return
            }
            if let style = parent.turnStyle {
                prepareTurn(in: view, direction: direction, style: style, touchHeight: touchHeight)
                if turnView != nil {
                    settleTurn(commit: true, velocity: 0)
                    return
                }
            }
            let target = CGPoint(x: 0, y: nextPageOffset(in: view, direction: direction))
            let animated = !parent.isEInkMode && parent.pageAnimation != 4 && parent.turnStyle == nil
            view.setContentOffset(target, animated: animated)
            if animated {
                isTurningPage = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.isTurningPage = false }
            }
        }

        private func prepareTurn(in view: UITextView, direction: Int, style: ReaderPageTurnStyle, touchHeight: CGFloat) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let pages = pages(in: view)
            let index = pageIndex(in: view, pages: pages)
            let next = index + direction
            guard pages.indices.contains(next) else {
                if panDirection != nil, !pages.isEmpty, let neighbor = parent.adjacentChapterIndex(direction) {
                    previewTask = Task { [weak self, weak view] in
                        guard let chapter = await self?.parent.chapterPreview(neighbor), !Task.isCancelled,
                              let self, let view, self.panDirection == direction, let pan = self.pagePan else { return }
                        let layout = ReaderScrollChapterLayout(chapter: chapter, configuration: self.parent, width: view.bounds.width)
                        let previewPages = ReaderTextPage.layout(manager: layout.manager, container: layout.container,
                                                                 height: self.readingViewportHeight(for: view))
                        guard let target = direction > 0 ? previewPages.first : previewPages.last else { return }
                        let image = self.pageImage(target, in: view, manager: layout.manager, left: layout.left)
                        self.showTurn(in: view, style: style, direction: direction, touchHeight: touchHeight,
                                      current: self.pageImage(pages[index], in: view), target: image)
                        self.previewChapter = neighbor
                        self.turnView?.update(progress: -CGFloat(direction) * pan.translation(in: view).x / view.bounds.width,
                                              touchHeight: (pan.location(in: view).y - view.bounds.minY) / view.bounds.height)
                    }
                }
                return
            }
            showTurn(in: view, style: style, direction: direction, touchHeight: touchHeight,
                     current: pageImage(pages[index], in: view), target: pageImage(pages[next], in: view))
            turnOffset = pages[next].offset
        }

        func animateLoadedChapter(in view: UITextView) {
            guard let pending = chapterTurn else { return }
            chapterTurn = nil
            guard let style = parent.turnStyle, pending.index == parent.chapterIndex,
                  view.bounds.size == pending.image.size else { return }
            let pages = pages(in: view)
            guard !pages.isEmpty else { return }
            showTurn(in: view, style: style, direction: pending.direction, touchHeight: pending.touchHeight,
                     current: pending.image, target: pageImage(pages[pageIndex(in: view, pages: pages)], in: view))
            settleTurn(commit: true, velocity: 0)
        }

        private func showTurn(in view: UITextView, style: ReaderPageTurnStyle, direction: Int, touchHeight: CGFloat,
                              current: UIImage, target: UIImage) {
            guard let host = view.superview else { return }
            let overlay = ReaderPageTurnView(frame: view.convert(view.bounds, to: host), style: style, direction: direction,
                                             current: current, target: target, paper: parent.paperColor ?? parent.backgroundColor,
                                             touchHeight: touchHeight)
            host.insertSubview(overlay, aboveSubview: view)
            turnView = overlay
        }

        private func navigateToAdjacentChapter(direction: Int, in view: UITextView) {
            let position = contentCharacter(at: view.contentOffset, in: view)
            if direction < 0 { parent.onReachedStart(position) } else { parent.onReachedEnd(position) }
        }

        private func settleTurn(commit: Bool, velocity: CGFloat) {
            guard let turnView else { return }
            turnView.settle(to: commit ? 1 : 0, velocity: velocity) { [weak self] in
                guard let self else { return }
                if commit, let neighbor = self.previewChapter, let view = self.textView,
                   self.parent.adjacentChapterIndex(turnView.direction) == neighbor {
                    // Keep the final preview on top until TextKit installs the new chapter.
                    self.awaitingPreviewChapter = true
                    self.navigateToAdjacentChapter(direction: turnView.direction, in: view)
                    return
                }
                if commit, let offset = self.turnOffset {
                    self.layoutAnchor = nil
                    self.textView?.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                }
                self.cancelTurn()
            }
        }

        func cancelTurn() {
            previewTask?.cancel()
            previewTask = nil
            previewChapter = nil
            awaitingPreviewChapter = false
            turnView?.cancelAnimation()
            turnView?.removeFromSuperview()
            turnView = nil
            turnOffset = nil
            panDirection = nil
        }

        /// Render the exact TextKit page without scrolling the live document.
        /// A partial or cancelled drag must never publish a new reading position.
        private func pageImage(_ page: ReaderTextPage, in view: UITextView, manager: NSLayoutManager? = nil,
                               left: CGFloat? = nil) -> UIImage {
            let manager = manager ?? view.layoutManager
            let rect = CGRect(origin: .zero, size: view.bounds.size)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = min(view.traitCollection.displayScale, parent.turnStyle == .curl ? 2 : 3)
            return UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
                (parent.paperColor ?? parent.backgroundColor).setFill()
                context.fill(rect)
                if let image = parent.paperImage, let window = view.window {
                    let canvas = view.convert(window.bounds, from: window).offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
                    let scale = max(canvas.width / image.size.width, canvas.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                                          width: size.width, height: size.height))
                }
                let inset = view.textContainerInset
                context.cgContext.clip(to: CGRect(x: 0, y: inset.top, width: rect.width,
                                                  height: min(page.height, readingViewportHeight(for: view))))
                let glyphs = manager.glyphRange(forCharacterRange: page.characterRange, actualCharacterRange: nil)
                let origin = CGPoint(x: left ?? inset.left, y: inset.top - page.offset)
                manager.drawBackground(forGlyphRange: glyphs, at: origin)
                manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else { return false }
            let target = nextPageOffset(in: view)
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            updatePageMask(in: view)
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            updatePageMask(in: view)
            isRenderingAutoPage = false

            let overlay = UIImageView(image: image)
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            overlay.frame = CGRect(x: 0, y: originalOffset.y, width: view.bounds.width, height: 0)
            view.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            layoutAnchor = nil
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay {
                overlay.frame = CGRect(
                    x: 0,
                    y: view.contentOffset.y,
                    width: view.bounds.width,
                    height: revealedHeight
                )
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            layoutAnchor = nil
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let target = nextPageOffset(in: view)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, turnView == nil, panDirection == nil, let view = textView else {
                lastTimestamp = link.timestamp
                return
            }
            guard lastTimestamp > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            let elapsed = link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}
