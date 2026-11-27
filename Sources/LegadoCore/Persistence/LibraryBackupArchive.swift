import Foundation
import CryptoKit

public struct LibraryBackupManifest: Codable, Sendable {
    public struct Attachment: Codable, Sendable {
        public var path: String
        public var bytes: Int64
        public var checksum: String
    }
    public var version = 1
    public var createdAt: Date
    public var snapshot: LibrarySnapshot
    public var attachments: [Attachment]
}

public final class PreparedLibraryBackup: Identifiable, Sendable {
    public let id: UUID
    public let manifest: LibraryBackupManifest
    public let directory: URL

    fileprivate init(id: UUID, manifest: LibraryBackupManifest, directory: URL) {
        self.id = id
        self.manifest = manifest
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
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
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".backup-" + UUID().uuidString)
        guard manager.createFile(atPath: staging.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? manager.removeItem(at: staging) }
        do {
            let output = try FileHandle(forWritingTo: staging)
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
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
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
              Set(manifest.attachments.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == manifest.attachments.count else { throw LibraryBackupError.invalid("附件数量或路径重复") }
        var total: Int64 = 0
        for file in manifest.attachments {
            try validate(path: file.path, bytes: file.bytes)
            total += file.bytes
            guard total <= totalLimit, file.checksum.count == 64 else { throw LibraryBackupError.tooLarge }
        }
        let paths = Set(manifest.attachments.map(\.path))
        for book in manifest.snapshot.books where book.origin == "local" {
            guard let url = URL(string: book.bookUrl), url.isFileURL,
                  paths.contains("local/" + url.lastPathComponent) else {
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
                var output: FileHandle?
                if file.path.hasPrefix("local/") {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    output = try FileHandle(forWritingTo: target)
                }
                defer { try? output?.close() }
                var remaining = file.bytes
                var hash = SHA256()
                while remaining > 0 {
                    try Task.checkCancellation()
                    let chunk = try read(input, count: Int(min(remaining, 1024 * 1024)))
                    hash.update(data: chunk)
                    try output?.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
                guard hex(hash.finalize()) == file.checksum else { throw LibraryBackupError.invalid("附件校验失败：\(file.path)") }
            }
            return PreparedLibraryBackup(id: UUID(), manifest: manifest, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hex(hash.finalize())
    }
    private static func copy(_ url: URL, output: FileHandle, bytes: Int64) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try read(input, count: Int(min(remaining, 1024 * 1024)))
            try output.write(contentsOf: data)
            hash.update(data: data)
            remaining -= Int64(data.count)
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw LibraryBackupError.changed }
        return hex(hash.finalize())
    }
    private static func hex(_ hash: SHA256.Digest) -> String { hash.map { String(format: "%02x", $0) }.joined() }
}

public struct LibraryBackupExportResult: Sendable {
    public let url: URL
    public let skippedLocalBooks: [String]
}

public actor LibraryBackupService {
    private static let ioQueue = DispatchQueue(label: "Legado.LibraryBackupIO", qos: .userInitiated, attributes: .concurrent)

    private let database: LegadoDatabase
    private let support: URL
    private var rulesURL: URL { support.appendingPathComponent("replace-rules.json") }

    public init(database: LegadoDatabase, support: URL) {
        self.database = database
        self.support = support
    }

    public static func live() throws -> LibraryBackupService {
        let location = LegadoDatabase.defaultURL()
        return .init(database: try LegadoDatabase.shared(url: location), support: location.deletingLastPathComponent())
    }

    private static func runBlockingIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    func snapshot() async throws -> LibrarySnapshot {
        try await database.librarySnapshot(legacyRulesURL: rulesURL)
    }

    func apply(_ value: LibrarySnapshot, expected: LibrarySnapshot) async throws {
        try await database.applyLibrarySnapshot(value, expected: expected, legacyRulesURL: rulesURL)
    }

    public func export(includeLocalBooks: Bool) async throws -> URL {
        try await exportDetailed(includeLocalBooks: includeLocalBooks).url
    }

    public func exportDetailed(includeLocalBooks: Bool) async throws -> LibraryBackupExportResult {
        var value = try await snapshot()
        var files: [String: URL] = [:]
        var skippedLocalBooks: [String] = []
        if includeLocalBooks {
            let localFolder = support.appendingPathComponent("LocalBooks", isDirectory: true)
            let localFolderPath = localFolder.resolvingSymlinksInPath().standardizedFileURL.path
            var missingIDs = Set<String>()
            for index in value.books.indices where value.books[index].origin == "local" {
                guard let url = URL(string: value.books[index].bookUrl), url.isFileURL else {
                    missingIDs.insert(value.books[index].id)
                    skippedLocalBooks.append(value.books[index].name)
                    continue
                }
                let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                let candidate: URL
                if resolvedParent == localFolderPath, FileManager.default.fileExists(atPath: url.path) {
                    candidate = url
                } else {
                    // Recover books whose saved absolute path came from a previous iOS container UUID.
                    let recovered = localFolder.appendingPathComponent(url.lastPathComponent)
                    guard FileManager.default.fileExists(atPath: recovered.path) else {
                        missingIDs.insert(value.books[index].id)
                        skippedLocalBooks.append(value.books[index].name)
                        continue
                    }
                    candidate = recovered
                }
                files["local/" + candidate.lastPathComponent] = candidate
                let portable = URL(fileURLWithPath: "/local").appendingPathComponent(candidate.lastPathComponent)
                value.relocateLocalBook(at: index, to: portable.absoluteString)
            }
            if !missingIDs.isEmpty {
                value.books.removeAll { missingIDs.contains($0.id) }
                let retained = Set(value.books.map(\.id))
                value.chapters = value.chapters.filter { retained.contains($0.key) }
            }
        } else {
            value.books.removeAll { $0.origin == "local" }
            let retained = Set(value.books.map(\.id))
            value.chapters = value.chapters.filter { retained.contains($0.key) }
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("小浣熊阅读-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).legadobackup")
        let snapshotToWrite = value
        let filesToWrite = files
        try await Self.runBlockingIO {
            try LibraryBackupArchive.write(snapshot: snapshotToWrite, files: filesToWrite, to: destination)
        }
        return LibraryBackupExportResult(url: destination, skippedLocalBooks: skippedLocalBooks)
    }

    public func prepare(_ url: URL) async throws -> PreparedLibraryBackup {
        try await Self.runBlockingIO {
            var coordinationError: NSError?
            var result: Result<PreparedLibraryBackup, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result { try LibraryBackupArchive.prepare(readable) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw LibraryBackupError.invalid("无法读取备份文件") }
            return try result.get()
        }
    }

    public func restore(_ prepared: PreparedLibraryBackup) async throws {
        var incoming = prepared.manifest.snapshot
        let before = try await snapshot().validated()
        try incoming.alignGroups(with: before.groups)
        let networkWorks = Set(before.books.filter { $0.origin != "local" }.map { [$0.name, $0.author] })
        let skipped = Set(incoming.books.filter { $0.origin == "local" && networkWorks.contains([$0.name, $0.author]) }.map(\.id))
        incoming.books.removeAll { skipped.contains($0.id) }
        incoming.chapters = incoming.chapters.filter { !skipped.contains($0.key) }
        let localBooks = before.books.filter { $0.origin == "local" }
        let localByID = Dictionary(uniqueKeysWithValues: localBooks.map { ($0.id, $0) })
        let localByWork = Dictionary(uniqueKeysWithValues: localBooks.map { ([$0.name, $0.author], $0) })
        var retainedLocalBooks = Set<String>()
        var missingLocalBooks = Set<String>()
        var localAttachments: [String: [Int]] = [:]
        for index in incoming.books.indices where incoming.books[index].origin == "local" {
            let book = incoming.books[index]
            if let name = URL(string: book.bookUrl)?.lastPathComponent { localAttachments[name, default: []].append(index) }
            guard var existing = localByID[book.id] ?? localByWork[[book.name, book.author]] else { continue }
            // Keep the local file and metadata; the normal merge still chooses progress by its timestamp.
            existing.copyProgress(from: book)
            existing.group |= book.group
            incoming.relocateLocalBook(at: index, to: existing.bookUrl)
            incoming.books[index] = existing
            if Self.hasReadableLocalFile(existing) { retainedLocalBooks.insert(existing.id) }
            else { missingLocalBooks.insert(existing.id) }
        }
        var created: [URL] = []
        var replacements: [String: String] = [:]
        let supportDirectory = support
        do {
            for attachment in prepared.manifest.attachments where attachment.path.hasPrefix("local/") {
                let source = prepared.directory.appendingPathComponent(attachment.path)
                let matchingBooks = (localAttachments[source.lastPathComponent] ?? []).filter { !retainedLocalBooks.contains(incoming.books[$0].id) }
                if matchingBooks.isEmpty { continue }
                // Each restore owns its files until the database transaction commits.
                // A failed concurrent restore can only remove the copies it created.
                let target = try await Self.runBlockingIO { () -> URL in
                    let folder = supportDirectory.appendingPathComponent("LocalBooks", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var stem = source.deletingPathExtension().lastPathComponent
                    while stem.utf8.count > 160 { stem.removeLast() }
                    let destination = folder.appendingPathComponent(stem + "-" + UUID().uuidString).appendingPathExtension(source.pathExtension)
                    let staging = folder.appendingPathComponent(".restore-" + UUID().uuidString)
                    do {
                        try FileManager.default.copyItem(at: source, to: staging)
                        try FileManager.default.moveItem(at: staging, to: destination)
                        return destination
                    } catch {
                        try? FileManager.default.removeItem(at: staging)
                        throw error
                    }
                }
                created.append(target)
                for index in matchingBooks {
                    let old = incoming.books[index].id
                    incoming.relocateLocalBook(at: index, to: target.absoluteString)
                    if missingLocalBooks.contains(old) { replacements[old] = target.absoluteString }
                }
            }
            guard incoming.books.filter({ $0.origin == "local" }).allSatisfy(Self.hasReadableLocalFile) else {
                throw LibraryBackupError.invalid("备份未能恢复可读取的本地书文件")
            }
            var current = before
            for (old, replacement) in replacements {
                if let index = current.books.firstIndex(where: { $0.id == old }) {
                    current.relocateLocalBook(at: index, to: replacement)
                }
            }
            _ = try incoming.validated()
            _ = try current.validated()
            try await apply(current.merging(incoming), expected: before)
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func hasReadableLocalFile(_ book: Book) -> Bool {
        guard let url = URL(string: book.bookUrl), url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return true
    }

}

private extension LibrarySnapshot {
    mutating func alignGroups(with existing: [BookGroup]) throws {
        var occupied = Set(existing.filter { $0.id > 0 }.map(\.id))
        var names = Dictionary(existing.filter { $0.id > 0 }.map { ($0.groupName, $0.id) }, uniquingKeysWith: { first, _ in first })
        var mapped: [Int64: Int64] = [:]
        var additions: [BookGroup] = []
        for var group in groups {
            if group.id <= 0 {
                if !existing.contains(where: { $0.id == group.id }) { additions.append(group) }
                continue
            }
            let old = group.id
            if let id = names[group.groupName] {
                mapped[old] = id
                continue
            }
            if occupied.contains(old) {
                guard let free = (0..<63).map({ Int64(1) << $0 }).first(where: { !occupied.contains($0) }) else {
                    throw LibraryBackupError.invalid("书架分组数量超出上限")
                }
                group.groupId = free
            }
            occupied.insert(group.id)
            names[group.groupName] = group.id
            mapped[old] = group.id
            additions.append(group)
        }
        groups = additions
        for index in books.indices {
            let mask = books[index].group
            books[index].group = mapped.reduce(Int64(0)) { value, entry in
                mask & entry.key == 0 ? value : value | entry.value
            }
        }
    }

    mutating func relocateLocalBook(at index: Int, to url: String) {
        let old = books[index].bookUrl
        books[index].bookUrl = url
        if books[index].tocUrl == old { books[index].tocUrl = url }
        if let chapters = chapters.removeValue(forKey: old) {
            self.chapters[url] = chapters.map { chapter in
                var chapter = chapter
                chapter.bookUrl = url
                if chapter.baseUrl == old { chapter.baseUrl = url }
                if chapter.url.hasPrefix(old + "#") || chapter.url == old { chapter.url = url + chapter.url.dropFirst(old.count) }
                return chapter
            }
        }
    }
}
