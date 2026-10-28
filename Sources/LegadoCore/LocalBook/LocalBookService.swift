import CoreFoundation
import CryptoKit
import Foundation

public enum LocalBookError: Error, LocalizedError, Sendable {
    case unsupportedFormat
    case oversized
    case unreadableEncoding
    case missingFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "当前支持 TXT 和 EPUB 本地书"
        case .oversized: "本地书超过当前配置允许的大小"
        case .unreadableEncoding: "无法识别 TXT 编码"
        case .missingFile: "本地书文件已丢失"
        }
    }
}

public struct LocalBookImportReport: Sendable {
    public var book: Book
    public var chapters: [BookChapter]

    public init(book: Book, chapters: [BookChapter]) {
        self.book = book
        self.chapters = chapters
    }
}

public enum TxtTocRuleSelector {
    public static let separator = "🫅🈳🏻"

    public static func select(
        content: String,
        rules: [TxtTocRule],
        transformTitle: (TxtTocRule, String, Int, String?, Int) -> String = { _, value, _, _, _ in value }
    ) -> TxtTocRule? {
        let source = content as NSString
        var maximum = -1
        var selected: TxtTocRule?
        for rule in rules.filter(\.enable).sorted(by: { $0.serialNumber < $1.serialNumber }) {
            guard !rule.rule.isEmpty else { continue }
            guard let expression = try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines) else { continue }
            var start = 0
            var validCount = 0
            var shortGapCount = 0
            var lastTitle: String?
            for match in expression.matches(in: content, range: NSRange(location: 0, length: source.length)) {
                let length = match.range.location - start
                if start == 0 || length > 1_000 {
                    let rawTitle = source.substring(with: match.range)
                    let title = transformTitle(rule, rawTitle, validCount, lastTitle, length)
                    if !title.isEmpty {
                        lastTitle = title
                        validCount += 1
                    }
                    start = NSMaxRange(match.range)
                } else if length < 100 {
                    shortGapCount += 1
                }
            }
            if validCount >= shortGapCount * 3, validCount > maximum + 2 {
                maximum = validCount
                selected = rule
                if maximum > 70 { break }
            }
        }
        return selected
    }
}

public enum TxtTocRuleDefaults {
    public static func load(bundle: Bundle = .main) -> [TxtTocRule] {
        guard let url = bundle.url(forResource: "txtTocRule", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([TxtTocRule].self, from: data) else { return [] }
        return values.sorted { $0.serialNumber < $1.serialNumber }
    }
}

private final class TxtVolumeState {
    var lastTitle = ""
}

private struct TxtHeadingMatch {
    var title: String
    var start: Int64
    var end: Int64
    var previousLength: Int
}

public struct LocalBookService: Sendable {
    public var maximumFileSize: Int64
    public var tocRules: [TxtTocRule]
    private var loadsLiveTocRules = false

    public init(maximumFileSize: Int64 = .max, tocRules: [TxtTocRule] = []) {
        self.maximumFileSize = maximumFileSize
        self.tocRules = tocRules.filter(\.enable).sorted { $0.serialNumber < $1.serialNumber }
    }

    public static func live() -> LocalBookService {
        LocalBookService(tocRules: TxtTocRuleDefaults.load())
    }

    public static func supports(_ url: URL) -> Bool {
        url.isFileURL && ["txt", "epub"].contains(url.pathExtension.lowercased())
    }

    public func loadCover(at url: URL) throws -> Data? {
        guard url.isFileURL, url.pathExtension.lowercased() == "epub" else { return nil }
        try validateFile(url)
        return try EPUBBook(url: url).coverThumbnail()
    }

    public func openFile(at url: URL) throws -> LocalBookImportReport {
        guard Self.supports(url) else { throw LocalBookError.unsupportedFormat }
        if url.pathExtension.lowercased() == "epub" {
            try validateFile(url)
            return try EPUBBook(url: url).report(url: url, originalName: url.lastPathComponent)
        }
        return try openTextFile(at: url)
    }

