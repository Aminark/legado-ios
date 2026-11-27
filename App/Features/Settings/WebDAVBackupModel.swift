import Foundation
import Security

/// Stores WebDAV passwords in the iOS Keychain rather than UserDefaults,
/// with a scoped fallback file in Application Support when running in an
/// unsigned/simulator environment that lacks a Keychain entitlement.
enum WebDAVKeychain {
    private static let service = "com.epiboly.legado.webdav"
    private static let account = "primary-password"

    static func loadPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        guard status == errSecItemNotFound || status == errSecMissingEntitlement else { return "" }
        return loadFallbackPassword() ?? ""
    }

    static func savePassword(_ password: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if password.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            try removeFallbackPassword()
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecSuccess {
            try removeFallbackPassword()
        } else if status == errSecMissingEntitlement {
            try saveFallbackPassword(password)
        } else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static var fallbackURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Legado", isDirectory: true)
            .appendingPathComponent(".webdav-secret")
    }

    private static func loadFallbackPassword() -> String? {
        guard let url = fallbackURL,
              let data = try? Data(contentsOf: url),
              let decoded = Data(base64Encoded: data) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    private static func saveFallbackPassword(_ password: String) throws {
        guard var url = fallbackURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = Data(password.utf8).base64EncodedData()
        try encoded.write(to: url, options: [.atomic, .completeFileProtection])
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try url.setResourceValues(attributes)
    }

    private static func removeFallbackPassword() throws {
        guard let url = fallbackURL, FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Manages WebDAV settings persistence, manual and automatic backups, history
/// browsing, retention pruning, and preview-before-merge cloud restores.
@MainActor
final class WebDAVBackupCoordinator: ObservableObject {
    static let shared = WebDAVBackupCoordinator()
    private static let settingsKey = "webdavBackupSettingsV1"

    @Published var settings: WebDAVBackupSettings {
        didSet {
            if settings.serverURL != oldValue.serverURL || settings.remoteDirectory != oldValue.remoteDirectory
                || settings.username != oldValue.username {
                backups = []
                previewBackup = nil
                previewFileName = nil
                settings.lastBackupAt = nil
                settings.lastFailureAt = nil
                settings.lastStatusMessage = nil
                clearStatus()
            }
        }
    }
    @Published var password: String
    @Published private(set) var backups: [WebDAVRemoteBackup] = []
    @Published private(set) var isWorking = false
    @Published private(set) var workingLabel = ""
    @Published var previewBackup: PreparedLibraryBackup?
    @Published var previewFileName: String?
    @Published var statusMessage: String?
    @Published var statusDetail: String?
    @Published var isStatusError = false

    private let client: WebDAVClient
    private var persistedPassword: String

    init(client: WebDAVClient = WebDAVClient()) {
        self.client = client
        if let raw = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(WebDAVBackupSettings.self, from: raw) {
            self.settings = decoded
        } else {
            self.settings = WebDAVBackupSettings()
        }
        let savedPassword = WebDAVKeychain.loadPassword()
        self.password = savedPassword
        self.persistedPassword = savedPassword
    }

    var credentials: WebDAVCredentials {
        WebDAVCredentials(
            serverURL: settings.serverURL,
            remoteDirectory: settings.remoteDirectory,
            username: settings.username,
            password: password
        )
    }

    @discardableResult
    func persistConfiguration() -> Bool {
        if password != persistedPassword {
            do {
                try WebDAVKeychain.savePassword(password)
                persistedPassword = password
            } catch {
                setError("无法保存 WebDAV 密码：\(error.localizedDescription)")
                return false
            }
        }
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        }
        return true
    }

    func testConnection() async {
        guard !isWorking else { return }
        guard persistConfiguration() else { return }
        isWorking = true
        workingLabel = "正在测试 WebDAV 连接…"
        clearStatus()
        defer { isWorking = false }
        do {
            try await client.testConnection(credentials: credentials)
            try await client.ensureDirectory(credentials: credentials)
            backups = try await client.listBackups(credentials: credentials)
            setSuccess("连接成功", detail: "云端共有 \(backups.count) 份历史备份")
        } catch {
            setError(error.localizedDescription)
        }
    }

    func refreshHistory() async {
        guard !isWorking else { return }
        guard persistConfiguration() else { return }
        guard credentials.isConfigured else {
            setError("请先填写 WebDAV 地址、账号和密码")
            return
        }
        isWorking = true
        workingLabel = "正在获取云端历史备份…"
        clearStatus()
        defer { isWorking = false }
        do {
            backups = try await client.listBackups(credentials: credentials)
            setSuccess("列表已更新", detail: backups.isEmpty ? "云端暂无备份文件" : "共找到 \(backups.count) 份历史备份")
        } catch {
            setError(error.localizedDescription)
        }
    }

    func backupNow(flushLibraries: @escaping @MainActor () async -> Void) async {
        guard !isWorking else { return }
        guard persistConfiguration() else { return }
        guard credentials.isConfigured else {
            setError("请先填写 WebDAV 地址、账号和密码")
            return
        }
        isWorking = true
        workingLabel = settings.includeLocalBooks ? "正在打包书库并上传至 WebDAV…" : "正在上传书库备份…"
        clearStatus()
        defer { isWorking = false }
        do {
            await flushLibraries()
            let summary = try await executeBackupUpload()
            setSuccess("已上传云端备份", detail: summary)
        } catch {
            settings.lastFailureAt = Date()
            settings.lastStatusMessage = "失败：\(error.localizedDescription)"
            persistConfiguration()
            setError(error.localizedDescription)
        }
    }

    func runAutomaticBackupIfDue(flushLibraries: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        guard WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(
            settings: settings,
            hasPassword: !password.isEmpty
        ) else { return }

        isWorking = true
        workingLabel = "正在自动备份书库…"
        Task {
            defer { self.isWorking = false }
            do {
                await flushLibraries()
                let detail = try await self.executeBackupUpload()
                DiagnosticLog.shared.record(category: "云同步", message: "WebDAV 自动备份成功：\(detail)")
            } catch {
                self.settings.lastFailureAt = Date()
                self.settings.lastStatusMessage = "自动备份失败：\(error.localizedDescription)"
                self.persistConfiguration()
                DiagnosticLog.shared.record(.error, category: "云同步", message: "WebDAV 自动备份失败：\(error.localizedDescription)")
            }
        }
    }

    func downloadAndPreview(_ remote: WebDAVRemoteBackup) async {
        guard !isWorking else { return }
        guard persistConfiguration() else { return }
        isWorking = true
        workingLabel = "正在下载并校验 \(remote.fileName)…"
        clearStatus()
        previewBackup = nil
        previewFileName = nil
        defer { isWorking = false }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-dl-\(UUID().uuidString).legadobackup")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            _ = try await client.download(remoteFileName: remote.fileName, credentials: credentials, to: tempFile)
            let service = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupService.live()
            }.value
            previewBackup = try await service.prepare(tempFile)
            previewFileName = remote.fileName
        } catch {
            setError(error.localizedDescription)
        }
    }

    func commitRestore(
        flushLibraries: @escaping @MainActor () async -> Void,
        reloadLibraries: @escaping @MainActor () async -> Void
    ) async {
        guard !isWorking, let prepared = previewBackup else { return }
        isWorking = true
        workingLabel = "正在合并云端备份到当前书库…"
        clearStatus()
        defer { isWorking = false }
        do {
            await flushLibraries()
            let service = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupService.live()
            }.value
            try await service.restore(prepared)
            await reloadLibraries()
            let restoredName = previewFileName ?? "云端备份"
            previewBackup = nil
            previewFileName = nil
            setSuccess("已从云端恢复书库", detail: "来源：\(restoredName)")
        } catch {
            setError(error.localizedDescription)
        }
    }

    func deleteRemoteBackup(_ remote: WebDAVRemoteBackup) async {
        guard !isWorking else { return }
        isWorking = true
        workingLabel = "正在删除云端备份…"
        clearStatus()
        defer { isWorking = false }
        do {
            try await client.delete(remoteFileName: remote.fileName, credentials: credentials)
            backups.removeAll { $0.id == remote.id }
            if previewFileName == remote.fileName {
                previewBackup = nil
                previewFileName = nil
            }
            setSuccess("已删除云端备份", detail: remote.fileName)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func executeBackupUpload() async throws -> String {
        let includeLocal = settings.includeLocalBooks
        let service = try await Task.detached(priority: .userInitiated) {
            try LibraryBackupService.live()
        }.value
        let exported = try await service.exportDetailed(includeLocalBooks: includeLocal)
        defer { try? FileManager.default.removeItem(at: exported.url) }

        let fileName = WebDAVAutoBackupPolicy.makeBackupFileName()
        let activeCreds = credentials
        try await client.upload(fileURL: exported.url, remoteFileName: fileName, credentials: activeCreds)

        let listed = try await client.listBackups(credentials: activeCreds)
        let obsolete = WebDAVAutoBackupPolicy.backupsToPrune(
            from: listed,
            maxRetained: settings.maxRetainedBackups,
            keeping: fileName
        )
        var deleted = Set<String>()
        for item in obsolete {
            do {
                try await client.delete(remoteFileName: item.fileName, credentials: activeCreds)
                deleted.insert(item.id)
            } catch {
                DiagnosticLog.shared.record(.error, category: "云同步", message: "清理 \(item.fileName) 失败：\(error.localizedDescription)")
            }
        }
        backups = listed.filter { !deleted.contains($0.id) }

        settings.lastBackupAt = Date()
        settings.lastFailureAt = nil
        var notes: [String] = [fileName]
        if !exported.skippedLocalBooks.isEmpty {
            notes.append("跳过 \(exported.skippedLocalBooks.count) 本缺失本地文件的书")
        }
        if !deleted.isEmpty {
            notes.append("已自动清理 \(deleted.count) 份过期备份")
        }
        if deleted.count < obsolete.count {
            notes.append("\(obsolete.count - deleted.count) 份过期备份清理失败")
        }
        let detail = notes.joined(separator: "；")
        settings.lastStatusMessage = "最近备份：\(fileName)"
        persistConfiguration()
        return detail
    }

    private func clearStatus() {
        statusMessage = nil
        statusDetail = nil
        isStatusError = false
    }

    private func setSuccess(_ title: String, detail: String? = nil) {
        isStatusError = false
        statusMessage = title
        statusDetail = detail
    }

    private func setError(_ detail: String) {
        isStatusError = true
        statusMessage = detail
        statusDetail = nil
    }
}
