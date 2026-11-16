import ImageIO
import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import Legado

@MainActor
final class ReaderPagingGeometryTests: XCTestCase {
    func testPagesContainWholeLinesAndCoverTheDocumentWithoutGaps() throws {
        for size in [CGSize(width: 430, height: 750), CGSize(width: 844, height: 280)] {
            for fontSize in [28.0, 40.0] {
                let view = UITextView(frame: CGRect(origin: .zero, size: size))
                view.textContainerInset = UIEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 8
                paragraph.paragraphSpacing = 12
                let text = String(repeating: "完整的文字行不能被页脚遮挡，翻页后也不能只剩半行。English words 与表情🙂。\n", count: 40)
                view.attributedText = NSAttributedString(string: text, attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph
                ])
                view.layoutIfNeeded()
                let height = size.height - 32
                let pages = ReaderTextPage.layout(in: view, height: height)
                XCTAssertGreaterThan(pages.count, 1)
                var end = 0
                for page in pages {
                    XCTAssertEqual(page.characterRange.location, end)
                    XCTAssertLessThanOrEqual(page.height, height + 0.01)
                    let glyphs = view.layoutManager.glyphRange(forCharacterRange: page.characterRange, actualCharacterRange: nil)
                    view.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
                        XCTAssertGreaterThanOrEqual(rect.minY, page.offset - 0.01)
                        XCTAssertLessThanOrEqual(rect.maxY, page.offset + page.height + 0.01)
                        XCTAssertEqual(NSIntersectionRange(glyphs, lineGlyphs), lineGlyphs)
                    }
                    end = NSMaxRange(page.characterRange)
                }
                XCTAssertEqual(end, text.utf16.count)
            }
        }
    }

    func testTurningPagesKeepsMarginsAndReadingRangesInSync() async throws {
        let text = String(repeating: "完整的文字行不能被页脚遮挡，翻页后也不能只剩半行。English words 与表情🙂。\n", count: 35)
        var ranges: [NSRange] = []
        var currentPage = 1
        var totalPages = 1
        let reader = ReaderTextView(
            text: text, title: "第一章 分页边界", previousTitle: nil, previousText: "", isPreviousReady: false,
            continuationTitle: nil, continuationText: "", isContinuationReady: false, isVolume: false,
            fontSize: 32, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
            paragraphIndent: "　　", paddingLeft: 18, paddingRight: 18, paddingTop: 16, paddingBottom: 16,
            headerInset: 0, footerInset: 0, fontWeight: 0, titleMode: 0, titleSize: 4,
            titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0, isSelectable: false,
            fullJustify: true, pageAnimation: 4, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
            backgroundColor: .white, foregroundColor: .black, requestedPosition: 0, jumpPosition: nil,
            renderRevision: 0, readerPosition: .constant(0), pageRanges: Binding(get: { ranges }, set: { ranges = $0 }),
            currentPage: Binding(get: { currentPage }, set: { currentPage = $0 }),
            totalPages: Binding(get: { totalPages }, set: { totalPages = $0 }), isAutoReading: false,
            isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
            onReachedEnd: { _ in }, onReachedStart: { _ in }, onEnteredPrevious: { _ in },
            onEnteredContinuation: { _ in }, onDeferredRender: {}, onCancelNextLoading: {},
            onPageChanged: {}, onTapAction: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 850))
        let host = UIHostingController(rootView: reader)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        func findTextView(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(findTextView).first
        }
        let view = try XCTUnwrap(findTextView(host.view))
        let coordinator = try XCTUnwrap(view.delegate as? ReaderTextView.Coordinator)
        defer { coordinator.invalidate() }
        let pages = ReaderTextPage.layout(in: view, height: view.bounds.height - 32)
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(totalPages, pages.count)
        XCTAssertEqual(ranges.first?.location, 0)
        XCTAssertEqual(ranges.last.map(NSMaxRange), text.utf16.count)
        for index in pages.indices {
            coordinator.updateInteractionMode(on: view, isScrollMode: false)
            coordinator.updateLoadingFooter(in: view, visible: false)
            coordinator.reportPage(in: view)
            XCTAssertFalse(view.isPagingEnabled)
            XCTAssertLessThanOrEqual(pages.last!.offset, view.contentSize.height - view.bounds.height + view.contentInset.bottom + 0.5)
            XCTAssertEqual(view.contentOffset.y, pages[index].offset, accuracy: 0.5)
            XCTAssertEqual(currentPage, index + 1)
            let clip = try XCTUnwrap(view.superview)
            XCTAssertTrue(clip.clipsToBounds)
            XCTAssertLessThanOrEqual(clip.frame.maxY, view.bounds.height - 16 + 0.5)
            let glyphs = view.layoutManager.glyphRange(forCharacterRange: pages[index].characterRange, actualCharacterRange: nil)
            view.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, lineGlyphs, _ in
                XCTAssertEqual(NSIntersectionRange(glyphs, lineGlyphs), lineGlyphs)
                XCTAssertGreaterThanOrEqual(rect.minY + view.textContainerInset.top - view.contentOffset.y, 16 - 0.5)
                XCTAssertLessThanOrEqual(used.maxY + view.textContainerInset.top - view.contentOffset.y, clip.bounds.height + 0.5)
            }
            if index + 1 < pages.count {
                XCTAssertEqual(NSMaxRange(ranges[index]), ranges[index + 1].location)
                coordinator.turnPage(1)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        coordinator.turnPage(-1)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(currentPage, pages.count - 1)
        XCTAssertEqual(view.contentOffset.y, pages[pages.count - 2].offset, accuracy: 0.5)
    }
}

