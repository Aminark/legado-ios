import SwiftUI
import UIKit

enum ReaderPageTurnGesture {
    static let maximumAngleFromHorizontal: CGFloat = 45
    static let minimumTranslation: CGFloat = 40

    static func isHorizontalEnough(_ vector: CGPoint) -> Bool {
        guard vector != .zero else { return true }
        let fromHorizontal = abs(atan2(vector.y, vector.x)) * 180 / .pi
        return min(fromHorizontal, 180 - fromHorizontal) <= maximumAngleFromHorizontal + 0.001
    }

    /// Next page is `1`, previous page is `-1`.
    static func direction(for translation: CGPoint) -> Int? {
        guard hypot(translation.x, translation.y) >= minimumTranslation else { return nil }
        guard isHorizontalEnough(translation) else { return nil }
        return translation.x < 0 ? 1 : -1
    }

    static func progress(translation: CGFloat, direction: Int, width: CGFloat) -> CGFloat {
        min(max(-translation * CGFloat(direction) / max(width, 1), 0), 1)
    }

    static func shouldFinish(translation: CGFloat, velocity: CGFloat, direction: Int, width: CGFloat) -> Bool {
        let distance = -translation * CGFloat(direction)
        let projected = distance - velocity * CGFloat(direction) * 0.18
        return distance >= 8 && projected >= max(width, 1) / 3
    }
}

private final class ReaderPageTurnPanGesture: UIPanGestureRecognizer {}

@MainActor
final class ReaderPageDrag {
    let overlay: UIView
    let previous: UIView
    private(set) var next: UIView
    let direction: Int
    let mode: Int
    private(set) var progress: CGFloat = 0

    init(overlay: UIView, previous: UIView, next: UIView, direction: Int, mode: Int) {
        self.overlay = overlay
        self.previous = previous
        self.next = next
        self.direction = direction
        self.mode = mode
        overlay.addSubview(previous)
        replaceDestination(next)
    }

    func replaceDestination(_ page: UIView) {
        next.removeFromSuperview()
        next = page
        page.frame = overlay.bounds
        if mode == 1 || direction < 0 { overlay.addSubview(page) }
        else { overlay.insertSubview(page, belowSubview: previous) }
        update(progress)
    }

    func update(_ value: CGFloat) {
        progress = min(max(value, 0), 1)
        let width = overlay.bounds.width
        if mode == 2 {
            let moving = direction > 0 ? previous : next
            moving.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            moving.layer.position = CGPoint(x: 0, y: overlay.bounds.height / 2)
            moving.layer.isDoubleSided = false
            var transform = CATransform3DIdentity
            transform.m34 = -1 / max(width * 3, 1)
            let folded = direction > 0 ? progress : 1 - progress
            moving.layer.transform = CATransform3DRotate(transform, -acos(1 - folded), 0, 1, 0)
            return
        }
        let distance = width * CGFloat(direction)
        previous.transform = CGAffineTransform(translationX: mode == 1 || direction > 0 ? -distance * progress : 0, y: 0)
        next.transform = CGAffineTransform(translationX: mode == 1 || direction < 0 ? distance * (1 - progress) : 0, y: 0)
    }

    func finish(commit: Bool, completion: @escaping () -> Void) {
        let remaining = commit ? 1 - progress : progress
        UIView.animate(withDuration: max(0.08, min(0.25, Double(remaining) * 0.3)), delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.update(commit ? 1 : 0)
        }, completion: { _ in completion() })
    }

    func remove() {
        overlay.layer.removeAllAnimations()
        overlay.removeFromSuperview()
    }
}

final class ReaderViewport: UIView {
    let textView: UITextView
    private let clippingView = UIView()
    private var pageClipHeight: CGFloat?
    private var chapterOverlay: UIView?
    private(set) var pageDrag: ReaderPageDrag?
    var pageBackgroundColor = UIColor.white
    var pageBackgroundImage: UIImage?

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "reader.viewport"
        // Keep clipping separate from the scroll view and SwiftUI's root mask.
        clippingView.clipsToBounds = true
        addSubview(clippingView)
        clippingView.addSubview(textView)
        (textView as? ReaderLayoutTextView)?.onPageClipHeightChanged = { [weak self] height in
            self?.pageClipHeight = height
            self?.updateClippingFrame()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        updateClippingFrame()
    }