    public func importFile(at source: URL, into directory: URL) throws -> LocalBookImportReport {
        guard Self.supports(source) else { throw LocalBookError.unsupportedFormat }
        try validateFile(source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            if source.pathExtension.lowercased() == "epub" {
                return try EPUBBook(url: destination).report(url: destination, originalName: source.lastPathComponent)
            }
            return try textFileReport(data: Data(contentsOf: destination, options: .mappedIfSafe), sourceURL: source, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func loadIllustrations(book: Book, chapter: BookChapter) throws -> [EPUBIllustration] {
        guard let url = URL(string: book.bookUrl), url.isFileURL, url.pathExtension.lowercased() == "epub" else { return [] }
        try validateFile(url)
        return try EPUBBook(url: url).illustrations(chapter: chapter)
    }

    private func validateFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missingFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw LocalBookError.missingFile }
        guard Int64(values.fileSize ?? 0) <= maximumFileSize else { throw LocalBookError.oversized }
    }

    public func importTextFile(at sourceURL: URL, into directory: URL) throws -> LocalBookImportReport {
        guard sourceURL.pathExtension.lowercased() == "txt" else { throw LocalBookError.unsupportedFormat }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LocalBookError.missingFile }
        if Int64(values.fileSize ?? 0) > maximumFileSize { throw LocalBookError.oversized }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).txt")
        try data.write(to: destination, options: .atomic)
        do {
            return try textFileReport(data: data, sourceURL: sourceURL, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func openTextFile(at url: URL) throws -> LocalBookImportReport {
        guard url.pathExtension.lowercased() == "txt" else { throw LocalBookError.unsupportedFormat }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LocalBookError.missingFile }
        guard Int64(values.fileSize ?? 0) <= maximumFileSize else { throw LocalBookError.oversized }
        return try textFileReport(data: Data(contentsOf: url, options: .mappedIfSafe), sourceURL: url, destination: url)
    }

    private func textFileReport(data: Data, sourceURL: URL, destination: URL) throws -> LocalBookImportReport {
        let decoded = try decode(Data(data.prefix(512_000)))

        let name = sourceURL.deletingPathExtension().lastPathComponent
        var book = Book(bookUrl: destination.absoluteString, name: name, origin: "local")
        book.originName = sourceURL.lastPathComponent
        book.charset = decoded.charset
        book.canUpdate = false
        let selectionVolumeState = TxtVolumeState()
        let probeText = textProbe(data, encoding: decoded.encoding)
        let selectedRule = TxtTocRuleSelector.select(content: probeText, rules: effectiveTocRules()) {
            rule, title, index, previous, length in
            transformedTitle(title, script: rule.replacement, index: index, previousTitle: previous, previousLength: length, book: book, volumeState: selectionVolumeState)
        }
        if let selectedRule {
            book.tocUrl = selectedRule.rule + TxtTocRuleSelector.separator + selectedRule.replacement
        }
        let fullBOMLength = bomLength(in: data, encoding: decoded.encoding)
        let hasTOC = !headingMatches(
            data: data,
            encoding: decoded.encoding,
            bomLength: fullBOMLength,
            pattern: selectedRule?.rule ?? fallbackTocPattern,
            usesFirstCapture: selectedRule == nil
        ).isEmpty
        var chapters = chapters(
            data: data,
            encoding: decoded.encoding,
            bomLength: fullBOMLength,
            book: book,
            fallbackTitle: name,
            selectedRule: selectedRule
        )
        let totalWordCount = applyWordCounts(&chapters, data: data, encoding: decoded.encoding)
        book.wordCount = wordCountFormat(totalWordCount)
        if hasTOC,
           let first = chapters.first(where: { !$0.isVolume && $0.start == Int64(fullBOMLength) }),
           first.start == Int64(fullBOMLength),
           let endValue = first.end,
           endValue > Int64(fullBOMLength),
           let preface = String(
               data: data.subdata(in: fullBOMLength..<min(Int(endValue), data.count)),
               encoding: decoded.encoding
           ) {
            book.intro = preface.utf16.count > 600 ? String(preface.prefix(600)) : preface
        }
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        return .init(book: book, chapters: chapters)
    }

    public func loadChapters(book: Book) throws -> ChapterListReport {
        if let url = URL(string: book.bookUrl), url.isFileURL, url.pathExtension.lowercased() == "epub" {
            try validateFile(url)
            return try .init(chapters: EPUBBook(url: url).chapters(book: book))
        }
        let decoded = try read(book)
        let selectionVolumeState = TxtVolumeState()
        let probeText = textProbe(decoded.data, encoding: decoded.encoding)
        let selectedRule = rule(storedIn: book.tocUrl) ?? TxtTocRuleSelector.select(content: probeText, rules: effectiveTocRules()) {
            rule, title, index, previous, length in
            transformedTitle(title, script: rule.replacement, index: index, previousTitle: previous, previousLength: length, book: book, volumeState: selectionVolumeState)
        }
        var chapters = chapters(
            data: decoded.data,
            encoding: decoded.encoding,
            bomLength: decoded.bomLength,
            book: book,
            fallbackTitle: book.name,
            selectedRule: selectedRule
        )
        _ = applyWordCounts(&chapters, data: decoded.data, encoding: decoded.encoding)
        return .init(chapters: chapters)
    }

    public func loadContent(book: Book, chapter: BookChapter) throws -> ChapterContentReport {
        if let url = URL(string: book.bookUrl), url.isFileURL, url.pathExtension.lowercased() == "epub" {
            try validateFile(url)
            return try EPUBBook(url: url).content(chapter: chapter)
        }
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missingFile }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let start = max(Int(chapter.start ?? 0), 0)
        let end = min(Int(chapter.end ?? Int64(fileSize)), fileSize)
        guard start <= end else {
            return .init(title: chapter.title, diagnostics: [
                .init(severity: .error, code: "local.range", message: "本地章节范围无效", rule: chapter.url)
            ])
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let contentData = try handle.read(upToCount: end - start) ?? Data()
        let encoding: String.Encoding
        if let charset = book.charset, let stored = self.encoding(named: charset) {
            encoding = stored
        } else {
            try handle.seek(toOffset: 0)
            let probe = try handle.read(upToCount: 512_000) ?? Data()
            encoding = try decode(probe).encoding
        }
        let content = (String(data: contentData, encoding: encoding) ?? "")
            .replacingOccurrences(of: #"^[\n\s]+"#, with: "　　", options: .regularExpression)
        return .init(title: chapter.title, content: content, pagesVisited: 1)
    }

    private func read(_ book: Book) throws -> (charset: String, encoding: String.Encoding, bomLength: Int, data: Data) {
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missingFile }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let charset = book.charset, let encoding = encoding(named: charset) {
            return (charset, encoding, bomLength(in: data, encoding: encoding), data)
        }
        let decoded = try decode(Data(data.prefix(512_000)))
        return (decoded.charset, decoded.encoding, bomLength(in: data, encoding: decoded.encoding), data)
    }

    private func decode(_ data: Data, preferredCharset: String? = nil) throws -> (text: String, charset: String, encoding: String.Encoding, bomLength: Int) {
        if let preferredCharset, let encoding = encoding(named: preferredCharset),
           let value = String(data: data, encoding: encoding) {
            return (stripBOM(value), preferredCharset, encoding, bomLength(in: data, encoding: encoding))
        }
        if data.starts(with: [0xFF, 0xFE]),
           let value = String(data: data, encoding: .utf16LittleEndian) {
            return (stripBOM(value), "UTF-16LE", .utf16LittleEndian, 2)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let value = String(data: data, encoding: .utf16BigEndian) {
            return (stripBOM(value), "UTF-16BE", .utf16BigEndian, 2)
        }
        let candidates: [(String, String.Encoding)] = [
            ("UTF-8", .utf8),
            ("UTF-16", .utf16),
            ("GB18030", .gb18030),
            ("Big5", .big5)
        ]
        for (name, encoding) in candidates {
            if let value = String(data: data, encoding: encoding), isPlausible(value) {
                return (stripBOM(value), name, encoding, bomLength(in: data, encoding: encoding))
            }
            // A bounded probe can end halfway through a UTF-8 scalar. Keep
            // UTF-8 as the selected charset instead of misclassifying the
            // truncated probe as UTF-16 and producing unreadable chapters.
            if encoding == .utf8 {
                let value = String(decoding: data, as: UTF8.self)
                let replacementCount = value.reduce(into: 0) { count, character in
                    if character == "\u{FFFD}" { count += 1 }
                }
                if replacementCount <= 2, isPlausible(value) {
                    return (stripBOM(value), name, encoding, bomLength(in: data, encoding: encoding))
                }
            }
        }
        throw LocalBookError.unreadableEncoding
    }

    private func chapters(
        data: Data,
        encoding: String.Encoding,
        bomLength: Int,
        book: Book,
        fallbackTitle: String,
        selectedRule: TxtTocRule?
    ) -> [BookChapter] {
        let pattern = selectedRule?.rule ?? fallbackTocPattern
        let matches = headingMatches(
            data: data,
            encoding: encoding,
            bomLength: bomLength,
            pattern: pattern,
            usesFirstCapture: selectedRule == nil
        )
        guard !matches.isEmpty else {
            if data.count - bomLength > 10 * 1_024 {
                return chaptersWithoutTOC(data, encoding: encoding, bomLength: bomLength, book: book)
            }
            var chapter = BookChapter(url: "local://chapter/0", title: fallbackTitle, bookUrl: book.bookUrl, index: 0)
            chapter.start = Int64(bomLength)
            chapter.end = Int64(data.count)
            chapter.baseUrl = book.bookUrl
            return finalized([chapter], book: book)
        }
        var previousTitle: String?
        var chapters: [BookChapter] = []
        let volumeState = TxtVolumeState()
        if let first = matches.first,
           first.start > Int64(bomLength),
           let preface = String(
               data: data.subdata(in: bomLength..<min(Int(first.start), data.count)),
               encoding: encoding
           ),
           !preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var insertedVolumes: [String] = []
            let title = transformedTitle(
                "前言",
                script: selectedRule?.replacement,
                index: chapters.count,
                book: book,
                volumeState: volumeState,
                onVolume: { insertedVolumes.append($0) }
            )
            for volumeTitle in insertedVolumes {
                var volume = BookChapter(url: "", title: volumeTitle, bookUrl: book.bookUrl, index: chapters.count)
                volume.start = Int64(bomLength)
                volume.end = Int64(bomLength)
                volume.baseUrl = book.bookUrl
                volume.isVolume = true
                chapters.append(volume)
            }
            if !title.isEmpty {
                var chapter = BookChapter(url: "", title: title, bookUrl: book.bookUrl, index: chapters.count)
                chapter.start = Int64(bomLength)
                chapter.end = first.start
                chapter.baseUrl = book.bookUrl
                chapters.append(chapter)
            }
        }
        for (matchIndex, match) in matches.enumerated() {
            splitLastLongChapterIfNeeded(
                &chapters,
                data: data,
                encoding: encoding,
                book: book,
                volumeState: volumeState,
                enabled: selectedRule != nil
            )
            var insertedVolumes: [String] = []
            let title = transformedTitle(
                match.title.isEmpty ? "第 \(matchIndex + 1) 章" : match.title,
                script: selectedRule?.replacement,
                index: chapters.count,
                previousTitle: previousTitle,
                previousLength: match.previousLength,
                book: book,
                volumeState: volumeState,
                onVolume: { insertedVolumes.append($0) }
            )
            previousTitle = title
            let start = match.end
            let end = matchIndex + 1 < matches.count ? matches[matchIndex + 1].start : Int64(data.count)
            for volumeTitle in insertedVolumes {
                let offset = chapters.last?.end ?? 0
                var volume = BookChapter(url: "local://chapter/\(chapters.count)", title: volumeTitle, bookUrl: book.bookUrl, index: chapters.count)
                volume.start = offset
                volume.end = offset
                volume.baseUrl = book.bookUrl
                volume.isVolume = true
                chapters.append(volume)
            }
            var chapter = BookChapter(url: "local://chapter/\(chapters.count)", title: title, bookUrl: book.bookUrl, index: chapters.count)
            chapter.start = start
            chapter.end = max(end, start)
            chapter.baseUrl = book.bookUrl
            chapters.append(chapter)
        }
        splitLastLongChapterIfNeeded(
            &chapters,
            data: data,
            encoding: encoding,
            book: book,
            volumeState: volumeState,
            enabled: selectedRule != nil
        )
        return finalized(chapters, book: book)
    }

    private var fallbackTocPattern: String {
        #"(?mi)^[\t ]*((?:第[0-9零〇一二三四五六七八九十百千万两]+[章节卷回部篇集][^\r\n]{0,50})|(?:chapter\s+\d+[^\r\n]{0,50}))[\t ]*$"#
    }

    private func splitLastLongChapterIfNeeded(
        _ chapters: inout [BookChapter],
        data: Data,
        encoding: String.Encoding,
        book: Book,
        volumeState: TxtVolumeState,
        enabled: Bool
    ) {
        guard enabled, book.readConfig?.splitLongChapter ?? true,
              var chapter = chapters.last,
              !chapter.isVolume,
              let startValue = chapter.start,
              let endValue = chapter.end,
              endValue - startValue > 102_400 else { return }
        let start = max(Int(startValue), 0)
        let end = min(max(Int(endValue), start), data.count)
        chapters.removeLast()
        chapter.end = chapter.start
        chapter.isVolume = true
        chapter.tag = nil
        chapters.append(chapter)
        volumeState.lastTitle = chapter.title
        chapters.append(contentsOf: splitByteRange(
            data,
            start: start,
            end: end,
            encoding: encoding,
            book: book,
            title: { "\(chapter.title)(\($0 + 1))" }
        ))
    }

    private func splitByteRange(
        _ data: Data,
        start initialStart: Int,
        end rangeEnd: Int,
        encoding: String.Encoding,
        book: Book,
        title: (Int) -> String
    ) -> [BookChapter] {
        splitHeadinglessRange(data, start: initialStart, end: rangeEnd, encoding: encoding, book: book) { _, _, index in title(index) }
    }

    private func headingMatches(
        data: Data,
        encoding: String.Encoding,
        bomLength: Int,
        pattern: String,
        usesFirstCapture: Bool
    ) -> [TxtHeadingMatch] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        if data.count <= 2 * 1_024 * 1_024,
           bomLength <= data.count,
           let text = String(data: data.subdata(in: bomLength..<data.count), encoding: encoding) {
            let source = text as NSString
            let offsets = byteOffsetMap(text, encoding: encoding, initialOffset: bomLength)
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
                let titleRange = usesFirstCapture && match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                let title = titleRange.location == NSNotFound ? "" : source.substring(with: titleRange)
                let start = min(match.range.location, offsets.count - 1)
                let end = min(NSMaxRange(match.range), offsets.count - 1)
                return .init(title: title, start: offsets[start], end: offsets[end], previousLength: match.range.location)
            }
        }
        let blockSize = 512_000
        var position = bomLength
        var output: [TxtHeadingMatch] = []
        while position < data.count {
            let limit = min(position + blockSize, data.count)
            var end = limit
            if limit < data.count,
               let newline = newlineIndex(in: data, range: position..<limit, encoding: encoding, fromEnd: true),
               newline > position {
                end = newline
            }
            if end <= position { end = limit }
            let blockData = data.subdata(in: position..<end)
            guard let block = String(data: blockData, encoding: encoding) else {
                position = end
                continue
            }
            let source = block as NSString
            let offsets = byteOffsetMap(block, encoding: encoding, initialOffset: position)
            var previousEnd = 0
            for match in expression.matches(in: block, range: NSRange(location: 0, length: source.length)) {
                let titleRange = usesFirstCapture && match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                let title = titleRange.location == NSNotFound ? "" : source.substring(with: titleRange)
                let startIndex = min(match.range.location, offsets.count - 1)
                let endIndex = min(NSMaxRange(match.range), offsets.count - 1)
                output.append(.init(
                    title: title,
                    start: offsets[startIndex],
                    end: offsets[endIndex],
                    previousLength: max(match.range.location - previousEnd, 0)
                ))
                previousEnd = NSMaxRange(match.range)
            }
            position = end
        }
        return output
    }

