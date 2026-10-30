import Foundation
import CryptoKit

/// Per-account checkpoints contain no credentials and advance only after a successful upload.
public actor AutomaticLibraryBackup {
    public static let defaultIntervalMinutes = 360
    public static let intervalMinutesRange = 1...10_080
    public static func normalizedIntervalMinutes(_ minutes: Int) -> Int {
        intervalMinutesRange.contains(minutes) ? minutes : defaultIntervalMinutes
    }
    public enum Outcome: Equatable, Sendable {
        case deferred(Date?), unchanged(Date?), uploaded(Date)
        public var lastBackup: Date? {
            switch self { case .deferred(let date), .unchanged(let date): date; case .uploaded(let date): date }
        }
    }
    private struct Checkpoint: Codable {
        var date: Date
        var fingerprint: String
    }
    private let directory: URL
    private var running = false
    private var attempts: [String: Date] = [:]

    public init(directory: URL) { self.directory = directory }

    public func lastBackup(account: String) throws -> Date? { try checkpoint(account)?.date }

    @discardableResult
    public func run(service: LibraryBackupService, store: any RemoteLibraryBackupStore,
                    account: String, now: Date = Date(), force: Bool = false,
                    intervalMinutes: Int = AutomaticLibraryBackup.defaultIntervalMinutes) async throws -> Outcome {
        guard !running else { throw LibraryCloudError.busy }
        running = true; defer { running = false }
        try Task.checkCancellation()
        let previous = try checkpoint(account)
        let interval = TimeInterval(Self.normalizedIntervalMinutes(intervalMinutes) * 60)
        if !force {
            if let previous, now.timeIntervalSince(previous.date) < interval { return .deferred(previous.date) }
            if let attempt = attempts[account], now.timeIntervalSince(attempt) < min(300, interval) { return .deferred(previous?.date) }
        }
        attempts[account] = now
        let file = try await service.export(includeLocalBooks: false, includeCachedChapters: false)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let prepared = try await service.prepare(file)
        let fingerprint: String
        do {
            fingerprint = Self.digest(try LibrarySnapshot.encode(prepared.manifest.snapshot))
        } catch {
            await service.cleanup(prepared)
            throw error
        }
        await service.cleanup(prepared)
        try Task.checkCancellation()
        guard fingerprint != previous?.fingerprint else { return .unchanged(previous?.date) }
        try await store.uploadBackup(file)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LibrarySnapshot.encode(Checkpoint(date: now, fingerprint: fingerprint)).write(to: path(account), options: .atomic)
        return .uploaded(now)
    }

    private func checkpoint(_ account: String) throws -> Checkpoint? {
        let file = path(account)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        // A damaged local checkpoint must not prevent a new backup of the actual library.
        return try? JSONDecoder().decode(Checkpoint.self, from: data)
    }
    private func path(_ account: String) -> URL { directory.appendingPathComponent(Self.digest(Data(account.utf8)) + ".json") }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
