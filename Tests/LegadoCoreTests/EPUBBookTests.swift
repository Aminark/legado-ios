import Foundation
import Testing
import ZIPFoundation
@testable import LegadoCore

struct EPUBBookTests {
    @Test(arguments: [true, false]) func findsCoverInSVGWrappedTitlePageWithoutImageMetadata(guide: Bool) throws {
        let url = try archive([
            ("META-INF/container.xml", Data(#"<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#.utf8)),
            ("OPS/book.opf", Data("""
                <package><metadata><title>封面回归</title><meta name="cover" content="broken"/></metadata>
                <manifest><item id="title" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="broken" href="missing.jpg" media-type="image/jpeg" properties="cover-image"/>
                <item id="image" href="Images/封面.png" media-type="image/png"/></manifest>
                <spine><itemref idref="title"/></spine>
                \(guide ? "<guide><reference type=\"cover\" href=\"Text/cover.xhtml\"/></guide>" : "")</package>
                """.utf8)),
            ("OPS/Text/cover.xhtml", Data(#"<html><body><svg viewBox="0 0 100 140"><image xlink:href="../Images/封面.png"/></svg></body></html>"#.utf8)),
            ("OPS/Images/封面.png", png)
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.openFile(at: url)
        #expect(report.book.coverUrl?.hasPrefix("data:image/png;base64,") == true)
        #expect(try service.loadCover(at: url) != nil)
    }
    private let service = LocalBookService()
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAABxklEQVR4nNXCA3YjAABF0becsW12bNdIGptt7Nq2bXeMjc06/j2XI8UG6RwtMUrnWGmtdI6XmaRzotwsnZMVFumcqrRK53SVTTpnqu3SOVvjkM45g1M6540u6VyodUvnoskjnUtmr3QuW3zSuWL1S+eqLSCda/agdK47QtK54QxL56arTjq33PXSue2JSOeONyqdu76YdO7549K5H0hI50EwKZ2HoZR0isJp6Tyqy0jncX1WOk8iOek8jeal8yxWkM7zeIN0XiQapfMy2SSdV6lm6bxOt0jnTaZVOm+zbdJ5l2uXzvt8h3Q+FDql87GhSzqfGrul87mpRzpfmnulU9zSJ52S1n7plLYNSKesfVA65R1D0qnoHJZOZdeIdKq6R6VT3TMmnZrecekY+iakY+yflE7twJR0TIPT0jEPzUjHMjwrHevInHRso/PSsY8tSMcxvigd58SSdFyTy9JxT61IxzO9Kh3vzJp0fLPr0vHPbUgnML8pneDClnRCi9vSCS/tSKdueVc69St70oms7ksnunYgndj6oXTiG1+lk9j8Jp3k1nfppLZ/SCe981M6md1f0snu/ZZObv+PdPIHf6VTOPwn/T/zbe3/96qaXAAAAABJRU5ErkJggg==")!

    private func archive(_ files: [(String, Data)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("示例.EPUB")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: path == "mimetype" ? .none : .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    private func fixture(epub3: Bool = true, navigation: Bool = true, extras: [(String, Data)] = [], chapter: String? = nil) throws -> URL {
        let navItem = epub3
            ? #"<item id="nav" href="目录/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
            : #"<item id="nav" href="目录/toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(epub3 ? "3.0" : "2.0")">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>测试书籍</dc:title><dc:creator>作者甲</dc:creator><dc:creator>作者乙</dc:creator>
            <dc:description>&lt;p&gt;测试简介 &amp;amp; 内容&lt;/p&gt;</dc:description>
            <meta name="cover" content="cover"/>
          </metadata>
          <manifest>
            <item id="last" href="Text/end.xhtml" media-type="application/xhtml+xml"/>
            \(navigation ? navItem : "")
            <item id="main" href="Text/中文%20章节.xhtml" media-type="application/xhtml+xml"/>
            <item id="intro" href="Text/intro.xhtml" media-type="application/xhtml+xml"/>
            <item id="cover" href="Images/封面.png" media-type="image/png" properties="cover-image"/>
            <item id="extra" href="Text/extra.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="nav"><itemref idref="intro"/><itemref idref="main"/><itemref idref="extra"/><itemref idref="last"/></spine>
        </package>
        """
        let body = chapter ?? """
        <html><head><title>正文</title><style>不要显示样式</style></head><body>
          <p>锚点前的引言</p><section><h1 id="one">第一章</h1><p>甲 &amp; 乙<em>相遇</em>。</p>
          <script>不要显示脚本</script><p style="display: none">隐藏内容</p>
          <p><ruby>字<rt>zi</rt><rp>(zi)</rp></ruby>形</p><img src="../Images/封面.png" alt="风景"/></section>
          <section><div><h1 id="two">第二章</h1></div><p>第二章正文</p></section>
        </body></html>
        """
        let nav = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="landmarks"><a href="../Text/end.xhtml">错误地标</a></nav>
        <nav epub:type="toc"><ol><li><span>第一卷</span><ol>
        <li><a href="../Text/中文%20章节.xhtml#one">第一章</a></li>
        <li><a href="../Text/中文%20章节.xhtml#two">第二章</a></li></ol></li>
        <li><a href="../Text/end.xhtml">尾声</a></li></ol></nav></body></html>
        """
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
        <navPoint><navLabel><text>第一卷</text></navLabel>
          <navPoint><navLabel><text>第一章</text></navLabel><content src="../Text/中文%20章节.xhtml#one"/></navPoint>
          <navPoint><navLabel><text>第二章</text></navLabel><content src="../Text/中文%20章节.xhtml#two"/></navPoint>
        </navPoint><navPoint><navLabel><text>尾声</text></navLabel><content src="../Text/end.xhtml"/></navPoint>
        </navMap></ncx>
        """
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(#"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8)),
            ("OPS/book.opf", Data(package.utf8)),
            ("OPS/Text/intro.xhtml", Data("<html><head><title>序言</title></head><body><p>开篇内容</p></body></html>".utf8)),
            ("OPS/Text/中文 章节.xhtml", Data(body.utf8)),
            ("OPS/Text/extra.xhtml", Data("<html><body><h1>未列入目录</h1><p>不应遗漏正文</p></body></html>".utf8)),
            ("OPS/Text/end.xhtml", Data("<html><body><p>完结正文</p></body></html>".utf8)),
            ("OPS/Images/封面.png", png)
        ]
        if navigation { files.append((epub3 ? "OPS/目录/nav.xhtml" : "OPS/目录/toc.ncx", Data((epub3 ? nav : ncx).utf8))) }
        return try archive(files + extras)
    }

    @Test(arguments: [true, false]) func readsEPUB2And3MetadataSpineAnchorsAndIllustrations(epub3: Bool) throws {
        let url = try fixture(epub3: epub3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.openFile(at: url)
        #expect(report.book.name == "测试书籍")
        #expect(report.book.author == "作者甲、作者乙")
        #expect(report.book.intro == "测试简介 & 内容")
        #expect(report.book.coverUrl?.hasPrefix("data:image/png;base64,") == true)
        #expect(report.book.readConfig?.useReplaceRule == false)
        #expect(!report.book.canUpdate)
        #expect(report.chapters.map(\.title) == ["序言", "正文", "第一章", "第二章", "未列入目录", "尾声"])
        #expect(report.chapters.map(\.index) == Array(0..<6))
        #expect(Set(report.chapters.map(\.id)).count == 6)
        #expect(try service.loadChapters(book: report.book).chapters == report.chapters)
        let contents = try report.chapters.map { try service.loadContent(book: report.book, chapter: $0).content }
        #expect(contents[0] == "开篇内容")
        #expect(contents[1] == "锚点前的引言")
        #expect(contents[2] == "第一章\n甲 & 乙相遇。\n字形\n【插图 1：风景】")
        #expect(contents[3] == "第二章\n第二章正文")
        #expect(contents[4].contains("不应遗漏正文"))
        #expect(contents[5] == "完结正文")
        let images = try service.loadIllustrations(book: report.book, chapter: report.chapters[2])
        #expect(images.count == 1 && images.first?.data == png && images.first?.caption == "风景")
        #expect(try service.loadIllustrations(book: report.book, chapter: report.chapters[3]).isEmpty)
    }

    @Test func fallsBackToSpineWithoutNavigationAndDoesNotUseManifestOrder() throws {
        let url = try fixture(navigation: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.openFile(at: url)
        #expect(report.chapters.count == 4)
        #expect(report.chapters.first?.title == "序言")
        let body = try service.loadContent(book: report.book, chapter: report.chapters[1]).content
        #expect(body.contains("锚点前的引言") && body.contains("第一章") && body.contains("第二章正文"))
    }

    @Test func importsCopyPreservingMetadataAndOriginalFile() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.importFile(at: url, into: url.deletingLastPathComponent().appendingPathComponent("managed"))
        let destination = try #require(URL(string: report.book.bookUrl))
        #expect(destination != url && destination.pathExtension == "epub")
        #expect(report.book.originName == "示例.EPUB")
        #expect(try Data(contentsOf: destination) == Data(contentsOf: url))
        #expect(try service.loadContent(book: report.book, chapter: report.chapters[2]).content.contains("甲 & 乙"))
    }

    @Test func fileManagementPreservesEPUBOnRenameExportAndRemoval() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let root = url.deletingLastPathComponent()
        let files = LocalFileService(directory: root.appendingPathComponent("managed"))
        let first = try await files.importFile(from: url)
        let second = try await files.importFile(from: url)
        #expect(second.lastPathComponent == "示例 (2).EPUB")
        let renamed = try await files.rename(first, to: "新名字")
        #expect(renamed.pathExtension == "EPUB")
        #expect(try await files.list().count == 2)
        let exporter = BookFileExporter(directory: root.appendingPathComponent("exports"))
        let export = try await exporter.originalFile(renamed, filename: "测试书籍.epub")
        #expect(export.url.lastPathComponent == "测试书籍.epub")
        #expect(try Data(contentsOf: export.url) == Data(contentsOf: url))
        let staged = try #require(try await files.stageRemoval(renamed))
        try await files.restore(staged)
        #expect(try service.openFile(at: renamed).book.name == "测试书籍")
        let removed = try #require(try await files.stageRemoval(renamed))
        try await files.finishRemoval(removed)
        #expect(try await files.list().count == 1)
    }

    @Test func rejectsCorruptionTraversalEncryptionAndOversizeWithoutLeavingImportedFiles() throws {
        let good = try fixture()
        defer { try? FileManager.default.removeItem(at: good.deletingLastPathComponent()) }
        #expect(throws: LocalBookError.self) { try LocalBookService(maximumFileSize: 1).openFile(at: good) }
        let broken = good.deletingLastPathComponent().appendingPathComponent("损坏.epub")
        try Data("不是压缩包".utf8).write(to: broken)
        let managed = good.deletingLastPathComponent().appendingPathComponent("managed")
        #expect(throws: EPUBError.self) { try service.importFile(at: broken, into: managed) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).isEmpty)
        let malicious = try fixture(extras: [("../escape", Data("outside".utf8))])
        defer { try? FileManager.default.removeItem(at: malicious.deletingLastPathComponent()) }
        #expect(throws: EPUBError.self) { try service.openFile(at: malicious) }
        let encrypted = try fixture(extras: [("META-INF/encryption.xml", Data(#"<encryption><EncryptedData><CipherData><CipherReference URI="OPS/Text/中文%20章节.xhtml"/></CipherData></EncryptedData></encryption>"#.utf8))])
        defer { try? FileManager.default.removeItem(at: encrypted.deletingLastPathComponent()) }
        #expect(throws: EPUBError.self) { try service.openFile(at: encrypted) }
        let fontOnly = try fixture(extras: [("META-INF/encryption.xml", Data(#"<encryption><EncryptedData><CipherData><CipherReference URI="OPS/Fonts/font.otf"/></CipherData></EncryptedData></encryption>"#.utf8))])
        defer { try? FileManager.default.removeItem(at: fontOnly.deletingLastPathComponent()) }
        #expect(try service.openFile(at: fontOnly).chapters.count == 6)
    }

    @Test func rejectsForgedChapterResourceAndMissingAnchors() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.openFile(at: url)
        var chapter = report.chapters[2]
        chapter.resourceUrl = "../../outside"
        #expect(throws: EPUBError.self) { try service.loadContent(book: report.book, chapter: chapter) }
        chapter = report.chapters[2]
        chapter.startFragmentId = "missing"
        #expect(throws: EPUBError.self) { try service.loadContent(book: report.book, chapter: chapter) }
    }

    @Test func ignoresBadNavigationAnchorsAndOrdersValidAnchorsByDocumentPosition() throws {
        let url = try fixture(chapter: "<html><body><h1 id='two'>第二章</h1><p>先读</p><h1 id='one'>第一章</h1><p>后读</p></body></html>")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try service.openFile(at: url)
        #expect(report.chapters.map(\.title) == ["序言", "第二章", "第一章", "未列入目录", "尾声"])
        #expect(try service.loadContent(book: report.book, chapter: report.chapters[1]).content == "第二章\n先读")
    }
}