    private func updateClippingFrame() {
        clippingView.frame = CGRect(origin: .zero, size: CGSize(
            width: bounds.width, height: min(max(pageClipHeight ?? bounds.height, 0), bounds.height)
        ))
    }

    func cancelChapterAnimation() {
        chapterOverlay?.layer.removeAllAnimations()
        chapterOverlay?.removeFromSuperview()
        chapterOverlay = nil
        clippingView.isHidden = false
    }

    func cancelPageDrag() {
        pageDrag?.remove()
        pageDrag = nil
        clippingView.isHidden = false
    }

    func beginPageDrag(destination: UIView, direction: Int, mode: Int) -> Bool {
        guard let previous = chapterSnapshot() else { return false }
        cancelChapterAnimation()
        cancelPageDrag()
        let overlay = UIView(frame: bounds)
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        previous.frame = overlay.bounds
        addSubview(overlay)
        pageDrag = .init(overlay: overlay, previous: previous, next: destination, direction: direction, mode: mode)
        return true
    }

    /// Render a prepared page over the reader's actual background, including photos.
    /// The live text view and its reading position are never moved for a preview.
    func pageSnapshot(_ page: UITextView? = nil, visibleHeight: CGFloat? = nil) -> UIView? {
        guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
        let location = convert(bounds, to: window)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            pageBackgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            if let background = pageBackgroundImage, background.size.width > 0, background.size.height > 0 {
                let scale = max(window.bounds.width / background.size.width, window.bounds.height / background.size.height)
                let size = CGSize(width: background.size.width * scale, height: background.size.height * scale)
                background.draw(in: CGRect(x: (window.bounds.width - size.width) / 2 - location.minX,
                                           y: (window.bounds.height - size.height) / 2 - location.minY,
                                           width: size.width, height: size.height))
            }
            if let page {
                context.cgContext.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: visibleHeight ?? bounds.height))
                let origin = CGPoint(x: page.textContainerInset.left,
                                     y: page.textContainerInset.top - page.contentOffset.y)
                let glyphs = NSRange(location: 0, length: page.layoutManager.numberOfGlyphs)
                page.layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
                page.layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
        }
        return UIImageView(image: image)
    }

    func loadingPage(color: UIColor) -> UIView? {
        guard let page = pageSnapshot() else { return nil }
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.color = color
        indicator.startAnimating()
        let label = UILabel()
        label.text = "正在准备章节…"
        label.font = .systemFont(ofSize: 13)
        label.textColor = color
        let stack = UIStackView(arrangedSubviews: [indicator, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: page.centerYAnchor)])
        return page
    }

    func chapterSnapshot() -> UIView? {
        pageSnapshot(textView, visibleHeight: pageClipHeight)
    }

    func stageChapterAnimation(_ previous: UIView) {
        cancelChapterAnimation()
        let overlay = UIView(frame: bounds)
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        previous.frame = overlay.bounds
        overlay.addSubview(previous)
        addSubview(overlay)
        chapterOverlay = overlay
    }

    @discardableResult
    func animateChapter(from previous: UIView, direction: Int, mode: Int, completion: @escaping () -> Void) -> Bool {
        guard let overlay = chapterOverlay, bounds.width > 0,
              let body = clippingView.snapshotView(afterScreenUpdates: true) else {
            cancelChapterAnimation(); completion(); return false
        }
        let next = UIView(frame: overlay.bounds)
        next.backgroundColor = textView.backgroundColor
        body.frame = clippingView.frame
        next.addSubview(body)
        overlay.insertSubview(next, at: 0)
        clippingView.isHidden = true
        let finish: (Bool) -> Void = { [weak self, weak overlay] _ in
            overlay?.removeFromSuperview()
            if self?.chapterOverlay === overlay {
                self?.chapterOverlay = nil
                self?.clippingView.isHidden = false
            }
            completion()
        }
        if mode == 2 {
            UIView.transition(with: overlay, duration: 0.38,
                options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                animations: { previous.isHidden = true }, completion: finish)
            return true
        }
        let distance = bounds.width * CGFloat(direction)
        if mode == 1 || direction < 0 {
            overlay.bringSubviewToFront(next)
            next.transform = CGAffineTransform(translationX: distance, y: 0)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut], animations: {
            next.transform = .identity
            if mode == 1 || direction > 0 { previous.transform = CGAffineTransform(translationX: -distance, y: 0) }
        }, completion: finish)
        return true
    }
}

