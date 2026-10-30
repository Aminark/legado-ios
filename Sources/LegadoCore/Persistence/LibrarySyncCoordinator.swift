import Foundation
import CryptoKit

public enum LibraryCloudError: Error, LocalizedError, Equatable {
    case unavailable(String), conflict, accountChanged, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .conflict: "其他设备刚更新了云端数据，请重试同步。"
        case .accountChanged: "iCloud 账号已变化，自动同步已停止。请重新启用以确认合并到当前账号。"
        case .busy: "正在处理备份或同步，请稍后再试。"
        }
    }
}

public struct LibraryCloudVersion: Sendable {
    public var document: LibrarySyncDocument
    public var token: Data?
    public init(document: LibrarySyncDocument = .init(), token: Data? = nil) { self.document = document; self.token = token }
}

public protocol LibraryCloudTransport: Sendable {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> LibraryCloudVersion
    func save(_ document: LibrarySyncDocument, replacing token: Data?) async throws
}

public actor LibrarySyncCoordinator {
    private let service: LibraryBackupService
    private let cloud: any LibraryCloudTransport
    private let directory: URL
    private let device: String
    private var busy = false
    public init(service: LibraryBackupService, cloud: any LibraryCloudTransport, directory: URL, device: String) {
        self.service = service; self.cloud = cloud; self.directory = directory; self.device = device
    }

    public func synchronize(account: String) async throws {
        guard !busy else { throw LibraryCloudError.busy }
        busy = true; defer { busy = false }
        let hash = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        let baselineURL = directory.appendingPathComponent(hash + ".json")
        let baseline = FileManager.default.fileExists(atPath: baselineURL.path)
            ? try JSONDecoder().decode(LibrarySyncDocument.self, from: Data(contentsOf: baselineURL)) : .init()
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard try await cloud.accountIdentifier() == account else { throw LibraryCloudError.accountChanged }
            let remote = try await cloud.fetch()
            let expected = try await service.snapshot(includeChapters: false)
            let merged = try LibrarySyncDocument.reconcile(local: expected, baseline: baseline, remote: remote.document,
                device: device, now: Int64(Date().timeIntervalSince1970 * 1000))
            guard try await cloud.accountIdentifier() == account else { throw LibraryCloudError.accountChanged }
            do {
                try Task.checkCancellation()
                if merged != remote.document { try await cloud.save(merged, replacing: remote.token) }
                try Task.checkCancellation()
                guard try await cloud.accountIdentifier() == account else { throw LibraryCloudError.accountChanged }
                var value = try merged.snapshot
                let localBooks = expected.books.filter { $0.origin == "local" }
                value.books.removeAll { book in localBooks.contains { $0.name == book.name && $0.author == book.author } }
                value.books.append(contentsOf: localBooks)
                try await service.apply(value, expected: expected)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try LibrarySnapshot.encode(merged).write(to: baselineURL, options: .atomic)
                return
            } catch LibraryCloudError.conflict where attempt < 2 { continue }
              catch LibraryBackupError.changed where attempt < 2 { continue }
        }
        throw LibraryCloudError.conflict
    }
}
