import SwiftUI
import UIKit

struct ReaderScrollView: UIViewRepresentable {
    let configuration: ReaderTextView
    let chapters: [ReaderScrollChapter]
    let resetID: Int
    let activeIndex: Int
    let loadingAhead: Bool
    let loadingBehind: Bool
    let onNeedChapters: (Int) -> Void
    let onPositionChanged: (Int, Int) -> Void
    let onRetainChapters: (Set<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ReaderScrollCollectionView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: ReaderScrollCollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    static func dismantleUIView(_ view: ReaderScrollCollectionView, coordinator: Coordinator) {
        coordinator.displayLink?.invalidate()
        view.viewportChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UIGestureRecognizerDelegate {
        var parent: ReaderScrollView
        private(set) var blocks: [ReaderScrollBlock] = []
        private var chapterLayouts: [Int: ReaderScrollChapterLayout] = [:]
        private weak var view: ReaderScrollCollectionView?
        var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var styleKey = ""
        private var viewportHeight: CGFloat = 0
        private var revision: Int?
        private var restored = false
        private var jumpKey: String?
        private var reporting = false
        private var applying = false
        private var requestedAhead: Int?
        private var requestedBehind: Int?
        private var wasLoadingAhead = false
        private var wasLoadingBehind = false
        private var lastPageKey = ""
        private var reachedEnd = false
        #if DEBUG
        private var decelerationInsertions = 0
        private var continuedDecelerations = 0
        private var interruptedDecelerations = 0
        private var awaitingDecelerationOffset: CGFloat?
        #endif

        init(parent: ReaderScrollView) { self.parent = parent }

        func makeView() -> ReaderScrollCollectionView {
            let collection = ReaderScrollCollectionView(frame: .zero, collectionViewLayout: ReaderContinuousLayout())
            collection.backgroundColor = parent.configuration.backgroundColor
            collection.contentInsetAdjustmentBehavior = .never
            collection.alwaysBounceVertical = true
            collection.showsVerticalScrollIndicator = false
            collection.decelerationRate = .normal
            collection.dataSource = self
            collection.delegate = self
            collection.accessibilityIdentifier = "reader.continuous"
            collection.register(ReaderScrollCell.self, forCellWithReuseIdentifier: "text")
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delegate = self
            collection.addGestureRecognizer(tap)
            collection.viewportChanged = { [weak self, weak collection] in
                guard let self, let collection else { return }
                self.update(collection)
            }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            view = collection
            return collection
        }

        func update(_ view: ReaderScrollCollectionView) {
            guard !applying, view.bounds.width > 0, view.bounds.height > 0 else { return }
            applying = true
            defer { applying = false }
            let config = parent.configuration
            if wasLoadingAhead, !parent.loadingAhead { requestedAhead = nil }
            if wasLoadingBehind, !parent.loadingBehind { requestedBehind = nil }
            wasLoadingAhead = parent.loadingAhead
            wasLoadingBehind = parent.loadingBehind
            view.backgroundColor = config.backgroundColor
            view.loadingLabel.textColor = config.foregroundColor.withAlphaComponent(0.6)
            view.loadingLabel.text = parent.chapters.isEmpty ? "正在加载正文…"
                : (parent.loadingAhead || parent.loadingBehind ? "正在加载后续章节…" : nil)
            view.positionLoadingLabel()
            let reset = revision != parent.resetID
            if reset {
                revision = parent.resetID
                restored = false
                jumpKey = nil
                requestedAhead = nil
                requestedBehind = nil
                lastPageKey = ""
                chapterLayouts = [:]
            }
            let anchor = reset ? nil : captureAnchor()
            let newStyleKey = config.scrollTypographyKey + "|\(view.bounds.width)"
            let styleChanged = styleKey != newStyleKey
            let contentChanged = styleChanged || viewportHeight != view.bounds.height || parent.chapters.count != chapterLayouts.count
                || parent.chapters.contains { chapterLayouts[$0.id]?.chapter != $0 }
            if contentChanged || reset {
                let oldIDs = blocks.map(\.id)
                var layouts: [Int: ReaderScrollChapterLayout] = [:]
                for chapter in parent.chapters {
                    if !styleChanged, let cached = chapterLayouts[chapter.id], cached.chapter == chapter {
                        layouts[chapter.id] = cached
                    } else {
                        layouts[chapter.id] = ReaderScrollChapterLayout(
                            chapter: chapter, configuration: config, width: view.bounds.width
                        )
                    }
                }
                let newBlocks = parent.chapters.flatMap { layouts[$0.id]?.blocks ?? [] }
                let layout = view.collectionViewLayout as! ReaderContinuousLayout
                let geometry = ReaderContinuousLayout.geometry(
                    blocks: newBlocks, width: view.bounds.width,
                    top: CGFloat(config.paddingTop), bottom: CGFloat(config.paddingBottom),
                    viewportHeight: view.bounds.height, scale: view.traitCollection.displayScale
                )
                let targetY = anchor.flatMap { offset(for: $0, blocks: newBlocks, frames: geometry.frames) }
                let correction = targetY.map { $0 - view.contentOffset.y } ?? 0
                let newIDs = newBlocks.map(\.id)
                let oldSet = Set(oldIDs), newSet = Set(newIDs)
                let deletions = oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) }.map { IndexPath(item: $0, section: 0) }
                let insertions = newIDs.indices.filter { !oldSet.contains(newIDs[$0]) }.map { IndexPath(item: $0, section: 0) }
                if !deletions.isEmpty { requestedAhead = nil; requestedBehind = nil }
                chapterLayouts = layouts
                styleKey = newStyleKey
                viewportHeight = view.bounds.height
                #if DEBUG
                let wasDecelerating = view.isDecelerating
                #endif
                UIView.performWithoutAnimation {
                    view.performBatchUpdates {
                        self.blocks = newBlocks
                        view.deleteItems(at: deletions)
                        view.insertItems(at: insertions)
                        // UIKit applies the geometry and anchor compensation together.
                        // Setting contentOffset here would cancel an in-flight deceleration.
                        layout.install(frames: geometry.frames, size: geometry.size, correction: correction)
                    }
                    view.layoutIfNeeded()
                }
                #if DEBUG
                if wasDecelerating, !insertions.isEmpty {
                    decelerationInsertions += 1
                    if view.isDecelerating { awaitingDecelerationOffset = view.contentOffset.y }
                    else { interruptedDecelerations += 1 }
                }
                #endif
                for cell in view.visibleCells {
                    guard let cell = cell as? ReaderScrollCell,
                          let index = view.indexPath(for: cell)?.item, blocks.indices.contains(index) else { continue }
                    cell.canvas.block = blocks[index]
                }
                reachedEnd = false
            }
            if !restored, let chapter = chapterLayouts[parent.activeIndex] {
                restored = true
                seek(chapter: chapter.chapter.id, position: config.requestedPosition, includeHeading: config.requestedPosition == 0)
            }
            if let position = config.jumpPosition {
                let key = "\(parent.activeIndex):\(position)"
                if jumpKey != key {
                    jumpKey = key
                    seek(chapter: parent.activeIndex, position: position, includeHeading: position == 0)
                }
            } else { jumpKey = nil }
            scheduleReport()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { blocks.count }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "text", for: indexPath) as! ReaderScrollCell
            cell.canvas.block = blocks[indexPath.item]
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !applying else { return }
            #if DEBUG
            if let offset = awaitingDecelerationOffset, scrollView.isDecelerating,
               abs(scrollView.contentOffset.y - offset) > 0.5 {
                continuedDecelerations += 1
                awaitingDecelerationOffset = nil
            }
            #endif
            view?.positionLoadingLabel()
            scheduleReport()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { scheduleReport() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleReport() }

        private func scheduleReport() {
            guard !reporting else { return }
            reporting = true
            let scheduledRevision = parent.resetID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reporting = false
                guard self.parent.resetID == scheduledRevision else { self.scheduleReport(); return }
                self.reportViewport()
            }
        }