private final class ReaderPanFixture: UIPanGestureRecognizer {
    var fixtureState: UIGestureRecognizer.State = .began
    var fixtureTranslation = CGPoint.zero
    var fixtureVelocity = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { fixtureState } set { fixtureState = newValue } }
    override func translation(in view: UIView?) -> CGPoint { fixtureTranslation }
    override func velocity(in view: UIView?) -> CGPoint { fixtureVelocity }
}

private final class BackgroundPhotoProvider: NSItemProvider, @unchecked Sendable {
    let photoData: Data?
    let photoError: (any Error)?

    init(data: Data?, error: (any Error)? = nil) {
        photoData = data
        photoError = error
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var registeredTypeIdentifiers: [String] { ["public.png"] }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Progress {
        DispatchQueue.global(qos: .userInitiated).async { [photoData, photoError] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            completionHandler(photoData, photoError)
        }
        return Progress(totalUnitCount: 1)
    }
}

@MainActor
final class ReadingPhotoPickerTests: XCTestCase {
    func testPhotoDataReturnedOnBackgroundQueueReachesMainActor() async throws {
        let expected = Data("photo-provider-data".utf8)
        let provider = BackgroundPhotoProvider(data: expected)
        let received = expectation(description: "Photo data delivered on main actor")
        let coordinator = ReadingPhotoPickerController.Coordinator { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result?.get(), expected)
            received.fulfill()
        }

        coordinator.loadImage(from: provider)
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(coordinator) {}
    }

    func testPhotoProviderFailureOnBackgroundQueueReachesMainActor() async throws {
        let errors: [(any Error)?] = [CocoaError(.fileReadNoPermission), nil]
        for error in errors {
            let provider = BackgroundPhotoProvider(data: nil, error: error)
            let received = expectation(description: "Photo error delivered on main actor")
            let coordinator = ReadingPhotoPickerController.Coordinator { result in
                XCTAssertTrue(Thread.isMainThread)
                guard case .failure(let failure)? = result else {
                    XCTFail("Expected an import error")
                    received.fulfill()
                    return
                }
                XCTAssertEqual((failure as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((failure as NSError).code, (error as NSError?)?.code ?? NSFileReadCorruptFileError)
                received.fulfill()
            }

            coordinator.loadImage(from: provider)
            await fulfillment(of: [received], timeout: 5)
            withExtendedLifetime(coordinator) {}
        }
    }
}

@MainActor
final class ReaderBackgroundStoreTests: XCTestCase {
    func testLargeBackgroundIsDownsampledOnImportAndLegacyReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
        }

        for _ in 0..<3 {
            let imported = try ReaderBackgroundStore.save(data, to: target)
            XCTAssertEqual(imported.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
            XCTAssertEqual(imported.size.height / imported.size.width, 0.75, accuracy: 0.001)
            let restored = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
            XCTAssertEqual(restored.size, imported.size)
        }
        try data.write(to: target)
        let legacy = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
        XCTAssertEqual(legacy.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
    }

    func testCorruptReplacementPreservesExistingBackground() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        _ = try ReaderBackgroundStore.save(try XCTUnwrap(image.pngData()), to: target)
        let saved = try Data(contentsOf: target)

        XCTAssertThrowsError(try ReaderBackgroundStore.save(Data("not an image".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), saved)
        XCTAssertNotNil(ReaderBackgroundStore.load(from: target))
    }

    func testBackgroundPreservesPhotoOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let saved = try ReaderBackgroundStore.save(data as Data, to: directory.appendingPathComponent("background.jpg"))
        XCTAssertEqual(saved.imageOrientation, .up)
        XCTAssertEqual(saved.size.height / saved.size.width, 2, accuracy: 0.001)
    }
}

@MainActor
final class ReaderBookmarkPersistenceTests: XCTestCase {
    func testBookmarkSurvivesNewActivityAndReaderInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileReadingActivityRepository(
            bookmarksURL: directory.appendingPathComponent("bookmarks.json"),
            recordsURL: directory.appendingPathComponent("records.json")
        )
        let book = Book(bookUrl: "demo://saved-bookmark", name: "书", author: "作者")
        let chapters = [BookChapter(url: "demo://chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)]
        let original = ReadingActivityModel(repository: repository, deviceID: "test")
        await original.load()
        await original.addBookmark(book: book, chapter: chapters[0], position: 40, content: String(repeating: "正文", count: 100))
        XCTAssertNil(original.errorMessage)

        let restored = ReadingActivityModel(repository: repository, deviceID: "test")
        await restored.load()
        let reader = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "正文")
        XCTAssertEqual(reader.bookmarks(at: 40, in: restored.bookmarks).count, 1)
        XCTAssertTrue(reader.bookmarks(at: 80, in: restored.bookmarks).isEmpty)
        await restored.removeBookmark(try XCTUnwrap(restored.bookmarks.first))
        XCTAssertTrue(reader.bookmarks(at: 40, in: restored.bookmarks).isEmpty)
    }
}

@MainActor
final class ReaderScrollGeometryTests: XCTestCase {
    func testDefaultChineseGlyphsUseTheRequestedFontSize() throws {
        let config = configuration(fontSize: 20)
        let text = NSAttributedString(string: "天地玄黄", attributes: ReaderTypography(configuration: config).bodyAttributes)
        let line = CTLineCreateWithAttributedString(text)
        XCTAssertEqual(CTLineGetTypographicBounds(line, nil, nil, nil), 4 * config.fontSize, accuracy: 0.1,
                       "Chinese glyphs should retain the requested em size instead of shrinking through font fallback")
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 2 * config.fontSize, accuracy: 0.1,
                       "The two-character indent should match the actual Chinese glyph size")
    }

