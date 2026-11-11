import CoreFoundation
import Foundation
import Testing
@testable import LegadoCore

struct TXTEncodingRegressionTests {
    enum Fixture: String, CaseIterable, Sendable {
        case gb2312, gbk, gb18030, big5, utf8, utf8BOM
        case utf16LE, utf16BE, utf16LEWithoutBOM, utf16BEWithoutBOM

        var encoding: String.Encoding {
            switch self {
            // Foundation cannot encode GB2312 on every OS. These fixtures use
            // only its shared repertoire, whose bytes are identical in GB18030.
            case .gb2312: Self.encoding(.GB_18030_2000)
            case .gbk: Self.encoding(.GBK_95)
            case .gb18030: Self.encoding(.GB_18030_2000)
            case .big5: Self.encoding(.big5)
            case .utf8, .utf8BOM: .utf8
            case .utf16LE, .utf16LEWithoutBOM: .utf16LittleEndian
            case .utf16BE, .utf16BEWithoutBOM: .utf16BigEndian
            }
        }

        var charset: String {
            switch self {
            case .gb2312, .gbk, .gb18030: "GB18030"
            case .big5: "Big5"
            case .utf8, .utf8BOM: "UTF-8"
            case .utf16LE, .utf16LEWithoutBOM: "UTF-16LE"
            case .utf16BE, .utf16BEWithoutBOM: "UTF-16BE"
            }
        }

        var bom: Data {
            switch self {
            case .utf8BOM: Data([0xEF, 0xBB, 0xBF])
            case .utf16LE: Data([0xFF, 0xFE])
            case .utf16BE: Data([0xFE, 0xFF])
            default: Data()
            }
        }

        var boundaryCharacter: String {
            switch self {
            case .gb2312, .big5: "中"
            case .gbk: "龘"
            case .gb18030: "𠀀"
            default: "🙂"
            }
        }

        private static func encoding(_ charset: CFStringEncodings) -> String.Encoding {
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(charset.rawValue)))
        }
    }

    // Issue #11: exercise complete and partial characters at the 512,000-byte
    // probe boundary, with generated data instead of bundling large TXT files.
    @Test(arguments: Fixture.allCases)
    func importsAndRereadsEveryProbeBoundary(fixture: Fixture) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoding = fixture.encoding
        let heading = "第一章 相遇"
        let line = fixture == .big5 ? "這是程式生成的編碼測試資料。\n" : "这是程序生成的编码测试数据。\n"
        // Existing replacement characters are valid UTF-8 and must not count
        // as decoding errors. The Big5 prefix is also decodable as GB18030.
        let initialBody = fixture == .big5 ? "尺測堣測\n" : encoding == .utf8 ? "已有替换字符：���\n" : ""
        let initialBytes = try #require((heading + "\n" + initialBody).data(using: encoding)).count
        let lineBytes = try #require(line.data(using: encoding)).count
        let asciiWidth = try #require("a".data(using: encoding)).count
        let characterWidth = try #require(fixture.boundaryCharacter.data(using: encoding)).count
        let service = LocalBookService()

        for retainedBytes in 0...characterWidth {
            let available = 512_000 - fixture.bom.count - initialBytes - retainedBytes
            guard available.isMultiple(of: asciiWidth) else { continue }
            let body = initialBody + String(repeating: line, count: available / lineBytes)
                + String(repeating: "a", count: (available % lineBytes) / asciiWidth)
                + fixture.boundaryCharacter + "\n"
            let text = heading + "\n" + body + "第二章\nTEST END\n"
            var data = fixture.bom
            data.append(try #require(text.data(using: encoding)))
            let source = root.appendingPathComponent("\(fixture.rawValue)-\(retainedBytes).txt")
            try data.write(to: source)
            let report = try service.importTextFile(at: source, into: root.appendingPathComponent("library"))

            #expect(report.book.charset == fixture.charset)
            #expect(report.chapters.map(\.title) == [heading, "第二章"])
            let first = try #require(report.chapters.first)
            let second = try #require(report.chapters.last)
            #expect(try service.loadContent(book: report.book, chapter: first).content == "　　" + body)
            #expect(try service.loadContent(book: report.book, chapter: second).content == "　　TEST END\n")
            #expect(try Data(contentsOf: #require(URL(string: report.book.bookUrl))) == data)

            // Older library entries may have no saved charset: both directory
            // rebuilding and direct chapter reading must detect it again.
            var withoutCharset = report.book
            withoutCharset.charset = nil
            #expect(try service.loadChapters(book: withoutCharset).chapters == report.chapters)
            #expect(try service.loadContent(book: withoutCharset, chapter: first).content == "　　" + body)
        }
    }

    @Test(arguments: [Fixture.utf8BOM, .utf16LE, .utf16BE])
    func incompleteCharacterAtActualEOFIsRejected(fixture: Fixture) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("incomplete.txt")
        var data = fixture.bom
        data.append(try #require("第一章\n正文🙂".data(using: fixture.encoding)).dropLast())
        try data.write(to: source)
        let library = root.appendingPathComponent("library")
        #expect(throws: LocalBookError.unreadableEncoding) {
            try LocalBookService().importTextFile(at: source, into: library)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }
}