        private func reportViewport() {
            guard let view, restored, let anchor = captureAnchor(),
                  let chapter = chapterLayouts[anchor.chapter] else { return }
            parent.onPositionChanged(anchor.chapter, anchor.position)
            let config = parent.configuration
            let chapterRows = blocks.indices.filter { blocks[$0].chapter.chapter.id == anchor.chapter }
            let layout = view.collectionViewLayout as! ReaderContinuousLayout
            if let first = chapterRows.first, let last = chapterRows.last {
                let start = layout.frames[first].minY, end = layout.frames[last].maxY
                let height = max(view.bounds.height, 1)
                let total = max(Int(ceil((end - start) / height)), 1)
                let page = min(max(Int(floor((view.contentOffset.y - start) / height)) + 1, 1), total)
                if config.currentPage != page { config.currentPage = page }
                if config.totalPages != total { config.totalPages = total }
                let ranges = chapter.chapter.content.isEmpty ? [] : [NSRange(location: 0, length: chapter.chapter.content.utf16.count)]
                if config.pageRanges != ranges { config.pageRanges = ranges }
                let key = "\(anchor.chapter):\(page)"
                if lastPageKey != key { lastPageKey = key; config.onPageChanged() }
            }
            let runway = view.bounds.height * 3
            if let last = parent.chapters.last, layout.collectionViewContentSize.height - view.bounds.maxY < runway,
               requestedAhead != last.id {
                requestedAhead = last.id
                parent.onNeedChapters(1)
            }
            if let first = parent.chapters.first, view.contentOffset.y < runway, requestedBehind != first.id {
                requestedBehind = first.id
                parent.onNeedChapters(-1)
            }
            if !view.isDragging, !view.isDecelerating, parent.chapters.count > 12 {
                let retainedRect = view.bounds.insetBy(dx: 0, dy: -view.bounds.height * 6)
                let visible = blocks.indices.filter { layout.frames[$0].intersects(retainedRect) }
                let indices = Set(visible.map { blocks[$0].chapter.chapter.id })
                let ordered = parent.chapters.map(\.id)
                if let lo = ordered.firstIndex(where: { indices.contains($0) }),
                   let hi = ordered.lastIndex(where: { indices.contains($0) }) {
                    let keep = Set(ordered[max(lo - 2, 0)...min(hi + 2, ordered.count - 1)])
                    if keep.count < ordered.count { parent.onRetainChapters(keep) }
                }
            }
            #if DEBUG
            view.accessibilityValue = "chapter=\(anchor.chapter) position=\(anchor.position) chapters=\(parent.chapters.count) decelInsertions=\(decelerationInsertions) continued=\(continuedDecelerations) interrupted=\(interruptedDecelerations)"
            #endif
        }

