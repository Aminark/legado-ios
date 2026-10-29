import XCTest
import UIKit

@MainActor
final class ReaderScrollGestureTests: XCTestCase {
    func testBackgroundSwitchRestoresPresetWithoutDeletingPhoto() throws {
        try exerciseBackgroundSwitch(readingMode: "0")
    }

    func testScrollBackgroundSwitchRestoresPresetWithoutDeletingPhoto() throws {
        try exerciseBackgroundSwitch(readingMode: "3")
    }

    private func exerciseBackgroundSwitch(readingMode: String) throws {
        continueAfterFailure = false
        let app = launchAppearance(readingMode: readingMode)
        let choose = app.buttons["选择背景图片"]
        scrollToAppearanceElement(choose, in: app)
        app.buttons["微信读书"].tap()
        choose.tap()
        let photo = app.images["PXGGridLayout-Info"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        let dismissed = expectation(for: NSPredicate { _, _ in !cancel.exists }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 15)
        let useBackground = app.switches["使用背景图片"]
        scrollToAppearanceElement(useBackground, in: app)
        XCTAssertEqual(useBackground.value as? String, "1")
        app.buttons["完成"].tap()
        let imageColor = try backgroundRGB(in: app)

        func openAppearance() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["外观"].tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
            scrollToAppearanceElement(useBackground, in: app)
        }
        openAppearance()
        attachScreenshot(app)
        app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.25, dy: useBackground.frame.midY / app.frame.height
        )).tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        XCTAssertTrue(app.buttons["删除背景图片"].exists)
        app.buttons["完成"].tap()
        XCTAssertEqual(try backgroundRGB(in: app), [192, 237, 198])

        openAppearance()
        useBackground.tap()
        XCTAssertEqual(useBackground.value as? String, "1")
        app.buttons["完成"].tap()
        XCTAssertEqual(try backgroundRGB(in: app), imageColor)

        openAppearance()
        app.buttons["预设2"].tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        app.buttons["完成"].tap()
        XCTAssertEqual(try backgroundRGB(in: app), [221, 192, 144])
    }

    private func backgroundRGB(in app: XCUIApplication) throws -> [Int] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(
            x: image.width / 50, y: image.height * 28 / 100, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }

    func testBackgroundPickerCanBeOpenedRepeatedly() throws {
        continueAfterFailure = false
        let app = launchAppearance()
        for _ in 0..<3 {
            let choose = app.buttons["选择背景图片"]
            scrollToAppearanceElement(choose, in: app)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        }
    }

    func testBackgroundPhotoCanBeSelectedAndReplaced() throws {
        try exerciseBackgroundPhotoSelection(usesLegacyUI: false)
    }

    func testLegacyBackgroundPhotoCanBeSelectedAndReplaced() throws {
        try exerciseBackgroundPhotoSelection(usesLegacyUI: true)
    }

    private func exerciseBackgroundPhotoSelection(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = launchAppearance(usesLegacyUI: usesLegacyUI)
        for _ in 0..<2 {
            let choose = app.buttons["选择背景图片"]
            scrollToAppearanceElement(choose, in: app)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            let photo = app.images["PXGGridLayout-Info"].firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 5), "Seed a demo image with simctl addmedia before running this test")
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let dismissed = expectation(for: NSPredicate { _, _ in !cancel.exists }, evaluatedWith: nil)
            wait(for: [dismissed], timeout: 15)
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 15))
            let useBackground = app.switches["使用背景图片"]
            scrollToAppearanceElement(useBackground, in: app)
            XCTAssertEqual(useBackground.value as? String, "1")
        }
    }

    func testFontPickerCanBePresentedAboveAppearanceAndReopened() throws {
        continueAfterFailure = false
        let app = launchAppearance()
        for _ in 0..<2 {
            let choose = app.buttons["选择字体文件"]
            scrollToAppearanceElement(choose, in: app)
            XCTAssertTrue(app.staticTexts["段落缩进"].exists)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            let pickerAppeared = cancel.waitForExistence(timeout: 10)
            if !pickerAppeared { print(app.debugDescription); attachScreenshot(app) }
            XCTAssertTrue(pickerAppeared)
            cancel.tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        }
    }

    func testBookmarkSelectionSurvivesLeavingAndReenteringReader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-pageAnim", "0", "-themeMode", "1", "-textSize", "28"]
        app.launch()
        let book = app.staticTexts["山海入梦来"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bookmark = app.buttons["书签"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.value as? String, "添加当前位置")
        bookmark.tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.value as? String, "已添加")
        app.buttons["更多"].tap()
        app.buttons["书签列表"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第一章 · 雨夜"].firstMatch.exists)
    }

    private func launchAppearance(readingMode: String = "0", usesLegacyUI: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderStyle", "-pageAnim", readingMode, "-themeMode", "1", "-textFont", ""]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 20))
        return app
    }

    private func scrollToAppearanceElement(_ element: XCUIElement, in app: XCUIApplication) {
        // Partly visible rows can be hittable while their center is inside
        // the home-indicator area, where a tap does not activate the button.
        let safeBottom = app.frame.maxY - 60
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.maxY <= safeBottom { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable && element.frame.maxY <= safeBottom)
    }

    func testFailedChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes() throws {
        try exerciseFailedChapters(partial: false)
    }

    func testPartialChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes() throws {
        try exerciseFailedChapters(partial: true)
    }

    private func exerciseFailedChapters(partial: Bool) throws {
        continueAfterFailure = false
        for mode in ["3", "0"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiReaderFailure", "-pageAnim", mode, "-themeMode", "0"]
            if partial { app.launchArguments += ["-uiReaderPartialFailure"] }
            app.launch()
            let retry = app.buttons["reader.retryChapter"]
            XCTAssertTrue(retry.waitForExistence(timeout: 20))
            retry.tap()
            XCTAssertTrue(app.buttons["reader.failureChangeSource"].waitForExistence(timeout: 10))
            app.buttons["reader.failureChangeSource"].tap()
            XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].waitForExistence(timeout: 10))
            app.buttons["取消"].tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 10))
            if mode == "3" {
                app.collectionViews["reader.continuous"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            } else {
                app.buttons["reader.failureMenu"].tap()
            }
            let changeSource = app.buttons["reader.changeSource"]
            XCTAssertTrue(changeSource.waitForExistence(timeout: 5))
            changeSource.tap()
            XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].waitForExistence(timeout: 10))
            attachScreenshot(app)
            app.terminate()
        }
    }

    func testPagedReadingReportsPageCountAndTurnsWithinTheSameChapter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics", "-pageAnim", "4", "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28"]
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
        let ready = expectation(for: NSPredicate { _, _ in
            print("[PagedReader] \(body.label) footer=\(page.label)")
            let total = page.label.split(separator: "/").last?.split(separator: " ").first.flatMap { Int($0) } ?? 0
            return page.exists && page.label.hasPrefix("1/") && total > 1
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        let chapter = body.value as? String
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let next = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("2/") }, evaluatedWith: nil)
        wait(for: [next], timeout: 5)
        XCTAssertEqual(body.value as? String, chapter)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let previous = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("1/") }, evaluatedWith: nil)
        wait(for: [previous], timeout: 5)
        XCTAssertEqual(body.value as? String, chapter)
        attachScreenshot(app)
    }

    func testPagedReadingChapterNavigationDirectorySearchAndSettings() throws {
        try exerciseChapterNavigationAndSettings(usesLegacyUI: false)
    }

    func testLegacyReadingChapterNavigationDirectorySearchAndPhotoPicker() throws {
        try exerciseChapterNavigationAndSettings(usesLegacyUI: true)
    }

    private func exerciseChapterNavigationAndSettings(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", "0", "-themeMode", "1"]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        func waitForChapter(_ title: String) {
            let ready = expectation(for: NSPredicate { _, _ in
                (body.value as? String ?? "").contains(title)
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 15)
        }
        func showMenu() {
            if !app.buttons["目录"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5))
        }
        waitForChapter("第一章 · 雨夜")
        showMenu()
        XCTAssertFalse(app.buttons["上一章"].isEnabled)
        app.buttons["下一章"].tap()
        waitForChapter("第二章 · 灯塔")
        showMenu()
        app.buttons["上一章"].tap()
        waitForChapter("第一章 · 雨夜")

        showMenu()
        app.buttons["目录"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        let chapterSearch = app.searchFields["搜索章节"]
        chapterSearch.tap()
        chapterSearch.typeText("天明")
        app.staticTexts["第五章 · 天明"].tap()
        waitForChapter("第五章 · 天明")
        showMenu()
        XCTAssertFalse(app.buttons["下一章"].isEnabled)

        app.buttons["更多"].tap()
        app.buttons["搜索正文"].tap()
        XCTAssertTrue(app.navigationBars["正文搜索"].waitForExistence(timeout: 5))
        let contentSearch = app.searchFields["搜索本章"]
        contentSearch.tap()
        contentSearch.typeText("灯塔")
        let match = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "林深推开阁楼的窗")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()
        XCTAssertFalse(app.navigationBars["正文搜索"].exists)

        showMenu()
        app.buttons["书签"].tap()
        app.buttons["更多"].tap()
        app.buttons["书签列表"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第五章 · 天明"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()

        showMenu()
        app.buttons["外观"].tap()
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        if usesLegacyUI {
            app.buttons["选择背景图片"].tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        }
        app.buttons["完成"].tap()
        showMenu()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        waitForChapter("第五章 · 天明")
        attachScreenshot(app)
    }

    func testForwardAndReverseFlicksKeepMomentumAcrossChapterInsertion() throws {
        let (app, reader) = launchReader(shortChapters: false)
        let initial = try value("chapter", in: reader)
        for _ in 0..<6 { flick(reader, forward: true) }
        let forward = try value("chapter", in: reader)
        XCTAssertGreaterThan(forward, initial + 2)
        for _ in 0..<6 { flick(reader, forward: false) }
        XCTAssertLessThan(try value("chapter", in: reader), forward)
        XCTAssertGreaterThan(try value("decelInsertions", in: reader), 0)
        XCTAssertGreaterThan(try value("continued", in: reader), 0)
        XCTAssertEqual(try value("interrupted", in: reader), 0)
        attachScreenshot(app)
    }

    func testManyShortChaptersFlowPastTheInitialWindow() throws {
        let (app, reader) = launchReader(shortChapters: true)
        let initial = try value("chapter", in: reader)
        for _ in 0..<4 { flick(reader, forward: true) }
        let forward = try value("chapter", in: reader)
        XCTAssertGreaterThan(forward, initial + 5)
        for _ in 0..<4 { flick(reader, forward: false) }
        XCTAssertLessThan(try value("chapter", in: reader), forward)
        XCTAssertEqual(try value("interrupted", in: reader), 0)
        attachScreenshot(app)
    }

    private func launchReader(shortChapters: Bool) -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "3", "-themeMode", "0"]
        if shortChapters { app.launchArguments.append("-uiShortChapters") }
        app.launch()
        let reader = app.collectionViews["reader.continuous"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        var lastInitialState = "<not reported>"
        let ready = expectation(for: NSPredicate { _, _ in
            let text = reader.value as? String ?? "<missing>"
            if text != lastInitialState {
                print("[ContinuousReaderInitial] \(text)")
                lastInitialState = text
            }
            return text.contains("chapter=20 ") && !text.contains("chapters=1 ")
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 20)
        return (app, reader)
    }

    private func flick(_ reader: XCUIElement, forward: Bool) {
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.8 : 0.2))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.2 : 0.8))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func value(_ name: String, in reader: XCUIElement) throws -> Int {
        let fields = (reader.value as? String ?? "").split(separator: " ")
        let field = try XCTUnwrap(fields.first { $0.hasPrefix(name + "=") })
        let value = try XCTUnwrap(Int(field.dropFirst(name.count + 1)))
        print("[ContinuousReader] \(reader.value ?? "")")
        return value
    }

    private func attachScreenshot(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
