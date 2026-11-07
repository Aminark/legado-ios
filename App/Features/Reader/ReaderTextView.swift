import SwiftUI
import UIKit

struct ReaderTextPage {
    let glyphRange: NSRange
    let offset: CGFloat
    let visibleHeight: CGFloat
}

@MainActor
enum ReaderChapterSnapshot {
    static func capture(_ view: UIView, excluding overlay: UIView? = nil) -> UIImageView? {
        guard let window = view.window, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let viewport = view.convert(view.bounds, to: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        // A page's text mask must not make its unused area transparent. Render
        // the complete viewport, including the reader background underneath it.
        // Temporarily exclude the outgoing cover without committing a frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hidden = overlay?.layer.isHidden
        overlay?.layer.isHidden = true
        defer {
            if let hidden { overlay?.layer.isHidden = hidden }
            CATransaction.commit()
        }
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            let background = view.backgroundColor ?? .clear
            (background.cgColor.alpha > 0 ? background : (window.backgroundColor ?? .systemBackground)).setFill()
            context.fill(CGRect(origin: .zero, size: view.bounds.size))
            context.cgContext.translateBy(x: -viewport.minX, y: -viewport.minY)
            window.layer.render(in: context.cgContext)
        }
        let snapshot = UIImageView(image: image)
        snapshot.isOpaque = true
        snapshot.isUserInteractionEnabled = false
        return snapshot
    }
}

@MainActor
enum ReaderTextPagination {
    static func pages(in view: UITextView) -> [ReaderTextPage] {
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        let height = max(view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom, 1)
        let scale = max(view.traitCollection.displayScale, 1)
        let text = view.textStorage.string as NSString
        var lines: [(range: NSRange, bounds: CGRect, blank: Bool)] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, range, _ in
            var bounds = rect
            if !used.isEmpty { bounds = bounds.union(used) }
            let ink = manager.boundingRect(forGlyphRange: range, in: view.textContainer)
            if !ink.isEmpty { bounds = bounds.union(ink) }
            let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let blank = text.substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lines.append((range, bounds, blank))
        }
        // Trailing empty paragraphs have no visible text and must not add a blank page.
        while lines.last?.blank == true { lines.removeLast() }
        guard !lines.isEmpty else {
            return [.init(glyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), offset: 0, visibleHeight: 0)]
        }
        var pages: [ReaderTextPage] = []
        var start = 0
        var offset: CGFloat = 0
        var bottom: CGFloat = 0
        for (index, line) in lines.enumerated() {
            if index > start, line.bounds.maxY - offset > height {
                let first = lines[start].range.location
                pages.append(.init(glyphRange: NSRange(location: first, length: line.range.location - first),
                                   offset: offset, visibleHeight: min(ceil((bottom - offset) * scale) / scale, height)))
                start = index
                offset = floor(line.bounds.minY * scale) / scale
            }
            bottom = line.bounds.maxY
        }
        let first = lines[start].range.location
        pages.append(.init(glyphRange: NSRange(location: first, length: manager.numberOfGlyphs - first),
                           offset: offset, visibleHeight: min(ceil(max(bottom - offset, 0) * scale) / scale, height)))
        return pages
    }

    static func index(at offset: CGFloat, pages: [ReaderTextPage]) -> Int {
        var low = 0, high = pages.count
        while low < high {
            let middle = (low + high) / 2
            if pages[middle].offset <= offset + 0.001 { low = middle + 1 }
            else { high = middle }
        }
        return max(low - 1, 0)
    }

    static func index(containing glyph: Int, pages: [ReaderTextPage]) -> Int {
        pages.firstIndex(where: { NSLocationInRange(glyph, $0.glyphRange) }) ?? max(pages.count - 1, 0)
    }
}