        private struct Anchor {
            let chapter: Int
            let position: Int
            let inHeading: Bool
            let screenY: CGFloat
        }

        private func captureAnchor() -> Anchor? {
            guard let view, !blocks.isEmpty else { return nil }
            let layout = view.collectionViewLayout as! ReaderContinuousLayout
            // The reading position starts below the configured top padding.
            // Preserve that reference point when earlier chapters are inserted.
            let y = max(view.contentOffset.y + CGFloat(max(parent.configuration.paddingTop, 0)),
                        layout.frames.first?.minY ?? 0)
            let scale = max(view.traitCollection.displayScale, 1)
            guard let row = layout.row(at: (y * scale).rounded() / scale) else { return nil }
            let block = blocks[row], chapter = block.chapter
            let localY = max(y - layout.frames[row].minY, 0) + block.top
            let glyph = chapter.manager.glyphIndex(for: CGPoint(x: 0, y: localY + 0.5), in: chapter.container)
            let safeGlyph = min(glyph, max(chapter.manager.numberOfGlyphs - 1, 0))
            let character = chapter.manager.characterIndexForGlyph(at: safeGlyph)
            let lineY = chapter.manager.lineFragmentRect(forGlyphAt: safeGlyph, effectiveRange: nil).minY
            return Anchor(
                chapter: chapter.chapter.id,
                position: min(max(character - chapter.bodyStart, 0), chapter.chapter.content.utf16.count),
                inHeading: character < chapter.bodyStart,
                screenY: layout.frames[row].minY + lineY - block.top - view.contentOffset.y
            )
        }

