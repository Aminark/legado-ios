import Foundation
import SwiftUI
import CloudKit

enum BackupCloudProvider: String, Identifiable {
    case webDAV, googleDrive
    var id: String { rawValue }
    var title: String { self == .webDAV ? "WebDAV" : "Google Drive" }
}

@MainActor
final class BackupSyncModel: ObservableObject {
    enum Operation: Equatable {
        case iCloudSync, webDAVConnection, webDAVSync, googleBinding
        case automaticBackup(BackupCloudProvider), upload(BackupCloudProvider), remoteList(BackupCloudProvider)
        case remotePreview(BackupCloudProvider, String)
        case export, prepare, restore
    }
    static let didApply = Notification.Name("LegadoLibraryBackupDidApply")
    @Published private(set) var enabled = false
    @Published private(set) var operation: Operation?
    var isWorking: Bool { operation != nil }
    @Published private(set) var accountStatus = "正在检查 iCloud…"
    @Published private(set) var lastSync: Date?
    @Published var message: String?
    @Published var prepared: PreparedLibraryBackup?
    @Published var exportURL: URL?
    @Published private(set) var webDAVConnected = false
    @Published private(set) var webDAVEnabled = false
    @Published private(set) var webDAVAddress = ""
    @Published private(set) var webDAVUsername = ""
    @Published private(set) var webDAVLastSync: Date?
    @Published private(set) var googleEmail: String?
    @Published private(set) var googleRestoring = false
    @Published private(set) var googleNotice: String?
    @Published private(set) var remoteBackups: [RemoteLibraryBackup] = []
    @Published private(set) var remoteListLoaded = false
    @Published private(set) var automaticBackupProviders: Set<BackupCloudProvider> = []
    @Published private(set) var automaticBackupDates: [BackupCloudProvider: Date] = [:]
    @Published private(set) var automaticBackupErrors: [BackupCloudProvider: String] = [:]
    @Published private(set) var automaticBackupIntervals: [BackupCloudProvider: Int] = [:]
    let iCloudConfigured: Bool
    var googleConfigured: Bool { demo || google.isConfigured }
    var hasAutomaticSync: Bool { enabled || webDAVEnabled || !automaticBackupProviders.isEmpty }
    private let service: LibraryBackupService?
    private let cloud: any LibraryCloudTransport
    private let sync: LibrarySyncCoordinator?
    private let defaults: UserDefaults
    private let demo: Bool
    private var ready = false
    private var syncTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private let automaticBackup: AutomaticLibraryBackup
    private var preparedForCleanup: PreparedLibraryBackup?
    private var restoreCompleted = false
    private let google = GoogleBackupAccount()
    private let supportDirectory: URL
    private var webDAV: WebDAVLibraryCloud?
    private let demoRemote = PreviewRemoteBackups()
    private let enabledKey = "legado.icloud.enabled"
    private let accountKey = "legado.icloud.account"

    init(demo: Bool = false) {
        self.demo = demo
        let suite = demo ? "BackupDemo.\(UUID().uuidString)" : nil
        defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let directory = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("backup-demo-\(UUID().uuidString)") : LegadoDatabase.defaultURL().deletingLastPathComponent()
        supportDirectory = directory
        automaticBackup = AutomaticLibraryBackup(directory: directory.appendingPathComponent("AutomaticBackups"))
        iCloudConfigured = demo || (Bundle.main.object(forInfoDictionaryKey: "LegadoICloudEnabled") as? String)?.uppercased() == "YES"
        cloud = demo ? PreviewLibraryCloud() : ICloudLibraryTransport(containerID: "iCloud." + (Bundle.main.bundleIdentifier ?? "com.epiboly.legado"))
        do {
            let storage: LibraryBackupService
            if demo {
                storage = LibraryBackupService(database: try LegadoDatabase(url: directory.appendingPathComponent("library.sqlite3")), support: directory,
                    cache: directory.appendingPathComponent("Chapters"), defaultsSuite: suite)
            } else { storage = try LibraryBackupService.live() }
            service = storage
            sync = LibrarySyncCoordinator(service: storage, cloud: cloud, directory: directory.appendingPathComponent("Sync"), device: Self.deviceID(defaults))
        } catch { service = nil; sync = nil; message = error.localizedDescription }
        enabled = defaults.bool(forKey: enabledKey)
        if !iCloudConfigured { enabled = false }
        webDAVEnabled = defaults.bool(forKey: "legado.webdav.enabled")
        if let date = defaults.object(forKey: "legado.icloud.lastSync") as? Date { lastSync = date }
    }

