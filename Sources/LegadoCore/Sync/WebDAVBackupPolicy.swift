import Foundation

/// Persisted configuration (excluding password, which is stored in Keychain)
/// and pure scheduling/retention rules for automatic WebDAV backups.
public struct WebDAVBackupSettings: Codable, Equatable, Sendable {
    public var serverURL: String
    public var remoteDirectory: String
    public var username: String
    public var autoBackupEnabled: Bool
    public var autoBackupIntervalHours: Int
    public var includeLocalBooks: Bool
    public var maxRetainedBackups: Int
    public var lastBackupAt: Date?
    public var lastFailureAt: Date?
    public var lastStatusMessage: String?

    public init(
        serverURL: String = "",
        remoteDirectory: String = "LegadoBackups",
        username: String = "",
        autoBackupEnabled: Bool = false,
        autoBackupIntervalHours: Int = 24,
        includeLocalBooks: Bool = true,
        maxRetainedBackups: Int = 10,
        lastBackupAt: Date? = nil,
        lastFailureAt: Date? = nil,
        lastStatusMessage: String? = nil
    ) {
        self.serverURL = serverURL
        self.remoteDirectory = remoteDirectory
        self.username = username
        self.autoBackupEnabled = autoBackupEnabled
        self.autoBackupIntervalHours = autoBackupIntervalHours
        self.includeLocalBooks = includeLocalBooks
        self.maxRetainedBackups = maxRetainedBackups
        self.lastBackupAt = lastBackupAt
        self.lastFailureAt = lastFailureAt
        self.lastStatusMessage = lastStatusMessage
    }
}

public enum WebDAVAutoBackupPolicy {
    public static let failureBackoffSeconds: TimeInterval = 30 * 60

    public static func shouldRunAutomaticBackup(
        settings: WebDAVBackupSettings,
        hasPassword: Bool,
        now: Date = Date()
    ) -> Bool {
        guard settings.autoBackupEnabled,
              hasPassword,
              !settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let lastFailure = settings.lastFailureAt,
           now.timeIntervalSince(lastFailure) < failureBackoffSeconds {
            return false
        }
        let interval = TimeInterval(max(settings.autoBackupIntervalHours, 1) * 3600)
        guard let lastSuccess = settings.lastBackupAt else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }

    public static func makeBackupFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "legado-\(formatter.string(from: date))-\(UUID().uuidString).legadobackup"
    }

    /// Returns the oldest backups exceeding `maxRetained` (newest-first input).
    public static func backupsToPrune(
        from backups: [WebDAVRemoteBackup],
        maxRetained: Int,
        keeping uploadedName: String? = nil
    ) -> [WebDAVRemoteBackup] {
        let limit = max(maxRetained, 1)
        guard backups.count > limit else { return [] }
        let sorted = backups.sorted { lhs, rhs in
            if lhs.fileName != rhs.fileName {
                if lhs.fileName == uploadedName { return true }
                if rhs.fileName == uploadedName { return false }
            }
            let leftDate = lhs.lastModified ?? .distantPast
            let rightDate = rhs.lastModified ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.fileName > rhs.fileName
        }
        return Array(sorted.dropFirst(limit))
    }
}
