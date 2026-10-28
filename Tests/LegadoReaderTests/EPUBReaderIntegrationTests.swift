import XCTest
import UIKit
import ReadiumShared
import ReadiumNavigator
import ZIPFoundation
@testable import Legado

@MainActor
final class EPUBReaderIntegrationTests: XCTestCase {
    func testOriginalCoverStylesImagesTablesAndRestoredLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("layout.epub")
        try makeEPUB(at: url)
        let report = try LocalBookService().openFile(at: url)
        XCTAssertNotNil(report.book.coverUrl)
        let model = EPUBReaderModel(book: report.book, chapters: report.chapters, initialIndex: 0)
        await model.open(preferences: .init(publisherStyles: true))
        XCTAssertNil(model.errorMessage)
        let navigator = try XCTUnwrap(model.navigator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigator
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await waitForJavaScript("!!document.querySelector('svg image')", in: navigator)
        XCTAssertEqual(model.tableOfContents.map { $0.link.title }, ["封面", "图文正文"])
        await model.go(to: ReadiumShared.Link(href: "Text/chapter.xhtml#body", mediaType: .xhtml))
        try await waitForJavaScript("document.querySelector('#illustration')?.complete && document.querySelector('#illustration').naturalWidth > 0 && getComputedStyle(document.querySelector('table')).borderTopStyle === 'solid' && document.querySelectorAll('td').length === 2", in: navigator)
        try await waitForLocation("Text/chapter.xhtml", in: model)
        let locator = try XCTUnwrap(model.location)
        XCTAssertEqual(EPUBReaderModel.path(locator.href.string), "Text/chapter.xhtml")
        var saved = report.book
        saved.readConfig?.epubLocation = locator.jsonString
        saved.durChapterIndex = try XCTUnwrap(model.currentChapter).index
        let restored = EPUBReaderModel(book: saved, chapters: report.chapters, initialIndex: saved.durChapterIndex)
        await restored.open(preferences: .init(fontSize: 1.4, publisherStyles: true))
        let reopened = try XCTUnwrap(restored.navigator)
        window.rootViewController = reopened
        window.layoutIfNeeded()
        try await waitForJavaScript("!!document.querySelector('#body') && !!document.querySelector('table')", in: reopened)
        try await waitForLocation("Text/chapter.xhtml", in: restored)
        XCTAssertEqual(EPUBReaderModel.path(try XCTUnwrap(restored.location).href.string), "Text/chapter.xhtml")
    }

    private func waitForLocation(_ path: String, in model: EPUBReaderModel) async throws {
        // Readium reports locations after the spread has finished laying out.
        for _ in 0..<100 {
            if let location = model.location, EPUBReaderModel.path(location.href.string) == path { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("EPUB location did not settle on \(path)")
    }

    private func waitForJavaScript(_ expression: String, in navigator: EPUBNavigatorViewController) async throws {
        for _ in 0..<150 {
            if let value = try? await navigator.evaluateJavaScript(expression).get() as? Bool, value { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("EPUB content did not render: \(expression)")
    }

    private func makeEPUB(at url: URL) throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAABxklEQVR4nNXCA3YjAABF0becsW12bNdIGptt7Nq2bXeMjc06/j2XI8UG6RwtMUrnWGmtdI6XmaRzotwsnZMVFumcqrRK53SVTTpnqu3SOVvjkM45g1M6540u6VyodUvnoskjnUtmr3QuW3zSuWL1S+eqLSCda/agdK47QtK54QxL56arTjq33PXSue2JSOeONyqdu76YdO7549K5H0hI50EwKZ2HoZR0isJp6Tyqy0jncX1WOk8iOek8jeal8yxWkM7zeIN0XiQapfMy2SSdV6lm6bxOt0jnTaZVOm+zbdJ5l2uXzvt8h3Q+FDql87GhSzqfGrul87mpRzpfmnulU9zSJ52S1n7plLYNSKesfVA65R1D0qnoHJZOZdeIdKq6R6VT3TMmnZrecekY+iakY+yflE7twJR0TIPT0jEPzUjHMjwrHevInHRso/PSsY8tSMcxvigd58SSdFyTy9JxT61IxzO9Kh3vzJp0fLPr0vHPbUgnML8pneDClnRCi9vSCS/tSKdueVc69St70oms7ksnunYgndj6oXTiG1+lk9j8Jp3k1nfppLZ/SCe981M6md1f0snu/ZZObv+PdPIHf6VTOPwn/T/zbe3/96qaXAAAAABJRU5ErkJggg==")!
        let files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(##"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"##.utf8)),
            ("book.opf", Data("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">layout-test</dc:identifier><dc:title>图文回归</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">2026-10-28T00:00:00Z</meta></metadata>
            <manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="body" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="image" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="css" href="Styles/book.css" media-type="text/css"/></manifest>
            <spine><itemref idref="cover"/><itemref idref="body"/></spine></package>
            """.utf8)),
            ("cover.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>封面</title></head><body><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 140"><image xlink:href="Images/cover.png" width="100" height="140"/></svg></body></html>"##.utf8)),
            ("Text/chapter.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>图文正文</title><link rel="stylesheet" href="../Styles/book.css"/></head><body><h1 id="body">图文正文</h1><p>图片与表格保留在原位置。</p><img id="illustration" src="../Images/cover.png" alt="内嵌插图"/><table><tr><td>项目</td><td>数值</td></tr></table><p><a href="#note">脚注</a></p><aside id="note">脚注内容</aside></body></html>"##.utf8)),
            ("nav.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="cover.xhtml">封面</a></li><li><a href="Text/chapter.xhtml#body">图文正文</a></li></ol></nav></body></html>"##.utf8)),
            ("Styles/book.css", Data("table { border: 3px solid #123456; } img { max-width: 80%; }".utf8)),
            ("Images/cover.png", png)
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
    }
}