    func start() async {
        if demo, let service, !ready {
            var fixture = LibrarySnapshot(); fixture.books = DemoContent.books; fixture.sources = DemoContent.sources
            fixture.bookmarks = DemoContent.bookmarks
            fixture.records = DemoContent.readRecords
            fixture.searchKeywords = [.init(word: "演示搜索记录", usage: 3, lastUseTime: 100)]
            fixture.rssReadRecords = [.init(record: "https://example.test/demo-article", title: "演示订阅文章", readTime: 100)]
            if let empty = try? await service.snapshot() { try? await service.apply(fixture, expected: empty) }
        }
        ready = true
        if !demo {
            do {
                if let saved = try BackupCredentialVault.readWebDAV() {
                    webDAV = try saved.transport(); webDAVConnected = true
                    webDAVAddress = saved.address; webDAVUsername = saved.username
                } else { webDAVEnabled = false }
            } catch { webDAVEnabled = false; message = error.localizedDescription }
            if defaults.bool(forKey: "legado.google.bound"), google.isConfigured {
                googleRestoring = true
                do { try await google.restore(); googleEmail = google.email }
                catch { googleNotice = "Google 登录状态暂不可用，请重新绑定。" }
                googleRestoring = false
            }
        }
        webDAVLastSync = defaults.object(forKey: "legado.webdav.lastSync") as? Date
        await refreshAutomaticBackup(.webDAV)
        await refreshAutomaticBackup(.googleDrive)
        await refreshAccount()
        await automaticSync()
    }

    func recoverInterruptedImport() async {
        do { try await service?.recoverInterruptedImport() }
        catch { message = "上次恢复尚未完成：\(error.localizedDescription)" }
    }

    func refreshAccount() async {
        guard iCloudConfigured else { accountStatus = "此版本暂未启用 iCloud，可使用下方其他备份方式。"; return }
        do {
            let account = try await cloud.accountIdentifier()
            if enabled, defaults.string(forKey: accountKey) != account { accountChanged(); return }
            accountStatus = "系统 iCloud 已登录"
        } catch { accountStatus = error.localizedDescription }
    }

    func setEnabled(_ value: Bool) async {
        guard value else { disable(); return }
        guard !isWorking, iCloudConfigured else { return }
        operation = .iCloudSync
        do {
            let account = try await cloud.accountIdentifier()
            webDAVEnabled = false; defaults.set(false, forKey: "legado.webdav.enabled")
            defaults.set(account, forKey: accountKey); defaults.set(true, forKey: enabledKey)
            enabled = true; accountStatus = "系统 iCloud 已登录"
            operation = nil
            await synchronize()
        } catch { operation = nil; accountStatus = error.localizedDescription; message = error.localizedDescription }
    }

    func disable() {
        enabled = false; defaults.set(false, forKey: enabledKey); syncTask?.cancel()
    }

    func cancelSynchronization() { automaticTask?.cancel(); syncTask?.cancel() }

    func accountChanged() {
        disable(); accountStatus = LibraryCloudError.accountChanged.localizedDescription
        defaults.removeObject(forKey: accountKey); defaults.removeObject(forKey: "legado.icloud.lastSync"); lastSync = nil
    }

    func automaticSync(forceBackup: BackupCloudProvider? = nil, backupsOnly: Bool = false) async {
        if let active = automaticTask { await active.value; return }
        guard ready, !isWorking else { return }
        let task = Task { @MainActor [self] in
            if forceBackup == nil && !backupsOnly {
                if enabled && !Task.isCancelled { await synchronize() }
                if webDAVEnabled && !Task.isCancelled { await synchronizeWebDAV() }
            }
            for provider in [BackupCloudProvider.webDAV, .googleDrive] {
                guard !Task.isCancelled else { return }
                if forceBackup == nil || forceBackup == provider { await backupAutomatically(to: provider, force: forceBackup == provider) }
            }
        }
        automaticTask = task
        await task.value
        automaticTask = nil
    }

