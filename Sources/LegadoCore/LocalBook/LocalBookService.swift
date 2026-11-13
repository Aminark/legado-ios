import CoreFoundation
import CryptoKit
import Foundation

public enum LocalBookError: Error, LocalizedError, Sendable {
    case unsupportedFormat
    case oversized
    case unreadableEncoding
    case missingFile
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "当前支持 TXT 和 EPUB 本地书"
        case .oversized: "本地书超过当前配置允许的大小"
        case .unreadableEncoding: "无法识别 TXT 编码"
        case .missingFile: "本地书文件已丢失"
        case .emptyFile: "TXT 文件没有正文"
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
            if Task.isCancelled { break }
            guard !rule.rule.isEmpty else { continue }
            guard let expression = try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines) else { continue }
            var start = 0
            var validCount = 0
            var shortGapCount = 0
            var lastTitle: String?
            for match in expression.matches(in: content, range: NSRange(location: 0, length: source.length)) {
                if Task.isCancelled { break }
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
    private var usesFallbackTocRule = true

    public init(maximumFileSize: Int64 = .max, tocRules: [TxtTocRule] = []) {
        self.maximumFileSize = maximumFileSize
        self.tocRules = tocRules.filter(\.enable).sorted { $0.serialNumber < $1.serialNumber }
    }

    public static func live() -> LocalBookService {
        LocalBookService(tocRules: TxtTocRuleDefaults.load())
    }

    public func usingStoredTocRules(from repository: SQLiteConfigurationRepository) async throws -> LocalBookService {
        var configured = self
        configured.tocRules = try await repository.loadTxtTocRules(initialDefaults: tocRules)
            .filter(\.enable).sorted { $0.serialNumber < $1.serialNumber }
        configured.usesFallbackTocRule = false
        return configured
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
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        let decoded = try decode(Data(data.prefix(512_000)), allowTruncatedTail: data.count > 512_000)
        guard data.count > bomLength(in: data, encoding: decoded.encoding) else { throw LocalBookError.emptyFile }

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
        } else if !usesFallbackTocRule {
            book.tocUrl = TxtTocRuleSelector.separator
        }
        let fullBOMLength = bomLength(in: data, encoding: decoded.encoding)
        var intro: String?
        var chapters = try chapters(
            data: data,
            encoding: decoded.encoding,
            bomLength: fullBOMLength,
            book: book,
            fallbackTitle: name,
            selectedRule: selectedRule,
            intro: &intro
        )
        let totalWordCount = try applyWordCounts(&chapters, data: data, encoding: decoded.encoding)
        book.wordCount = wordCountFormat(totalWordCount)
        book.intro = intro
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
        var intro: String?
        var chapters = try chapters(
            data: decoded.data,
            encoding: decoded.encoding,
            bomLength: decoded.bomLength,
            book: book,
            fallbackTitle: book.name,
            selectedRule: selectedRule,
            intro: &intro
        )
        _ = try applyWordCounts(&chapters, data: decoded.data, encoding: decoded.encoding)
        return .init(chapters: chapters)
    }

    /// Rebuild on the original file; nil selects from the current enabled rules,
    /// while an explicit empty rule requests byte-based chapters without a TOC.
    public func rebuildTextFile(
        book: Book, rule: TxtTocRule?, splitLongChapter: Bool,
        previousChapters: [BookChapter]
    ) throws -> LocalBookImportReport {
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              url.pathExtension.lowercased() == "txt" else { throw LocalBookError.unsupportedFormat }
        try Task.checkCancellation()
        if let rule, !rule.rule.isEmpty { _ = try NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines) }
        let decoded = try read(book)
        guard decoded.data.count > decoded.bomLength else { throw LocalBookError.emptyFile }
        var updated = book
        updated.charset = decoded.charset
        if updated.readConfig == nil { updated.readConfig = BookReadConfig() }
        updated.readConfig?.splitLongChapter = splitLongChapter
        let volumeState = TxtVolumeState()
        let selected = rule ?? TxtTocRuleSelector.select(
            content: textProbe(decoded.data, encoding: decoded.encoding), rules: effectiveTocRules()
        ) { rule, title, index, previous, length in
            transformedTitle(title, script: rule.replacement, index: index, previousTitle: previous,
                             previousLength: length, book: updated, volumeState: volumeState)
        }
        try Task.checkCancellation()
        updated.tocUrl = selected.map { $0.rule + TxtTocRuleSelector.separator + $0.replacement }
            ?? (usesFallbackTocRule ? "" : TxtTocRuleSelector.separator)
        var intro: String?
        var rebuilt = try chapters(data: decoded.data, encoding: decoded.encoding, bomLength: decoded.bomLength,
                               book: updated, fallbackTitle: updated.name, selectedRule: selected, intro: &intro)
        updated.wordCount = wordCountFormat(try applyWordCounts(&rebuilt, data: decoded.data, encoding: decoded.encoding))
        updated.intro = intro
        updated.totalChapterNum = rebuilt.count
        updated.latestChapterTitle = rebuilt.last?.title
        remapReadingPosition(&updated, from: previousChapters, to: rebuilt, data: decoded.data, encoding: decoded.encoding)
        return .init(book: updated, chapters: rebuilt)
    }

    private func remapReadingPosition(
        _ book: inout Book, from previous: [BookChapter], to chapters: [BookChapter],
        data: Data, encoding: String.Encoding
    ) {
        let readable = chapters.filter { !$0.isVolume }
        guard let first = readable.first else { return }
        let old = previous.first { $0.index == book.durChapterIndex }
        var anchor = old?.start ?? first.start ?? 0
        if let old, let raw = chapterText(old, data: data, encoding: encoding) {
            let leading = leadingWhitespaceLength(raw)
            let position = max(book.durChapterPos, 0)
            var rawPosition = min(raw.utf16.count, leading > 0 && position > 0 ? leading + max(position - 2, 0) : position)
            // Reader offsets are UTF-16. Clamp an offset inside an emoji to a
            // scalar boundary before converting that prefix back to file bytes.
            while rawPosition > 0,
                  String.Index(raw.utf16.index(raw.utf16.startIndex, offsetBy: rawPosition), within: raw) == nil {
                rawPosition -= 1
            }
            let prefix = (raw as NSString).substring(to: rawPosition)
            anchor += Int64(prefix.data(using: encoding)?.count ?? 0)
        }
        let chapter = readable.first { ($0.start ?? 0) <= anchor && anchor < ($0.end ?? 0) }
            ?? readable.last { ($0.start ?? 0) <= anchor } ?? first
        let start = max(Int(chapter.start ?? 0), 0)
        let end = min(Int(chapter.end ?? Int64(data.count)), data.count)
        let point = min(max(Int(anchor), start), end)
        let prefix = String(data: data.subdata(in: start..<point), encoding: encoding) ?? ""
        let raw = chapterText(chapter, data: data, encoding: encoding) ?? ""
        let leading = leadingWhitespaceLength(raw)
        book.durChapterIndex = chapter.index
        book.durChapterTitle = chapter.title
        book.durChapterPos = leading > 0 ? (prefix.utf16.count <= leading ? 0 : prefix.utf16.count - leading + 2) : prefix.utf16.count
    }

    private func chapterText(_ chapter: BookChapter, data: Data, encoding: String.Encoding) -> String? {
        let start = max(Int(chapter.start ?? 0), 0)
        let end = min(Int(chapter.end ?? Int64(data.count)), data.count)
        guard start <= end else { return nil }
        return String(data: data.subdata(in: start..<end), encoding: encoding)
    }

    private func leadingWhitespaceLength(_ text: String) -> Int {
        guard let range = text.range(of: #"^[\n\s]+"#, options: .regularExpression) else { return 0 }
        return text[range].utf16.count
    }

    public func loadContent(book: Book, chapter: BookChapter) throws -> ChapterContentReport {
        if let url = URL(string: book.bookUrl), url.isFileURL, url.pathExtension.lowercased() == "epub" {
            try validateFile(url)
            return try EPUBBook(url: url).content(chapter: chapter)
        }
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missingFile }
        try validateFile(url)
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
            if stored == .utf16 {
                try handle.seek(toOffset: 0)
                let marker = try handle.read(upToCount: 2) ?? Data()
                encoding = marker.starts(with: [0xFF, 0xFE]) ? .utf16LittleEndian : .utf16BigEndian
            } else { encoding = stored }
        } else {
            try handle.seek(toOffset: 0)
            let probe = try handle.read(upToCount: 512_000) ?? Data()
            encoding = try decode(probe, allowTruncatedTail: fileSize > probe.count).encoding
        }
        guard let decodedContent = String(data: contentData, encoding: encoding) else { throw LocalBookError.unreadableEncoding }
        let content = decodedContent.replacingOccurrences(of: #"^[\n\s]+"#, with: "　　", options: .regularExpression)
        return .init(title: chapter.title, content: content, pagesVisited: 1)
    }

    private func read(_ book: Book) throws -> (charset: String, encoding: String.Encoding, bomLength: Int, data: Data) {
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missingFile }
        try validateFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        if let charset = book.charset, let encoding = encoding(named: charset) {
            let concrete = encoding == .utf16
                ? (data.starts(with: [0xFF, 0xFE]) ? String.Encoding.utf16LittleEndian : .utf16BigEndian) : encoding
            let resolvedCharset = encoding == .utf16 ? (concrete == .utf16LittleEndian ? "UTF-16LE" : "UTF-16BE") : charset
            return (resolvedCharset, concrete, bomLength(in: data, encoding: concrete), data)
        }
        let decoded = try decode(Data(data.prefix(512_000)), allowTruncatedTail: data.count > 512_000)
        return (decoded.charset, decoded.encoding, bomLength(in: data, encoding: decoded.encoding), data)
    }

    private func decode(_ data: Data, allowTruncatedTail: Bool = false) throws -> (text: String, charset: String, encoding: String.Encoding, bomLength: Int) {
        let marked: (String, String.Encoding)?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { marked = ("UTF-8", .utf8) }
        else if data.starts(with: [0xFF, 0xFE]) { marked = ("UTF-16LE", .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { marked = ("UTF-16BE", .utf16BigEndian) }
        else { marked = nil }
        if let (name, encoding) = marked {
            guard let value = probeString(data, encoding: encoding, allowTruncatedTail: allowTruncatedTail) else {
                throw LocalBookError.unreadableEncoding
            }
            return (stripBOM(value), name, encoding, bomLength(in: data, encoding: encoding))
        }
        if let value = probeString(data, encoding: .utf8, allowTruncatedTail: allowTruncatedTail), isPlausible(value) {
            return (value, "UTF-8", .utf8, 0)
        }
        // Foundation can return no converted string for BOM-less UTF-16.
        // Require byte-order evidence from ASCII code units before trying it;
        // merely decoding an even-length GB/Big5 buffer as UTF-16 is ambiguous.
        if let encoding = unmarkedUTF16Encoding(in: data),
           let value = probeString(data, encoding: encoding, allowTruncatedTail: allowTruncatedTail),
           isPlausible(value) {
            return (value, encoding == .utf16LittleEndian ? "UTF-16LE" : "UTF-16BE", encoding, 0)
        }
        // Successful UTF-16 decoding alone proves nothing: most even-length GB
        // files also decode to unrelated UTF-16 characters. Use Foundation's
        // charset detector, as Android uses ICU detection, without lossy output.
        let candidates: [(String, String.Encoding)] = [
            ("GB18030", .gb18030), ("Big5", .big5),
            ("UTF-16LE", .utf16LittleEndian), ("UTF-16BE", .utf16BigEndian)
        ]
        for removed in 0...(allowTruncatedTail ? 3 : 0) where data.count > removed {
            let sample = Data(data.dropLast(removed))
            var converted: NSString?
            var lossy: ObjCBool = false
            let detected = NSString.stringEncoding(for: sample, encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.1.rawValue) },
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
                .likelyLanguageKey: "zh"
            ], convertedString: &converted, usedLossyConversion: &lossy)
            if let (name, encoding) = candidates.first(where: { $0.1.rawValue == detected }),
               !lossy.boolValue, let value = converted as String?, isPlausible(value) {
                return (stripBOM(value), name, encoding, 0)
            }
        }
        throw LocalBookError.unreadableEncoding
    }

    private func probeString(_ data: Data, encoding: String.Encoding, allowTruncatedTail: Bool) -> String? {
        for removed in 0...(allowTruncatedTail ? 3 : 0) where data.count >= removed {
            if let text = String(data: Data(data.dropLast(removed)), encoding: encoding) { return text }
        }
        return nil
    }

    private func unmarkedUTF16Encoding(in data: Data) -> String.Encoding? {
        let counts = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> (little: Int, big: Int) in
            var little = 0
            var big = 0
            func isASCIIText(_ byte: UInt8) -> Bool {
                byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte)
            }
            for index in stride(from: 0, to: max(bytes.count - 1, 0), by: 2) {
                if bytes[index + 1] == 0, isASCIIText(bytes[index]) { little += 1 }
                if bytes[index] == 0, isASCIIText(bytes[index + 1]) { big += 1 }
            }
            return (little, big)
        }
        if counts.little >= 4, counts.little > counts.big * 4 { return .utf16LittleEndian }
        if counts.big >= 4, counts.big > counts.little * 4 { return .utf16BigEndian }
        return nil
    }

    private func chapters(
        data: Data,
        encoding: String.Encoding,
        bomLength: Int,
        book: Book,
        fallbackTitle: String,
        selectedRule: TxtTocRule?,
        intro: inout String?
    ) throws -> [BookChapter] {
        let pattern = selectedRule?.rule ?? (usesFallbackTocRule ? fallbackTocPattern : "")
        let matches = try headingMatches(
            data: data,
            encoding: encoding,
            bomLength: bomLength,
            pattern: pattern,
            usesFirstCapture: selectedRule == nil
        )
        guard !matches.isEmpty else {
            if data.count - bomLength > 10 * 1_024 {
                return try chaptersWithoutTOC(data, encoding: encoding, bomLength: bomLength, book: book)
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
        func appendPreface(before boundary: Int64) {
            if boundary > Int64(bomLength),
               let preface = String(
                   data: data.subdata(in: bomLength..<min(Int(boundary), data.count)),
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
                // Android preserves a deliberately hidden preface in full in
                // the introduction, so suppressing its title never loses text.
                intro = !title.isEmpty && preface.utf16.count > 600 ? String(preface.prefix(600)) : preface
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
                    chapter.end = boundary
                    chapter.baseUrl = book.bookUrl
                    chapters.append(chapter)
                }
            }
        }
        var previousAcceptedEnd = Int64(bomLength)
        for (matchIndex, match) in matches.enumerated() {
            try Task.checkCancellation()
            if chapters.allSatisfy(\.isVolume) { appendPreface(before: match.start) }
            try splitLastLongChapterIfNeeded(
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
                previousLength: previousTitle == nil ? -1 : (String(
                    data: data.subdata(in: Int(previousAcceptedEnd)..<Int(match.start)), encoding: encoding
                )?.utf16.count ?? 0),
                book: book,
                volumeState: volumeState,
                onVolume: { insertedVolumes.append($0) }
            )
            let start = match.end
            let end = matchIndex + 1 < matches.count ? matches[matchIndex + 1].start : Int64(data.count)
            guard !title.isEmpty else {
                // A suppressed heading is ordinary body text. Extend the last
                // chapter through it instead of dropping bytes or adding an
                // unreadable chapter with an empty title.
                if let last = chapters.lastIndex(where: { !$0.isVolume }) { chapters[last].end = end }
                // putVolume is a script side effect even when the returned
                // heading is hidden. Keep a zero-length volume marker and the
                // body in the preceding readable chapter, without turning the
                // marker into a normal chapter on the next match.
                for volumeTitle in insertedVolumes {
                    var volume = BookChapter(url: "", title: volumeTitle, bookUrl: book.bookUrl, index: chapters.count)
                    volume.start = match.start
                    volume.end = match.start
                    volume.baseUrl = book.bookUrl
                    volume.isVolume = true
                    chapters.append(volume)
                }
                if let volumeTitle = insertedVolumes.last { previousTitle = volumeTitle }
                continue
            }
            if let last = chapters.indices.last, !chapters[last].isVolume,
               let priorStart = chapters[last].start,
               let body = String(data: data.subdata(in: Int(priorStart)..<Int(match.start)), encoding: encoding),
               body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters[last].isVolume = true
                volumeState.lastTitle = chapters[last].title
            }
            previousTitle = title
            previousAcceptedEnd = match.end
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
        if chapters.allSatisfy(\.isVolume) {
            var chapter = BookChapter(url: "", title: fallbackTitle, bookUrl: book.bookUrl, index: chapters.count)
            chapter.start = Int64(bomLength)
            chapter.end = Int64(data.count)
            chapter.baseUrl = book.bookUrl
            chapters.append(chapter)
            return finalized(chapters, book: book)
        }
        try splitLastLongChapterIfNeeded(
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
    ) throws {
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
        chapters.append(contentsOf: try splitByteRange(
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
    ) throws -> [BookChapter] {
        try splitHeadinglessRange(data, start: initialStart, end: rangeEnd, encoding: encoding, book: book) { _, _, index in title(index) }
    }

    private func headingMatches(
        data: Data,
        encoding: String.Encoding,
        bomLength: Int,
        pattern: String,
        usesFirstCapture: Bool
    ) throws -> [TxtHeadingMatch] {
        try Task.checkCancellation()
        guard !pattern.isEmpty else { return [] }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        if data.count <= 2 * 1_024 * 1_024,
           bomLength <= data.count,
           let text = String(data: data.subdata(in: bomLength..<data.count), encoding: encoding) {
            let source = text as NSString
            let offsets = try byteOffsetMap(text, encoding: encoding, initialOffset: bomLength)
            var previousEnd = 0
            return try expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
                try Task.checkCancellation()
                let titleRange = usesFirstCapture && match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                let title = titleRange.location == NSNotFound ? "" : source.substring(with: titleRange)
                let start = min(match.range.location, offsets.count - 1)
                let end = min(NSMaxRange(match.range), offsets.count - 1)
                defer { previousEnd = NSMaxRange(match.range) }
                return .init(title: title, start: offsets[start], end: offsets[end], previousLength: match.range.location - previousEnd)
            }
        }
        let blockSize = 512_000
        var position = bomLength
        var output: [TxtHeadingMatch] = []
        while position < data.count {
            try Task.checkCancellation()
            let limit = min(position + blockSize, data.count)
            var end = limit
            if limit < data.count,
               let newline = newlineIndex(in: data, range: position..<limit, encoding: encoding, fromEnd: true),
               newline > position {
                end = newline
            }
            if end <= position { end = limit }
            end = alignedBoundary(in: data, start: position, proposedEnd: end, encoding: encoding)
            let blockData = data.subdata(in: position..<end)
            guard let block = String(data: blockData, encoding: encoding) else {
                position = end
                continue
            }
            let source = block as NSString
            let offsets = try byteOffsetMap(block, encoding: encoding, initialOffset: position)
            var previousEnd = 0
            for match in expression.matches(in: block, range: NSRange(location: 0, length: source.length)) {
                try Task.checkCancellation()
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

    private func chaptersWithoutTOC(_ data: Data, encoding: String.Encoding, bomLength: Int, book: Book) throws -> [BookChapter] {
        let chapters = try splitHeadinglessRange(data, start: bomLength, end: data.count, encoding: encoding, book: book) {
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
    ) throws -> [BookChapter] {
        let bufferSize = 512_000
        let maximumLength = 10 * 1_024
        var cursor = rangeStart
        var block = 0
        var output: [BookChapter] = []
        var finalChapterNumber = 0
        while cursor < rangeEnd {
            try Task.checkCancellation()
            block += 1
            let blockEnd = alignedBoundary(in: data, start: cursor, proposedEnd: min(cursor + bufferSize, rangeEnd), encoding: encoding)
            var chapterInBlock = 0
            while blockEnd - cursor > maximumLength {
                try Task.checkCancellation()
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
    ) throws -> Int {
        var total = 0
        for index in chapters.indices where !chapters[index].isVolume {
            try Task.checkCancellation()
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
        guard let separator = value.range(of: TxtTocRuleSelector.separator) else {
            return .init(name: "本书目录规则", rule: value)
        }
        return .init(name: "本书目录规则", rule: String(value[..<separator.lowerBound]), replacement: String(value[separator.upperBound...]))
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

    private func alignedBoundary(in data: Data, start: Int, proposedEnd: Int, encoding: String.Encoding) -> Int {
        for removed in 0...3 where proposedEnd - removed > start {
            let end = proposedEnd - removed
            if String(data: data.subdata(in: start..<end), encoding: encoding) != nil { return end }
        }
        return proposedEnd
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

    private func byteOffsetMap(_ content: String, encoding: String.Encoding, initialOffset: Int) throws -> [Int64] {
        var offsets = [Int64](repeating: Int64(initialOffset), count: content.utf16.count + 1)
        var utf16Index = 0
        var byteOffset = initialOffset
        for scalar in content.unicodeScalars {
            if utf16Index.isMultiple(of: 1_024) { try Task.checkCancellation() }
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