        private func offset(for anchor: Anchor, blocks: [ReaderScrollBlock], frames: [CGRect]) -> CGFloat? {
            guard let chapter = blocks.first(where: { $0.chapter.chapter.id == anchor.chapter })?.chapter else { return nil }
            let character = anchor.inHeading ? 0 : ReaderPositionResolver.renderedLocation(
                position: anchor.position, prefixLength: chapter.bodyStart, renderedLength: chapter.storage.length
            )
            let glyph = chapter.manager.glyphIndexForCharacter(at: character)
            guard let row = blocks.firstIndex(where: {
                $0.chapter.chapter.id == anchor.chapter && NSLocationInRange(glyph, $0.glyphRange)
            }) else { return nil }
            let lineY = chapter.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            return frames[row].minY + lineY - blocks[row].top - anchor.screenY
        }

        private func seek(chapter: Int, position: Int, includeHeading: Bool) {
            guard let view else { return }
            let layout = view.collectionViewLayout as! ReaderContinuousLayout
            let anchor = Anchor(chapter: chapter, position: max(position, 0), inHeading: includeHeading, screenY: 0)
            guard let y = offset(for: anchor, blocks: blocks, frames: layout.frames) else { return }
            let maximum = max(layout.collectionViewContentSize.height - view.bounds.height, 0)
            view.setContentOffset(CGPoint(x: 0, y: min(max(y, 0), maximum)), animated: false)
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, !view.isDragging, !view.isDecelerating else { return }
            let point = gesture.location(in: view)
            if let row = (view.collectionViewLayout as? ReaderContinuousLayout)?.row(at: point.y),
               blocks[row].chapter.chapter.error != nil {
                parent.configuration.onTapAction(0)
                return
            }
            let x = point.x - view.bounds.minX, y = point.y - view.bounds.minY
            let column = min(max(Int(x / max(view.bounds.width / 3, 1)), 0), 2)
            let row = min(max(Int(y / max(view.bounds.height / 3, 1)), 0), 2)
            let index = row * 3 + column
            let actions = parent.configuration.clickActions
            let action = index == 4 ? 0 : (actions.indices.contains(index) ? actions[index] : 0)
            if action == 1 || action == 2 {
                parent.configuration.onTapAction(0)
            } else if action != -1 {
                parent.configuration.onTapAction(action)
            }
        }

        @objc private func step(_ link: CADisplayLink) {
            defer { lastTimestamp = link.timestamp }
            guard let view, lastTimestamp > 0, parent.configuration.isAutoReading,
                  !parent.configuration.isAutoReadPaused, !view.isDragging, !view.isDecelerating else { return }
            let elapsed = min(link.timestamp - lastTimestamp, 0.1)
            let maximum = max(view.contentSize.height - view.bounds.height, 0)
            let next = min(view.contentOffset.y + view.bounds.height / CGFloat(max(parent.configuration.secondsPerScreen, 1)) * elapsed, maximum)
            if next > view.contentOffset.y { view.setContentOffset(CGPoint(x: 0, y: next), animated: false) }
            if next >= maximum - 0.5, !reachedEnd {
                reachedEnd = true
                parent.configuration.onReachedEnd(parent.configuration.readerPosition)
            }
        }
    }
}