    func testPagedRangesCoverAllTextWithoutSplittingCharactersOrCuttingLines() throws {
        for size in [15.0, 20.0, 28.0, 50.0] {
            let config = configuration(fontSize: size, pageAnimation: 4)
            let view: UITextView
            if #available(iOS 16.0, *) { view = UITextView(usingTextLayoutManager: false) }
            else { view = UITextView(frame: .zero) }
            view.frame = CGRect(x: 0, y: 0, width: 402, height: 713)
            view.textContainerInset = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            view.attributedText = NSAttributedString(string: config.text, attributes: ReaderTypography(configuration: config).bodyAttributes)
            view.layoutIfNeeded()

            let pages = ReaderPageLayout.pages(in: view)
            XCTAssertGreaterThan(pages.count, 1)
            var end = 0
            let text = config.text as NSString
            for page in pages {
                XCTAssertEqual(page.renderedRange.location, end, "No text may be skipped or repeated between pages")
                XCTAssertEqual(text.rangeOfComposedCharacterSequence(at: page.renderedRange.location).location,
                               page.renderedRange.location, "A page cannot start inside an emoji or composed character")
                XCTAssertLessThanOrEqual(page.visibleHeight, view.bounds.height - view.textContainerInset.bottom + 0.5)
                end = NSMaxRange(page.renderedRange)
            }
            XCTAssertEqual(end, text.length)
        }
    }