    func connectWebDAV(address: String, username: String, password: String) async -> Bool {
        guard !isWorking else { return false }
        operation = .webDAVConnection; defer { operation = nil }
        do {
            let account = WebDAVBackupAccount(address: address.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            let transport = try account.transport()
            if !demo { try await transport.connect(); try BackupCredentialVault.saveWebDAV(account) }
            webDAV = transport; webDAVConnected = true; webDAVAddress = account.address; webDAVUsername = account.username
            webDAVEnabled = false; defaults.set(false, forKey: "legado.webdav.enabled")
            webDAVLastSync = nil; defaults.removeObject(forKey: "legado.webdav.lastSync")
            await refreshAutomaticBackup(.webDAV)
            operation = nil
            await automaticSync(forceBackup: .webDAV)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func disconnectWebDAV() {
        guard !isWorking else { return }
        do {
            if !demo { try BackupCredentialVault.removeWebDAV() }
            webDAVEnabled = false; webDAVConnected = false; webDAV = nil
            webDAVAddress = ""; webDAVUsername = ""; webDAVLastSync = nil
            defaults.removeObject(forKey: "legado.webdav.enabled"); defaults.removeObject(forKey: "legado.webdav.lastSync")
            disableAutomaticBackup(.webDAV)
        } catch { message = error.localizedDescription }
    }

    func setWebDAVEnabled(_ enabled: Bool) async {
        guard !isWorking, webDAVConnected else { return }
        webDAVEnabled = enabled; defaults.set(enabled, forKey: "legado.webdav.enabled")
        if enabled { disable() }
        if enabled { await synchronizeWebDAV() }
    }

    func synchronizeWebDAV() async {
        guard !isWorking, let webDAV, let service else { return }
        operation = .webDAVSync; defer { operation = nil }
        let task = Task { @MainActor [self] in
            do {
                if !demo {
                    let coordinator = LibrarySyncCoordinator(service: service, cloud: webDAV, directory: supportDirectory.appendingPathComponent("Sync/WebDAV"), device: Self.deviceID(defaults))
                    try await coordinator.synchronize(account: webDAV.accountIdentifier())
                }
                try Task.checkCancellation()
                webDAVLastSync = Date(); defaults.set(webDAVLastSync, forKey: "legado.webdav.lastSync")
                NotificationCenter.default.post(name: Self.didApply, object: nil)
            } catch is CancellationError { }
              catch { message = error.localizedDescription }
        }
        syncTask = task; await task.value; syncTask = nil
    }

    func bindGoogle() async {
        guard !isWorking, !googleRestoring else { return }
        operation = .googleBinding
        var bound = false
        do {
            if demo { googleEmail = "demo@example.com（演示）" }
            else { try await google.bind(); googleEmail = google.email; defaults.set(true, forKey: "legado.google.bound") }
            googleNotice = nil
            await refreshAutomaticBackup(.googleDrive)
            bound = true
        } catch { if (error as NSError).code != -5 { message = error.localizedDescription } }
        operation = nil
        if bound { await automaticSync(forceBackup: .googleDrive) }
    }

    func disconnectGoogle() {
        guard !isWorking, !googleRestoring else { return }
        if !demo { google.disconnect() }
        googleEmail = nil; googleNotice = nil; defaults.removeObject(forKey: "legado.google.bound")
        disableAutomaticBackup(.googleDrive)
    }

    func setAutomaticBackup(_ enabled: Bool, for provider: BackupCloudProvider) async {
        guard !isWorking, !googleRestoring else { return }
        do {
            let account = try await automaticBackupAccount(provider)
            defaults.set(enabled, forKey: automaticBackupPreferenceKey(provider, account: account))
            guard enabled else { disableAutomaticBackup(provider); return }
            defaults.set(account, forKey: automaticBackupKey(provider))
            automaticBackupProviders.insert(provider)
            await automaticSync(forceBackup: provider)
        } catch { automaticBackupErrors[provider] = error.localizedDescription }
    }

    private func automaticBackupKey(_ provider: BackupCloudProvider) -> String { "legado.backup.automatic.\(provider.rawValue).account" }

    private func automaticBackupPreferenceKey(_ provider: BackupCloudProvider, account: String) -> String {
        "legado.backup.automatic.\(provider.rawValue).enabled.\(account)"
    }

    func automaticBackupInterval(for provider: BackupCloudProvider) -> Int {
        automaticBackupIntervals[provider] ?? AutomaticLibraryBackup.defaultIntervalMinutes
    }

    private func automaticBackupIntervalKey(_ provider: BackupCloudProvider, account: String) -> String {
        "legado.backup.automatic.\(provider.rawValue).interval.\(account)"
    }

    @discardableResult
    func setAutomaticBackupInterval(_ minutes: Int, for provider: BackupCloudProvider) async -> Bool {
        guard !isWorking, !googleRestoring, AutomaticLibraryBackup.intervalMinutesRange.contains(minutes) else { return false }
        do {
            let account = try await automaticBackupAccount(provider)
            defaults.set(minutes, forKey: automaticBackupIntervalKey(provider, account: account))
            automaticBackupIntervals[provider] = minutes
            return true
        } catch { message = error.localizedDescription; return false }
    }

    private func disableAutomaticBackup(_ provider: BackupCloudProvider) {
        automaticBackupProviders.remove(provider)
        automaticBackupErrors[provider] = nil
        automaticBackupDates[provider] = nil
        defaults.removeObject(forKey: automaticBackupKey(provider))
    }

    private func automaticBackupAccount(_ provider: BackupCloudProvider) async throws -> String {
        switch provider {
        case .googleDrive:
            guard googleEmail != nil, let id = demo ? "demo-google" : google.accountIdentifier else { throw RemoteLibraryError.authentication }
            return provider.rawValue + ":" + id
        case .webDAV:
            guard webDAVConnected, let webDAV else { throw RemoteLibraryError.authentication }
            return provider.rawValue + ":" + (try await webDAV.accountIdentifier())
        }
    }

    private func refreshAutomaticBackup(_ provider: BackupCloudProvider) async {
        automaticBackupProviders.remove(provider)
        automaticBackupDates[provider] = nil
        automaticBackupErrors[provider] = nil
        automaticBackupIntervals[provider] = nil
        guard let account = try? await automaticBackupAccount(provider) else { return }
        automaticBackupIntervals[provider] = AutomaticLibraryBackup.normalizedIntervalMinutes(
            defaults.integer(forKey: automaticBackupIntervalKey(provider, account: account)))
        let enabled = defaults.object(forKey: automaticBackupPreferenceKey(provider, account: account)) as? Bool ?? true
        if enabled {
            defaults.set(account, forKey: automaticBackupKey(provider))
            automaticBackupProviders.insert(provider)
        } else { defaults.removeObject(forKey: automaticBackupKey(provider)) }
        do { automaticBackupDates[provider] = try await automaticBackup.lastBackup(account: account) }
        catch { automaticBackupErrors[provider] = error.localizedDescription }
    }

    private func backupAutomatically(to provider: BackupCloudProvider, force: Bool) async {
        guard automaticBackupProviders.contains(provider), !isWorking, prepared == nil, exportURL == nil, let service else { return }
        operation = .automaticBackup(provider); defer { operation = nil }
        do {
            let account = try await automaticBackupAccount(provider)
            guard defaults.string(forKey: automaticBackupKey(provider)) == account else { disableAutomaticBackup(provider); return }
            let outcome = try await automaticBackup.run(service: service, store: remote(provider), account: account, force: force,
                                                       intervalMinutes: automaticBackupInterval(for: provider))
            automaticBackupDates[provider] = outcome.lastBackup
            if case .deferred = outcome { return }
            automaticBackupErrors[provider] = nil
        } catch is CancellationError { }
          catch { automaticBackupErrors[provider] = error.localizedDescription }
    }

    private func remote(_ provider: BackupCloudProvider) throws -> any RemoteLibraryBackupStore {
        if demo { return demoRemote }
        switch provider {
        case .webDAV: guard let webDAV else { throw RemoteLibraryError.authentication }; return webDAV
        case .googleDrive: return try google.store()
        }
    }

    func uploadBackup(to provider: BackupCloudProvider) async {
        guard !isWorking, let service else { return }
        operation = .upload(provider); defer { operation = nil }
        do {
            try await demoBackupDelay()
            let store = try remote(provider)
            let url = try await service.export(includeLocalBooks: false, includeCachedChapters: false)
            defer { try? FileManager.default.removeItem(at: url) }
            try await store.uploadBackup(url)
            message = demo ? "演示备份已保存，未上传到真实云端。" : "备份已保存到 \(provider.title)。"
        } catch { message = error.localizedDescription }
    }

    func loadRemoteBackups(from provider: BackupCloudProvider) async {
        guard !isWorking else { return }
        operation = .remoteList(provider); remoteListLoaded = false; remoteBackups = []
        defer { operation = nil }
        do { remoteBackups = try await remote(provider).listBackups(); remoteListLoaded = true }
        catch { message = error.localizedDescription }
    }

    func previewRemoteBackup(_ backup: RemoteLibraryBackup, from provider: BackupCloudProvider) async {
        guard !isWorking, let service else { return }
        operation = .remotePreview(provider, backup.id); defer { operation = nil }
        do {
            try await demoBackupDelay()
            let url = try await remote(provider).downloadBackup(backup)
            defer { try? FileManager.default.removeItem(at: url) }
            prepared = try await service.prepare(url); preparedForCleanup = prepared
        } catch { message = error.localizedDescription }
    }

    func synchronize() async {
        guard enabled, !isWorking, let sync, let account = defaults.string(forKey: accountKey) else { return }
        operation = .iCloudSync
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil; self.syncTask = nil }
            do {
                try await sync.synchronize(account: account)
                try Task.checkCancellation()
                self.lastSync = Date(); self.defaults.set(self.lastSync, forKey: "legado.icloud.lastSync")
                self.accountStatus = "已同步到 iCloud"
                NotificationCenter.default.post(name: Self.didApply, object: nil)
            } catch is CancellationError { }
              catch LibraryCloudError.accountChanged { self.accountChanged(); self.message = LibraryCloudError.accountChanged.localizedDescription }
              catch { self.accountStatus = "同步未完成，本机数据仍保留"; self.message = error.localizedDescription }
        }
        syncTask = task; await task.value
    }

    func export(localBooks: Bool, cachedChapters: Bool) async {
        guard !isWorking, let service else { return }
        operation = .export; defer { operation = nil }
        do { exportURL = try await service.export(includeLocalBooks: localBooks, includeCachedChapters: cachedChapters) }
        catch { message = error.localizedDescription }
    }

    func prepare(_ url: URL) async {
        guard !isWorking, let service else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        operation = .prepare; defer { operation = nil }
        do { prepared = try await service.prepare(url); preparedForCleanup = prepared } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !isWorking, let service, let prepared else { return }
        operation = .restore; defer { operation = nil }
        do {
            try await service.restore(prepared)
            await service.cleanup(prepared)
            preparedForCleanup = nil
            restoreCompleted = true
            self.prepared = nil
            NotificationCenter.default.post(name: Self.didApply, object: nil)
        } catch { message = error.localizedDescription }
    }

    func cancelRestore() {
        guard !isWorking else { return }
        if let prepared = preparedForCleanup, let service { Task { await service.cleanup(prepared) } }
        preparedForCleanup = nil
        prepared = nil
    }
    func finishRestorePreview() {
        cancelRestore()
        if restoreCompleted {
            restoreCompleted = false
            message = "备份已合并恢复，原有数据已保留。"
        }
    }
    func cleanupExport() {
        if let url = exportURL { try? FileManager.default.removeItem(at: url) }
        exportURL = nil
    }

    private func demoBackupDelay() async throws {
        #if DEBUG
        if demo, ProcessInfo.processInfo.arguments.contains("-uiDemoSlowBackup") {
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        #endif
    }
    #if DEBUG
    func prepareDemoPreviewIfRequested() async {
        guard demo, ProcessInfo.processInfo.arguments.contains("-uiBackupPreview"), prepared == nil, let service else { return }
        do {
            let url = try await service.export(includeLocalBooks: false, includeCachedChapters: false)
            defer { try? FileManager.default.removeItem(at: url) }
            prepared = try await service.prepare(url); preparedForCleanup = prepared
        } catch { message = error.localizedDescription }
    }
    #endif
    private static func deviceID(_ defaults: UserDefaults) -> String {
        let key = "legado.icloud.device"
        if let value = defaults.string(forKey: key) { return value }
        let value = UUID().uuidString; defaults.set(value, forKey: key); return value
    }
}

private struct PreviewLibraryCloud: LibraryCloudTransport {
    func accountIdentifier() async throws -> String { throw LibraryCloudError.unavailable("演示模式不连接真实 iCloud。") }
    func fetch() async throws -> LibraryCloudVersion { throw LibraryCloudError.unavailable("演示模式不连接真实 iCloud。") }
    func save(_ document: LibrarySyncDocument, replacing token: Data?) async throws { throw LibraryCloudError.unavailable("演示模式不连接真实 iCloud。") }
}

private actor PreviewRemoteBackups: RemoteLibraryBackupStore {
    private var files: [String: Data] = [:]
    func listBackups() async throws -> [RemoteLibraryBackup] {
        files.keys.sorted().map { .init(id: $0, name: $0, date: Date(), bytes: Int64(files[$0]!.count)) }
    }
    func uploadBackup(_ file: URL) async throws { files[UUID().uuidString + ".legadobackup"] = try Data(contentsOf: file) }
    func downloadBackup(_ backup: RemoteLibraryBackup) async throws -> URL {
        guard let data = files[backup.id] else { throw RemoteLibraryError.invalidResponse }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".legadobackup")
        try data.write(to: url); return url
    }
}