private final class ReaderLayoutTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    var onPageClipHeightChanged: ((CGFloat?) -> Void)?
    var pageClipHeight: CGFloat? { didSet { onPageClipHeightChanged?(pageClipHeight) } }
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }

}

struct ReaderTextPage {
    let offset: CGFloat
    let renderedRange: NSRange
    let visibleHeight: CGFloat
}

@MainActor
enum ReaderPageLayout {
    static func pages(in view: UITextView) -> [ReaderTextPage] {
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        let capacity = max(view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom, 1)
        var pages: [ReaderTextPage] = []
        var start: Int?
        var end = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        func appendPage() {
            guard let start else { return }
            let range = manager.characterRange(forGlyphRange: NSRange(location: start, length: end - start), actualGlyphRange: nil)
            pages.append(ReaderTextPage(offset: top, renderedRange: range,
                                        visibleHeight: view.textContainerInset.top + bottom - top))
        }
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, range, _ in
            if start != nil, used.maxY - top > capacity + 0.01 {
                appendPage()
                start = nil
            }
            if start == nil {
                start = range.location
                top = pages.isEmpty ? 0 : rect.minY
            }
            end = NSMaxRange(range)
            bottom = used.maxY
        }
        appendPage()
        return pages
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
    var chapterTransition: ReaderChapterTransition? = nil
    var onWillTurnPage: (() -> Void)? = nil
    var canGoPreviousChapter = false
    var canGoNextChapter = false
    var onPrepareChapter: ((Int) async -> ReaderPreparedChapter?)? = nil
    var onCommitChapter: ((ReaderPreparedChapter) -> Bool)? = nil
    var onCancelChapterPreparation: (() -> Void)? = nil
    var pageBackgroundColor: UIColor? = nil
    var pageBackgroundImage: UIImage? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ReaderViewport {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view: ReaderLayoutTextView
        if #available(iOS 16.0, *) {
            view = ReaderLayoutTextView(usingTextLayoutManager: false)
        } else {
            view = ReaderLayoutTextView(frame: .zero)
        }
        view.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.reportPage(in: view)
            coordinator?.reportPageRanges(in: view)
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
        view.contentInsetAdjustmentBehavior = .never
        view.clipsToBounds = true
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        let viewport = ReaderViewport(textView: view)
        viewport.pageBackgroundColor = pageBackgroundColor ?? backgroundColor
        viewport.pageBackgroundImage = pageBackgroundImage
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: viewport)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return viewport
    }

    func updateUIView(_ viewport: ReaderViewport, context: Context) {
        let view = viewport.textView
        viewport.pageBackgroundColor = pageBackgroundColor ?? backgroundColor
        viewport.pageBackgroundImage = pageBackgroundImage
        context.coordinator.parent = self
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
            context.coordinator.cancelPageDrag()
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
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
        let primaryContentKey = "\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)|\(viewport.pageBackgroundColor.hash)|\(pageBackgroundImage?.hash ?? 0)"
        let chapterChanged = context.coordinator.chapterTransitionID != chapterTransition?.id
        if context.coordinator.styleKey != styleKey || chapterChanged {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let finishesDrag = chapterChanged && context.coordinator.isCommittingPageDrag
            if !finishesDrag { context.coordinator.cancelPageDrag() }
            viewport.cancelChapterAnimation()
            let animatesChapter = chapterChanged && chapterTransition != nil && !context.coordinator.styleKey.isEmpty
                && !finishesDrag && (0...2).contains(effectivePageAnimation) && !UIAccessibility.isReduceMotionEnabled
            let oldPage = animatesChapter ? viewport.chapterSnapshot() : nil
            // Cover the old document before TextKit lays out the new one; an after-update
            // snapshot can otherwise briefly flush the new page to the display.
            if let oldPage { viewport.stageChapterAnimation(oldPage) }
            context.coordinator.chapterTransitionID = chapterTransition?.id
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey || chapterChanged
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
            view.attributedText = rendered
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view,
                immediately: chapterChanged && chapterTransition != nil
            )
            context.coordinator.isApplyingContent = false
            if finishesDrag { context.coordinator.cancelPageDrag(cancelPreparation: false) }
            if let oldPage, let chapterTransition {
                view.layoutIfNeeded()
                context.coordinator.animateChapter(in: viewport, previous: oldPage, transition: chapterTransition, mode: effectivePageAnimation)
            }
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
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

    static func dismantleUIView(_ view: ReaderViewport, coordinator: Coordinator) {
        coordinator.cancelPageDrag()
        view.cancelChapterAnimation()
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var chapterTransitionID: Int?
        private var chapterTransitionCount = 0
        private var lastChapterDirection = 0
        private var lastChapterSnapshotPage = (current: 0, total: 0)
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
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private var cachedPagination: (key: String, pages: [ReaderTextPage])?
        private weak var pageTurnPan: UIPanGestureRecognizer?
        private weak var viewport: ReaderViewport?
        private weak var readerTap: UITapGestureRecognizer?
        private var handledPageTurnPan = false
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false
        private final class PageDragSession {
            let direction: Int
            let offset: CGFloat?
            var prepared: ReaderPreparedChapter?
            var task: Task<Void, Never>?
            var released = false
            var failed = false
            var committing = false
            var snapshotPage = (current: 0, total: 0)
            init(direction: Int, offset: CGFloat?) { self.direction = direction; self.offset = offset }
        }
        private var pageDragSession: PageDragSession?
        var isCommittingPageDrag: Bool { pageDragSession?.committing == true }

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on viewport: ReaderViewport) {
            self.viewport = viewport
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            viewport.addGestureRecognizer(tap)
            readerTap = tap
            let pan = ReaderPageTurnPanGesture(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delaysTouchesBegan = false
            pan.delegate = self
            viewport.addGestureRecognizer(pan)
            pageTurnPan = pan
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // page-turn pans must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            pageTurnPan?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = false
            view.delaysContentTouches = false
            view.canCancelContentTouches = isScrollMode
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                if parent.pageAnimation == 3 { view.contentInset.bottom = 0 }
                else { _ = pagedPages(in: view) }
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
            cancelPageDrag()
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

        func scroll(to characterPosition: Int, in view: UITextView, immediately: Bool = false) {
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            let prefix = characterPosition == 0 && parent.pageAnimation == 3
                ? currentSectionStart
                : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: characterPosition,
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            if immediately && parent.pageAnimation != 3 {
                // A chapter transition snapshots the destination in this same update.
                // Position it under the old-page cover before the snapshot is taken.
                view.layoutIfNeeded()
                applyScroll(to: location, in: view, generation: generation)
                updatePageMask(in: view)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.applyScroll(to: location, in: view, generation: generation)
                }
            }
        }

        private func applyScroll(to location: Int, in view: UITextView, generation: Int) {
            guard layoutGeneration == generation else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            if parent.pageAnimation != 3 {
                let pages = pagedPages(in: view)
                if let page = pages.first(where: { NSLocationInRange(location, $0.renderedRange) }) ?? pages.last {
                    view.setContentOffset(CGPoint(x: 0, y: page.offset), animated: false)
                }
                return
            }
            let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
            var point = view.layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1),
                in: view.textContainer
            ).origin
            point.y += view.textContainerInset.top
            let limits = scrollLimits(for: view)
            let target = min(
                max(point.y - view.adjustedContentInset.top, limits.minimum),
                limits.maximum
            )
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - (parent.pageAnimation == 3 ? view.adjustedContentInset.top + view.adjustedContentInset.bottom : 0)
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func pagedPages(in view: UITextView) -> [ReaderTextPage] {
            let key = "\(styleKey)|\(view.bounds.size)|\(view.textContainerInset)|\(view.text.utf16.count)"
            if cachedPagination?.key != key {
                let pages = ReaderPageLayout.pages(in: view)
                cachedPagination = (key, pages)
            }
            let pages = cachedPagination?.pages ?? []
            // Content size can settle after TextKit's first layout pass.
            let bottom = max((pages.last?.offset ?? 0) + view.bounds.height - view.contentSize.height, 0)
            if abs(view.contentInset.bottom - bottom) > 0.5 { view.contentInset.bottom = bottom }
            return pages
        }

        private func pageIndex(at offset: CGFloat, pages: [ReaderTextPage]) -> Int {
            pages.lastIndex(where: { $0.offset <= offset + 0.5 }) ?? 0
        }

        private func adjacentPageOffset(in view: UITextView, direction: Int) -> CGFloat? {
            let pages = pagedPages(in: view)
            let index = pageIndex(at: view.contentOffset.y, pages: pages) + direction
            return pages.indices.contains(index) ? pages[index].offset : nil
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            if parent.pageAnimation != 3 {
                let pages = pagedPages(in: view)
                return (pageIndex(at: view.contentOffset.y, pages: pages) + 1, max(pages.count, 1))
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
            if parent.pageAnimation != 3 {
                let pages = pagedPages(in: view)
                let index = pageIndex(at: offset.y, pages: pages)
                return pages.indices.contains(index) ? pages[index].renderedRange.location : 0
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
            let metrics = pageMetrics(for: view)
            updatePageMask(in: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) offset=\(view.contentOffset) frame=\(view.frame) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total) chapterTransitions=\(chapterTransitionCount) chapterDirection=\(lastChapterDirection) snapshotPage=\(lastChapterSnapshotPage.current)/\(lastChapterSnapshotPage.total)"
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

        private func updatePageMask(in view: UITextView) {
            if let layoutView = view as? ReaderLayoutTextView {
                let pages = parent.pageAnimation == 3 ? [] : pagedPages(in: view)
                let index = pageIndex(at: view.contentOffset.y, pages: pages)
                layoutView.pageClipHeight = pages.indices.contains(index) ? pages[index].visibleHeight : nil
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
            view.layoutManager.ensureLayout(for: view.textContainer)
            var ranges: [NSRange] = []
            for page in pagedPages(in: view) {
                let characterRange = page.renderedRange
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
            let space = gesture.view ?? view
            let point = gesture.location(in: space)
            // The tap grid covers the full viewport, including blank areas
            // below a short page. If a test sends the gesture on
            // the text view, convert out of its content coordinate space.
            let viewportX = point.x - space.bounds.minX
            let viewportY = point.y - space.bounds.minY
            let column = min(max(Int(viewportX / max(space.bounds.width / 3, 1)), 0), 2)
            let row = min(max(Int(viewportY / max(space.bounds.height / 3, 1)), 0), 2)
            let index = row * 3 + column
            let action = index == 4
                ? 0
                : (parent.clickActions.indices.contains(index) ? parent.clickActions[index] : 0)
            switch action {
            case 1, 2:
                parent.onTapAction(0)
            case -1:
                break
            default:
                parent.onTapAction(action)
            }
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            let interactive = !parent.isEInkMode && (0...2).contains(parent.pageAnimation)
                && !UIAccessibility.isReduceMotionEnabled
            if interactive {
                switch gesture.state {
                case .began:
                    if pageDragSession?.released == true, pageDragSession?.task != nil { cancelPageDrag() }
                    guard !isTurningPage else { return }
                    handledPageTurnPan = false
                case .changed:
                    updatePageDrag(gesture.translation(in: gesture.view))
                case .ended:
                    updatePageDrag(gesture.translation(in: gesture.view))
                    finishPageDrag(translation: gesture.translation(in: gesture.view).x,
                                   velocity: gesture.velocity(in: gesture.view).x)
                case .cancelled, .failed:
                    rollBackPageDrag()
                default: break
                }
                return
            }
            switch gesture.state {
            case .began:
                handledPageTurnPan = false
            case .ended:
                guard !handledPageTurnPan else { return }
                guard let direction = ReaderPageTurnGesture.direction(for: gesture.translation(in: gesture.view)) else { return }
                handledPageTurnPan = true
                turnPage(direction)
            default:
                break
            }
        }

        private func updatePageDrag(_ translation: CGPoint) {
            guard let viewport else { return }
            if let session = pageDragSession, !session.released,
               translation.x * CGFloat(session.direction) > 6 {
                cancelPageDrag()
            }
            if pageDragSession == nil {
                guard !isTurningPage, abs(translation.x) >= 6,
                      ReaderPageTurnGesture.isHorizontalEnough(translation) else { return }
                beginPageDrag(direction: translation.x < 0 ? 1 : -1)
            }
            guard let session = pageDragSession, !session.released else { return }
            viewport.pageDrag?.update(ReaderPageTurnGesture.progress(
                translation: translation.x, direction: session.direction, width: viewport.bounds.width))
            reportPageDrag()
        }

        private func beginPageDrag(direction: Int) {
            guard let viewport, let view = textView else { return }
            let offset = adjacentPageOffset(in: view, direction: direction)
            if offset == nil {
                guard direction > 0 ? parent.canGoNextChapter : parent.canGoPreviousChapter,
                      parent.onPrepareChapter != nil else { return }
            }
            parent.onWillTurnPage?()
            resetAutoReadForPageChange()
            let session = PageDragSession(direction: direction, offset: offset)
            let destination: UIView?
            if let offset {
                let preview = pagePreview(view.attributedText, offset: offset, last: false, in: viewport)
                destination = preview?.view
                session.snapshotPage = preview?.page ?? (0, 0)
            } else { destination = viewport.loadingPage(color: parent.foregroundColor) }
            guard let destination, viewport.beginPageDrag(destination: destination, direction: direction, mode: parent.pageAnimation) else { return }
            pageDragSession = session
            isTurningPage = true
            if offset == nil {
                session.task = Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    let prepared = await self.parent.onPrepareChapter?(direction)
                    guard self.pageDragSession === session, !Task.isCancelled else { return }
                    session.task = nil
                    guard let prepared, let viewport = self.viewport,
                          let preview = self.chapterPreview(prepared, in: viewport) else {
                        session.failed = true
                        if session.released { self.rollBackPageDrag(cancelPreparation: false) }
                        return
                    }
                    session.prepared = prepared
                    session.snapshotPage = preview.page
                    viewport.pageDrag?.replaceDestination(preview.view)
                    self.reportPageDrag()
                    if session.released { self.completePageDrag(session) }
                }
            }
        }

        private func pagePreview(_ text: NSAttributedString, offset: CGFloat?, last: Bool,
                                 in viewport: ReaderViewport) -> (view: UIView, page: (current: Int, total: Int))? {
            guard let view = textView else { return nil }
            let preview: UITextView
            if #available(iOS 16.0, *) { preview = UITextView(usingTextLayoutManager: false) }
            else { preview = UITextView(frame: .zero) }
            preview.frame = viewport.bounds
            preview.contentInsetAdjustmentBehavior = .never
            preview.textContainerInset = view.textContainerInset
            preview.textContainer.lineFragmentPadding = view.textContainer.lineFragmentPadding
            preview.backgroundColor = view.backgroundColor
            preview.attributedText = text
            preview.layoutIfNeeded()
            let pages = ReaderPageLayout.pages(in: preview)
            let index = last ? max(pages.count - 1, 0) : pageIndex(at: offset ?? 0, pages: pages)
            let page = pages.indices.contains(index) ? pages[index] : nil
            preview.contentInset.bottom = max((pages.last?.offset ?? 0) + preview.bounds.height - preview.contentSize.height, 0)
            preview.setContentOffset(CGPoint(x: 0, y: page?.offset ?? 0), animated: false)
            preview.layoutIfNeeded()
            guard let snapshot = viewport.pageSnapshot(preview, visibleHeight: page?.visibleHeight) else { return nil }
            return (snapshot, (index + 1, max(pages.count, 1)))
        }

        private func chapterPreview(_ prepared: ReaderPreparedChapter, in viewport: ReaderViewport)
            -> (view: UIView, page: (current: Int, total: Int))? {
            let typography = ReaderTypography(configuration: parent)
            let text = NSMutableAttributedString(string: "")
            if parent.titleMode != 2, !prepared.title.isEmpty {
                text.append(NSAttributedString(string: prepared.title + "\n", attributes: typography.headingAttributes))
            }
            text.append(NSAttributedString(string: prepared.content, attributes: typography.bodyAttributes))
            return pagePreview(text, offset: nil, last: prepared.direction < 0, in: viewport)
        }

        private func finishPageDrag(translation: CGFloat, velocity: CGFloat) {
            guard let session = pageDragSession, !session.released, let viewport else { return }
            session.released = true
            if !ReaderPageTurnGesture.shouldFinish(translation: translation, velocity: velocity,
                                                  direction: session.direction, width: viewport.bounds.width) || session.failed {
                rollBackPageDrag(cancelPreparation: !session.failed)
            } else if session.offset != nil || session.prepared != nil {
                completePageDrag(session)
            }
            // Otherwise keep the current progress until the requested chapter is ready.
        }

        private func completePageDrag(_ session: PageDragSession) {
            guard pageDragSession === session, let viewport, let drag = viewport.pageDrag else { return }
            drag.finish(commit: true) { [weak self, weak session] in
                guard let self, let session, self.pageDragSession === session else { return }
                if let offset = session.offset, let view = self.textView {
                    view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    self.reportPage(in: view)
                    self.cancelPageDrag(cancelPreparation: false)
                } else if let prepared = session.prepared {
                    session.committing = true
                    if self.parent.onCommitChapter?(prepared) == true {
                        self.chapterTransitionCount += 1
                        self.lastChapterDirection = session.direction
                        self.lastChapterSnapshotPage = session.snapshotPage
                    } else { self.cancelPageDrag() }
                }
            }
        }

        private func rollBackPageDrag(cancelPreparation: Bool = true) {
            guard let session = pageDragSession, let drag = viewport?.pageDrag else { return }
            session.released = true
            session.task?.cancel()
            session.task = nil
            if cancelPreparation, session.offset == nil { parent.onCancelChapterPreparation?() }
            drag.finish(commit: false) { [weak self, weak session] in
                guard let self, let session, self.pageDragSession === session else { return }
                self.cancelPageDrag(cancelPreparation: false)
            }
        }

        func cancelPageDrag(cancelPreparation: Bool = true) {
            guard let session = pageDragSession else { return }
            pageDragSession = nil
            session.task?.cancel()
            session.task = nil
            viewport?.cancelPageDrag()
            isTurningPage = false
            if cancelPreparation, session.offset == nil { parent.onCancelChapterPreparation?() }
            reportPageDrag()
        }

        private func reportPageDrag() {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics"), let viewport {
                viewport.accessibilityValue = viewport.pageDrag.map { "dragProgress=\($0.progress) direction=\($0.direction)" } ?? "dragProgress=0"
            }
            #endif
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !isTurningPage, let view = textView else { return }
            if isAutoReading { resetAutoReadForPageChange() }
            guard let target = adjacentPageOffset(in: view, direction: direction) else {
                if direction < 0 { parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view)) }
                else { parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view)) }
                return
            }
            parent.onWillTurnPage?()
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

        func animateChapter(in viewport: ReaderViewport, previous: UIView, transition: ReaderChapterTransition, mode: Int) {
            isTurningPage = true
            #if DEBUG
            lastChapterSnapshotPage = pageMetrics(for: viewport.textView)
            #endif
            let animated = viewport.animateChapter(from: previous, direction: transition.direction, mode: mode) { [weak self, weak viewport] in
                guard let self else { return }
                self.isTurningPage = false
                if let view = viewport?.textView { self.reportPage(in: view) }
            }
            if animated {
                chapterTransitionCount += 1
                lastChapterDirection = transition.direction
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
            guard let target = adjacentPageOffset(in: view, direction: 1) else { return false }
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            updatePageMask(in: view)
            view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in
                if let height = (view as? ReaderLayoutTextView)?.pageClipHeight {
                    context.cgContext.clip(to: CGRect(origin: view.bounds.origin,
                        size: CGSize(width: view.bounds.width, height: height)))
                }
                view.layer.render(in: context.cgContext)
            }
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
            guard let target = adjacentPageOffset(in: view, direction: 1) else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, !isTurningPage, let view = textView else {
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
