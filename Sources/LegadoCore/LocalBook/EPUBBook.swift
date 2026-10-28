import Foundation
import ImageIO
import SwiftSoup
import ZIPFoundation

public enum EPUBError: Error, LocalizedError, Sendable {
    case invalidArchive, invalidPackage, missingResource(String), encrypted, resourceTooLarge, invalidChapter

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "EPUB 文件已损坏或不是有效的压缩包"
        case .invalidPackage: "EPUB 缺少有效的书籍信息或阅读顺序"
        case .missingResource(let path): "EPUB 中缺少文件：\(path)"
        case .encrypted: "此 EPUB 的正文或图片已加密，暂不支持读取"
        case .resourceTooLarge: "EPUB 单个章节或资源过大，无法安全读取"
        case .invalidChapter: "EPUB 章节或目录锚点无效，请重新打开书籍"
        }
    }
}

public struct EPUBIllustration: Identifiable, Sendable {
    public let id: Int
    public let caption: String
    public let data: Data
}

/// Reads resources on demand without unpacking untrusted archive paths to disk.
/// Navigation follows the spine; EPUB 2 NCX and EPUB 3 nav supply chapter labels/anchors.
struct EPUBBook {
    private struct Item {
        let id: String
        let path: String
        let mediaType: String
        let properties: Set<String>
    }
    private struct Reference {
        let path: String
        let fragment: String?
        let title: String
    }
    private let archive: Archive
    private let entries: [String: Entry]
    private let package: EPUBXMLNode
    private let packagePath: String
    private let manifest: [Item]
    private let spine: [Item]
    private let encryptedPaths: Set<String>
    private static let resourceLimit = 32 * 1_024 * 1_024

