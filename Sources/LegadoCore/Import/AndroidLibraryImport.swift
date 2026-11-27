import Foundation
import ZIPFoundation

public enum ImportSection: String, CaseIterable, Sendable {
    case books = "bookshelf.json"
    case sources = "bookSource.json"
    case rules = "replaceRule.json"
    case preferences = "config.xml"

    public var title: String {
        switch self {
        case .books: "书架与阅读进度"
        case .sources: "书源"
        case .rules: "净化规则"
        case .preferences: "阅读设置"
        }
    }
}

public struct AndroidLibraryImport: Sendable {
    public private(set) var books: [Book] = []
    public private(set) var sources: [BookSource] = []
    public private(set) var rules: [ReplaceRule] = []
    public private(set) var preferences: [String: Bool] = [:]
    public private(set) var skippedLocalBooks = 0

    public func count(_ section: ImportSection) -> Int {
        switch section {
        case .books: books.count
        case .sources: sources.count
        case .rules: rules.count
        case .preferences: preferences.count
        }
    }

    /// Inspect recognized documents in memory. Archive entry names never become filesystem paths.
    public init(url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let decoder = JSONDecoder()
        var found = Set<ImportSection>()
        var root: String?
        var remaining = 64 * 1024 * 1024
        for entry in archive {
            try Task.checkCancellation()
            let parts = entry.path.components(separatedBy: "/")
            guard let name = parts.last, let section = ImportSection(rawValue: name) else { continue }
            let prefix = parts.dropLast().joined(separator: "/")
            guard entry.type == .file, parts.count <= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }),
                  root == nil || root == prefix, found.insert(section).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = prefix
            guard entry.uncompressedSize <= UInt64(remaining) else { throw CocoaError(.fileReadTooLarge) }
            var data = Data()
            let crc = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
                remaining -= chunk.count
                data.append(chunk)
            }
            guard crc == entry.checksum else { throw CocoaError(.fileReadCorruptFile) }
            switch section {
            case .books:
                for book in try decoder.decode([Book].self, from: data) {
                    guard !book.name.isEmpty, !book.bookUrl.isEmpty,
                          book.durChapterIndex >= 0, book.durChapterPos >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                    if book.origin == "local" || book.origin == "loc_book" || book.bookUrl.hasPrefix("file:") || book.bookUrl.hasPrefix("content:") {
                        skippedLocalBooks += 1
                    } else { books.append(book) }
                }
            case .sources:
                sources = try decoder.decode([BookSource].self, from: data)
                for source in sources {
                    guard !source.id.isEmpty, !source.bookSourceName.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                }
            case .rules:
                rules = try decoder.decode([ReplaceRule].self, from: data)
                for rule in rules { try ReplaceRuleValidator.validate(rule) }
            case .preferences:
                let reader = PreferenceReader()
                let parser = XMLParser(data: data)
                parser.delegate = reader
                parser.shouldResolveExternalEntities = false
                guard parser.parse() else { throw CocoaError(.fileReadCorruptFile) }
                preferences = reader.values
            }
        }
        guard !found.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
    }
}

private final class PreferenceReader: NSObject, XMLParserDelegate {
    private(set) var values: [String: Bool] = [:]
    private let keys = ["enableReadRecord": "enableReadRecord", "keep_light": "readerKeepScreenOn",
                        "auto_refresh": "auto_refresh"]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "boolean", let name = attributeDict["name"], let key = keys[name],
              let text = attributeDict["value"], let flag = Bool(text) else { return }
        values[key] = flag
    }
}
