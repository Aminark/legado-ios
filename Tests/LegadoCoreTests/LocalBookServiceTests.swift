import Foundation
import CoreFoundation
import Testing
@testable import LegadoCore

struct LocalBookServiceTests {
    @Test func configuredRulesSeedOnceAndHonorDisabledOrDeletedRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try LegadoDatabase(url: root.appendingPathComponent("rules.sqlite3"))
        let repository = SQLiteConfigurationRepository(database: database)
        let rule = TxtTocRule(id: 1, name: "章节", rule: #"(?m)^第[一二三]章$"#)
        let source = root.appendingPathComponent("规则配置.txt")
        let body = String(repeating: "a", count: 1_100)
        try Data("第一章\n\(body)\n第二章\n\(body)\n第三章\n\(body)".utf8).write(to: source)
        let initial = LocalBookService(tocRules: [rule])
        let configured = try await initial.usingStoredTocRules(from: repository)
        #expect(try configured.openTextFile(at: source).chapters.count == 3)
        #expect(try await repository.loadTxtTocRules().count == 1)
        var disabled = rule
        disabled.enable = false
        try await repository.saveTxtTocRules([disabled])
        let stopped = try await initial.usingStoredTocRules(from: repository)
        let stoppedReport = try stopped.openTextFile(at: source)
        #expect(stoppedReport.chapters.count == 1)
        #expect(try LocalBookService().loadChapters(book: stoppedReport.book).chapters.count == 1)
        try await repository.saveTxtTocRules([])
        let cleared = try await initial.usingStoredTocRules(from: repository)
        #expect(try cleared.openTextFile(at: source).chapters.count == 1)
        #expect(try await repository.loadTxtTocRules(initialDefaults: [rule]).isEmpty)
    }

