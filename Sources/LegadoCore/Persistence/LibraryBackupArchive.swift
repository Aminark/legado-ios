import Foundation
import CryptoKit

public struct LibraryBackupManifest: Codable, Sendable {
    public struct Attachment: Codable, Sendable {
        public var path: String; public var bytes: Int64; public var checksum: String
    }
    public var version = 1
    public var createdAt: Date
    public var snapshot: LibrarySnapshot
    public var attachments: [Attachment]
}

public struct PreparedLibraryBackup: Identifiable, Sendable {
    public let id: UUID
    public let manifest: LibraryBackupManifest
    public let directory: URL
}

/// A bounded, streaming single-file archive; attachments are never decoded into one large Data value.
public enum LibraryBackupArchive {
    private static let magic = Data("LGBK0001".utf8)
    private static let manifestLimit = 32 * 1024 * 1024
    private static let totalLimit: Int64 = 8 * 1024 * 1024 * 1024

    public static func write(snapshot: LibrarySnapshot, files: [String: URL], to destination: URL) throws {
        _ = try snapshot.validated()
        var descriptors: [LibraryBackupManifest.Attachment] = []
        for key in files.keys.sorted() {
            guard let url = files[key] else { throw LibraryBackupError.changed }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryBackupError.invalid("不支持符号链接") }
            let bytes = Int64(values.fileSize ?? 0)
            try validate(path: key, bytes: bytes)
            descriptors.append(.init(path: key, bytes: bytes, checksum: try hashFile(url)))
        }
        guard descriptors.count <= 50_000, descriptors.reduce(Int64(0), { $0 + $1.bytes }) <= totalLimit else { throw LibraryBackupError.tooLarge }
        let manifest = LibraryBackupManifest(createdAt: Date(), snapshot: snapshot, attachments: descriptors)
        let data = try LibrarySnapshot.encode(manifest)
        guard data.count <= manifestLimit else { throw LibraryBackupError.tooLarge }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.write(contentsOf: magic)
            var length = UInt64(data.count).bigEndian
            try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
            try output.write(contentsOf: Data(SHA256.hash(data: data)))
            try output.write(contentsOf: data)
            for descriptor in descriptors {
                guard let url = files[descriptor.path] else { throw LibraryBackupError.changed }
                let digest = try copy(url, output: output, bytes: descriptor.bytes)
                guard digest == descriptor.checksum else { throw LibraryBackupError.changed }
            }
            try output.synchronize()
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    public static func prepare(_ source: URL) throws -> PreparedLibraryBackup {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try read(input, count: 8) == magic else { throw LibraryBackupError.invalid("不是小浣熊阅读备份") }
        let lengthData = try read(input, count: 8)
        let length = lengthData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= manifestLimit else { throw LibraryBackupError.tooLarge }
        let digest = try read(input, count: 32)
        let data = try read(input, count: Int(length))
        guard Data(SHA256.hash(data: data)) == digest else { throw LibraryBackupError.invalid("清单校验失败") }
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: data)
        guard manifest.version == 1 else { throw LibraryBackupError.unsupportedVersion }
        _ = try manifest.snapshot.validated()
        guard manifest.attachments.count <= 50_000,
              Set(manifest.attachments.map(\.path)).count == manifest.attachments.count else { throw LibraryBackupError.invalid("附件数量或路径重复") }
        var total: Int64 = 0
        for file in manifest.attachments {
            try validate(path: file.path, bytes: file.bytes)
            total += file.bytes
            guard total <= totalLimit, file.checksum.count == 64 else { throw LibraryBackupError.tooLarge }
        }
        for book in manifest.snapshot.books where book.origin == "local" {
            guard let url = URL(string: book.bookUrl), url.isFileURL,
                  manifest.attachments.contains(where: { $0.path == "local/" + url.lastPathComponent }) else {
                throw LibraryBackupError.invalid("本地书缺少对应文件")
            }
        }
        let expectedBytes = Int64(48 + data.count) + total
        guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(expectedBytes) else { throw LibraryBackupError.invalid("文件不完整或含多余数据") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legado-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for file in manifest.attachments {
                let target = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: target.path, contents: nil)
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var remaining = file.bytes
                var hash = SHA256()
                while remaining > 0 {
                    try Task.checkCancellation()
                    let chunk = try read(input, count: Int(min(remaining, 1024 * 1024)))
                    hash.update(data: chunk); try output.write(contentsOf: chunk); remaining -= Int64(chunk.count)
                }
                guard hex(hash.finalize()) == file.checksum else { throw LibraryBackupError.invalid("附件校验失败：\(file.path)") }
            }
            return PreparedLibraryBackup(id: UUID(), manifest: manifest, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private static func validate(path: String, bytes: Int64) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["local", "chapters"].contains(parts[0]),
              !parts[1].isEmpty, !parts[1].hasPrefix("."), parts[1].utf8.count <= 255,
              !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              bytes >= 0, bytes <= 512 * 1024 * 1024 else { throw LibraryBackupError.invalid("附件路径或大小不正确") }
        if parts[0] == "chapters" {
            guard bytes <= ChapterContentCache.maximumEntryBytes, parts[1].hasSuffix(".json"),
                  parts[1].dropLast(5).count == 129,
                  parts[1].dropLast(5).allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
                throw LibraryBackupError.invalid("正文缓存附件不正确")
            }
        } else if !["txt", "epub"].contains(URL(fileURLWithPath: String(parts[1])).pathExtension.lowercased()) { throw LibraryBackupError.invalid("本地书格式不正确") }
    }

    private static func read(_ input: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try input.read(upToCount: count - data.count) ?? Data()
            guard !chunk.isEmpty else { throw LibraryBackupError.invalid("文件已截断") }
            data.append(chunk)
        }
        return data
    }
    private static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hex(hash.finalize())
    }
    private static func copy(_ url: URL, output: FileHandle, bytes: Int64) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256(); var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try read(input, count: Int(min(remaining, 1024 * 1024)))
            try output.write(contentsOf: data); hash.update(data: data); remaining -= Int64(data.count)
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw LibraryBackupError.changed }
        return hex(hash.finalize())
    }
    private static func hex(_ hash: SHA256.Digest) -> String { hash.map { String(format: "%02x", $0) }.joined() }
}