    private func chaptersWithoutTOC(_ data: Data, encoding: String.Encoding, bomLength: Int, book: Book) -> [BookChapter] {
        let chapters = splitHeadinglessRange(data, start: bomLength, end: data.count, encoding: encoding, book: book) {
            block, chapter, _ in "第\(block)章(\(chapter))"
        }
        return finalized(chapters, book: book)
    }

    private func splitHeadinglessRange(
        _ data: Data,
        start rangeStart: Int,
        end rangeEnd: Int,
        encoding: String.Encoding,
        book: Book,
        title: (Int, Int, Int) -> String
    ) -> [BookChapter] {
        let bufferSize = 512_000
        let maximumLength = 10 * 1_024
        var cursor = rangeStart
        var block = 0
        var output: [BookChapter] = []
        var finalChapterNumber = 0
        while cursor < rangeEnd {
            block += 1
            let blockEnd = min(cursor + bufferSize, rangeEnd)
            var chapterInBlock = 0
            while blockEnd - cursor > maximumLength {
                chapterInBlock += 1
                let searchStart = cursor + maximumLength
                let newline = newlineIndex(
                    in: data,
                    range: searchStart..<blockEnd,
                    encoding: encoding,
                    fromEnd: false
                )
                let end = newline ?? blockEnd
                var chapter = BookChapter(
                    url: "",
                    title: title(block, chapterInBlock, output.count),
                    bookUrl: book.bookUrl,
                    index: output.count
                )
                chapter.start = Int64(cursor)
                chapter.end = Int64(end)
                chapter.baseUrl = book.bookUrl
                output.append(chapter)
                cursor = end
            }
            finalChapterNumber = chapterInBlock + 1
            if blockEnd == rangeEnd { break }
        }
        if cursor < rangeEnd {
            if rangeEnd - cursor <= 100, !output.isEmpty {
                output[output.count - 1].end = Int64(rangeEnd)
            } else {
                var chapter = BookChapter(
                    url: "",
                    title: title(block, finalChapterNumber, output.count),
                    bookUrl: book.bookUrl,
                    index: output.count
                )
                chapter.start = Int64(cursor)
                chapter.end = Int64(rangeEnd)
                chapter.baseUrl = book.bookUrl
                output.append(chapter)
            }
        }
        return output
    }