@MainActor
final class ReaderScrollCollectionView: UICollectionView {
    var viewportChanged: (() -> Void)?
    let loadingLabel = UILabel()
    private var viewportSize = CGSize.zero

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        loadingLabel.font = .systemFont(ofSize: 12)
        loadingLabel.textAlignment = .center
        loadingLabel.isUserInteractionEnabled = false
        addSubview(loadingLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionLoadingLabel()
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            viewportChanged?()
        }
    }

    func positionLoadingLabel() {
        loadingLabel.frame = CGRect(x: 0, y: bounds.maxY - 28, width: bounds.width, height: 24)
        bringSubviewToFront(loadingLabel)
    }
}

@MainActor
final class ReaderContinuousLayout: UICollectionViewLayout {
    private(set) var frames: [CGRect] = []
    private var size = CGSize.zero
    override var collectionViewContentSize: CGSize { size }

    static func geometry(blocks: [ReaderScrollBlock], width: CGFloat, top: CGFloat, bottom: CGFloat, viewportHeight: CGFloat, scale: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let scale = max(scale, 1)
        // Keep insertion offsets in whole physical pixels. UIKit rounds scroll
        // offsets, so fractional chapter heights otherwise accumulate drift.
        var pixels = (top * scale).rounded()
        let frames = blocks.map { block -> CGRect in
            let height = ceil(block.height * scale)
            let frame = CGRect(x: 0, y: pixels / scale, width: width, height: height / scale)
            pixels += height
            return frame
        }
        let finalChapter = blocks.last?.chapter.chapter.id
        let finalStart = blocks.indices.first(where: { blocks[$0].chapter.chapter.id == finalChapter })
            .map { frames[$0].minY } ?? top
        return (frames, CGSize(width: width, height: max(pixels / scale, finalStart + viewportHeight) + bottom))
    }

    func install(frames: [CGRect], size: CGSize, correction: CGFloat) {
        let context = UICollectionViewLayoutInvalidationContext()
        context.contentOffsetAdjustment = CGPoint(x: 0, y: correction)
        context.contentSizeAdjustment = CGSize(width: size.width - self.size.width, height: size.height - self.size.height)
        self.frames = frames
        self.size = size
        invalidateLayout(with: context)
    }

    func row(at y: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].minY <= y { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let start = row(at: rect.minY) else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        for row in start..<frames.count {
            if frames[row].minY > rect.maxY { break }
            if let attributes = layoutAttributesForItem(at: IndexPath(item: row, section: 0)) { result.append(attributes) }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }
}

@MainActor
struct ReaderScrollBlock {
    struct ID: Hashable { let chapter: Int; let firstGlyph: Int }
    let chapter: ReaderScrollChapterLayout
    let glyphRange: NSRange
    let top: CGFloat
    let height: CGFloat
    var id: ID { .init(chapter: chapter.chapter.id, firstGlyph: glyphRange.location) }
}

@MainActor
final class ReaderScrollChapterLayout {
    let chapter: ReaderScrollChapter
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    let bodyStart: Int
    let left: CGFloat
    private var fragments: [(range: NSRange, top: CGFloat, height: CGFloat)] = []
    var blocks: [ReaderScrollBlock] {
        fragments.map { .init(chapter: self, glyphRange: $0.range, top: $0.top, height: $0.height) }
    }