    init(url: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw EPUBError.invalidArchive }
        var entries: [String: Entry] = [:]
        for entry in archive {
            guard entries.count < 50_000 else { throw EPUBError.resourceTooLarge }
            // Directories and symlinks are never used as book resources.
            guard entry.type == .file else { continue }
            guard Self.safePath(entry.path), entries[entry.path] == nil else { throw EPUBError.invalidArchive }
            entries[entry.path] = entry
        }
        self.archive = archive
        self.entries = entries
        let container = try EPUBXMLNode.parse(Self.read("META-INF/container.xml", archive: archive, entries: entries))
        guard let rootfile = container.descendants("rootfile").first,
              let fullPath = rootfile.attributes["full-path"],
              let path = Self.resolve(fullPath, relativeTo: "")?.path else { throw EPUBError.invalidPackage }
        packagePath = path
        package = try EPUBXMLNode.parse(Self.read(path, archive: archive, entries: entries))
        guard package.name == "package", let manifestNode = package.children.first(where: { $0.name == "manifest" }),
              let spineNode = package.children.first(where: { $0.name == "spine" }) else { throw EPUBError.invalidPackage }
        manifest = manifestNode.children.compactMap { node in
            guard node.name == "item", let id = node.attributes["id"], let href = node.attributes["href"],
                  let ref = Self.resolve(href, relativeTo: path) else { return nil }
            return Item(id: id, path: ref.path, mediaType: node.attributes["media-type"] ?? "",
                        properties: Set((node.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
        }
        let items = manifest
        let readable = spineNode.children.filter { $0.name == "itemref" && $0.attributes["linear"] != "no" }
        spine = try readable.map { node in
            guard let item = items.first(where: { $0.id == node.attributes["idref"] }),
                  ["application/xhtml+xml", "text/html"].contains(item.mediaType), entries[item.path] != nil else {
                throw EPUBError.invalidPackage
            }
            return item
        }
        guard !spine.isEmpty else { throw EPUBError.invalidPackage }
        if entries["META-INF/encryption.xml"] != nil {
            let encryption = try EPUBXMLNode.parse(Self.read("META-INF/encryption.xml", archive: archive, entries: entries))
            encryptedPaths = Set(encryption.descendants("CipherReference").compactMap {
                $0.attributes["URI"].flatMap { Self.resolve($0, relativeTo: "")?.path }
            })
        } else { encryptedPaths = [] }
        // Font obfuscation is common and does not prevent text reading.
        guard !spine.contains(where: { encryptedPaths.contains($0.path) }) else { throw EPUBError.encrypted }
    }

    func report(url: URL, originalName: String) throws -> LocalBookImportReport {
        let metadata = package.children.first { $0.name == "metadata" }
        let title = metadata?.descendants("title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authors = metadata?.descendants("creator").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        var book = Book(bookUrl: url.absoluteString, name: title.isEmpty ? (originalName as NSString).deletingPathExtension : title,
                        author: authors.joined(separator: "、"), origin: "local")
        book.originName = originalName
        book.intro = MetadataTextSanitizer().clean(metadata?.descendants("description").first?.text)
        book.canUpdate = false
        var configuration = BookReadConfig()
        configuration.useReplaceRule = false
        book.readConfig = configuration
        if let thumbnail = coverThumbnail() {
            // A bounded embedded thumbnail survives file renames, backups and cache eviction.
            book.coverUrl = "data:image/png;base64,\(thumbnail.base64EncodedString())"
        }
        let chapters = try chapters(book: book)
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        return .init(book: book, chapters: chapters)
    }

    func coverThumbnail() -> Data? {
        let metadata = package.children.first { $0.name == "metadata" }
        let coverID = metadata?.descendants("meta").first { $0.attributes["name"] == "cover" }?.attributes["content"]
        var paths = manifest.filter { $0.properties.contains("cover-image") }.map(\.path)
        paths += manifest.filter { $0.id == coverID }.map(\.path)
        // EPUB 2 guide references commonly point at an XHTML/SVG wrapper.
        paths += package.descendants("reference").filter {
            ($0.attributes["type"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover")
        }.compactMap { $0.attributes["href"].flatMap { Self.resolve($0, relativeTo: packagePath)?.path } }
        if let first = spine.first { paths.append(first.path) }
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            guard let data = try? read(path) else { continue }
            if let image = Self.coverThumbnail(data) { return image }
            guard let doc = try? document(path), let images = try? doc.select("img, image").array() else { continue }
            for image in images {
                let href = ["src", "xlink:href", "href"].compactMap { try? image.attr($0) }.first { !$0.isEmpty }
                guard let href, let resource = Self.resolve(href, relativeTo: path),
                      let bytes = try? read(resource.path), let thumbnail = Self.coverThumbnail(bytes) else { continue }
                return thumbnail
            }
        }
        return nil
    }

    func chapters(book: Book) throws -> [BookChapter] {
        let references = navigation()
        var chapters: [BookChapter] = []
        for item in spine where !item.properties.contains("nav") {
            let document = try document(item.path)
            guard let body = document.body() else { continue }
            let elements = try body.getAllElements().array()
            var positions: [String: Int] = [:]
            for (index, element) in elements.enumerated() {
                for key in [element.id(), (try? element.attr("name")) ?? ""] where !key.isEmpty && positions[key] == nil {
                    positions[key] = index
                }
            }
            var seen = Set<String>()
            let refs = references.filter { $0.path == item.path }
                .filter { ref in
                    guard ref.fragment == nil || positions[ref.fragment!] != nil else { return false }
                    return seen.insert(ref.fragment ?? "").inserted
                }
                .sorted { (positions[$0.fragment ?? ""] ?? -1) < (positions[$1.fragment ?? ""] ?? -1) }
            let documentTitle = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = try body.select("h1,h2,h3").first()?.text() ?? ""
            let fallback = !documentTitle.isEmpty ? documentTitle : (!heading.isEmpty ? heading : "第\(chapters.count + 1)章")
            var boundaries = refs
            if boundaries.isEmpty {
                boundaries = [Reference(path: item.path, fragment: nil, title: fallback)]
            } else if let first = boundaries.first, let fragment = first.fragment {
                let prefix = try render(body: body, from: nil, to: fragment).text
                if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    boundaries.insert(Reference(path: item.path, fragment: nil, title: fallback), at: 0)
                }
            }
            for (index, ref) in boundaries.enumerated() {
                var chapter = BookChapter(url: Self.referenceURL(path: item.path, fragment: ref.fragment),
                                          title: ref.title.isEmpty ? fallback : ref.title, bookUrl: book.bookUrl, index: chapters.count)
                chapter.resourceUrl = item.path
                chapter.startFragmentId = ref.fragment
                chapter.endFragmentId = boundaries.indices.contains(index + 1) ? boundaries[index + 1].fragment : nil
                chapters.append(chapter)
            }
        }
        guard !chapters.isEmpty else { throw EPUBError.invalidPackage }
        return chapters
    }

    func content(chapter: BookChapter) throws -> ChapterContentReport {
        let (body, _) = try body(chapter: chapter)
        let value = try render(body: body, from: chapter.startFragmentId, to: chapter.endFragmentId)
        return .init(title: chapter.title, content: value.text, pagesVisited: 1)
    }

    func illustrations(chapter: BookChapter) throws -> [EPUBIllustration] {
        let (body, path) = try body(chapter: chapter)
        let value = try render(body: body, from: chapter.startFragmentId, to: chapter.endFragmentId)
        var totalBytes = 0
        return try value.images.enumerated().map { index, image in
            guard let ref = Self.resolve(image.src, relativeTo: path),
                  let item = manifest.first(where: { $0.path == ref.path }), item.mediaType.hasPrefix("image/") else {
                throw EPUBError.missingResource(image.src)
            }
            let data = try read(ref.path)
            totalBytes += data.count
            guard totalBytes <= Self.resourceLimit else { throw EPUBError.resourceTooLarge }
            return EPUBIllustration(id: index + 1, caption: image.alt, data: data)
        }
    }

    private func body(chapter: BookChapter) throws -> (Element, String) {
        guard let path = chapter.resourceUrl, spine.contains(where: { $0.path == path }),
              let body = try document(path).body() else { throw EPUBError.invalidChapter }
        return (body, path)
    }

    private func document(_ path: String) throws -> Document {
        let data = try read(path)
        let text: String
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let utf16 = String(data: data, encoding: .utf16) {
            text = utf16
        } else if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else { throw EPUBError.invalidPackage }
        return try SwiftSoup.parse(text)
    }

    private func navigation() -> [Reference] {
        if let nav = manifest.first(where: { $0.properties.contains("nav") }), let doc = try? document(nav.path),
           let nodes = try? doc.select("nav").array() {
            let toc = nodes.first { node in
                let type = (try? node.attr("epub:type")) ?? ""
                return type.split(whereSeparator: \.isWhitespace).contains("toc") || (try? node.attr("role")) == "doc-toc"
            }
            if let links = try? toc?.select("a[href]").array() {
                let refs = links.compactMap { element -> Reference? in
                    guard let href = try? element.attr("href"), let ref = Self.resolve(href, relativeTo: nav.path) else { return nil }
                    return Reference(path: ref.path, fragment: ref.fragment, title: (try? element.text()) ?? "")
                }
                if !refs.isEmpty { return refs }
            }
        }
        let tocID = package.children.first { $0.name == "spine" }?.attributes["toc"]
        if let ncx = manifest.first(where: { $0.id == tocID }) ?? manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
           let data = try? read(ncx.path), let root = try? EPUBXMLNode.parse(data) {
            return root.descendants("navPoint").compactMap { node in
                guard let href = node.children.first(where: { $0.name == "content" })?.attributes["src"],
                      let ref = Self.resolve(href, relativeTo: ncx.path) else { return nil }
                return Reference(path: ref.path, fragment: ref.fragment,
                                 title: node.children.first(where: { $0.name == "navLabel" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
        return []
    }

    /// Walk DOM boundaries rather than slicing serialized HTML: anchors can be nested
    /// in different parents, and all text after the end anchor belongs to the next chapter.
    private func render(body: Element, from start: String?, to end: String?) throws -> (text: String, images: [(src: String, alt: String)]) {
        var active = start == nil
        var foundStart = start == nil
        var foundEnd = end == nil
        var finished = false
        var output = ""
        var images: [(src: String, alt: String)] = []
        let blocks: Set<String> = ["p", "div", "section", "article", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "tr", "hr"]
        func visit(_ node: Node, depth: Int) throws {
            guard depth < 512 else { throw EPUBError.invalidPackage }
            guard !finished else { return }
            guard let element = node as? Element else {
                if active, let text = node as? TextNode {
                    output += text.getWholeText().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                }
                return
            }
            let id = element.id()
            let name = try element.attr("name")
            if let end, id == end || name == end { active = false; finished = true; foundEnd = true; return }
            if let start, id == start || name == start { active = true; foundStart = true }
            let tag = element.tagName().lowercased()
            let style = try element.attr("style").lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            if ["script", "style", "noscript", "rt", "rp", "title"].contains(tag) || element.hasAttr("hidden") || style.contains("display:none") { return }
            if active, blocks.contains(tag) || tag == "br" { output += "\n" }
            if active, tag == "img" || tag == "image" {
                var src = try element.attr(tag == "img" ? "src" : "xlink:href")
                if src.isEmpty, tag == "image" { src = try element.attr("href") }
                let alt = try element.attr("alt")
                if !src.isEmpty {
                    images.append((src, alt))
                    output += "\n【插图 \(images.count)\(alt.isEmpty ? "" : "：" + alt)】\n"
                }
            }
            for child in element.getChildNodes() { try visit(child, depth: depth + 1) }
            if active, blocks.contains(tag) { output += "\n" }
            if active, tag == "td" || tag == "th" { output += " " }
        }
        try visit(body, depth: 0)
        guard foundStart && foundEnd else { throw EPUBError.invalidChapter }
        let text = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return (text, images)
    }

    private func read(_ path: String) throws -> Data {
        guard !encryptedPaths.contains(path) else { throw EPUBError.encrypted }
        return try Self.read(path, archive: archive, entries: entries)
    }

    private static func read(_ path: String, archive: Archive, entries: [String: Entry]) throws -> Data {
        guard let entry = entries[path] else { throw EPUBError.missingResource(path) }
        guard entry.uncompressedSize <= resourceLimit else { throw EPUBError.resourceTooLarge }
        var result = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard result.count + chunk.count <= resourceLimit else { throw EPUBError.resourceTooLarge }
            result.append(chunk)
        }
        guard checksum == entry.checksum, result.count == entry.uncompressedSize else { throw EPUBError.invalidArchive }
        return result
    }

    private static func coverThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && !path.split(separator: "/").contains("..")
    }

    private static func resolve(_ href: String, relativeTo base: String) -> (path: String, fragment: String?)? {
        guard !href.hasPrefix("/"), !href.contains("\\"),
              URLComponents(string: href)?.scheme == nil else { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pathPart = String(parts[0]).removingPercentEncoding else { return nil }
        var components = pathPart.isEmpty ? base.split(separator: "/").map(String.init) : base.split(separator: "/").dropLast().map(String.init)
        if !pathPart.isEmpty {
            for part in pathPart.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
                else { components.append(String(part)) }
            }
        }
        let path = components.joined(separator: "/")
        guard safePath(path), !pathPart.hasPrefix("/") else { return nil }
        let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        return (path, fragment?.isEmpty == false ? fragment : nil)
    }

    private static func referenceURL(path: String, fragment: String?) -> String {
        var url = URLComponents()
        url.scheme = "epub"
        url.host = "book"
        url.path = "/" + path
        url.fragment = fragment
        return url.string ?? path
    }
}

/// Small namespace-independent XML tree for package metadata and navigation.
private final class EPUBXMLNode: NSObject, XMLParserDelegate {
    var name = ""
    var attributes: [String: String] = [:]
    var children: [EPUBXMLNode] = []
    var text = ""
    private var stack: [EPUBXMLNode] = []
    private var count = 0

    func descendants(_ name: String) -> [EPUBXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    static func parse(_ data: Data) throws -> EPUBXMLNode {
        let delegate = EPUBXMLNode()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.children.first else { throw EPUBError.invalidPackage }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 128, count <= 50_000 else { parser.abortParsing(); return }
        let node = EPUBXMLNode()
        node.name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        node.attributes = attributeDict
        (stack.last ?? self).children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for node in stack {
            guard node.text.utf8.count + string.utf8.count <= 4 * 1_024 * 1_024 else { parser.abortParsing(); return }
            node.text += string
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}
