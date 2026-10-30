import SwiftUI
import CloudKit

@main
struct LegadoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookLibrary: BookLibraryModel
    @StateObject private var replaceRuleLibrary: ReplaceRuleLibraryModel
    @StateObject private var readingActivity: ReadingActivityModel
    @StateObject private var rssLibrary: RSSLibraryModel
    @StateObject private var ruleSubscriptions: RuleSubscriptionModel
    @StateObject private var backupSync: BackupSyncModel

    init() {
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        _backupSync = StateObject(wrappedValue: BackupSyncModel(demo: demo))
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
                .environmentObject(backupSync)
                .task {
                    await backupSync.recoverInterruptedImport()
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
                    await backupSync.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in backupSync.accountChanged() }
                .onReceive(NotificationCenter.default.publisher(for: BackupSyncModel.didApply)) { _ in
                    Task {
                        await bookLibrary.waitForPendingSaves()
                        await sourceLibrary.reloadAfterLibraryImport()
                        await bookLibrary.load(); await readingActivity.load(); await replaceRuleLibrary.load()
                        await rssLibrary.load(); await ruleSubscriptions.load()
                    }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                        catch { return }
                        guard !Task.isCancelled, scenePhase == .active else { return }
                        if !backupSync.automaticBackupProviders.isEmpty {
                            await bookLibrary.waitForPendingSaves()
                            guard !Task.isCancelled else { return }
                            await backupSync.automaticSync(backupsOnly: true)
                        }
                    }
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active || phase == .background else { return }
                    let backgroundID = phase == .background && backupSync.hasAutomaticSync
                        ? UIApplication.shared.beginBackgroundTask(withName: "LibrarySync") { Task { @MainActor in backupSync.cancelSynchronization() } } : .invalid
                    Task {
                        await bookLibrary.waitForPendingSaves()
                        await backupSync.automaticSync()
                        if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
                    }
                }
                .onOpenURL { url in
                    if GoogleBackupAccount.handle(url) { return }
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
                        if url.scheme?.lowercased() == "legado", url.path.lowercased() == "/replacerule" {
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