    func testPagedViewportRendersTextAndClipsBelowItsActualLastLine() async throws {
        let controller = UIHostingController(rootView: configuration(fontSize: 20, pageAnimation: 4))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        window.rootViewController = controller
        window.backgroundColor = .white
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        func viewport(in view: UIView) -> ReaderViewport? {
            if let value = view as? ReaderViewport { return value }
            return view.subviews.lazy.compactMap { viewport(in: $0) }.first
        }
        let view = try XCTUnwrap(viewport(in: controller.view))
        let text = view.textView
        let clipHeight = try XCTUnwrap(text.superview?.bounds.height)
        let page = try XCTUnwrap(ReaderPageLayout.pages(in: text).first)
        XCTAssertEqual(clipHeight, page.visibleHeight, accuracy: 0.5)
        XCTAssertLessThan(clipHeight, view.bounds.height)

        let image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            UIColor.white.setFill()
            context.fill(view.bounds)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.cgImage)
        func ink(in rect: CGRect) throws -> Int {
            let crop = try XCTUnwrap(image.cropping(to: rect))
            var pixels = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
            return try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                    width: crop.width, height: crop.height, bitsPerComponent: 8,
                    bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                return stride(from: 0, to: buffer.count, by: 4).filter {
                    buffer[$0] < 100 && buffer[$0 + 1] < 100 && buffer[$0 + 2] < 100
                }.count
            }
        }
        XCTAssertGreaterThan(try ink(in: CGRect(x: 0, y: 0, width: image.width, height: image.height / 3)), 200)
        let firstUnusedRow = Int(ceil(clipHeight * CGFloat(image.height) / view.bounds.height)) + 1
        XCTAssertEqual(try ink(in: CGRect(x: 0, y: firstUnusedRow, width: image.width,
                                        height: image.height - firstUnusedRow)), 0,
                       "The next page must not leak below the actual last complete line")
    }

    func testPagedTurnsStartAtACompleteLineAndReturnToTheSamePosition() async throws {
        let config = configuration(fontSize: 20, pageAnimation: 4)
        let coordinator = ReaderTextView.Coordinator(parent: config)
        let view: UITextView
        if #available(iOS 16.0, *) { view = UITextView(usingTextLayoutManager: false) }
        else { view = UITextView(frame: .zero) }
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 713)
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        view.textContainer.lineFragmentPadding = 4
        view.attributedText = NSAttributedString(string: config.text, attributes: ReaderTypography(configuration: config).bodyAttributes)
        view.delegate = coordinator
        coordinator.installDisplayLink(for: view)
        let window = UIWindow(frame: view.frame)
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        defer { coordinator.invalidate(); window.isHidden = true }

        let next = UISwipeGestureRecognizer()
        next.direction = .left
        let previous = UISwipeGestureRecognizer()
        previous.direction = .right
        var offsets: [CGFloat] = [view.contentOffset.y]
        let pages = ReaderPageLayout.pages(in: view)
        for page in pages.dropFirst() {
            coordinator.perform(NSSelectorFromString("swiped:"), with: next)
            coordinator.updateLoadingFooter(in: view, visible: false)
            view.layoutIfNeeded()
            offsets.append(view.contentOffset.y)
            XCTAssertEqual(view.contentOffset.y, page.offset, accuracy: 0.5)
            // A used rect includes line spacing, so the preceding line's blank
            // tail may overlap the top inset. Inspect this page's first glyph.
            let glyph = view.layoutManager.glyphIndexForCharacter(at: page.renderedRange.location)
            let first = view.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertGreaterThanOrEqual(first.minY + view.textContainerInset.top - view.contentOffset.y,
                                        view.textContainerInset.top - 0.5, "A new page must show the whole first line")
        }
        for expected in offsets.dropLast().reversed() {
            coordinator.perform(NSSelectorFromString("swiped:"), with: previous)
            XCTAssertEqual(view.contentOffset.y, expected, accuracy: 0.5)
        }
    }

    func testPrependingAndRecyclingStayWithinOnePhysicalPixel() async throws {
        let chapters = (4...6).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 5)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(coordinator.blocks.firstIndex { $0.chapter.chapter.id == 5 })
        let id = coordinator.blocks[row].id
        view.setContentOffset(CGPoint(x: 0, y: layout.frames[row].minY + 71.25), animated: false)
        let screenY = layout.frames[row].minY - view.contentOffset.y
        let chapterLayout = coordinator.blocks[row].chapter

        coordinator.parent = surface(chapters: [chapter(2), chapter(3)] + chapters, active: 5)
        coordinator.update(view)
        let insertedRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[insertedRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[insertedRow].chapter === chapterLayout)

        coordinator.parent = surface(chapters: [chapter(5), chapter(6), chapter(7)], active: 5)
        coordinator.update(view)
        let recycledRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[recycledRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[recycledRow].chapter === chapterLayout)
    }

    func testAppendingAndNaturalChapterChangesDoNotRebuildVisibleText() async throws {
        let chapters = (0...2).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let original = try XCTUnwrap(coordinator.blocks.first?.chapter)
        view.setContentOffset(CGPoint(x: 0, y: 123.75), animated: false)
        let offset = view.contentOffset
        coordinator.parent = surface(chapters: chapters + [chapter(3), chapter(4)], active: 1)
        coordinator.update(view)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.01)
        XCTAssertTrue(coordinator.blocks[0].chapter === original)
        XCTAssertEqual(Set(coordinator.blocks.map { $0.chapter.chapter.id }), Set(0...4))
    }

    func testPreloadingShortChaptersPreservesTheInitialChapterHeading() async throws {
        for content in [DemoContent.readerText, "短章正文，继续向下可以自然读到下一章。"] {
            try await checkInitialHeadingDuringPreload(content: content)
        }
    }

    private func checkInitialHeadingDuringPreload(content: String) async throws {
        func shortChapter(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "第\(index + 1)章 · 连续阅读", content: content)
        }
        let fixture = host(chapters: [shortChapter(20)], active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let initialScreenY = try XCTUnwrap(layout.frames.first).minY - view.contentOffset.y
        for step in 1...14 {
            let indices = (20 - step)...(20 + step)
            coordinator.parent = surface(chapters: indices.map(shortChapter), active: 20)
            coordinator.update(view)
            view.layoutIfNeeded()
            let row = try XCTUnwrap(coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
            XCTAssertEqual(layout.frames[row].minY - view.contentOffset.y, initialScreenY,
                           accuracy: 1 / fixture.window.screen.scale)
            // UIKit snaps offsets to physical pixels, while TextKit chapter heights are fractional.
            let scale = fixture.window.screen.scale
            if step == 1 {
                let snapped = (layout.frames[row].minY * scale).rounded(.down) / scale
                view.setContentOffset(CGPoint(x: 0, y: snapped), animated: false)
            }
            coordinator.update(view)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertTrue(view.accessibilityValue?.hasPrefix("chapter=20 ") == true,
                          "Pixel rounding must not report the end of the previous chapter: \(view.accessibilityValue ?? "nil")")
        }
    }

    func testReflowKeepsTheSameTextLineAtTheSameScreenPosition() async throws {
        let fixture = host(chapters: [chapter(0), chapter(1)], active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let old = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let glyph = old.manager.glyphIndexForCharacter(at: old.bodyStart + 200)
        let lineY = old.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        let startOfLine = old.manager.characterIndexForGlyph(at: old.manager.glyphIndex(
            for: CGPoint(x: 0, y: lineY + 0.5), in: old.container))
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let chapterY = layout.frames[0].minY
        view.setContentOffset(CGPoint(x: 0, y: chapterY + lineY + 3.25), animated: false)
        let previousScreenY = chapterY + lineY - view.contentOffset.y
        coordinator.parent = surface(chapters: [chapter(0), chapter(1)], active: 0, fontSize: 25)
        coordinator.update(view)
        let new = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let newGlyph = new.manager.glyphIndexForCharacter(at: startOfLine)
        let newLineY = new.manager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
        XCTAssertEqual(layout.frames[0].minY + newLineY - view.contentOffset.y, previousScreenY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testChunksCoverAllGlyphsAndDoNotRetainTheirChapter() async {
        weak var released: ReaderScrollChapterLayout?
        autoreleasepool {
            let layout = ReaderScrollChapterLayout(chapter: chapter(0), configuration: configuration(), width: 390)
            released = layout
            XCTAssertGreaterThan(layout.blocks.count, 2)
            var nextGlyph = 0
            for block in layout.blocks {
                XCTAssertEqual(block.glyphRange.location, nextGlyph)
                XCTAssertGreaterThan(block.height, 0)
                nextGlyph = NSMaxRange(block.glyphRange)
            }
            XCTAssertEqual(nextGlyph, layout.manager.numberOfGlyphs)
            XCTAssertTrue(layout.storage.string.contains("👨‍👩‍👧‍👦"))
        }
        XCTAssertNil(released, "Recycled TextKit chapter layouts must be released")
    }

    func testShortLastChapterCanReachTheTopWithoutChangingTheRequestedChapter() async throws {
        let short = ReaderScrollChapter(id: 8, title: "短章", content: "仅一行正文")
        let fixture = host(chapters: [chapter(7), short], active: 8)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 8 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testRepeatedShortChapterPrependingDoesNotAccumulateOffsetDrift() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "第\(index + 1)章 · 连续阅读", content: "短章正文，继续向下可以自然读到下一章。")
        }
        let fixture = host(chapters: (20...22).map(short), active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        for first in stride(from: 19, through: 0, by: -1) {
            fixture.coordinator.parent = surface(chapters: (first...22).map(short), active: 20)
            fixture.coordinator.update(fixture.view)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    func testFractionalPixelBoundariesBelongToTheFollowingRow() {
        let layout = ReaderContinuousLayout()
        let frames = (0..<100).map { CGRect(x: 0, y: CGFloat($0 * 5) / 3, width: 390, height: 5.0 / 3) }
        layout.install(frames: frames, size: CGSize(width: 390, height: 500.0 / 3), correction: 0)
        for index in frames.indices {
            XCTAssertEqual(layout.row(at: frames[index].minY), index)
        }
    }

    func testPrependingPreservesTheChapterBelowTopPadding() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "短章\(index)", content: "短章正文")
        }
        let fixture = host(chapters: [short(20)], active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        // A short initial chapter can settle at offset zero with its heading
        // still below the reading area's top padding.
        fixture.view.setContentOffset(.zero, animated: false)
        fixture.coordinator.parent = surface(chapters: (19...21).map(short), active: 20)
        fixture.coordinator.update(fixture.view)
        try await Task.sleep(nanoseconds: 10_000_000)
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(layout.frames[row].minY - fixture.view.contentOffset.y, 16,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    private func chapter(_ index: Int) -> ReaderScrollChapter {
        .init(id: index, title: "第\(index)章", content: String(repeating: "正文包含中文、英文 words 与家庭表情👨‍👩‍👧‍👦，用于验证连续阅读的排版和位置。\n", count: 100))
    }

    private func host(chapters: [ReaderScrollChapter], active: Int) -> (window: UIWindow, view: ReaderScrollCollectionView, coordinator: ReaderScrollView.Coordinator) {
        let parent = surface(chapters: chapters, active: active)
        let coordinator = parent.makeCoordinator()
        let view = coordinator.makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        controller.view.addSubview(view)
        view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        coordinator.update(view)
        view.layoutIfNeeded()
        return (window, view, coordinator)
    }

    private func surface(chapters: [ReaderScrollChapter], active: Int, fontSize: Double = 20) -> ReaderScrollView {
        .init(configuration: configuration(fontSize: fontSize), chapters: chapters,
              resetID: 0, activeIndex: active, loadingAhead: false, loadingBehind: false,
              onNeedChapters: { _ in }, onPositionChanged: { _, _ in },
              onRetainChapters: { _ in })
    }

    func testHorizontalPageTurnAcceptsFortyFiveDegreeSwipes() {
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: -80, y: 0)), 1)
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: 80, y: 0)), -1)
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: -80, y: -80)), 1)
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: -80, y: 80)), 1)
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: 80, y: 80)), -1)
        XCTAssertEqual(ReaderPageTurnGesture.direction(for: CGPoint(x: 80, y: -80)), -1)
        XCTAssertNil(ReaderPageTurnGesture.direction(for: CGPoint(x: -80, y: -81)))
        XCTAssertNil(ReaderPageTurnGesture.direction(for: CGPoint(x: 0, y: -80)))
        XCTAssertNil(ReaderPageTurnGesture.direction(for: CGPoint(x: -20, y: 0)))
        XCTAssertEqual(ReaderPageTurnGesture.progress(translation: -100, direction: 1, width: 400), 0.25)
        XCTAssertEqual(ReaderPageTurnGesture.progress(translation: 100, direction: -1, width: 400), 0.25)
        XCTAssertEqual(ReaderPageTurnGesture.progress(translation: 50, direction: 1, width: 400), 0)
        XCTAssertFalse(ReaderPageTurnGesture.shouldFinish(translation: -80, velocity: 0, direction: 1, width: 400))
        XCTAssertTrue(ReaderPageTurnGesture.shouldFinish(translation: -80, velocity: -700, direction: 1, width: 400))
        XCTAssertFalse(ReaderPageTurnGesture.shouldFinish(translation: -180, velocity: 800, direction: 1, width: 400))
    }

    func testPageDragTracksTheFingerAndPartialReleaseKeepsTheReadingPosition() async throws {
        for mode in [0, 1, 2] {
            let fixture = hostPaged(mode: mode)
            defer { fixture.coordinator.invalidate(); fixture.window.isHidden = true }
            let pan = ReaderPanFixture()
            fixture.viewport.addGestureRecognizer(pan)
            fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
            let offset = fixture.viewport.textView.contentOffset
            for distance: CGFloat in [40, 100, 60] {
                pan.fixtureState = .changed
                pan.fixtureTranslation = CGPoint(x: -distance, y: 0)
                fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
                let drag = try XCTUnwrap(fixture.viewport.pageDrag)
                XCTAssertEqual(drag.progress, distance / fixture.viewport.bounds.width, accuracy: 0.001)
                if mode != 2 { XCTAssertEqual(drag.previous.transform.tx, -distance, accuracy: 0.5) }
                XCTAssertEqual(fixture.viewport.textView.contentOffset, offset, "A held gesture must not change the document's position")
                XCTAssertFalse(fixture.viewport.textView.superview?.isHidden ?? true,
                               "The snapshot overlay must not hide the live document from accessibility")
                if distance == 100 {
                    let image = try XCTUnwrap((drag.next as? UIImageView)?.image?.cgImage)
                    let width = image.width, height = image.height / 4
                    var pixels = [UInt8](repeating: 255, count: width * height * 4)
                    let ink = pixels.withUnsafeMutableBytes { buffer -> Int in
                        guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                        guard let top = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else { return 0 }
                        bitmap.draw(top, in: CGRect(x: 0, y: 0, width: width, height: height))
                        return stride(from: 0, to: buffer.count, by: 4).filter {
                            buffer[$0] < 100 && buffer[$0 + 1] < 100 && buffer[$0 + 2] < 100
                        }.count
                    }
                    XCTAssertGreaterThan(ink, 200, "The destination snapshot must render the next page's text at its top, not an empty scrolled layer")
                }
            }
            pan.fixtureState = .ended
            fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertNil(fixture.viewport.pageDrag)
            XCTAssertEqual(fixture.viewport.textView.contentOffset, offset)
        }
    }

    func testPageDragCommitsOnlyOnReleaseAndCancellationKeepsTheCurrentPage() async throws {
        let fixture = hostPaged(mode: 1)
        defer { fixture.coordinator.invalidate(); fixture.window.isHidden = true }
        let view = fixture.viewport.textView
        let pages = ReaderPageLayout.pages(in: view)
        XCTAssertGreaterThan(pages.count, 1)
        let pan = ReaderPanFixture()
        fixture.viewport.addGestureRecognizer(pan)
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        pan.fixtureState = .changed
        pan.fixtureTranslation = CGPoint(x: -view.bounds.width * 0.65, y: 0)
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        XCTAssertEqual(view.contentOffset.y, pages[0].offset, accuracy: 0.5)
        pan.fixtureState = .ended
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(view.contentOffset.y, pages[1].offset, accuracy: 0.5)
        pan.fixtureState = .began
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        pan.fixtureState = .changed
        pan.fixtureTranslation = CGPoint(x: view.bounds.width * 0.65, y: 0)
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        pan.fixtureState = .cancelled
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(fixture.viewport.pageDrag)
        XCTAssertEqual(view.contentOffset.y, pages[1].offset, accuracy: 0.5)
        pan.fixtureState = .began
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        pan.fixtureState = .changed
        pan.fixtureTranslation = CGPoint(x: -100, y: 0)
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        pan.fixtureTranslation = CGPoint(x: 100, y: 0)
        fixture.coordinator.perform(NSSelectorFromString("panned:"), with: pan)
        XCTAssertEqual(fixture.viewport.pageDrag?.direction, -1, "Crossing back over the starting point must reveal the other adjacent page")
        XCTAssertEqual(view.contentOffset.y, pages[1].offset, accuracy: 0.5)
        fixture.coordinator.cancelPageDrag()
    }

    private func hostPaged(mode: Int) -> (window: UIWindow, viewport: ReaderViewport, coordinator: ReaderTextView.Coordinator) {
        let config = configuration(fontSize: 20, pageAnimation: mode)
        let coordinator = ReaderTextView.Coordinator(parent: config)
        let textView: UITextView
        if #available(iOS 16.0, *) { textView = UITextView(usingTextLayoutManager: false) }
        else { textView = UITextView(frame: .zero) }
        let viewport = ReaderViewport(textView: textView)
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        textView.frame = viewport.bounds
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        textView.attributedText = NSAttributedString(string: config.text, attributes: ReaderTypography(configuration: config).bodyAttributes)
        textView.delegate = coordinator
        coordinator.installDisplayLink(for: textView)
        coordinator.installGestures(on: viewport)
        coordinator.updateInteractionMode(on: textView, isScrollMode: false)
        let window = UIWindow(frame: viewport.frame)
        window.backgroundColor = .white
        let controller = UIViewController()
        controller.view = viewport
        window.rootViewController = controller
        window.makeKeyAndVisible()
        viewport.layoutIfNeeded()
        return (window, viewport, coordinator)
    }

    func testPagedViewportKeepsPageTurnsOnBlankAreaBelowShortText() {
        let config = configuration(fontSize: 20, pageAnimation: 4)
        let coordinator = ReaderTextView.Coordinator(parent: config)
        let textView: UITextView
        if #available(iOS 16.0, *) { textView = UITextView(usingTextLayoutManager: false) }
        else { textView = UITextView(frame: .zero) }
        let viewport = ReaderViewport(textView: textView)
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        textView.frame = viewport.bounds
        coordinator.installGestures(on: viewport)
        coordinator.updateInteractionMode(on: textView, isScrollMode: false)
        viewport.layoutIfNeeded()

        let pans = viewport.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        XCTAssertEqual(pans.count, 1, "Page turns must live on the full viewport, not only the laid-out text")
        XCTAssertTrue(pans[0].isEnabled)
        XCTAssertFalse(textView.gestureRecognizers?.contains { $0 is UISwipeGestureRecognizer } ?? false)

        let blank = CGPoint(x: 200, y: 720)
        let hit = viewport.hitTest(blank, with: nil)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit === viewport || hit?.isDescendant(of: viewport) == true)

        coordinator.updateInteractionMode(on: textView, isScrollMode: true)
        XCTAssertFalse(pans[0].isEnabled)
        XCTAssertTrue(textView.panGestureRecognizer.isEnabled)
        let textHit = viewport.hitTest(CGPoint(x: 100, y: 100), with: nil)
        XCTAssertTrue(textHit === textView || textHit?.isDescendant(of: textView) == true,
                      "The viewport must preserve text-view touches so vertical scrolling still works")
    }

    private func configuration(fontSize: Double = 20, pageAnimation: Int = 3) -> ReaderTextView {
        .init(text: pageAnimation == 3 ? "" : String(repeating: "正文包含中文、英文 words 与家庭表情👨‍👩‍👧‍👦，用于验证分页时正文不会被截断。\n", count: 90), title: "", previousTitle: nil, previousText: "", isPreviousReady: false,
              continuationTitle: nil, continuationText: "", isContinuationReady: false, isVolume: false,
              fontSize: fontSize, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
              paragraphIndent: "　　", paddingLeft: 20, paddingRight: 20, paddingTop: 16, paddingBottom: 16,
              headerInset: 0, footerInset: 0, fontWeight: 0, titleMode: 0, titleSize: 4,
              titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0, isSelectable: false,
              fullJustify: true, pageAnimation: pageAnimation, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
              backgroundColor: .white, foregroundColor: .black, requestedPosition: 0, jumpPosition: nil,
              renderRevision: 0, readerPosition: .constant(0), pageRanges: .constant([]),
              currentPage: .constant(1), totalPages: .constant(1), isAutoReading: false,
              isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
              onReachedEnd: { _ in }, onReachedStart: { _ in }, onEnteredPrevious: { _ in },
              onEnteredContinuation: { _ in }, onDeferredRender: {}, onCancelNextLoading: {},
              onPageChanged: {}, onTapAction: { _ in })
    }
}