    init(chapter: ReaderScrollChapter, configuration: ReaderTextView, width: CGFloat) {
        self.chapter = chapter
        let typography = ReaderTypography(configuration: configuration)
        left = CGFloat(configuration.paddingLeft) + 4
        let textWidth = max(width - left - CGFloat(configuration.paddingRight) - 4, 1)
        container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let attributed = NSMutableAttributedString(string: "")
        if configuration.titleMode != 2, !chapter.title.isEmpty {
            attributed.append(NSAttributedString(string: chapter.title + "\n", attributes: typography.headingAttributes))
        }
        bodyStart = attributed.length
        let body = chapter.error.map { "本章加载失败\n\n\($0)\n\n轻点打开阅读菜单。\n" } ?? (chapter.content.isEmpty ? "本章暂无正文\n" : chapter.content)
        attributed.append(NSAttributedString(string: body, attributes: typography.bodyAttributes))
        storage = NSTextStorage(attributedString: attributed)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var startGlyph = 0
        var top: CGFloat = 0
        let count = manager.numberOfGlyphs
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: count)) { rect, _, _, range, _ in
            if rect.minY - top >= 1000, range.location > startGlyph {
                self.fragments.append((NSRange(location: startGlyph, length: range.location - startGlyph),
                                       top, rect.minY - top))
                startGlyph = range.location
                top = rect.minY
            }
        }
        let bottom = manager.usedRect(for: container).maxY + CGFloat(configuration.fontSize * 1.4)
        fragments.append((NSRange(location: startGlyph, length: count - startGlyph), top, max(bottom - top, 1)))
    }
}

@MainActor
private final class ReaderScrollCell: UICollectionViewCell {
    let canvas = ReaderScrollCanvas()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); canvas.frame = contentView.bounds }
    override func prepareForReuse() { super.prepareForReuse(); canvas.block = nil }
}

@MainActor
private final class ReaderScrollCanvas: UIView {
    var block: ReaderScrollBlock? {
        didSet {
            if let block {
                let range = block.chapter.manager.characterRange(forGlyphRange: block.glyphRange, actualGlyphRange: nil)
                accessibilityLabel = block.chapter.storage.attributedSubstring(from: range).string
            } else { accessibilityLabel = nil }
            setNeedsDisplay()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let block else { return }
        let origin = CGPoint(x: block.chapter.left, y: -block.top)
        block.chapter.manager.drawBackground(forGlyphRange: block.glyphRange, at: origin)
        block.chapter.manager.drawGlyphs(forGlyphRange: block.glyphRange, at: origin)
    }
}

@MainActor
struct ReaderTypography {
    let bodyAttributes: [NSAttributedString.Key: Any]
    let headingAttributes: [NSAttributedString.Key: Any]

    init(configuration c: ReaderTextView) {
        let font = ReaderFontStore.resolvedFont(at: c.fontPath, size: CGFloat(c.fontSize), weight: c.fontWeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(c.lineSpacing)
        paragraph.paragraphSpacing = CGFloat(c.paragraphSpacing)
        paragraph.firstLineHeadIndent = (c.paragraphIndent as NSString).size(withAttributes: [
            .font: font, .kern: CGFloat(c.letterSpacing * c.fontSize)
        ]).width
        paragraph.alignment = c.fullJustify ? .justified : .natural
        var body: [NSAttributedString.Key: Any] = [
            .font: font, .kern: CGFloat(c.letterSpacing * c.fontSize),
            .foregroundColor: c.foregroundColor, .paragraphStyle: paragraph
        ]
        if c.underlineMode != 0 {
            var underline = NSUnderlineStyle.single
            if c.underlineMode == 2 { underline.insert(.patternDash) }
            body[.underlineStyle] = underline.rawValue
            body[.underlineColor] = c.foregroundColor
        }
        bodyAttributes = body
        let headingFont = ReaderFontStore.resolvedFont(at: c.fontPath, size: CGFloat(max(5, c.fontSize + c.titleSize)), weight: 1)
        let heading = NSMutableParagraphStyle()
        heading.alignment = c.titleMode == 1 ? .center : .left
        heading.paragraphSpacingBefore = CGFloat(c.titleTopSpacing)
        heading.paragraphSpacing = CGFloat(c.titleBottomSpacing)
        headingAttributes = [.font: headingFont, .foregroundColor: c.foregroundColor, .paragraphStyle: heading]
    }
}

extension ReaderTextView {
    var scrollTypographyKey: String {
        "\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(fullJustify)|\(foregroundColor.hash)"
    }
}
