import Foundation
@preconcurrency import CloudKit
#if SWIFT_PACKAGE
import LegadoCore
#endif

actor ICloudLibraryTransport: LibraryCloudTransport {
    private let containerID: String
    private let recordID = CKRecord.ID(recordName: "library-v1")
    init(containerID: String) { self.containerID = containerID }

    private var container: CKContainer { CKContainer(identifier: containerID) }

    func accountIdentifier() async throws -> String {
        #if targetEnvironment(simulator)
        throw LibraryCloudError.unavailable("请在已登录 iCloud 的 iPhone 或 iPad 上启用；模拟器仅用于界面与合并测试。")
        #else
        switch try await container.accountStatus() {
        case .available: return try await container.userRecordID().recordName
        case .noAccount: throw LibraryCloudError.unavailable("请先在系统设置中登录 iCloud。")
        case .restricted: throw LibraryCloudError.unavailable("此设备限制了 iCloud 访问，请检查系统设置。")
        case .temporarilyUnavailable: throw LibraryCloudError.unavailable("iCloud 暂时不可用，请稍后重试。")
        default: throw LibraryCloudError.unavailable("无法确定 iCloud 账号状态，请检查网络后重试。")
        }
        #endif
    }

    func fetch() async throws -> LibraryCloudVersion {
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
                  let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 32 * 1024 * 1024 else {
                throw LibraryBackupError.invalid("iCloud 数据缺失或超出限制")
            }
            let document = try JSONDecoder().decode(LibrarySyncDocument.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            _ = try document.snapshot
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            record.encodeSystemFields(with: coder); coder.finishEncoding()
            return .init(document: document, token: coder.encodedData)
        } catch let error as CKError where error.code == .unknownItem { return .init() }
    }

    func save(_ document: LibrarySyncDocument, replacing token: Data?) async throws {
        let data = try LibrarySnapshot.encode(document)
        guard data.count <= 32 * 1024 * 1024 else { throw LibraryBackupError.tooLarge }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-library-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let record: CKRecord
        if let token {
            let coder = try NSKeyedUnarchiver(forReadingFrom: token)
            coder.requiresSecureCoding = true
            guard let decoded = CKRecord(coder: coder) else { throw LibraryBackupError.invalid("iCloud 版本标记无效") }
            record = decoded; coder.finishDecoding()
        } else { record = CKRecord(recordType: "LibraryState", recordID: recordID) }
        record["payload"] = CKAsset(fileURL: url)
        do {
            let (results, _) = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results[recordID] else { throw LibraryCloudError.unavailable("iCloud 未返回保存结果，请重试。") }
            _ = try result.get()
        } catch let error as CKError {
            if error.code == .serverRecordChanged || error.partialErrorsByItemID?.values.contains(where: { ($0 as? CKError)?.code == .serverRecordChanged }) == true {
                throw LibraryCloudError.conflict
            }
            throw error
        }
    }
}
