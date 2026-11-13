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
            RootTabView()
                .environmentObject(sourceLibrary)
                .environmentObject(bookLibrary)
                .environmentObject(replaceRuleLibrary)
                .environmentObject(readingActivity)
                .environmentObject(rssLibrary)
                .environmentObject(ruleSubscriptions)
                .task {
                    await sourceLibrary.load()
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                        await sourceLibrary.handleDeepLink(url)
                        if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                            sourceLibrary.notice = nil
                        }
                    }
                    await bookLibrary.load()
                    await replaceRuleLibrary.load()
                    await readingActivity.load()
                    await rssLibrary.load()
                    await ruleSubscriptions.load()
                    if UserDefaults.standard.bool(forKey: "auto_refresh") {
                        await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                    }
                    await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                }
                .onOpenURL { url in
                    Task {
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