    @discardableResult
    private func applyWordCounts(
        _ chapters: inout [BookChapter],
        data: Data,
        encoding: String.Encoding
    ) -> Int {
        var total = 0
        for index in chapters.indices where !chapters[index].isVolume {
            let start = max(Int(chapters[index].start ?? 0), 0)
            let end = min(max(Int(chapters[index].end ?? Int64(start)), start), data.count)
            guard start < end else {
                chapters[index].wordCount = ""
                continue
            }
            let text = String(data: data.subdata(in: start..<end), encoding: encoding) ?? ""
            let count = text.utf16.count
            chapters[index].wordCount = wordCountFormat(count)
            total += count
        }
        return total
    }

    private func wordCountFormat(_ words: Int) -> String {
        guard words > 0 else { return "" }
        guard words > 10_000 else { return "\(words)字" }
        let value = Double(words) / 10_000
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded { return "\(Int(rounded))万字" }
        return String(format: "%.1f万字", rounded)
    }

    private func finalized(_ chapters: [BookChapter], book: Book) -> [BookChapter] {
        chapters.enumerated().map { index, value in
            var chapter = value
            chapter.index = index
            chapter.bookUrl = book.bookUrl
            let seed = book.originName + String(index) + chapter.title
            let digest = Insecure.MD5.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            chapter.url = String(digest.dropFirst(8).prefix(16))
            return chapter
        }
    }

