import XCTest
import UIKit

@MainActor
final class ReaderScrollGestureTests: XCTestCase {
    func testReopeningSourceSwitchUsesCachedVerificationAndCanRefresh() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoSourceSwitch", "-uiDemoSourceReference"]
        app.launch()
        let verification = app.staticTexts["sourceSwitch.verification.https://science.example"]
        XCTAssertTrue(verification.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate(format: "label CONTAINS %@", "可见片段相似"), evaluatedWith: verification)
        wait(for: [ready], timeout: 10)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://science.example|")).firstMatch.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)
        app.buttons["取消"].tap()
        app.buttons["选择书源"].tap()
        XCTAssertTrue(app.staticTexts["sourceSwitch.cache"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourceSwitch.reference"].label.contains("QQ 阅读（演示）"))
        XCTAssertTrue(verification.label.contains("100%"))
        XCTAssertFalse(app.buttons["sourceSwitch.confirm"].isEnabled)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://science.example|")).firstMatch.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)
        attachScreenshot(app)
        app.buttons["sourceSwitch.refresh"].tap()
        let cleared = expectation(for: NSPredicate { _, _ in !app.staticTexts["sourceSwitch.cache"].exists }, evaluatedWith: nil)
        wait(for: [cleared], timeout: 5)
        XCTAssertFalse(app.buttons["sourceSwitch.confirm"].isEnabled)
        let refreshed = expectation(for: NSPredicate(format: "label CONTAINS %@", "可见片段相似"), evaluatedWith: verification)
        wait(for: [refreshed], timeout: 10)
    }

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



    func testDownloadingKeepsDirectoryScrollableAndUpdatesCachedRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiCacheRegression", "-pageAnim", "4", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["目录"].tap()
        let current = app.buttons["reader.toc.chapter.demo://cache/369"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isHittable, "Opening the directory must locate the current chapter, not chapter one")
        XCTAssertEqual(current.value as? String, "已缓存")
        app.buttons["reader.toc.cacheMenu"].tap()
        app.buttons["缓存剩余章节"].tap()
        let result = app.staticTexts["reader.toc.cacheResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let failed = expectation(for: NSPredicate { _, _ in !result.label.contains("失败 0 章") }, evaluatedWith: nil)
        wait(for: [failed], timeout: 8)
        let list = app.descendants(matching: .any)["reader.toc.list"].firstMatch
        XCTAssertTrue(list.exists)
        list.swipeUp(velocity: .fast)
        list.swipeUp(velocity: .fast)
        XCTAssertFalse(current.isHittable)
        list.swipeDown(velocity: .fast)
        app.buttons["reader.toc.current"].tap()
        XCTAssertTrue(current.isHittable)
        XCTAssertEqual(app.buttons["reader.toc.chapter.demo://cache/370"].value as? String, "已缓存")
        XCTAssertTrue(app.buttons["reader.toc.cacheStop"].isHittable)
        attachScreenshot(app)
        app.buttons["reader.toc.cacheStop"].tap()
        let stopped = expectation(for: NSPredicate { _, _ in !app.buttons["reader.toc.cacheStop"].exists }, evaluatedWith: nil)
        wait(for: [stopped], timeout: 5)
        app.navigationBars["目录"].buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["目录"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["reader.toc.chapter.demo://cache/370"].value as? String, "已缓存")
        attachScreenshot(app)
    }

    func testDefaultLayoutCanBeAppliedInPagedAndScrollReading() throws {
        continueAfterFailure = false
        for mode in ["4", "3"] {
            let app = launchAppearance(readingMode: mode, extraArguments: ["-readerTheme", "wechat", "-readerUseBackgroundImage", "NO"])
            let preset = app.buttons["reader.defaultLayout"]
            XCTAssertTrue(preset.waitForExistence(timeout: 5))
            preset.tap()
            app.buttons["完成"].tap()
            let dismissed = expectation(for: NSPredicate { _, _ in !app.navigationBars["阅读样式"].exists }, evaluatedWith: nil)
            wait(for: [dismissed], timeout: 5)
            let surface = mode == "3" ? app.collectionViews["reader.continuous"] : app.textViews["reader.text"]
            XCTAssertTrue(surface.waitForExistence(timeout: 10))
            let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            before.name = "默认排版 · 模式 \(mode)"
            before.lifetime = .keepAlways
            add(before)
            if mode == "4" {
                let viewport = app.otherElements["reader.viewport"]
                XCTAssertTrue(viewport.exists)
                // Clipping is checked in the native viewport test; this screen
                // capture also includes the intentionally raised footer.
                viewport.swipeLeft()
                let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
                let progressed = progress.waitForExistence(timeout: 5)
                attachScreenshot(app)
                XCTAssertTrue(progressed)
                XCTAssertGreaterThan(surface.frame.minY, 50)
            } else {
                surface.swipeUp()
                attachScreenshot(app)
            }
            app.terminate()
        }
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
            app.buttons["设置"].tap()
            XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
            app.buttons["reader.moreAppearance"].tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
            scrollToAppearanceElement(useBackground, in: app)
        }
        func closeAppearance() {
            app.navigationBars["阅读样式"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
            app.buttons["完成"].tap()
        }
        openAppearance()
        attachScreenshot(app)
        app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.25, dy: useBackground.frame.midY / app.frame.height
        )).tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        XCTAssertTrue(app.buttons["删除背景图片"].exists)
        closeAppearance()
        XCTAssertEqual(try backgroundRGB(in: app), [192, 237, 198])

