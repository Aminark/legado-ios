import SwiftUI

@main
struct LegadoApp: App {
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookLibrary: BookLibraryModel
    @StateObject private var replaceRuleLibrary: ReplaceRuleLibraryModel
    @StateObject private var readingActivity: ReadingActivityModel
    @StateObject private var rssLibrary: RSSLibraryModel
    @StateObject private var ruleSubscriptions: RuleSubscriptionModel
    @State private var incomingBackupURL: URL?

    init() {
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        _sourceLibrary = StateObject(wrappedValue: demo
            ? SourceLibraryModel.demo(sources: DemoContent.sources)
            : SourceLibraryModel.live())
        _bookLibrary = StateObject(wrappedValue: demo
            ? BookLibraryModel.demo(books: DemoContent.books)
            : BookLibraryModel.live())
        _replaceRuleLibrary = StateObject(wrappedValue: demo
            ? ReplaceRuleLibraryModel.demo()
            : ReplaceRuleLibraryModel.live())
        _readingActivity = StateObject(wrappedValue: demo
            ? ReadingActivityModel.demo(bookmarks: DemoContent.bookmarks, records: DemoContent.readRecords)
            : ReadingActivityModel.live())
        _rssLibrary = StateObject(wrappedValue: RSSLibraryModel.live())
        _ruleSubscriptions = StateObject(wrappedValue: RuleSubscriptionModel())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(incomingBackupURL: $incomingBackupURL)
                .environmentObject(sourceLibrary)
                .environmentObject(bookLibrary)
                .environmentObject(replaceRuleLibrary)
                .environmentObject(readingActivity)
                .environmentObject(rssLibrary)
                .environmentObject(ruleSubscriptions)
                .task {
                    // Load books and sources in parallel so the bookshelf renders immediately.
                    async let initialBooks: Void = bookLibrary.load()
                    async let initialSources: Void = sourceLibrary.load()
                    _ = await (initialBooks, initialSources)

                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                        await sourceLibrary.handleDeepLink(url)
                        if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                            sourceLibrary.notice = nil
                        }
                    }
                    if !ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                        do {
                            let db = try LegadoDatabase.shared()
                            try await db.applyImportedPreferences()
                            try await OfflineEditions.shared.activate(sources: sourceLibrary.sources)
                        } catch {
                            sourceLibrary.notice = .init(kind: .error, title: "书库恢复失败", detail: error.localizedDescription)
                        }
                    }
                    async let loadRules: Void = replaceRuleLibrary.load()
                    async let loadActivity: Void = readingActivity.load()
                    async let loadRSS: Void = rssLibrary.load()
                    async let loadSubs: Void = ruleSubscriptions.load()
                    _ = await (loadRules, loadActivity, loadRSS, loadSubs)
                    if UserDefaults.standard.bool(forKey: "auto_refresh") {
                        await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                    }
                    await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                    if !ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                        WebDAVBackupCoordinator.shared.runAutomaticBackupIfDue {
                            await bookLibrary.waitForLibraryWrites()
                            await sourceLibrary.waitForLibraryWrites()
                            await replaceRuleLibrary.waitForLibraryWrites()
                            await readingActivity.waitForLibraryWrites()
                            await rssLibrary.waitForLibraryWrites()
                            await ruleSubscriptions.waitForLibraryWrites()
                        }
                    }
                }
                .onOpenURL { url in
                    Task {
                        if url.isFileURL && url.pathExtension.lowercased() == "legadobackup" {
                            incomingBackupURL = url
                            return
                        }
                        if url.isFileURL && url.pathExtension.lowercased() == "epub" {
                            let file = LocalBookImportFile(url: url)
                            await bookLibrary.load()
                            await bookLibrary.importPickedLocalFiles([file])
                            sourceLibrary.notice = .init(kind: bookLibrary.errorMessage == nil ? .success : .error,
                                                         title: bookLibrary.errorMessage == nil ? "EPUB 已加入书架" : "导入失败",
                                                         detail: bookLibrary.errorMessage ?? url.lastPathComponent)
                            return
                        }
                        await sourceLibrary.load()
                        if RuleImportInput.isDeepLink(url, for: "replaceRule") {
                            await replaceRuleLibrary.load()
                            await replaceRuleLibrary.importText(url.absoluteString)
                            if let notice = replaceRuleLibrary.notice {
                                sourceLibrary.notice = .init(kind: notice.kind == .error ? .error : .success, title: notice.title, detail: notice.detail)
                                replaceRuleLibrary.notice = nil
                            }
                        } else { await sourceLibrary.handleDeepLink(url) }
                    }
                }
        }
    }
}

final class LegadoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderScreenOrientation.supportedOrientations
    }
}