    private func rule(storedIn value: String) -> TxtTocRule? {
        guard !value.isEmpty else { return nil }
        let parts = value.components(separatedBy: TxtTocRuleSelector.separator)
        return .init(name: "本书目录规则", rule: parts[0], replacement: parts.dropFirst().first ?? "")
    }

    private func effectiveTocRules() -> [TxtTocRule] {
        tocRules
    }

    private func transformedTitle(
        _ value: String,
        script: String?,
        index: Int,
        previousTitle: String? = nil,
        previousLength: Int = -1,
        book: Book,
        volumeState: TxtVolumeState = .init(),
        onVolume: ((String) -> Void)? = nil
    ) -> String {
        guard let script = script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else { return value }
        let previous: String
        if let previousTitle,
           let data = try? JSONSerialization.data(withJSONObject: [previousTitle]),
           let encoded = String(data: data, encoding: .utf8) {
            previous = String(encoded.dropFirst().dropLast())
        } else {
            previous = "null"
        }
        let volumeLiteral = (try? JSONSerialization.data(withJSONObject: [volumeState.lastTitle]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let wrapped = """
        var index = \(index + 1); var prevTitle = \(previous); var prevLength = \(previousLength);
        var lastVolumeTitle = \(volumeLiteral);
        \(script)
        """
        guard let evaluated = try? JavaScriptRuleEvaluator().evaluate(
            script: wrapped,
            result: .string(value),
            executionContext: .init(page: index + 1, book: book)
        ) else { return value }
        let title = evaluated.value.stringValue
        let volumes = evaluated.variables["__legadoVolumes"]
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        for volume in volumes {
            volumeState.lastTitle = volume
            onVolume?(volume)
        }
        return title
    }

    private func encoding(named name: String) -> String.Encoding? {
        switch name.uppercased() {
        case "UTF-8", "UTF8": .utf8
        case "UTF-16", "UTF16": .utf16
        case "UTF-16LE", "UTF16LE": .utf16LittleEndian
        case "UTF-16BE", "UTF16BE": .utf16BigEndian
        case "GB18030", "GBK", "GB2312": .gb18030
        case "BIG5": .big5
        default: nil
        }
    }

    private func bomLength(in data: Data, encoding: String.Encoding) -> Int {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return 3 }
        if isUTF16(encoding),
           data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return 2 }
        return 0
    }

