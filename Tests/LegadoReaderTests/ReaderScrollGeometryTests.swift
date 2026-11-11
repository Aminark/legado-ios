import ImageIO
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
            let mask = try XCTUnwrap((view.layer.mask as? CAShapeLayer)?.path?.boundingBoxOfPath)
            XCTAssertEqual(mask.minY - view.contentOffset.y, 16, accuracy: 0.5)
            XCTAssertLessThanOrEqual(mask.maxY - view.contentOffset.y, view.bounds.height - 16 + 0.5)
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

    private func configuration(fontSize: Double = 20) -> ReaderTextView {
        .init(text: "", title: "", previousTitle: nil, previousText: "", isPreviousReady: false,
              continuationTitle: nil, continuationText: "", isContinuationReady: false, isVolume: false,
              fontSize: fontSize, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
              paragraphIndent: "　　", paddingLeft: 20, paddingRight: 20, paddingTop: 16, paddingBottom: 16,
              headerInset: 0, footerInset: 0, fontWeight: 0, titleMode: 0, titleSize: 4,
              titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0, isSelectable: false,
              fullJustify: true, pageAnimation: 3, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
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