        openAppearance()
        useBackground.tap()
        XCTAssertEqual(useBackground.value as? String, "1")
        closeAppearance()
        XCTAssertEqual(try backgroundRGB(in: app), imageColor)

        openAppearance()
        app.buttons["预设2"].tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        closeAppearance()
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
        app.launchArguments = ["-uiDemo", "-pageAnim", "0", "-themeMode", "1", "-textSize", "28", "-headerMode", "1"]
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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(app)
        app.buttons["reader.headerBack"].tap()
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

    private func launchAppearance(readingMode: String = "0", usesLegacyUI: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderStyle", "-pageAnim", readingMode, "-themeMode", "1", "-textFont", ""] + extraArguments
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
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics", "-pageAnim", "4", "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28",
                               "-clickActionMiddleLeft", "1", "-clickActionMiddleRight", "2"]
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
        let viewport = app.otherElements["reader.viewport"]
        // Old persisted left/right page actions must now open the menu without turning.
        for x in [0.8, 0.2] {
            let side = viewport.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
            side.tap()
            XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5))
            XCTAssertTrue(page.label.hasPrefix("1/"))
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let closed = expectation(for: NSPredicate { _, _ in !app.buttons["目录"].exists }, evaluatedWith: nil)
            wait(for: [closed], timeout: 5)
        }
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let next = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("2/") }, evaluatedWith: nil)
        wait(for: [next], timeout: 5)
        XCTAssertEqual(body.value as? String, chapter)
        attachScreenshot(app)
        viewport.swipeRight()
        let previous = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("1/") }, evaluatedWith: nil)
        wait(for: [previous], timeout: 5)
        XCTAssertEqual(body.value as? String, chapter)
        attachScreenshot(app)
    }

    func testDiagonalAndBlankAreaSwipesTurnExactlyOnePage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics",
                               "-pageAnim", "0", "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28"]
        app.launch()
        let viewport = app.otherElements["reader.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
        func waitForPage(_ number: Int) {
            let ready = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("\(number)/") }, evaluatedWith: nil)
            wait(for: [ready], timeout: 5)
        }
        waitForPage(1)
        let center = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let start = center.withOffset(CGVector(dx: 90, dy: 90))
        let end = center.withOffset(CGVector(dx: -90, dy: -90))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForPage(2)
        end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForPage(1)
        // Below the last complete line, the clipped-out area must still receive page turns.
        let bottomStart = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 1)).withOffset(CGVector(dx: 0, dy: -2))
        let bottomEnd = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 1)).withOffset(CGVector(dx: 0, dy: -2))
        bottomStart.press(forDuration: 0.05, thenDragTo: bottomEnd, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForPage(2)
        attachScreenshot(app)
    }

    func testSwipingBlankAreaOfAShortChapterMovesForwardAndBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["0", "1", "4"] {
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiShortChapters", "-uiPagingDiagnostics",
                                   "-pageAnim", mode, "-themeMode", "1"]
            app.launch()
            let body = app.textViews["reader.text"]
            XCTAssertTrue(body.waitForExistence(timeout: 20))
            let viewport = app.otherElements["reader.viewport"]
            func waitForChapter(_ number: Int) {
                let ready = expectation(for: NSPredicate { _, _ in
                    (body.value as? String ?? "").contains("第\(number)章 · 连续阅读")
                }, evaluatedWith: nil)
                wait(for: [ready], timeout: 5)
            }
            waitForChapter(21)
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            waitForChapter(22)
            XCTAssertTrue(body.label.contains("chapterTransitions=\(mode == "4" ? 0 : 1)"), body.label)
            if mode != "4" { XCTAssertTrue(body.label.contains("chapterDirection=1")) }
            end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.3)
            waitForChapter(21)
            XCTAssertTrue(body.label.contains("chapterTransitions=\(mode == "4" ? 0 : 2)"), body.label)
            if mode != "4" { XCTAssertTrue(body.label.contains("chapterDirection=-1")) }
            attachScreenshot(app)
        }
    }

    func testInteractivePageDragCanPauseAndReturnWithoutTurning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics",
                               "-pageAnim", "1", "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28"]
        app.launch()
        let viewport = app.otherElements["reader.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
        let body = app.textViews["reader.text"]
        let chapter = body.value as? String
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
        let partial = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 1.5)
        XCTAssertTrue(page.label.hasPrefix("1/"), page.label)
        XCTAssertEqual(body.value as? String, chapter)
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(page.label.hasPrefix("2/"), page.label)
        end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(page.label.hasPrefix("1/"), page.label)
        attachScreenshot(app)
    }

    func testPreviousChapterAnimationStartsOnItsLastPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["0", "1", "2"] {
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics",
                                   "-pageAnim", mode, "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28"]
            app.launch()
            let body = app.textViews["reader.text"]
            XCTAssertTrue(body.waitForExistence(timeout: 20))
            let viewport = app.otherElements["reader.viewport"]
            let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
            func waitForChapter(_ number: Int) {
                let ready = expectation(for: NSPredicate { _, _ in
                    (body.value as? String ?? "").contains("第\(number)章 · 连续阅读")
                }, evaluatedWith: nil)
                wait(for: [ready], timeout: 5)
            }
            func snapshotPage() -> (Int, Int) {
                let values = body.label.components(separatedBy: "snapshotPage=").last?.split(separator: "/") ?? []
                guard values.count == 2, let current = Int(values[0]), let total = Int(values[1]) else {
                    XCTFail("Missing animation snapshot page: \(body.label)")
                    return (0, 0)
                }
                return (current, total)
            }
            waitForChapter(21)
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
            let partial = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.8))
            end.press(forDuration: 0.05, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 0.5)
            waitForChapter(21)
            XCTAssertTrue(page.label.hasPrefix("1/"), "Cancelling a prepared previous chapter must keep the current chapter and page")
            end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.3)
            waitForChapter(20)
            let previousSnapshot = snapshotPage()
            XCTAssertGreaterThan(previousSnapshot.1, 1, "This regression requires a chapter with several pages")
            XCTAssertEqual(previousSnapshot.0, previousSnapshot.1, "The incoming animation must capture the last page, not the title page: \(body.label)")
            XCTAssertTrue(page.label.hasPrefix("\(previousSnapshot.1)/"), page.label)
            attachScreenshot(app)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            waitForChapter(21)
            let nextSnapshot = snapshotPage()
            XCTAssertEqual(nextSnapshot.0, 1, "Forward navigation must still start on the first page")
            XCTAssertTrue(page.label.hasPrefix("1/"), page.label)
        }
    }

    func testPagedChapterWaitsOnTheCurrentPageAndFailedLoadsCanRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagedBoundaryRegression", "-uiPagedBoundaryFailure",
                               "-uiPagingDiagnostics", "-pageAnim", "1", "-themeMode", "1"]
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let viewport = app.otherElements["reader.viewport"]
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(app.descendants(matching: .any)["reader.chapterPreparing"].waitForExistence(timeout: 2))
        XCTAssertTrue((body.value as? String ?? "").contains("第21章 · 连续阅读"))
        XCTAssertFalse(app.staticTexts["正在打开本章"].exists)
        XCTAssertTrue(app.staticTexts["reader.chapterTurnError"].waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String ?? "").contains("第21章 · 连续阅读"))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        let ready = expectation(for: NSPredicate { _, _ in
            (body.value as? String ?? "").contains("第22章 · 连续阅读")
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 8)
        XCTAssertTrue(body.label.contains("chapterTransitions=1"), body.label)
        XCTAssertFalse(app.staticTexts["reader.chapterTurnError"].exists)
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
        app.buttons["目录"].tap()
        XCTAssertTrue(app.staticTexts["reader.toc.cachedSummary"].waitForExistence(timeout: 5))
        app.buttons["reader.toc.cacheMenu"].tap()
        app.buttons["缓存管理"].tap()
        XCTAssertTrue(app.navigationBars["缓存管理"].waitForExistence(timeout: 5))
        app.navigationBars["缓存管理"].buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        app.navigationBars["目录"].buttons["关闭"].tap()

        showMenu()
        XCTAssertFalse(app.buttons["外观"].exists)
        let dayNight = app.buttons["reader.toggleDayNight"]
        let initialMode = dayNight.label
        dayNight.tap()
        XCTAssertTrue(app.buttons["设置"].isHittable, "切换日夜间后菜单应保持打开")
        XCTAssertNotEqual(dayNight.label, initialMode)
        dayNight.tap()
        XCTAssertEqual(dayNight.label, initialMode)

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["阅读亮度"].isHittable)
        let systemBrightness = app.switches["reader.followSystemBrightness"]
        XCTAssertTrue(systemBrightness.isHittable)
        if systemBrightness.value as? String == "0" { systemBrightness.tap() }
        app.sliders["阅读亮度"].adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertEqual(systemBrightness.value as? String, "0")
        systemBrightness.tap()
        XCTAssertEqual(systemBrightness.value as? String, "1")
        XCTAssertTrue(app.navigationBars["阅读设置"].exists)
        XCTAssertFalse(app.navigationBars["阅读样式"].exists)
        app.buttons["reader.quickDefaultLayout"].tap()
        let size = app.staticTexts["reader.quickFontSize"]
        XCTAssertEqual(size.value as? String, "20")
        app.buttons["增大字号"].tap()
        XCTAssertEqual(size.value as? String, "21")
        app.buttons["减小字号"].tap()
        XCTAssertEqual(size.value as? String, "20")
        attachScreenshot(app)

        for attempt in 0..<2 {
            app.buttons["reader.moreAppearance"].tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
            if usesLegacyUI && attempt == 0 {
                let choose = app.buttons["选择背景图片"]
                scrollToAppearanceElement(choose, in: app)
                choose.tap()
                let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
                XCTAssertTrue(cancel.waitForExistence(timeout: 10))
                cancel.tap()
                XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
            }
            app.navigationBars["阅读样式"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["reader.moreAppearance"].isHittable)
            XCTAssertEqual(size.value as? String, "20")
        }
        app.buttons["完成"].tap()
        waitForChapter("第五章 · 天明")
        attachScreenshot(app)
    }

    func testForwardAndReverseFlicksKeepMomentumAcrossChapterInsertion() throws {
        let (app, reader) = launchReader(shortChapters: false, delayedLoads: true)
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

    private func launchReader(shortChapters: Bool, delayedLoads: Bool = false) -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "3", "-themeMode", "0"]
        if shortChapters { app.launchArguments.append("-uiShortChapters") }
        if delayedLoads { app.launchArguments.append("-uiDelayedScrollLoads") }
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

    func testSourceListAutomaticallyShowsScopedReferenceComparison() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoSourceSwitch", "-uiDemoSourceReference"]
        app.launch()
        let result = app.staticTexts["sourceSwitch.verification.https://science.example"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let verified = expectation(for: NSPredicate(format: "label CONTAINS %@", "可见片段相似"), evaluatedWith: result)
        wait(for: [verified], timeout: 10)
        XCTAssertTrue(app.staticTexts["sourceSwitch.reference"].label.contains("QQ 阅读（演示）"))
        XCTAssertTrue(result.label.contains("正文多于参照"))
        XCTAssertFalse(app.buttons["sourceSwitch.confirm"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Automatic-visible-reference-comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSourceListGroupsEqualBodiesWithoutAnOfficialReference() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoSourceSwitch", "-uiDemoSourceGroups"]
        app.launch()
        let group = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "同文组 1", "2 个书源")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        XCTAssertTrue(group.label.contains("未验证"))
        XCTAssertTrue(app.staticTexts["sourceSwitch.reference.unavailable"].label.contains("不代表正确"))
        XCTAssertFalse(app.buttons["sourceSwitch.confirm"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Unverified-identical-body-group"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSourceSearchFiltersCandidatesAndKeepsTheSelectedPreview() {
        continueAfterFailure = false
        let app = launchSourceSwitchPreview()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://science.example|")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://audio.example|")).firstMatch
        let search = app.textFields["sourceSwitch.search"]
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("SCIENCE\n")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        first.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)

        search.tap()
        app.buttons["sourceSwitch.search.clear"].tap()
        search.typeText("no-such-source\n")
        XCTAssertTrue(app.staticTexts["没有匹配的书源"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        XCTAssertFalse(second.exists)
        waitForSourcePreview("远方书库的本章正文", in: app)
        XCTAssertTrue(app.buttons["sourceSwitch.confirm"].isEnabled)
        app.buttons["sourceSwitch.search.clear"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        attachScreenshot(app)
        app.buttons["sourceSwitch.confirm"].tap()
        let current = app.staticTexts["sourceSwitch.demo.current"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(current.label, "当前书源：远方书库")
    }

    func testSourceSwitchPreviewsCurrentChapterUntilExplicitConfirmation() {
        continueAfterFailure = false
        let app = launchSourceSwitchPreview()
        let confirm = app.buttons["sourceSwitch.confirm"]
        XCTAssertFalse(confirm.isEnabled)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://science.example|")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://audio.example|")).firstMatch
        first.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)
        XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].exists)
        XCTAssertEqual(app.staticTexts["sourceSwitch.preview.mapping"].label, "仅目录标题匹配")
        XCTAssertEqual(app.staticTexts["sourceSwitch.preview.chapter"].label, "第二章 · 灯塔")
        XCTAssertTrue(confirm.isEnabled)
        attachScreenshot(app)

        second.tap()
        waitForSourcePreview("听见故事的本章正文", in: app)
        XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].exists)
        XCTAssertEqual(app.staticTexts["sourceSwitch.preview.mapping"].label, "按进度定位")
        first.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)
        confirm.tap()
        let dismissed = expectation(for: NSPredicate { _, _ in
            !app.navigationBars["为《长夜里的灯》换源"].exists
        }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 5)
        XCTAssertEqual(app.staticTexts["sourceSwitch.demo.current"].label, "当前书源：远方书库")
    }

    func testCancelSourcePreviewKeepsTheOriginalSource() {
        continueAfterFailure = false
        let app = launchSourceSwitchPreview()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceSwitch.candidate.https://science.example|")).firstMatch.tap()
        waitForSourcePreview("远方书库的本章正文", in: app)
        app.buttons["取消"].tap()
        let current = app.staticTexts["sourceSwitch.demo.current"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(current.label, "当前书源：经典文学馆")
        XCTAssertFalse(app.navigationBars["为《长夜里的灯》换源"].exists)
    }

    private func launchSourceSwitchPreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoSourceSwitch", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].waitForExistence(timeout: 20))
        return app
    }

    private func waitForSourcePreview(_ text: String, in app: XCUIApplication) {
        let content = app.staticTexts["sourceSwitch.preview.content"]
        let loaded = expectation(for: NSPredicate { _, _ in content.exists && content.label.contains(text) }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 10)
    }

    private func attachScreenshot(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