    private func isUTF16(_ encoding: String.Encoding) -> Bool {
        encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian
    }

    private func newlineIndex(
        in data: Data,
        range: Range<Int>,
        encoding: String.Encoding,
        fromEnd: Bool
    ) -> Int? {
        guard !range.isEmpty else { return nil }
        let bytePair: (UInt8, UInt8)?
        if encoding == .utf16LittleEndian || (encoding == .utf16 && data.starts(with: [0xFF, 0xFE])) {
            bytePair = (0x0A, 0x00)
        } else if encoding == .utf16BigEndian || (encoding == .utf16 && data.starts(with: [0xFE, 0xFF])) {
            bytePair = (0x00, 0x0A)
        } else {
            bytePair = nil
        }
        guard let bytePair else {
            return fromEnd ? data[range].lastIndex(of: 0x0A) : data[range].firstIndex(of: 0x0A)
        }
        var index = range.lowerBound + (range.lowerBound.isMultiple(of: 2) ? 0 : 1)
        guard index + 1 < range.upperBound else { return nil }
        if fromEnd {
            index = range.upperBound - 2
            if !index.isMultiple(of: 2) { index -= 1 }
            while index >= range.lowerBound {
                if data[index] == bytePair.0, data[index + 1] == bytePair.1 { return index }
                index -= 2
            }
        } else {
            while index + 1 < range.upperBound {
                if data[index] == bytePair.0, data[index + 1] == bytePair.1 { return index }
                index += 2
            }
        }
        return nil
    }