    @Test(arguments: [CFStringEncodings.GB_18030_2000, CFStringEncodings.big5])
    func detectsChineseLegacyEncodingWithoutMisclassifyingItAsUTF16(charset: CFStringEncodings) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("中文编码.txt")
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(charset.rawValue)))
        let body = charset == .big5 ? "繁體中文閱讀內容，今天我們閱讀一本小說。English 123。" : "简体中文阅读内容，今天我们阅读一本小说。English 123。"
        let text = "第一章 开始\n" + String(repeating: body + "\n", count: 100) + "第二章 完成\n" + body
        // Big5 cannot encode 开/始 in every converter; use shared CJK headings.
        let encodedText = text.replacingOccurrences(of: "开始", with: "相遇")
        try #require(encodedText.data(using: encoding)).write(to: source)
        let service = LocalBookService()
        let report = try service.openTextFile(at: source)
        #expect(report.book.charset == (charset == .big5 ? "Big5" : "GB18030"))
        #expect(report.chapters.map(\.title) == ["第一章 相遇", "第二章 完成"])
        #expect(try service.loadContent(book: report.book, chapter: report.chapters[1]).content == "　　" + body)
    }

    @Test func emptyImportRemovesStagedFileAndDoesNotCreateAChapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("empty.txt")
        try Data().write(to: source)
        let library = root.appendingPathComponent("library")
        #expect(throws: LocalBookError.emptyFile) { try LocalBookService().importTextFile(at: source, into: library) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
        try Data([0xEF, 0xBB, 0xBF]).write(to: source)
        #expect(throws: LocalBookError.emptyFile) { try LocalBookService().openTextFile(at: source) }
    }

    @Test func headinglessMultibyteTextRoundTripsAcrossByteBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("无换行正文.txt")
        let text = String(repeating: "中文🙂", count: 180_000)
        try Data(text.utf8).write(to: source)
        let service = LocalBookService()
        let report = try service.openTextFile(at: source)
        #expect(report.chapters.count > 1)
        let loaded = try report.chapters.map { try service.loadContent(book: report.book, chapter: $0).content }.joined()
        #expect(loaded == text)
    }

    @Test func titleSuppressionRetainsBodyAndUsesPreviousAcceptedHeadingContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("标题过滤.txt")
        let body = String(repeating: "正文", count: 650)
        let text = "章1\n\(body)\n章2\n隐藏标题后的正文\n章3\n\(body)\n章4\n\(body)"
        try Data(text.utf8).write(to: source)
        let rule = TxtTocRule(name: "章节", rule: #"(?m)^章\d$"#,
            replacement: "result === '章2' ? '' : result === '章3' ? prevTitle + '|' + prevLength + '|' + index : result")
        var book = Book(bookUrl: source.absoluteString, name: "标题过滤")
        book.charset = "UTF-8"
        book.tocUrl = rule.rule + TxtTocRuleSelector.separator + rule.replacement
        let service = LocalBookService()
        let chapters = try service.loadChapters(book: book).chapters
        let between = "\n\(body)\n章2\n隐藏标题后的正文\n"
        #expect(chapters.map(\.title) == ["章1", "章1|\(between.utf16.count)|2", "章4"])
        #expect(try service.loadContent(book: book, chapter: chapters[0]).content.contains("章2\n隐藏标题后的正文"))
        #expect(chapters.allSatisfy { !$0.title.isEmpty })
    }

    @Test func suppressedHeadingKeepsInsertedVolumeAndFollowingScriptContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("隐藏标题分卷.txt")
        try Data("章1\n甲\n章2\n乙\n章3\n丙".utf8).write(to: source)
        var book = Book(bookUrl: source.absoluteString, name: "隐藏标题分卷")
        book.tocUrl = #"(?m)^章\d$"# + TxtTocRuleSelector.separator
            + "if(result === '章2') { java.putVolume('卷二'); '' } else if(result === '章3') { prevTitle + '|' + index + '|' + prevLength } else { result }"
        let service = LocalBookService()
        let chapters = try service.loadChapters(book: book).chapters
        #expect(chapters.map(\.title) == ["章1", "卷二", "卷二|3|8"])
        #expect(chapters.map(\.isVolume) == [false, true, false])
        #expect(chapters[1].start == chapters[1].end)
        #expect(try service.loadContent(book: book, chapter: chapters[0]).content == "　　甲\n章2\n乙\n")
        #expect(try service.loadContent(book: book, chapter: chapters[2]).content == "　　丙")
    }

    @Test func suppressedOnlyHeadingWithVolumeStillHasReadableBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("仅卷标.txt")
        let text = "章1\n正文必须保留"
        try Data(text.utf8).write(to: source)
        var book = Book(bookUrl: source.absoluteString, name: "仅卷标")
        book.tocUrl = #"(?m)^章\d$"# + TxtTocRuleSelector.separator + "java.putVolume('卷一'); ''"
        let service = LocalBookService()
        let chapters = try service.loadChapters(book: book).chapters
        #expect(chapters.map(\.isVolume) == [true, false])
        #expect(chapters.first?.title == "卷一")
        #expect(try service.loadContent(book: book, chapter: chapters[1]).content == text)
    }

    @Test func titleScriptReceivesPreviousChapterLengthRatherThanAbsoluteFileOffset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("长度上下文.txt")
        try Data("章1\n甲\n章2\n乙乙\n章3\n丙".utf8).write(to: source)
        var book = Book(bookUrl: source.absoluteString, name: "长度上下文")
        book.charset = "UTF-8"
        book.tocUrl = #"(?m)^章\d$"# + TxtTocRuleSelector.separator + "result + '|' + prevLength"
        #expect(try LocalBookService().loadChapters(book: book).chapters.map(\.title) == ["章1|-1", "章2|3", "章3|4"])
    }

    @Test func storedRuleScriptRetainsSeparatorTextInsideJavaScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("脚本.txt")
        try Data("章1\n正文".utf8).write(to: source)
        var book = Book(bookUrl: source.absoluteString, name: "脚本")
        book.tocUrl = #"(?m)^章\d$"# + TxtTocRuleSelector.separator + "result + '\(TxtTocRuleSelector.separator)'"
        #expect(try LocalBookService().loadChapters(book: book).chapters.first?.title == "章1" + TxtTocRuleSelector.separator)
    }
    @Test func suppressedPrefaceIsPreservedInFullInIntroduction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("隐藏前言.txt")
        let preface = String(repeating: "前言内容", count: 200) + "\n"
        let body = String(repeating: "正文", count: 650)
        try Data("\(preface)章1\n\(body)\n章2\n\(body)\n章3\n结尾".utf8).write(to: source)
        let rule = TxtTocRule(name: "隐藏前言", rule: #"(?m)^章\d$"#,
            replacement: "result === '前言' ? '' : result")
        let service = LocalBookService(tocRules: [rule])
        let report = try service.openTextFile(at: source)
        #expect(report.book.intro == preface)
        #expect(report.chapters.map(\.title) == ["章1", "章2", "章3"])
        #expect(try service.loadContent(book: report.book, chapter: report.chapters[2]).content == "　　结尾")
        #expect(try service.loadChapters(book: report.book).chapters == report.chapters)
    }

    @Test func UTF16ProbeEndingInsideSurrogatePairStillReadsFullBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let heading = "第一章 开始"
        // BOM + prefix end at 511,998: the 512,000-byte probe contains
        // only the high surrogate of the emoji following this prefix.
        let prefix = heading + "\n" + String(repeating: "a", count: 255_998 - heading.utf16.count - 1)
        let text = prefix + "🙂正文\n第二章 结束\n结尾"
        for (encoding, bom, charset) in [
            (String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE], "UTF-16LE"),
            (String.Encoding.utf16BigEndian, [UInt8(0xFE), 0xFF], "UTF-16BE")
        ] {
            let source = root.appendingPathComponent("\(charset).txt")
            var data = Data(bom)
            data.append(try #require(text.data(using: encoding)))
            try data.write(to: source)
            let service = LocalBookService()
            let report = try service.openTextFile(at: source)
            #expect(report.book.charset == charset)
            #expect(report.chapters.map(\.title) == [heading, "第二章 结束"])
            let first = try service.loadContent(book: report.book, chapter: report.chapters[0]).content
            #expect(first == "　　" + String(prefix.dropFirst(heading.count + 1)) + "🙂正文\n")
            #expect(try service.loadContent(book: report.book, chapter: report.chapters[1]).content == "　　结尾")
        }
    }

    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian])
    func rebuildingMapsReadingPositionThroughFileBytesWithoutCopying(encoding: String.Encoding) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("重新分章.txt")
        let text = "第一章 起点\n正文🙂甲\n第二章 继续\n读到🙂目标位置\n第三章 尾声\n结束"
        var data = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : encoding == .utf16BigEndian ? Data([0xFE, 0xFF]) : Data()
        data.append(try #require(text.data(using: encoding)))
        try data.write(to: source)
        let service = LocalBookService()
        let original = try service.openTextFile(at: source)
        var reading = original.book
        reading.name = "保留自定义书名"
        reading.author = "作者"
        reading.group = 8
        reading.durChapterTime = 12345
        reading.durChapterIndex = 1
        reading.durChapterTitle = original.chapters[1].title
        let oldBody = try service.loadContent(book: reading, chapter: original.chapters[1]).content
        reading.durChapterPos = (oldBody as NSString).range(of: "目标位置").location
        let report = try service.rebuildTextFile(book: reading, rule: .init(name: "无标题", rule: ""),
                                                 splitLongChapter: false, previousChapters: original.chapters)
        #expect(report.chapters.count == 1)
        #expect(report.book.bookUrl == reading.bookUrl)
        #expect(report.book.name == reading.name && report.book.author == reading.author && report.book.group == 8)
        #expect(report.book.durChapterTime == reading.durChapterTime)
        #expect(report.book.readConfig?.splitLongChapter == false)
        let rebuiltBody = try service.loadContent(book: report.book, chapter: report.chapters[0]).content as NSString
        #expect(rebuiltBody.substring(from: report.book.durChapterPos).hasPrefix("目标位置"))
        #expect(try service.loadChapters(book: report.book).chapters == report.chapters)
        #expect(try Data(contentsOf: source) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [source.lastPathComponent])
    }

    @Test func genericUTF16StoredCharsetResolvesBOMForRebuildAndContentSlices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]), (.utf16BigEndian, [UInt8(0xFE), 0xFF])] {
            let source = root.appendingPathComponent("\(encoding.rawValue).txt")
            var data = Data(bom)
            data.append(try #require("第一章\n正文\n第二章\n🙂阅读位置".data(using: encoding)))
            try data.write(to: source)
            let service = LocalBookService()
            let original = try service.openTextFile(at: source)
            var reading = original.book
            reading.charset = "UTF-16"
            reading.durChapterIndex = 1
            reading.durChapterTitle = original.chapters[1].title
            reading.durChapterPos = 4
            #expect(try service.loadContent(book: reading, chapter: original.chapters[1]).content == "　　🙂阅读位置")
            let report = try service.rebuildTextFile(book: reading, rule: .init(name: "无标题", rule: ""),
                                                     splitLongChapter: false, previousChapters: original.chapters)
            #expect(report.book.charset == (encoding == .utf16LittleEndian ? "UTF-16LE" : "UTF-16BE"))
            let content = try service.loadContent(book: report.book, chapter: report.chapters[0]).content as NSString
            #expect(content.substring(from: report.book.durChapterPos).hasPrefix("阅读位置"))
        }
    }

    @Test func rebuildingLongChapterHonorsPerBookSplitSetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("长章重建.txt")
        let text = "第一章\n" + String(repeating: "长章正文\n", count: 12_000) + "第二章\n最后正文"
        try Data(text.utf8).write(to: source)
        let service = LocalBookService()
        let original = try service.openTextFile(at: source)
        let rule = TxtTocRule(name: "标题", rule: #"(?m)^第[一二]章$"#)
        let unsplit = try service.rebuildTextFile(book: original.book, rule: rule, splitLongChapter: false,
                                                  previousChapters: original.chapters)
        #expect(unsplit.chapters.map(\.title) == ["第一章", "第二章"])
        let split = try service.rebuildTextFile(book: unsplit.book, rule: rule, splitLongChapter: true,
                                                previousChapters: unsplit.chapters)
        #expect(split.chapters.first?.isVolume == true)
        #expect(split.chapters.count > unsplit.chapters.count)
        #expect(split.book.totalChapterNum == split.chapters.count)
        #expect(try service.loadChapters(book: split.book).chapters == split.chapters)
    }

    @Test func decodesDefaultTocRuleWithMissingReplacement() throws {
        let data = Data(#"{"id":-1,"name":"目录","rule":"^第.+章$","serialNumber":0,"enable":true}"#.utf8)
        let value = try JSONDecoder().decode(TxtTocRule.self, from: data)
        #expect(value.replacement == "")
        #expect(value.example == nil)
        #expect(value.enable)
    }

    @Test func importsUTF8TextSplitsChaptersAndReadsContent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "测试书.txt")
        let sourceData = Data("序言\n第一章 相遇\n这是第一章正文\n第二章 远行\n这是第二章正文".utf8)
        try sourceData.write(to: source)

        let service = LocalBookService()
        let report = try service.importTextFile(at: source, into: root.appending(path: "library"))

        #expect(report.book.origin == "local")
        #expect(report.book.charset == "UTF-8")
        #expect(report.chapters.map(\.title) == ["前言", "第一章 相遇", "第二章 远行"])
        #expect(report.chapters[1].url == "82e56047094237f3")
        let firstTitle = try #require(sourceData.range(of: Data("第一章 相遇".utf8)))
        let secondTitle = try #require(sourceData.range(of: Data("第二章 远行".utf8)))
        #expect(report.chapters[1].start == Int64(firstTitle.upperBound))
        #expect(report.chapters[1].end == Int64(secondTitle.lowerBound))
        #expect(report.chapters.map(\.wordCount) == ["3字", "9字", "8字"])
        #expect(report.book.wordCount == "20字")
        #expect(report.book.intro == "序言\n")
        let content = try service.loadContent(book: report.book, chapter: report.chapters[1])
        #expect(content.content == "　　这是第一章正文\n")
        #expect(FileManager.default.fileExists(atPath: try #require(URL(string: report.book.bookUrl)).path))
    }

    @Test func createsSingleChapterWhenNoHeadingExists() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "短篇.txt")
        try Data("这是一个没有章节标题的短篇。".utf8).write(to: source)

        let report = try LocalBookService().importTextFile(at: source, into: root.appending(path: "library"))

        #expect(report.chapters.count == 1)
        #expect(report.chapters[0].title == "短篇")
        #expect(try LocalBookService().loadContent(book: report.book, chapter: report.chapters[0]).content == "这是一个没有章节标题的短篇。")
    }

    @Test func splitsLongHeadinglessTextAtTenKiBThreshold() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "无目录长文.txt")
        let paragraph = String(repeating: "a", count: 10_500)
        try Data("\(paragraph)\n\(paragraph)\n尾声".utf8).write(to: source)

        let report = try LocalBookService(tocRules: []).importTextFile(
            at: source,
            into: root.appending(path: "library")
        )

        #expect(report.chapters.count == 2)
        #expect(report.chapters.map(\.title) == ["第1章(1)", "第1章(2)"])
        #expect(report.chapters[0].end == report.chapters[1].start)
        #expect(report.book.wordCount == "2.1万字")
        #expect(report.book.intro == nil)
    }

    @Test func numbersHeadinglessChaptersBy512KBBlock() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "多块无目录.txt")
        let paragraph = String(repeating: "a", count: 10_500) + "\n"
        try Data(String(repeating: paragraph, count: 55).utf8).write(to: source)

        let report = try LocalBookService(tocRules: []).importTextFile(
            at: source,
            into: root.appending(path: "library")
        )

        #expect(report.chapters.first?.title == "第1章(1)")
        #expect(report.chapters.contains { $0.title.hasPrefix("第2章(") })
        for index in 1..<report.chapters.count {
            #expect(report.chapters[index - 1].end == report.chapters[index].start)
        }
    }

    @Test func selectsCustomTocRuleAndRunsTitleScript() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "自定义目录.txt")
        let body = String(repeating: "正文", count: 650)
        try Data("卷1 开始\n\(body)\n卷2 继续\n\(body)\n卷3 结束\n\(body)".utf8).write(to: source)
        let rule = TxtTocRule(
            name: "卷标题",
            rule: #"(?m)^卷\d+[^\r\n]*$"#,
            replacement: "result.replace('卷', '第')",
            serialNumber: 1
        )

        let report = try LocalBookService(tocRules: [rule]).importTextFile(
            at: source,
            into: root.appending(path: "library")
        )

        #expect(report.book.tocUrl == rule.rule + TxtTocRuleSelector.separator + rule.replacement)
        #expect(report.chapters.map(\.title) == ["第1 开始", "第2 继续", "第3 结束"])
    }

    @Test func tocRuleSelectorKeepsEarlierRuleUnlessLaterWinsByMoreThanTwo() {
        let body = String(repeating: "字", count: 1_100)
        let content = "A1\n\(body)\nA2\n\(body)\nA3\n\(body)\nB1\n\(body)\nB2\n\(body)\nB3\n\(body)\nB4"
        let first = TxtTocRule(id: 1, name: "A", rule: #"(?m)^A\d$"#, serialNumber: 1)
        let second = TxtTocRule(id: 2, name: "B", rule: #"(?m)^B\d$"#, serialNumber: 2)

        #expect(TxtTocRuleSelector.select(content: content, rules: [first, second])?.id == first.id)
    }

    @Test func titleScriptPutVolumeInsertsVolumeChapter() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "分卷.txt")
        let body = String(repeating: "正文", count: 650)
        try Data("章1\n\(body)\n章2\n\(body)\n章3\n\(body)".utf8).write(to: source)
        let rule = TxtTocRule(
            name: "脚本分卷",
            rule: #"(?m)^章\d$"#,
            replacement: "if (index === 2) java.putVolume('第二卷'); result;",
            serialNumber: 1
        )

        let report = try LocalBookService(tocRules: [rule]).importTextFile(
            at: source,
            into: root.appending(path: "library")
        )

        #expect(report.chapters.map(\.title) == ["章1", "第二卷", "章2", "章3"])
        #expect(report.chapters.map(\.isVolume) == [false, true, false, false])
        #expect(report.chapters[1].start == report.chapters[1].end)
    }

    @Test func scansHeadingsAcross512KBBlocksAndReadsByByteRange() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "跨块.txt")
        let longBody = String(repeating: "段落内容\n", count: 50_000)
        let sourceData = Data("第一章 开始\n\(longBody)第二章 结束\n结尾".utf8)
        try sourceData.write(to: source)

        let report = try LocalBookService().importTextFile(
            at: source,
            into: root.appending(path: "library")
        )
        let secondTitle = try #require(sourceData.range(of: Data("第二章 结束".utf8)))

        #expect(report.chapters.map(\.title) == ["第一章 开始", "第二章 结束"])
        #expect(report.chapters[0].end == Int64(secondTitle.lowerBound))
        #expect(report.chapters[1].start == Int64(secondTitle.upperBound))
        #expect(try LocalBookService().loadContent(book: report.book, chapter: report.chapters[1]).content == "　　结尾")
    }

    @Test func preservesUTF16EndianBoundariesAcross512KBBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "第一章 开始\n\(String(repeating: "段落内容\n", count: 70_000))第二章 结束\n结尾"
        let fixtures: [(String, String.Encoding, [UInt8], String)] = [
            ("LE", .utf16LittleEndian, [0xFF, 0xFE], "UTF-16LE"),
            ("BE", .utf16BigEndian, [0xFE, 0xFF], "UTF-16BE")
        ]

        for (suffix, encoding, bom, charset) in fixtures {
            let source = root.appending(path: "UTF16\(suffix).txt")
            var sourceData = Data(bom)
            sourceData.append(try #require(text.data(using: encoding)))
            try sourceData.write(to: source)
            let report = try LocalBookService().importTextFile(
                at: source,
                into: root.appending(path: "library-\(suffix)")
            )
            let titleData = try #require("第二章 结束".data(using: encoding))
            let titleRange = try #require(sourceData.range(of: titleData))
            let second = try #require(report.chapters.first(where: { $0.title == "第二章 结束" }))

            #expect(report.book.charset == charset)
            #expect(second.start == Int64(titleRange.upperBound))
            #expect(try LocalBookService().loadContent(book: report.book, chapter: second).content == "　　结尾")
        }
    }

    @Test func splitsOversizedTocChapterIntoVolumeAndUpdatesFollowingScriptState() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "超长章节.txt")
        let longBody = String(repeating: "正文内容\n", count: 12_000)
        try Data("第一章\n\(longBody)第二章\n结尾".utf8).write(to: source)
        let rule = TxtTocRule(
            name: "长章脚本",
            rule: #"(?m)^第[一二]章$"#,
            replacement: "result === '第二章' ? lastVolumeTitle + '|' + index + '|' + result : result",
            serialNumber: 1
        )

        let report = try LocalBookService(tocRules: [rule]).importTextFile(
            at: source,
            into: root.appending(path: "library")
        )

        #expect(report.chapters.first?.title == "第一章")
        #expect(report.chapters.first?.isVolume == true)
        #expect(report.chapters.dropFirst().contains { $0.title == "第一章(1)" })
        #expect(report.chapters.last?.title.hasPrefix("第一章|") == true)
        #expect(report.chapters.last?.title.hasSuffix("|第二章") == true)
    }
}