final class ReaderLayoutTextView: UITextView {
    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var paginates = false
    var onLayout: ((UITextView) -> Void)?
    private(set) var pages: [ReaderTextPage] = []
    private var paginationDirty = true
    private var paginationSize = CGSize.zero
    private var paginationInsets = UIEdgeInsets.zero
    private var paginationWidth: CGFloat = 0
    private(set) var isUpdatingPagination = false
    private(set) var isUpdatingLayout = false
    private let pageMask = CAShapeLayer()
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            var size = newValue
            if paginates, !paginationDirty, paginationSize == bounds.size,
               paginationInsets == textContainerInset, paginationWidth == textContainer.size.width,
               let last = pages.last {
                // The last page is allowed to keep its unused bottom space.
                // Otherwise UITextView clamps it upward into the previous page.
                size.height = last.offset + bounds.height
            }
            super.contentSize = size
        }
    }

    func invalidatePagination() {
        paginationDirty = true
        setNeedsLayout()
    }

    @discardableResult
    func updatePagination() -> Bool {
        guard paginates else {
            layer.mask = nil
            pages = []
            paginationDirty = true
            return false
        }
        guard !isUpdatingPagination, bounds.width > 0, bounds.height > 0 else { return false }
        isUpdatingPagination = true
        defer { isUpdatingPagination = false }
        let changed = paginationDirty || paginationSize != bounds.size || paginationInsets != textContainerInset
            || paginationWidth != textContainer.size.width
        if changed {
            pages = ReaderTextPagination.pages(in: self)
            paginationDirty = false
            paginationSize = bounds.size
            paginationInsets = textContainerInset
            paginationWidth = textContainer.size.width
        }
        let size = CGSize(width: contentSize.width, height: (pages.last?.offset ?? 0) + bounds.height)
        if contentSize != size { contentSize = size }
        updatePageMask()
        return changed
    }

    func updatePageMask() {
        guard paginates, !pages.isEmpty else { layer.mask = nil; return }
        let page = pages[ReaderTextPagination.index(at: contentOffset.y, pages: pages)]
        let height = min(max(page.offset + page.visibleHeight - contentOffset.y, 0), bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageMask.frame = bounds
        pageMask.path = UIBezierPath(rect: CGRect(x: 0, y: textContainerInset.top, width: bounds.width, height: height)).cgPath
        layer.mask = pageMask
        CATransaction.commit()
    }

    override func layoutSubviews() {
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        super.layoutSubviews()
        isUpdatingLayout = false
        guard !isUpdatingPagination else { return }
        let changed = updatePagination()
        guard bounds.width > 0, bounds.height > 0,
              changed || bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
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
    var chapterRevision = 0
    var chapterIndex = 0
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view = ReaderLayoutTextView()
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator else { return }
            let previousSize = coordinator.lastViewportSize
            coordinator.lastViewportSize = view.bounds.size
            if coordinator.hasPendingScroll {
                coordinator.applyPendingScroll(in: view)
                return
            }
            if previousSize != .zero, previousSize != view.bounds.size {
                coordinator.scroll(to: coordinator.parent.readerPosition, in: view)
            } else {
                coordinator.reportPage(in: view)
                coordinator.reportPageRanges(in: view)
            }
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.paginates = effectivePageAnimation != 3
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.contentInsetAdjustmentBehavior = .never
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        if let layoutView = view as? ReaderLayoutTextView {
            layoutView.paginates = effectivePageAnimation != 3
        }
        if viewportSizeChanged {
            view.layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: view.textStorage.length),
                actualCharacterRange: nil
            )
        }
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
        view.isSelectable = false
        view.selectedRange = NSRange(location: 0, length: 0)
        view.resignFirstResponder()
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        let primaryContentKey = "\(chapterRevision)|\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = showsPrevious || showsContinuation
            ? "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue : 0
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(chapterRevision)|\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if context.coordinator.styleKey != styleKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey
            if primaryContentChanged, effectivePageAnimation != 3,
               let oldIndex = context.coordinator.displayedChapterIndex, oldIndex != chapterIndex {
                context.coordinator.prepareChapterTurn(chapterIndex > oldIndex ? 1 : -1, in: view)
            }
            context.coordinator.displayedChapterIndex = chapterIndex
            let visiblePosition = context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
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
            rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))
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
            (view as? ReaderLayoutTextView)?.invalidatePagination()
            view.attributedText = rendered
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view
            )
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged, !context.coordinator.hasPendingScroll {
            context.coordinator.scroll(to: readerPosition, in: view)
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
        var displayedChapterIndex: Int?
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        private(set) var layoutGeneration = 0
        private var pendingScrollPosition: Int?
        private var isApplyingScroll = false
        var hasPendingScroll: Bool { pendingScrollPosition != nil }
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
        private var chapterTurnCover: UIView?
        private var chapterTurnDirection = 0
        private var chapterTurnContentKey: Int?
        private var isAnimatingChapterTurn = false
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

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
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
            nextSwipe?.isEnabled = !isScrollMode
            previousSwipe?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            // Page boundaries follow complete text lines rather than a uniform screen stride.
            view.isPagingEnabled = false
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
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

        func invalidate() {
            clearChapterTurn()
            layoutGeneration &+= 1
            pendingScrollPosition = nil
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
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            pendingScrollPosition = characterPosition
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.applyPendingScroll(in: view)
            }
        }

        @discardableResult
        func applyPendingScroll(in view: UITextView) -> Bool {
            guard !isApplyingScroll, let characterPosition = pendingScrollPosition,
                  view.bounds.width > 0, view.bounds.height > 0, !view.text.isEmpty else { return false }
            isApplyingScroll = true
            defer { isApplyingScroll = false }
            view.layoutManager.ensureLayout(for: view.textContainer)
            view.layoutIfNeeded()
            let limits = scrollLimits(for: view)
            let target: CGFloat
            if characterPosition == Int.max {
                // An end-of-chapter jump is a viewport destination, not the
                // bounding rect of a possibly invisible trailing newline.
                target = limits.maximum
            } else {
                let prefix = characterPosition == 0 && parent.pageAnimation == 3
                    ? currentSectionStart
                    : renderedPrefixLength
                let location = ReaderPositionResolver.renderedLocation(
                    position: characterPosition,
                    prefixLength: prefix,
                    renderedLength: view.text.utf16.count
                )
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                if usesPagination {
                    let pages = pageLayout(in: view)
                    let index = characterPosition == 0 ? 0 : ReaderTextPagination.index(containing: glyph, pages: pages)
                    target = pages.isEmpty ? 0 : pages[index].offset
                } else {
                    point.y += view.textContainerInset.top
                    target = min(max(point.y - view.adjustedContentInset.top, limits.minimum), limits.maximum)
                }
            }
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            pendingScrollPosition = nil
            reportPage(in: view)
            reportPageRanges(in: view)
            completeChapterTurn(in: view)
            return true
        }

        private var usesPagination: Bool { parent.pageAnimation != 3 || parent.isEInkMode }

        private func pageLayout(in view: UITextView) -> [ReaderTextPage] {
            if let paged = view as? ReaderLayoutTextView {
                paged.updatePagination()
                return paged.pages
            }
            let pages = ReaderTextPagination.pages(in: view)
            let size = CGSize(width: view.contentSize.width, height: (pages.last?.offset ?? 0) + view.bounds.height)
            if view.contentSize != size { view.contentSize = size }
            return pages
        }

        private func adjacentPageOffset(_ direction: Int, in view: UITextView) -> CGFloat {
            if usesPagination {
                let pages = pageLayout(in: view)
                guard !pages.isEmpty else { return 0 }
                let index = ReaderTextPagination.index(at: view.contentOffset.y, pages: pages)
                return pages[min(max(index + direction, 0), pages.count - 1)].offset
            }
            let limits = scrollLimits(for: view)
            return min(max(view.contentOffset.y + CGFloat(direction) * readingViewportHeight(for: view), limits.minimum), limits.maximum)
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            if usesPagination {
                return (0, pageLayout(in: view).last?.offset ?? 0)
            }
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            if usesPagination {
                let pages = pageLayout(in: view)
                return (ReaderTextPagination.index(at: view.contentOffset.y, pages: pages) + 1, max(pages.count, 1))
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

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            if usesPagination {
                let pages = pageLayout(in: view)
                guard !pages.isEmpty else { return 0 }
                let range = pages[ReaderTextPagination.index(at: offset.y, pages: pages)].glyphRange
                guard range.length > 0 else { return 0 }
                return view.layoutManager.characterIndexForGlyph(at: range.location)
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
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isRenderingAutoPage, !isApplyingContent else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if let paged = view as? ReaderLayoutTextView {
                guard !paged.isUpdatingPagination, !paged.isUpdatingLayout else { return }
                paged.updatePageMask()
            }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    clearChapterTurn()
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
            let metrics = pageMetrics(for: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
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
            if !usesPagination {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            var ranges: [NSRange] = []
            for page in pageLayout(in: view) {
                let glyphRange = page.glyphRange
                guard glyphRange.length > 0 else { continue }
                let characterRange = view.layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                let start = max(characterRange.location - renderedPrefixLength, 0)
                let end = min(
                    characterRange.location + characterRange.length - renderedPrefixLength,
                    parent.text.utf16.count
                )
                guard end > start else { continue }
                let range = NSRange(location: start, length: end - start)
                if ranges.last?.location == range.location,
                   ranges.last?.length == range.length { continue }
                ranges.append(range)
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
            guard let view = textView, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
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
            case 1: turnPage(1)
            case 2: turnPage(-1)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !isTurningPage, let view = textView else { return }
            if isAutoReading { resetAutoReadForPageChange() }
            let (minimum, maximum) = scrollLimits(for: view)
            let target = adjacentPageOffset(direction, in: view)
            if direction < 0, view.contentOffset.y <= minimum + 0.5 {
                if parent.previousTitle != nil { prepareChapterTurn(direction, in: view) }
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            if direction > 0, view.contentOffset.y >= maximum - 0.5 {
                if parent.continuationTitle != nil { prepareChapterTurn(direction, in: view) }
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            isTurningPage = true
            let completion: (Bool) -> Void = { [weak self] _ in self?.isTurningPage = false }
            switch parent.isEInkMode ? 4 : parent.pageAnimation {
            case 4:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
            case 0:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = direction > 0 ? .reveal : .moveIn
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-cover")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 1:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = .push
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-slide")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 2:
                UIView.transition(
                    with: view,
                    duration: 0.38,
                    options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                    animations: { view.setContentOffset(CGPoint(x: 0, y: target), animated: false) },
                    completion: completion
                )
            default:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.isTurningPage = false }
            }
        }

        func prepareChapterTurn(_ direction: Int, in view: UITextView) {
            guard chapterTurnCover == nil, usesPagination, !view.text.isEmpty, let host = view.superview,
                  let snapshot = ReaderChapterSnapshot.capture(view) else { return }
            clearChapterTurn()
            let cover = UIView(frame: view.convert(view.bounds, to: host))
            cover.isUserInteractionEnabled = false
            cover.clipsToBounds = true
            cover.backgroundColor = view.backgroundColor
            snapshot.frame = cover.bounds
            cover.addSubview(snapshot)
            host.addSubview(cover)
            chapterTurnCover = cover
            chapterTurnDirection = direction
            chapterTurnContentKey = primaryContentKey
            isTurningPage = true
        }

        private func clearChapterTurn() {
            chapterTurnCover?.removeFromSuperview()
            chapterTurnCover = nil
            chapterTurnContentKey = nil
            isAnimatingChapterTurn = false
            isTurningPage = false
        }

        private func completeChapterTurn(in view: UITextView) {
            guard let cover = chapterTurnCover, !isAnimatingChapterTurn,
                  chapterTurnContentKey != primaryContentKey else { return }
            guard let oldPage = cover.subviews.first,
                  let newPage = ReaderChapterSnapshot.capture(view, excluding: cover) else {
                clearChapterTurn()
                return
            }
            isAnimatingChapterTurn = true
            let direction = chapterTurnDirection
            let distance = CGFloat(direction) * cover.bounds.width
            newPage.frame = cover.bounds
            cover.addSubview(newPage)
            let completion: (Bool) -> Void = { [weak self, weak cover] _ in
                guard let self, let cover, self.chapterTurnCover === cover else { return }
                self.clearChapterTurn()
            }
            switch parent.isEInkMode ? 4 : parent.pageAnimation {
            case 0:
                if direction > 0 {
                    cover.insertSubview(newPage, belowSubview: oldPage)
                    UIView.animate(withDuration: 0.3, animations: {
                        oldPage.transform = CGAffineTransform(translationX: -distance, y: 0)
                    }, completion: completion)
                } else {
                    newPage.transform = CGAffineTransform(translationX: distance, y: 0)
                    UIView.animate(withDuration: 0.3, animations: { newPage.transform = .identity }, completion: completion)
                }
            case 1:
                newPage.transform = CGAffineTransform(translationX: distance, y: 0)
                UIView.animate(withDuration: 0.3, animations: {
                    oldPage.transform = CGAffineTransform(translationX: -distance, y: 0)
                    newPage.transform = .identity
                }, completion: completion)
            case 2:
                newPage.isHidden = true
                UIView.transition(with: cover, duration: 0.38,
                                  options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                                  animations: { oldPage.isHidden = true; newPage.isHidden = false }, completion: completion)
            default:
                completion(true)
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
            let target = adjacentPageOffset(1, in: view)
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            view.layoutIfNeeded()
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
            let target = adjacentPageOffset(1, in: view)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, let view = textView else {
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
