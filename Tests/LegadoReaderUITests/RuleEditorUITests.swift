import XCTest

@MainActor
final class RuleEditorUITests: XCTestCase {
    func testOnlineSourceEntryOpensTheInternalBrowser() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["在线书源"].tap()
        XCTAssertTrue(app.navigationBars["在线书源"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["喵公子书源"].exists)
        app.staticTexts["开源阅读 · 九月书源更新"].tap()
        XCTAssertTrue(app.navigationBars["阅读书源分享"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "Online source catalog in the internal browser")
        app.navigationBars["阅读书源分享"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["在线书源"].waitForExistence(timeout: 10))
        app.staticTexts["喵公子书源"].tap()
        XCTAssertTrue(app.navigationBars["阅读书源分享"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "Miaogongzi catalog in the internal browser")
    }


    func testRSSSearchSubmissionPaginationAndFavorites() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LEGADO_RSS_UI_FIXTURE_URL"] else {
            throw XCTSkip("Set LEGADO_RSS_UI_FIXTURE_URL to the local RSS fixture source URL")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["RSS"].waitForExistence(timeout: 20))
        // Replace an existing source in this launch, so a cached navigation
        // destination cannot silently keep using the previous content rules.
        for url in [fixture + "?legacy=1", fixture] {
            app.buttons["RSS操作"].tap()
            app.buttons["URL或粘贴JSON"].tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            editor.typeText(url)
            app.navigationBars["导入RSS源"].buttons["导入"].tap()
            let dismissed = expectation(for: NSPredicate { _, _ in !app.navigationBars["导入RSS源"].exists }, evaluatedWith: nil)
            wait(for: [dismissed], timeout: 10)
        }
        let source = app.staticTexts["RSS 全流程测试"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        XCTAssertTrue(app.staticTexts["首页文章"].waitForExistence(timeout: 10))
        let search = app.searchFields["源内搜索"]
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("needle\n")
        let result = app.staticTexts["搜索结果 needle 第1页"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let nextPage = app.buttons["加载下一页"]
        let ready = expectation(for: NSPredicate { _, _ in nextPage.exists && nextPage.isEnabled }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        nextPage.tap()
        XCTAssertTrue(app.staticTexts["搜索结果 needle 第2页"].waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.navigationBars["文章"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["第1次加载的订阅正文"].waitForExistence(timeout: 10))
        app.buttons["阅读操作"].tap()
        app.buttons["刷新"].tap()
        XCTAssertTrue(app.webViews.staticTexts["第2次加载的订阅正文"].waitForExistence(timeout: 10))
        if app.buttons["取消收藏"].exists { app.buttons["取消收藏"].tap() }
        XCTAssertTrue(app.buttons["收藏"].waitForExistence(timeout: 5))
        app.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
        app.navigationBars["文章"].buttons.element(boundBy: 0).tap()
        let cancelSearch = app.navigationBars["RSS 全流程测试"].buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "取消", "Close", "关闭"]
        )).firstMatch
        if cancelSearch.exists { cancelSearch.tap() }
        app.navigationBars["RSS 全流程测试"].buttons["RSS"].tap()
        XCTAssertTrue(app.navigationBars["RSS"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["收藏"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        attach(app, name: "RSS search article saved to favorites")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["RSS 全流程测试"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["收藏"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
    }

    func testBookshelfFilePickerImportsTXTAndEPUBAndDisablesJSON() throws {
        try exerciseLocalBookImport(fromFileManagement: false)
    }

    func testFileManagementFilePickerImportsTXTAndEPUBAndDisablesJSON() throws {
        try exerciseLocalBookImport(fromFileManagement: true)
    }

    private func exerciseLocalBookImport(fromFileManagement: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-themeMode", "1", "-bookshelfLayout", "grid3", "-pageAnim", "0"]
        if fromFileManagement { app.launchArguments += ["-uiDemoTab", "settings", "-uiDemoFiles"] }
        app.launch()
        let importTitle = fromFileManagement ? "导入 TXT / EPUB" : "本地书"
        let more = fromFileManagement
            ? app.navigationBars["文件管理"].buttons["更多"].firstMatch
            : app.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons[importTitle].firstMatch.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let closed = expectation(for: NSPredicate { _, _ in !cancel.exists }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
        more.tap()
        app.buttons[importTitle].firstMatch.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))

        let pickerFiles = app.collectionViews["File View"].cells
        let txt = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch
        let fixtureJSON = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Source")).firstMatch
        let fixtures = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "书源导入测试")).firstMatch
        // The file-management page underneath the picker can also contain TXT.
        // JSON exists only inside our fixture folder in the actual picker.
        if !fixtureJSON.waitForExistence(timeout: 3) {
            if !fixtures.exists {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览", "Locations", "位置"])).firstMatch
                if browse.exists { browse.tap() }
                if !fixtures.waitForExistence(timeout: 2) {
                    let local = app.descendants(matching: .any).matching(NSPredicate(
                        format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@", "我的 iPhone", "我的iPhone", "On My iPhone"
                    )).firstMatch
                    XCTAssertTrue(local.waitForExistence(timeout: 5))
                    local.tap()
                }
            }
            XCTAssertTrue(fixtures.waitForExistence(timeout: 10), "Run sh scripts/prepare-source-import-fixture.sh <simulator-UUID>")
            fixtures.tap()
        }
        XCTAssertTrue(txt.waitForExistence(timeout: 10))
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Import", "导入"])).firstMatch
        for name in ["JSON-Source", "JSON-Uppercase"] {
            let json = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(json.waitForExistence(timeout: 5))
            XCTAssertFalse(json.isEnabled)
            json.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(open.exists && open.isEnabled, "JSON must not be selectable as a local book")
        }
        txt.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let uppercase = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Uppercase")).firstMatch
        XCTAssertTrue(uppercase.waitForExistence(timeout: 5))
        uppercase.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let epub = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "EPUB-Book")).firstMatch
        XCTAssertTrue(epub.waitForExistence(timeout: 5))
        XCTAssertTrue(epub.isEnabled)
        epub.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        attach(app, name: "TXT selectable and JSON excluded")
        open.tap()

        if fromFileManagement {
            XCTAssertTrue(app.navigationBars["文件管理"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.alerts["文件操作失败"].waitForExistence(timeout: 3), app.debugDescription)
            app.tabBars.buttons["书架"].tap()
        } else {
            XCTAssertTrue(app.navigationBars["导入本地书"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["JSON-Source.json"].exists)
            XCTAssertFalse(app.staticTexts["JSON-Uppercase.JSON"].exists)
            XCTAssertTrue(app.staticTexts["TXT-Book.txt"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["TXT-Uppercase.TXT"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["导入"].tap()
        }
        // Repeated runs preserve managed files and correctly add a numeric suffix.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Uppercase")).firstMatch.waitForExistence(timeout: 15))
        let epubBook = app.staticTexts["EPUB 导入测试"].firstMatch
        XCTAssertTrue(epubBook.waitForExistence(timeout: 15))
        attach(app, name: "Local TXT and EPUB books imported onto shelf")
        epubBook.tap()
        let reader = app.webViews.firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        XCTAssertTrue(reader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这是 EPUB 导入后的第一章正文")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(reader.images["测试插图"].waitForExistence(timeout: 10))
        attach(app, name: "EPUB original layout with inline illustration")
        app.buttons["目录"].tap()
        app.buttons["第二章 EPUB"].firstMatch.tap()
        let secondChapter = reader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "目录锚点跳转成功")).firstMatch
        XCTAssertTrue(secondChapter.waitForExistence(timeout: 10))
        attach(app, name: "EPUB original layout after TOC navigation")
    }

    func testJSONFilePickerOffersOpenAndImportsSelectedFiles() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["从文件导入"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let pickerClosed = expectation(for: NSPredicate { _, _ in
            !cancel.exists && app.navigationBars["书源"].buttons["更多"].isHittable
        }, evaluatedWith: nil)
        wait(for: [pickerClosed], timeout: 10)
        app.buttons["更多"].firstMatch.tap()
        app.buttons["从文件导入"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))

        let json = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Source")).firstMatch
        let fixtures = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "书源导入测试")).firstMatch
        if !json.waitForExistence(timeout: 3) {
            if !fixtures.exists {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览", "Locations", "位置"])).firstMatch
                if browse.exists { browse.tap() }
                if !fixtures.waitForExistence(timeout: 2) {
                    let local = app.descendants(matching: .any).matching(NSPredicate(
                        format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@", "我的 iPhone", "我的iPhone", "On My iPhone"
                    )).firstMatch
                    if !local.waitForExistence(timeout: 5) { print("[SourceFilePicker] \(app.debugDescription)") }
                    XCTAssertTrue(local.exists)
                    local.tap()
                }
            }
            XCTAssertTrue(fixtures.waitForExistence(timeout: 10), "Run sh scripts/prepare-source-import-fixture.sh <simulator-UUID> before this test")
            fixtures.tap()
        }
        XCTAssertTrue(json.waitForExistence(timeout: 10))
        json.tap()
        let uppercase = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Uppercase")).firstMatch
        XCTAssertTrue(uppercase.waitForExistence(timeout: 5))
        uppercase.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Import", "导入"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        attach(app, name: "JSON files selected with Open available")
        open.tap()

        let reviewAppeared = app.navigationBars["书源导入预检"].waitForExistence(timeout: 15)
        if !reviewAppeared {
            print("[SourceFilePickerAfterOpen] \(app.debugDescription)")
            attach(app, name: "File picker after Open")
        }
        XCTAssertTrue(reviewAppeared)
        XCTAssertTrue(app.buttons["导入"].isEnabled)
        attach(app, name: "JSON import review after file picker dismissal")
        app.buttons["导入"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons["好"].tap() }
        XCTAssertTrue(app.staticTexts["文件导入 JSON 测试"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["文件导入大写扩展名测试"].exists)
    }

    func testSourceFormJSONSwitchKeepsHighlightedTextAndSaves() throws {
        try exerciseSourceEditor(usesLegacyUI: false)
    }

    func testLegacySourceFormJSONSwitchKeepsHighlightedTextAndSaves() throws {
        try exerciseSourceEditor(usesLegacyUI: true)
    }

    private func exerciseSourceEditor(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources"]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["新建书源"].tap()
        XCTAssertTrue(app.navigationBars["新建书源"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源名称")).firstMatch.tap()
        let editor = app.textViews["syntaxCodeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("UI Source")
        attach(app, name: "Typed source name")
        XCTAssertEqual(editor.value as? String, "UI Source")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源地址")).firstMatch.tap()
        editor.tap(); editor.typeText("https://ui-editor.test")
        XCTAssertEqual(editor.value as? String, "https://ui-editor.test")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["JSON"].tap()
        attach(app, name: "Source JSON editor")
        let json = editor.value as? String ?? ""
        XCTAssertTrue(json.contains("UI Source"), "Actual JSON: \(json)")
        XCTAssertTrue(json.contains("https://ui-editor.test"), "Actual JSON: \(json)")
        app.segmentedControls.buttons["字段编辑"].tap()
        app.buttons["保存"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons["好"].tap() }
        XCTAssertTrue(app.staticTexts["UI Source"].waitForExistence(timeout: 10))
    }

    func testPurificationDraftRunsThroughReaderPipeline() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoRules"]
        app.launch()
        XCTAssertTrue(app.buttons["新建规则"].waitForExistence(timeout: 20))
        app.buttons["新建规则"].tap()
        app.textFields["名称"].tap(); app.textFields["名称"].typeText("UI Rule")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "匹配内容")).firstMatch.tap()
        let editor = app.textViews["syntaxCodeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(".")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["测试规则"].tap()
        app.buttons["运行当前草稿"].tap()
        XCTAssertTrue(app.staticTexts["规则已生效"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["（正文为空）"].exists)
        attach(app, name: "Purification test result")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["净化规则"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UI Rule"].exists)
    }

    func testLegacySearchSubmitsAndFiltersSources() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "search", "-uiLegacyCompatibility"]
        app.launch()
        let search = app.textFields["书名或作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        app.buttons["搜索选项"].tap()
        app.buttons["分组或书源"].tap()
        XCTAssertTrue(app.navigationBars["分组或书源"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["书源"].tap()
        let filter = app.textFields["筛选书源"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText("no-match")
        XCTAssertFalse(app.staticTexts["经典文学馆"].exists)
        app.navigationBars["分组或书源"].buttons["取消"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("legacy-probe\n")
        XCTAssertTrue(app.buttons["修改关键词"].waitForExistence(timeout: 30))
        app.buttons["修改关键词"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Legacy search after keyboard submission")
    }

    func testLegacyAboutCanPresentSystemShareSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoAbout", "-uiLegacyCompatibility"]
        app.launch()
        let share = app.buttons["分享版本信息"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        share.tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        let appeared = copy.waitForExistence(timeout: 10)
        if !appeared { print("[Share sheet hierarchy] \(app.debugDescription)") }
        XCTAssertTrue(appeared)
        attach(app, name: "Legacy system share sheet")
    }

    func testLegacyRuleMenuCanExportThroughSystemShareSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoRules", "-uiLegacyCompatibility"]
        app.launch()
        XCTAssertTrue(app.navigationBars["净化规则"].waitForExistence(timeout: 20))
        app.buttons["更多"].tap()
        app.buttons["导出全部规则"].tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        let appeared = copy.waitForExistence(timeout: 10)
        if !appeared { print("[Share sheet hierarchy] \(app.debugDescription)") }
        XCTAssertTrue(appeared)
        attach(app, name: "Legacy rule menu export")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
