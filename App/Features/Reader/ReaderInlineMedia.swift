import ImageIO
import SwiftUI
@preconcurrency import WebKit

private struct ReaderMediaEntry {
    let body: String
    let inline: ChapterInlineMedia
    var images: [String: UIImage] = [:]
}

@MainActor
final class ReaderMediaLibrary: ObservableObject {
    private let loader: ChapterImageLoader
    init(loader: ChapterImageLoader = .init()) { self.loader = loader }

    private var chapters: [Int: ReaderMediaEntry] = [:]
    @Published private var revision = 0
    private var bookKey: Book.ID?
    private var sourceID: String?

    func presentation(activate: @escaping (Int, ChapterInlineMedia.Item) -> Void) -> ReaderMediaPresentation {
        ReaderMediaPresentation(chapters: chapters, revision: revision, action: activate)
    }

    func prepare(_ visible: [ReaderScrollChapter], directory: [BookChapter], book: Book, source: BookSource) async {
        if bookKey != book.id || sourceID != source.id {
            chapters.removeAll()
            bookKey = book.id
            sourceID = source.id
            revision &+= 1
        }
        let retained = Set(visible.map(\.id))
        chapters = chapters.filter { retained.contains($0.key) }
        for chapter in visible where directory.indices.contains(chapter.id) {
            let record = directory[chapter.id]
            let base = URL(string: record.baseUrl.isEmpty ? record.url : record.baseUrl)
            if chapters[chapter.id]?.body != chapter.content {
                chapters[chapter.id] = .init(body: chapter.content, inline: ChapterInlineMedia(chapter.content, baseURL: base))
                revision &+= 1
            }
            guard var entry = chapters[chapter.id] else { continue }
            var uniqueRequests: [String] = []
            var seenRequests = Set<String>()
            for item in entry.inline.items where entry.images[item.request] == nil {
                if seenRequests.insert(item.request).inserted {
                    uniqueRequests.append(item.request)
                }
            }
            guard !uniqueRequests.isEmpty else { continue }
            let fetched = await Self.fetchBatch(
                requests: uniqueRequests,
                loader: loader,
                source: source,
                book: book,
                chapter: record
            )
            guard !Task.isCancelled else { return }
            for (request, bitmap) in fetched.bitmaps {
                entry.images[request] = bitmap
            }
            for (request, data) in fetched.vectors {
                guard !Task.isCancelled else { return }
                if let image = try? await ReaderVectorPreview().image(data) {
                    entry.images[request] = image
                }
            }
            guard !Task.isCancelled else { return }
            if chapters[chapter.id]?.images.count != entry.images.count {
                chapters[chapter.id] = entry
                revision &+= 1
            }
        }
    }

    private nonisolated static func fetchBatch(
        requests: [String],
        loader: ChapterImageLoader,
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ) async -> (bitmaps: [String: UIImage], vectors: [(String, Data)]) {
        var bitmaps: [String: UIImage] = [:]
        var vectors: [(String, Data)] = []
        await withTaskGroup(of: (String, UIImage?, Data?).self) { group in
            var iterator = requests.makeIterator()
            let maxConcurrency = 4
            func enqueueNext() {
                guard !Task.isCancelled, let request = iterator.next() else { return }
                group.addTask {
                    do {
                        let data = try await loader.load(request, source: source, book: book, chapter: chapter)
                        try Task.checkCancellation()
                        if let bitmap = decodeThumbnail(data: data, maxPixelSize: 1440) {
                            return (request, bitmap, nil)
                        }
                        if request.lowercased().hasPrefix("data:image/svg+xml") || data.prefix(512).contains(0x3c) {
                            return (request, nil, data)
                        }
                        return (request, nil, nil)
                    } catch {
                        return (request, nil, nil)
                    }
                }
            }
            for _ in 0..<min(maxConcurrency, requests.count) { enqueueNext() }
            while let (request, bitmap, vectorData) = await group.next() {
                if let bitmap {
                    bitmaps[request] = bitmap
                } else if let vectorData {
                    vectors.append((request, vectorData))
                }
                enqueueNext()
            }
        }
        return (bitmaps, vectors)
    }

    private nonisolated static func decodeThumbnail(data: Data, maxPixelSize: Int) -> UIImage? {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

@MainActor
struct ReaderMediaPresentation {
    fileprivate var chapters: [Int: ReaderMediaEntry] = [:]
    var revision = 0
    fileprivate var action: ((Int, ChapterInlineMedia.Item) -> Void)?
    private static let hitKey = NSAttributedString.Key("LegadoReaderMediaHit")

    func document(_ text: String, chapter: Int) -> ChapterInlineMedia {
        if let entry = chapters[chapter], entry.body == text { return entry.inline }
        return ChapterInlineMedia(text)
    }

    func render(_ text: String, inline: ChapterInlineMedia, attributes: [NSAttributedString.Key: Any],
                width: CGFloat, chapter: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let line = (attributes[.font] as? UIFont)?.lineHeight ?? 20
        for item in inline.items.reversed() {
            let bitmap = chapters[chapter]?.images[item.request]
            let attachment = NSTextAttachment()
            attachment.image = bitmap ?? UIImage(systemName: item.action == nil ? "photo" : "text.bubble")
            let size = bitmap?.size ?? CGSize(width: line, height: line)
            let heightLimit = item.textSized || bitmap == nil ? line : min(max(width, line), 280)
            let scale = min(max(width, line) / max(1, size.width), heightLimit / max(1, size.height))
            attachment.bounds.size = CGSize(width: size.width * scale, height: size.height * scale)
            let token = NSMutableAttributedString(attachment: attachment)
            token.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            if item.action != nil {
                token.addAttribute(Self.hitKey, value: ReaderMediaHit(chapter: chapter, item: item),
                                   range: NSRange(location: 0, length: 1))
            }
            result.replaceCharacters(in: item.range, with: token)
        }
        return result
    }

    func activate(at point: CGPoint, manager: NSLayoutManager, container: NSTextContainer) -> Bool {
        guard let action, manager.numberOfGlyphs > 0 else { return false }
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point),
              let hit = manager.textStorage?.attribute(Self.hitKey, at: manager.characterIndexForGlyph(at: glyph),
                                                       effectiveRange: nil) as? ReaderMediaHit else { return false }
        action(hit.chapter, hit.item)
        return true
    }
}

private final class ReaderMediaHit: NSObject {
    let chapter: Int
    let item: ChapterInlineMedia.Item
    init(chapter: Int, item: ChapterInlineMedia.Item) { self.chapter = chapter; self.item = item }
}

@MainActor
private final class ReaderVectorPreview: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private var finished: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 240), configuration: config)
        super.init()
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
    }

    func image(_ data: Data) async throws -> UIImage {
        let html = """
        <meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>*{margin:0}img{width:100%;height:100%;object-fit:contain}</style>
        <img src="data:image/svg+xml;base64,\(data.base64EncodedString())">
        """
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        try Task.checkCancellation()
        let ratio = try await view.evaluateJavaScript("document.images[0].naturalHeight / document.images[0].naturalWidth") as? Double
        guard let ratio, ratio.isFinite, ratio > 0 else { throw ChapterImageError.emptyImage }
        view.frame.size = CGSize(width: 640, height: min(960, max(1, 640 * ratio)))
        return try await view.takeSnapshot(configuration: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.resume(); finished = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(ChapterImageError.emptyImage) }
    private func fail(_ error: Error) { finished?.resume(throwing: error); finished = nil }
}
