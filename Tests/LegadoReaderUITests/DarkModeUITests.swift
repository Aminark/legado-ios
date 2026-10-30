import UIKit
import XCTest

@MainActor
final class DarkModeUITests: XCTestCase {
    func testPrimaryActionsKeepDarkFillInBothAppearances() throws {
        continueAfterFailure = false
        for theme in ["2", "1"] {
            let app = launch(["-uiDemoBookDetail", "-themeMode", theme])
            let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["开始阅读", "继续阅读"])).firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 20))
            XCTAssertTrue(read.isEnabled)
            try assertReadableDarkFill(read, in: app)
            attach(app, name: "Book detail theme \(theme)")
            app.terminate()
        }
    }

    func testNightReaderSelectionsKeepDarkFillAndReadableLabels() throws {
        continueAfterFailure = false
        let app = launch([
            "-uiDemoReader", "-uiDemoReaderStyle", "-themeMode", "2",
            "-readerTheme", "night", "-readerUseBackgroundImage", "NO",
            "-lineSpacingExtra", "12", "-pageAnim", "0"
        ])
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 20))
        // Expand the sheet so the controls can be inspected without clipping.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        let standard = app.buttons["标准"]
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        try assertReadableDarkFill(standard, in: app)
        attach(app, name: "Night reader spacing selection")
        let cover = app.buttons["覆盖"]
        for _ in 0..<16 {
            if cover.exists && cover.isHittable && cover.frame.maxY < app.frame.height - 50 { break }
            app.swipeUp()
        }
        XCTAssertTrue(cover.exists && cover.isHittable)
        try assertReadableDarkFill(cover, in: app)
        attach(app, name: "Night reader animation selection")
    }

    func testDarkAppearanceAcrossTabsAndPresentedEditors() throws {
        continueAfterFailure = false
        let app = launch(["-themeMode", "2"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 20))
        for (tab, heading) in [("书架", "阅读，让时间有了形状"), ("发现", "下一本好书，在这里遇见"),
                               ("统计", "每一页，都算数"), ("我的", "按照你的方式阅读")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
            if tab == "统计" {
                let today = app.otherElements["statistics.todayCard"]
                XCTAssertTrue(today.waitForExistence(timeout: 5))
                try assertReadableDarkFill(today, in: app)
            }
            attach(app, name: "Dark tab \(tab)")
        }
        app.buttons["profile.globe"].tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
        attach(app, name: "Dark source library")
        app.buttons["更多"].firstMatch.tap()
        app.buttons["新建书源"].tap()
        XCTAssertTrue(app.navigationBars["新建书源"].waitForExistence(timeout: 10))
        let basic = app.buttons["基础"]
        try assertReadableDarkFill(basic, in: app)
        let login = app.buttons["登录"]
        login.tap()
        try assertReadableDarkFill(login, in: app)
        attach(app, name: "Dark source category selection")
        attach(app, name: "Dark presented source editor")
        app.segmentedControls.buttons["JSON"].tap()
        XCTAssertTrue(app.textViews["syntaxCodeEditor"].waitForExistence(timeout: 5))
        attach(app, name: "Dark JSON editor")
        app.textViews["syntaxCodeEditor"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Dark editor keyboard and accessory toolbar")
        let visibleKeyboard = app.keyboards.firstMatch.frame.intersection(app.frame)
        if !visibleKeyboard.isNull && visibleKeyboard.width > 20 && visibleKeyboard.height > 20 {
            let keyboard = try luminances(app.keyboards.firstMatch, in: app)
            XCTAssertLessThan(keyboard[keyboard.count / 2], 0.15)
        }
        let accessory = app.buttons["syntaxCodeEditor.done"]
        XCTAssertTrue(accessory.exists && accessory.isHittable)
        try assertReadableDarkFill(accessory, in: app)
        app.buttons["@"].tap()
        XCTAssertTrue((app.textViews["syntaxCodeEditor"].value as? String)?.contains("@") == true)
        accessory.tap()
        let dismissed = expectation(for: NSPredicate { _, _ in !accessory.exists || !accessory.isHittable }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 5)
    }

    func testDarkSettingsRulesAndManagementPages() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2"])
        let routes: [(String, String, String?)] = [
            ("textformat.size", "阅读设置", nil),
            ("waveform", "在线朗读引擎", "新建"),
            ("bookmark", "书签", nil),
            ("clock", "阅读记录", nil),
            ("link", "规则订阅", "新建"),
            ("text.badge.checkmark", "净化规则", "新建规则"),
            ("list.bullet.rectangle", "TXT目录规则", "新建"),
            ("folder", "文件管理", nil),
            ("internaldrive", "缓存管理", nil),
            ("gearshape", "其他设置", nil),
            ("info.circle", "关于", nil)
        ]
        for (icon, title, create) in routes {
            let entry = app.buttons["profile.\(icon)"]
            scrollTo(entry, in: app)
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            try captureDarkPage(app, name: "Management \(title)")
            if let create {
                app.buttons[create].firstMatch.tap()
                XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
                try captureDarkPage(app, name: "Editor \(title)")
                if title == "净化规则" {
                    app.segmentedControls.buttons["测试规则"].tap()
                    try captureDarkPage(app, name: "Rule test form")
                }
                app.buttons["取消"].tap()
            }
            if title == "其他设置" {
                for (entry, destination) in [("网络与缓存设置", "网络与缓存"), ("章节缓存管理", "缓存管理"), ("日志与诊断", "日志与诊断")] {
                    let link = app.buttons[entry]
                    scrollTo(link, in: app)
                    link.tap()
                    XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
                    try captureDarkPage(app, name: "Settings \(destination)")
                    app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
                }
            }
            if title == "关于" {
                let license = app.buttons["开源许可"]
                scrollTo(license, in: app)
                license.tap()
                XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
                try captureDarkPage(app, name: "Licenses")
                app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            }
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.scrollViews["profile.scroll"].waitForExistence(timeout: 5))
        }
    }

    func testDarkSearchFiltersAndSourceImportSheets() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "search", "-themeMode", "2", "-uiAutomationSearch", "深色外观检查"])
        let cancelSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if cancelSearch.waitForExistence(timeout: 3) { cancelSearch.tap() }
        XCTAssertTrue(app.buttons["search.options"].waitForExistence(timeout: 10))
        app.buttons["search.options"].tap()
        app.buttons["分组或书源"].tap()
        XCTAssertTrue(app.navigationBars["分组或书源"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Search group filter")
        app.segmentedControls.buttons["书源"].tap()
        try captureDarkPage(app, name: "Search source filter")
        app.buttons["取消"].tap()
        app.terminate()

        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources", "-themeMode", "2"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
        app.buttons["排序"].tap()
        XCTAssertTrue(app.buttons["倒序"].waitForExistence(timeout: 5))
        try assertReadableDarkFill(app.buttons["倒序"], in: app)
        attach(app, name: "Source sorting menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        app.buttons["更多"].firstMatch.tap()
        app.buttons["URL 或粘贴 JSON"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Source text import")
    }

    func testDarkRSSAndBlackPhotoViewerInLightAppearance() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "rss", "-themeMode", "2"])
        XCTAssertTrue(app.navigationBars["RSS"].waitForExistence(timeout: 10))
        for tab in ["订阅", "收藏", "记录"] {
            app.segmentedControls.buttons[tab].tap()
            try captureDarkPage(app, name: "RSS \(tab)")
        }
        app.segmentedControls.buttons["订阅"].tap()
        app.buttons["RSS操作"].tap()
        app.buttons["新建RSS源"].tap()
        XCTAssertTrue(app.navigationBars["新建RSS源"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "RSS source editor")
        app.terminate()

        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss-photo", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.alerts["图片"].waitForExistence(timeout: 10))
        app.alerts["图片"].buttons["好"].tap()
        let error = app.staticTexts["图片加载失败"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        try assertReadableDarkFill(error, in: app)
        let done = app.navigationBars.buttons["完成"]
        XCTAssertTrue(done.exists && done.isEnabled)
        attach(app, name: "Photo viewer navigation and content")
        let toolbar = try luminances(done, in: app)
        XCTAssertGreaterThanOrEqual((toolbar[toolbar.count * 98 / 100] + 0.05) / (toolbar[toolbar.count * 2 / 100] + 0.05), 4.5)
        attach(app, name: "Readable photo error on black canvas")
    }

    func testNightReaderMenusAndSettings() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoReader", "-uiDemoReaderMenu", "-readerTheme", "night", "-themeMode", "2", "-readerUseBackgroundImage", "NO"])
        XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 15))
        try captureDarkPage(app, name: "Night reader menu")
        app.buttons["目录"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night table of contents")
        app.buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night reader settings")
        let click = app.buttons["点击区域设置"]
        scrollTo(click, in: app)
        click.tap()
        XCTAssertTrue(app.navigationBars["点击区域设置"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night click action grid")
    }

    func testAppearanceMenuRestoresSystemAndUpdatesVisiblePage() throws {
        continueAfterFailure = false
        // Launch arguments override writes to UserDefaults; leave themeMode mutable here.
        let app = launch(["-uiDemoTab", "settings"])
        let appearance = app.buttons["profile.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let system = app.buttons["跟随系统"]
        XCTAssertTrue(system.waitForExistence(timeout: 3))
        system.tap()
        let followsSystem = expectation(for: NSPredicate(format: "value == %@", "跟随系统"), evaluatedWith: appearance)
        wait(for: [followsSystem], timeout: 5)
        let initial = try luminances(app, in: app)
        let systemIsDark = initial[initial.count / 2] < 0.15
        for (choice, expectsDark) in [("深色", true), ("浅色", false), ("跟随系统", systemIsDark)] {
            appearance.tap()
            let option = app.buttons[choice]
            if !option.waitForExistence(timeout: 2), app.buttons["外观"].exists { app.buttons["外观"].tap() }
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            let changed = expectation(for: NSPredicate(format: "value == %@", choice), evaluatedWith: appearance)
            wait(for: [changed], timeout: 5)
            let values = try luminances(app, in: app)
            let median = values[values.count / 2]
            if expectsDark { XCTAssertLessThan(median, 0.15) }
            else { XCTAssertGreaterThan(median, 0.6) }
            attach(app, name: "Live appearance \(choice)")
        }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.maxY < app.frame.height / 2 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func captureDarkPage(_ app: XCUIApplication, name: String) throws {
        let values = try luminances(app, in: app)
        XCTAssertLessThan(values[values.count / 2], 0.15, "Unexpected light page or sheet: \(name)")
        attach(app, name: name)
    }

    // Check both the rendered label contrast and the fill's actual brightness.
    // A readable white surface must still fail the dark appearance regression.
    private func assertReadableDarkFill(_ element: XCUIElement, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let luminances = try luminances(element, in: app, file: file, line: line)
        let low = luminances[luminances.count * 2 / 100]
        let high = luminances[luminances.count * 98 / 100]
        XCTAssertGreaterThanOrEqual((high + 0.05) / (low + 0.05), 4.5,
                                    "Rendered label has insufficient contrast", file: file, line: line)
        XCTAssertLessThan(luminances[luminances.count / 2], 0.15,
                          "Filled control or card is too bright for the dark palette", file: file, line: line)
    }

    private func luminances(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [Double] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage, file: file, line: line)
        let scaleX = CGFloat(image.width) / app.frame.width
        let scaleY = CGFloat(image.height) / app.frame.height
        let bounds = element.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
        let rect = CGRect(x: bounds.minX * scaleX, y: bounds.minY * scaleY,
                          width: bounds.width * scaleX, height: bounds.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: rect), file: file, line: line)
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ), file: file, line: line)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let sampleStride = crop.width * crop.height > 250_000 ? 64 : 4
        return stride(from: 0, to: bytes.count, by: sampleStride).map {
            0.2126 * linear(bytes[$0]) + 0.7152 * linear(bytes[$0 + 1]) + 0.0722 * linear(bytes[$0 + 2])
        }.sorted()
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo"] + arguments
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