    private func byteOffsetMap(_ content: String, encoding: String.Encoding, initialOffset: Int) -> [Int64] {
        var offsets = [Int64](repeating: Int64(initialOffset), count: content.utf16.count + 1)
        var utf16Index = 0
        var byteOffset = initialOffset
        for scalar in content.unicodeScalars {
            let scalarText = String(scalar)
            let unitCount = scalarText.utf16.count
            let byteCount = isUTF16(encoding)
                ? unitCount * 2
                : (scalarText.data(using: encoding, allowLossyConversion: true)?.count ?? 0)
            if unitCount > 1 {
                for step in 1..<unitCount { offsets[utf16Index + step] = Int64(byteOffset) }
            }
            utf16Index += unitCount
            byteOffset += byteCount
            offsets[utf16Index] = Int64(byteOffset)
        }
        return offsets
    }

    private func textProbe(_ data: Data, encoding: String.Encoding) -> String {
        let prefix = Data(data.prefix(512_000))
        for removed in 0...8 where prefix.count >= removed {
            let candidate = prefix.dropLast(removed)
            if let value = String(data: Data(candidate), encoding: encoding) { return stripBOM(value) }
        }
        return ""
    }

    private func stripBOM(_ value: String) -> String {
        value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value
    }

    private func isPlausible(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let controls = value.unicodeScalars.filter { $0.value < 32 && !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return controls * 100 < max(value.unicodeScalars.count, 1)
    }
}

private extension String.Encoding {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)
    ))
}