@MainActor
final class ReaderComicGeometryTests: XCTestCase {
    func testRestoresImageOffsetAndKeepsAspectRatioAfterWidthChange() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 240)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
        }.pngData()!
        let address = "data:image/png;base64," + data.base64EncodedString()
        let content = Array(repeating: "<img src=\"\(address)\">", count: 4).joined(separator: "\n")
        let blocks = ChapterImageParser().blocks(in: content, baseURL: nil)
        let requested = blocks[1].range.location + blocks[1].range.length / 2
        var lastPosition = 0
        var lastPage = 0
        let book = Book(bookUrl: "comic", name: "漫画", origin: "https://comic.invalid")
        let chapter = BookChapter(url: "https://comic.invalid/chapter", title: "第一话", bookUrl: book.bookUrl, index: 0)
        let reader = ReaderComicView(blocks: blocks,
            source: BookSource(bookSourceUrl: book.origin, bookSourceName: "测试源"), book: book, chapter: chapter,
            background: .white, foreground: .black, fontSize: 20, requestedPosition: requested, jumpPosition: nil,
            onPosition: { position, page, count in lastPosition = position; lastPage = page; XCTAssertEqual(count, 4) }, onTap: {})
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let host = UIHostingController(rootView: reader)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        func table(in view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            return view.subviews.compactMap { table(in: $0) }.first
        }
        let view = try XCTUnwrap(table(in: host.view))
        for _ in 0..<60 {
            if abs(view.rectForRow(at: IndexPath(row: 1, section: 0)).height - view.bounds.width * 2) < 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(view.rectForRow(at: IndexPath(row: 1, section: 0)).height, view.bounds.width * 2, accuracy: 1)
        XCTAssertEqual(lastPage, 2)
        XCTAssertEqual(lastPosition, requested, accuracy: 2)
        host.view.frame.size.width = 600
        host.view.layoutIfNeeded()
        for _ in 0..<30 {
            if abs(view.rectForRow(at: IndexPath(row: 1, section: 0)).height - view.bounds.width * 2) < 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(view.rectForRow(at: IndexPath(row: 1, section: 0)).height, view.bounds.width * 2, accuracy: 1)
        XCTAssertEqual(lastPosition, requested, accuracy: 2)
        view.delegate?.scrollViewWillBeginDragging?(view)
        view.setContentOffset(CGPoint(x: 0, y: view.rectForRow(at: IndexPath(row: 2, section: 0)).minY + 40), animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lastPage, 3)
        XCTAssertGreaterThan(lastPosition, blocks[2].range.location)
    }
}
