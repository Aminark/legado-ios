import XCTest
import UIKit

@MainActor
final class ReaderScrollGestureTests: XCTestCase {
    func testBackupExportAndCloudOptInCanBeCancelled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-themeMode", "1"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.exists && entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(app.navigationBars["备份与同步"].waitForExistence(timeout: 10))
        let toggle = app.switches["backup.cloudToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        for _ in 0..<6 { if toggle.isHittable { break }; app.swipeUp() }
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["启用并合并"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        for _ in 0..<6 { if app.buttons["backup.export"].isHittable { break }; app.swipeDown() }
        app.buttons["backup.export"].tap()
        let picker = app.otherElements["Browse View (Picker)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let dismissed = expectation(for: NSPredicate { _, _ in !picker.exists }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.export"].isEnabled)
        attachScreenshot(app)
    }

    func testWebDAVConnectBackupAndRemoteRestorePreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-themeMode", "1"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        let configure = app.buttons["backup.webdav.configure"]
        for _ in 0..<6 { if configure.isHittable { break }; app.swipeUp() }
        configure.tap()
        let address = app.textFields["backup.webdav.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("https://dav.example/dav/")
        let username = app.textFields["backup.webdav.username"]; username.tap(); username.typeText("fixture@example.com")
        let password = app.secureTextFields["backup.webdav.password"]; password.tap(); password.typeText("synthetic-password")
        app.buttons["backup.webdav.save"].tap()
        XCTAssertTrue(app.navigationBars["备份与同步"].waitForExistence(timeout: 5))
        let upload = app.buttons["backup.webdav.upload"]
        for _ in 0..<6 { if upload.isHittable { break }; app.swipeUp() }
        upload.tap()
        XCTAssertTrue(app.alerts["备份与同步"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["演示备份已保存，未上传到真实云端。"].exists)
        app.buttons["好"].tap()
        let list = app.buttons["backup.webdav.list"]
        for _ in 0..<6 { if list.isHittable { break }; app.swipeUp() }
        list.tap()
        let backup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "backup.remote.item.")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10)); backup.tap()
        XCTAssertTrue(app.navigationBars["恢复预览"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["backup.restoreConfirm"].isEnabled)
        attachScreenshot(app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["WebDAV 备份"].waitForExistence(timeout: 5))
        app.navigationBars["WebDAV 备份"].buttons.element(boundBy: 0).tap()
        let toggle = app.switches["backup.webdav.toggle"]
        let navigationBottom = app.navigationBars["备份与同步"].frame.maxY
        for _ in 0..<6 {
            if toggle.isHittable && toggle.frame.minY > navigationBottom && toggle.frame.maxY < app.frame.maxY - 100 { break }
            app.swipeDown()
        }
        XCTAssertGreaterThan(toggle.frame.minY, navigationBottom)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["启用 WebDAV 同步"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap(); app.buttons["启用并合并"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let automatic = app.switches["backup.webDAV.automatic"]
        for _ in 0..<6 { if automatic.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)["backup.webDAV.lastAutomatic"].waitForExistence(timeout: 10))
        XCTAssertEqual(automatic.value as? String, "1")
        XCTAssertEqual(app.buttons["backup.webDAV.interval"].value as? String, "6 小时")
        automatic.switches.firstMatch.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        attachScreenshot(app)
    }

    func testGoogleAutomaticBackupDefaultsOnAndRemembersOptOut() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-themeMode", "1"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        let bind = app.buttons["backup.google.bind"]
        for _ in 0..<8 { if bind.isHittable { break }; app.swipeUp() }
        bind.tap()
        let toggle = app.switches["backup.googleDrive.automatic"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<6 { if toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["backup.googleDrive.lastAutomatic"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        let interval = app.buttons["backup.googleDrive.interval"]
        for _ in 0..<6 { if interval.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(interval.value as? String, "6 小时")
        interval.tap(); app.buttons["15 分钟"].tap()
        XCTAssertEqual(interval.value as? String, "15 分钟")
        interval.tap(); app.buttons["自定义…"].tap()
        let custom = app.textFields["backup.interval.customMinutes"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        custom.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (custom.value as? String ?? "").count) + "0")
        XCTAssertEqual(custom.value as? String, "0")
        app.buttons["backup.interval.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["请输入 1～10080 分钟"].waitForExistence(timeout: 5), app.debugDescription)
        custom.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        custom.typeText(XCUIKeyboardKey.delete.rawValue + "37")
        XCTAssertEqual(custom.value as? String, "37")
        app.buttons["backup.interval.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(interval.value as? String, "37 分钟")
        attachScreenshot(app)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let list = app.buttons["backup.google.list"]
        for _ in 0..<6 { if list.isHittable { break }; app.swipeUp() }
        list.tap()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "backup.remote.item."))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(items.count, 1)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertEqual(items.count, 1)
        let back = app.navigationBars["Google Drive 备份"].buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["备份与同步"].waitForExistence(timeout: 5))
        let disconnect = app.buttons["解除 Google 绑定"]
        for _ in 0..<6 { if disconnect.isHittable { break }; app.swipeUp() }
        disconnect.tap(); app.alerts["解除 Google 绑定？"].buttons["解除绑定"].tap()
        XCTAssertTrue(bind.waitForExistence(timeout: 5)); bind.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(interval.value as? String, "37 分钟")
        attachScreenshot(app)
    }

    func testGoogleBindingBackupAndConfirmedRemoteRestore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-themeMode", "2", "-uiDemoSlowBackup"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        let bind = app.buttons["backup.google.bind"]
        for _ in 0..<8 { if bind.isHittable { break }; app.swipeUp() }
        bind.tap()
        let upload = app.buttons["backup.google.upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        for _ in 0..<6 { if upload.isHittable { break }; app.swipeUp() }
        upload.tap()
        let uploadProgress = app.descendants(matching: .any)["backup.rowProgress"]
        XCTAssertTrue(uploadProgress.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(uploadProgress.frame.midX, upload.frame.midX)
        XCTAssertFalse(app.descendants(matching: .any)["backup.progress"].exists)
        attachScreenshot(app)
        XCTAssertTrue(app.alerts["备份与同步"].waitForExistence(timeout: 10)); app.buttons["好"].tap()
        app.buttons["backup.google.list"].tap()
        let backup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "backup.remote.item.")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        let rowY = backup.frame.minY
        let backupID = String(backup.identifier.dropFirst("backup.remote.item.".count))
        backup.tap()
        let previewProgress = app.descendants(matching: .any)["backup.remote.loading.\(backupID)"]
        XCTAssertTrue(previewProgress.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(previewProgress.frame.midX, backup.frame.midX)
        XCTAssertEqual(backup.frame.minY, rowY, accuracy: 1)
        XCTAssertFalse(backup.isEnabled)
        XCTAssertFalse(app.staticTexts["正在读取…"].exists)
        attachScreenshot(app)
        XCTAssertTrue(app.navigationBars["恢复预览"].waitForExistence(timeout: 10))
        XCTAssertFalse(previewProgress.exists)
        app.buttons["backup.restoreConfirm"].tap()
        XCTAssertTrue(app.alerts["备份与同步"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["备份已合并恢复，原有数据已保留。"].exists)
        app.buttons["好"].tap()
        XCTAssertTrue(app.navigationBars["Google Drive 备份"].exists)
        attachScreenshot(app)
    }

    func testBackupRestorePreviewRequiresExplicitConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiBackupPreview", "-themeMode", "2"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.exists && entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(app.navigationBars["恢复预览"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["backup.preview.readRecords"].exists)
        XCTAssertTrue(app.staticTexts["2 条"].exists)
        XCTAssertTrue(app.staticTexts["128 分钟"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["backup.preview.searchHistory"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["backup.preview.rssHistory"].exists)
        XCTAssertTrue(app.buttons["backup.restoreConfirm"].isEnabled)
        XCTAssertTrue(app.staticTexts["3 个"].firstMatch.exists)
        attachScreenshot(app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["备份与同步"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["backup.restoreConfirm"].exists)
    }

    func testConfirmedBackupRestoreReturnsToManagerAndReportsSuccess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiBackupPreview", "-themeMode", "1"]
        app.launch()
        let entry = app.buttons["profile.icloud"]
        for _ in 0..<8 { if entry.exists && entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(app.navigationBars["恢复预览"].waitForExistence(timeout: 15))
        app.buttons["backup.restoreConfirm"].tap()
        XCTAssertTrue(app.alerts["备份与同步"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["备份已合并恢复，原有数据已保留。"].exists)
        app.buttons["好"].tap()
        XCTAssertTrue(app.navigationBars["备份与同步"].exists)
        XCTAssertTrue(app.buttons["backup.export"].isEnabled)
        attachScreenshot(app)
    }


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