public actor LibraryBackupService {
    private let database: LegadoDatabase
    private let support: URL
    private let cache: URL
    private let defaults: UserDefaults
    private let removeJournal: @Sendable (URL) throws -> Void
    private var applying = false
    private var rulesURL: URL { support.appendingPathComponent("replace-rules.json") }
    private var journalURL: URL { support.appendingPathComponent("library-import-journal.json") }

    public init(database: LegadoDatabase, support: URL, cache: URL, defaultsSuite: String? = nil,
                removeJournal: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.database = database; self.support = support; self.cache = cache
        self.removeJournal = removeJournal
        defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
    public static func live() throws -> LibraryBackupService {
        .init(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()), support: LegadoDatabase.defaultURL().deletingLastPathComponent(),
              cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Legado/Chapters"))
    }
    public func snapshot(includeChapters: Bool = true) async throws -> LibrarySnapshot {
        try await recoverInterruptedImport()
        guard !applying else { throw LibraryCloudError.busy }
        applying = true; defer { applying = false }
        var value = try await database.librarySnapshot(includeChapters: includeChapters)
        value.replaceRules = try readRules()
        value.preferences = try LibraryPreferences.read(defaults)
        return value
    }
    public func export(includeLocalBooks: Bool, includeCachedChapters: Bool) async throws -> URL {
        var value = try await snapshot()
        var files: [String: URL] = [:]
        if includeLocalBooks {
            for book in value.books where book.origin == "local" {
                guard let url = URL(string: book.bookUrl), url.isFileURL,
                      url.deletingLastPathComponent().standardizedFileURL == support.appendingPathComponent("LocalBooks").standardizedFileURL else {
                    throw LibraryBackupError.invalid("本地书文件位置不正确")
                }
                files["local/" + url.lastPathComponent] = url
            }
        } else {
            value.books.removeAll { $0.origin == "local" }
            value.chapters = value.chapters.filter { key, _ in value.books.contains { $0.id == key } }
        }
        if includeCachedChapters, FileManager.default.fileExists(atPath: cache.path) {
            for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                files["chapters/" + url.lastPathComponent] = url
            }
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("小浣熊阅读-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).legadobackup")
        try LibraryBackupArchive.write(snapshot: value, files: files, to: destination)
        return destination
    }
    public func prepare(_ url: URL) throws -> PreparedLibraryBackup {
        var coordinationError: NSError?
        var result: Result<PreparedLibraryBackup, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try LibraryBackupArchive.prepare(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LibraryBackupError.invalid("无法读取备份文件") }
        return try result.get()
    }
    public func cleanup(_ prepared: PreparedLibraryBackup) { try? FileManager.default.removeItem(at: prepared.directory) }

    public func restore(_ prepared: PreparedLibraryBackup) async throws {
        var incoming = prepared.manifest.snapshot
        let before = try await snapshot()
        let skipped = incoming.books.filter { book in book.origin == "local" && before.books.contains { $0.name == book.name && $0.author == book.author } }
        incoming.books.removeAll { book in skipped.contains { $0.id == book.id } }
        for book in skipped { incoming.chapters.removeValue(forKey: book.id) }
        var created: [URL] = []
        do {
            for attachment in prepared.manifest.attachments {
                let source = prepared.directory.appendingPathComponent(attachment.path)
                let local = attachment.path.hasPrefix("local/")
                if local, !incoming.books.contains(where: { $0.origin == "local" && URL(string: $0.id)?.lastPathComponent == source.lastPathComponent }) { continue }
                var stem = source.deletingPathExtension().lastPathComponent
                while stem.utf8.count > 180 { stem.removeLast() }
                let target = local ? support.appendingPathComponent("LocalBooks/\(stem)-\(attachment.checksum.prefix(12)).\(source.pathExtension.lowercased())") : cache.appendingPathComponent(source.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let staging = target.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString)")
                    do {
                        try FileManager.default.copyItem(at: source, to: staging)
                        try FileManager.default.moveItem(at: staging, to: target); created.append(target)
                    } catch { try? FileManager.default.removeItem(at: staging); throw error }
                } else {
                    let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw LibraryBackupError.invalid("目标文件不是普通文件") }
                }
                if local {
                    for index in incoming.books.indices where incoming.books[index].origin == "local" && URL(string: incoming.books[index].bookUrl)?.lastPathComponent == source.lastPathComponent {
                        let old = incoming.books[index].bookUrl
                        incoming.books[index].bookUrl = target.absoluteString
                        if incoming.books[index].tocUrl == old { incoming.books[index].tocUrl = target.absoluteString }
                        if let chapters = incoming.chapters.removeValue(forKey: old) {
                            incoming.chapters[target.absoluteString] = chapters.map { chapter in
                                var chapter = chapter; chapter.bookUrl = target.absoluteString
                                if chapter.url.hasPrefix(old) { chapter.url = target.absoluteString + chapter.url.dropFirst(old.count) }
                                return chapter
                            }
                        }
                    }
                }
            }
            let existing = try await snapshot()
            try await apply(existing.merging(incoming), expected: existing)
        } catch { for url in created { try? FileManager.default.removeItem(at: url) }; throw error }
    }

    public func apply(_ value: LibrarySnapshot, expected: LibrarySnapshot) async throws {
        try await recoverInterruptedImport()
        guard !applying else { throw LibraryCloudError.busy }
        applying = true; defer { applying = false }
        _ = try value.validated()
        guard try readRules() == expected.replaceRules, try LibraryPreferences.read(defaults) == expected.preferences else { throw LibraryBackupError.changed }
        let journal = LibraryImportJournal(id: UUID().uuidString, oldPreferences: expected.preferences,
            newPreferences: value.preferences, oldRules: expected.replaceRules, newRules: value.replaceRules)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try LibrarySnapshot.encode(journal).write(to: journalURL, options: .atomic)
        var databaseCommitted = false
        do {
            try applyJournal(journal, committed: true)
            try await database.applyLibrarySnapshot(value, expected: expected, transactionID: journal.id)
            databaseCommitted = true
            try removeJournal(journalURL)
        } catch {
            if databaseCommitted {
                // A cleanup failure must not make restore remove attachments already referenced by committed books.
                DiagnosticLog.shared.record(.error, category: "备份", message: "数据已恢复，恢复日志稍后清理：\(error.localizedDescription)")
                return
            }
            // Keep the journal if rollback cannot finish; startup will use SQLite's commit marker.
            do {
                let committed = try await database.cacheValue(for: "library.lastImport", now: 0) == journal.id
                var recovery = journal
                if !committed {
                    let current = try LibraryPreferences.read(defaults)
                    for key in LibraryPreferences.keys where current[key] != journal.newPreferences[key] { recovery.oldPreferences[key] = current[key] }
                    let rules = try readRules()
                    if rules != journal.newRules { recovery.oldRules = rules }
                    try LibrarySnapshot.encode(recovery).write(to: journalURL, options: .atomic)
                }
                try applyJournal(recovery, committed: committed)
                try removeJournal(journalURL)
            } catch { DiagnosticLog.shared.record(.error, category: "备份", message: "恢复日志将在下次启动时重试：\(error.localizedDescription)") }
            throw error
        }
    }

    public func recoverInterruptedImport() async throws {
        guard !applying else { throw LibraryCloudError.busy }
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        applying = true; defer { applying = false }
        let journal = try JSONDecoder().decode(LibraryImportJournal.self, from: Data(contentsOf: journalURL))
        let committed = try await database.cacheValue(for: "library.lastImport", now: 0) == journal.id
        try applyJournal(journal, committed: committed)
        try removeJournal(journalURL)
    }
    private func applyJournal(_ journal: LibraryImportJournal, committed: Bool) throws {
        let preferences = committed ? journal.newPreferences : journal.oldPreferences
        try LibraryPreferences.write(preferences, to: defaults)
        try LibrarySnapshot.encode(committed ? journal.newRules : journal.oldRules).write(to: rulesURL, options: .atomic)
        defaults.synchronize()
    }
    private func readRules() throws -> [ReplaceRule] {
        guard FileManager.default.fileExists(atPath: rulesURL.path) else { return [] }
        return try JSONDecoder().decode([ReplaceRule].self, from: Data(contentsOf: rulesURL))
    }
}

struct LibraryImportJournal: Codable {
    var id: String
    var oldPreferences: [String: JSONValue]; var newPreferences: [String: JSONValue]
    var oldRules: [ReplaceRule]; var newRules: [ReplaceRule]
}
