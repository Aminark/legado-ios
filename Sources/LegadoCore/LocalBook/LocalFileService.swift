import Foundation

public struct LocalFileEntry: Identifiable, Sendable, Equatable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date?
    public var id: String { url.absoluteString }
}

public enum LocalFileError: Error, LocalizedError, Equatable {
    case outsideLibrary, invalidName, alreadyExists, missingFile, emptyCache, missingDirectory
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideLibrary: "只能管理应用内的本地书文件。"
        case .invalidName: "文件名不能为空，不能包含路径分隔符或控制字符。"
        case .alreadyExists: "同名文件已存在，请换一个名称。"
        case .missingFile: "文件已不存在，请重新导入。"
        case .emptyCache: "这本书还没有可导出的缓存正文，请先缓存章节。"
        case .missingDirectory: "还没有这本书的目录，请先打开详情加载目录。"
        case .saveFailed(let message): "书架保存失败：\(message)"
        }
    }
}

public struct StagedLocalFile: Sendable {
    public let original: URL
    public let staged: URL
}

public actor LocalFileService {
    public let directory: URL

    public init(directory: URL) { self.directory = URL(fileURLWithPath: directory.path, isDirectory: true).standardizedFileURL }

    public func list() throws -> [LocalFileEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, LocalBookService.supports(url) else { return nil }
            return .init(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    public func importFile(from source: URL) throws -> URL {
        guard LocalBookService.supports(source) else { throw LocalBookError.unsupportedFormat }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw LocalFileError.missingFile }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // File providers can preserve the extension's case differently between
        // imports. Reserve names case-insensitively before asking Cocoa to copy.
        let occupiedNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
        let stem = source.deletingPathExtension().lastPathComponent
        var target = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while occupiedNames.contains(target.lastPathComponent.lowercased()) || FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(stem) (\(suffix)).\(source.pathExtension)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    public func rename(_ source: URL, to name: String) throws -> URL {
        try validate(source)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.hasPrefix("."),
              !trimmed.contains(where: { $0 == "/" || $0 == "\\" || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw LocalFileError.invalidName
        }
        let suffix = "." + source.pathExtension
        let filename = trimmed.lowercased().hasSuffix(suffix.lowercased()) ? trimmed : trimmed + suffix
        guard filename.utf8.count <= 255 else { throw LocalFileError.invalidName }
        let target = directory.appendingPathComponent(filename)
        if source.standardizedFileURL == target.standardizedFileURL { return source }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LocalFileError.alreadyExists }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    public func stageRemoval(_ source: URL) throws -> StagedLocalFile? {
        try validate(source, allowMissing: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let trash = directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let staged = trash.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
        try FileManager.default.moveItem(at: source, to: staged)
        return .init(original: source, staged: staged)
    }

    public func restore(_ file: StagedLocalFile) throws {
        try validate(file.original, allowMissing: true)
        guard file.staged.deletingLastPathComponent().standardizedFileURL == directory.appendingPathComponent(".Trash").standardizedFileURL else {
            throw LocalFileError.outsideLibrary
        }
        try FileManager.default.moveItem(at: file.staged, to: file.original)
    }

    public func finishRemoval(_ file: StagedLocalFile) throws {
        guard file.staged.deletingLastPathComponent().standardizedFileURL == directory.appendingPathComponent(".Trash").standardizedFileURL else {
            throw LocalFileError.outsideLibrary
        }
        try FileManager.default.removeItem(at: file.staged)
    }

    private func validate(_ url: URL, allowMissing: Bool = false) throws {
        guard url.isFileURL, LocalBookService.supports(url),
              url.standardizedFileURL.deletingLastPathComponent() == directory,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw LocalFileError.outsideLibrary
        }
        if !allowMissing, !FileManager.default.fileExists(atPath: url.path) { throw LocalFileError.missingFile }
    }
}

public struct BookFileExport: Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let cachedChapters: Int
    public let totalChapters: Int
    public var isPartial: Bool { cachedChapters < totalChapters }
}

public actor BookFileExporter {
    private let directory: URL
    private let cache: ChapterContentCache

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("LegadoExports"), cache: ChapterContentCache = .live()) {
        self.directory = directory
        self.cache = cache
    }

    public func originalFile(_ source: URL, filename: String) throws -> BookFileExport {
        let target = try destination(filename: filename, extension: source.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return .init(url: target, cachedChapters: 0, totalChapters: 0)
        } catch {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            throw error
        }
    }

    public func cachedBook(_ book: Book, chapters: [BookChapter]) async throws -> BookFileExport {
        guard chapters.contains(where: { !$0.isVolume }) else { throw LocalFileError.missingDirectory }
        let target = try destination(filename: book.name + ".txt")
        do {
            _ = FileManager.default.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try output.write(contentsOf: Data((book.name + (book.author.isEmpty ? "" : "\n作者：" + book.author) + "\n\n").utf8))
            var cached = 0
            var total = 0
            for chapter in chapters.sorted(by: { $0.index < $1.index }) {
                try Task.checkCancellation()
                try output.write(contentsOf: Data((chapter.title + "\n\n").utf8))
                guard !chapter.isVolume else { continue }
                total += 1
                if let entry = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url) {
                    cached += 1
                    try output.write(contentsOf: Data((entry.content + "\n" + (entry.supplementalContent ?? "") + "\n\n").utf8))
                } else {
                    try output.write(contentsOf: Data("【本章尚未缓存】\n\n".utf8))
                }
            }
            guard cached > 0 else { throw LocalFileError.emptyCache }
            return .init(url: target, cachedChapters: cached, totalChapters: total)
        } catch {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            throw error
        }
    }

    public func discard(_ export: BookFileExport) throws {
        guard export.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw LocalFileError.outsideLibrary
        }
        try FileManager.default.removeItem(at: export.url.deletingLastPathComponent())
    }

    private func destination(filename: String, extension fileExtension: String = "txt") throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = filename.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "_")
        let stem = String(safe.replacingOccurrences(of: "." + fileExtension, with: "", options: [.caseInsensitive, .anchored, .backwards]).prefix(70))
        return folder.appendingPathComponent((stem.isEmpty ? "书籍" : stem) + "." + fileExtension)
    }
}
