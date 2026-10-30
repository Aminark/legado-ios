import CryptoKit
import Foundation
import OSLog
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct SourceSwitchSnapshot: Codable, Sendable {
    var version = 1
    var createdAt: Date
    var candidates: [BookSourceCandidate]
    var searchComplete: Bool
    var reference: SourceChapterReference?
    var referenceCheckedAt: Date?
    var reports: [String: BookSourceSwitchReport]
    var unmatched: [String]
    var searchedSourceIDs: Set<String> = []
}

/// Memory survives sheet dismissal; disk survives app restarts. Neither cache
/// writes to the bookshelf or changes the current reading source.
@MainActor
final class SourceSwitchCache {
    static let shared = SourceSwitchCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Legado/SourceSwitch", isDirectory: true))

    private let disk: SourceSwitchCacheDisk?
    private let maximumAge: TimeInterval
    private let now: () -> Date
    private var entries: [String: SourceSwitchSnapshot] = [:]
    private var recent: [String] = []
    private var writes: [String: Task<Void, Never>] = [:]
    private var revisions: [String: Int] = [:]

    init(directory: URL? = nil, maximumAge: TimeInterval = 86_400, now: @escaping () -> Date = Date.init) {
        disk = directory.map { SourceSwitchCacheDisk(directory: $0) }
        self.maximumAge = maximumAge
        self.now = now
    }

    static func key(book: Book, sources: [BookSource]) -> String? {
        struct Identity: Encodable {
            let version: Int
            let bookURL: String
            let origin: String
            let name: String
            let author: String
            let chapter: String?
            let index: Int
            let total: Int
            let sources: [BookSource]
        }
        // Timing/weight change after network requests without changing rules.
        let rules = sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }
            .sorted { $0.id < $1.id }.map { source in
                var copy = source
                copy.respondTime = 0
                copy.weight = 0
                return copy
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Identity(version: 1, bookURL: book.bookUrl, origin: book.origin,
            name: book.name, author: book.author, chapter: book.durChapterTitle, index: book.durChapterIndex,
            total: book.totalChapterNum, sources: rules)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load(_ key: String) async -> SourceSwitchSnapshot? {
        if let value = entries[key] { return valid(value) ? value : discard(key) }
        let revision = revisions[key, default: 0]
        await writes[key]?.value
        let stored = await disk?.load(key)
        // A refresh/store during disk IO takes precedence over the old read.
        guard revision == revisions[key, default: 0] else {
            return entries[key].flatMap { valid($0) ? $0 : nil }
        }
        guard let stored else { return nil }
        guard valid(stored) else { return discard(key) }
        remember(stored, key: key)
        return stored
    }

    func store(_ snapshot: SourceSwitchSnapshot, key: String) {
        revisions[key, default: 0] += 1
        remember(snapshot, key: key)
        writes[key]?.cancel()
        guard let disk else { return }
        writes[key] = Task {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            await disk.save(snapshot, key: key)
        }
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
        recent.removeAll { $0 == key }
        revisions[key, default: 0] += 1
        writes[key]?.cancel()
        if let disk { writes[key] = Task { await disk.remove(key) } }
    }

    func flush() async {
        for task in writes.values { await task.value }
    }

    private func valid(_ value: SourceSwitchSnapshot) -> Bool {
        let age = now().timeIntervalSince(value.createdAt)
        return value.version == 1 && age >= -300 && age < maximumAge
    }

    private func discard(_ key: String) -> SourceSwitchSnapshot? { remove(key); return nil }

    private func remember(_ value: SourceSwitchSnapshot, key: String) {
        entries[key] = value
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > 3 { entries.removeValue(forKey: recent.removeFirst()) }
    }
}

private actor SourceSwitchCacheDisk {
    private let directory: URL
    private let logger = Logger(subsystem: "Legado", category: "SourceSwitchCache")
    private let maximumEntryBytes = 16 * 1_024 * 1_024

    init(directory: URL) { self.directory = directory }

    func load(_ key: String) -> SourceSwitchSnapshot? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumEntryBytes else { remove(key); return nil }
            return try JSONDecoder().decode(SourceSwitchSnapshot.self, from: Data(contentsOf: url))
        } catch {
            logger.error("读取换源缓存失败：\(error.localizedDescription, privacy: .public)")
            remove(key)
            return nil
        }
    }

    func save(_ value: SourceSwitchSnapshot, key: String) {
        guard !Task.isCancelled else { return }
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= maximumEntryBytes else {
                remove(key)
                logger.notice("换源缓存超过单项上限，跳过落盘")
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(key), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
                .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
            var bytes = 0
            for (index, item) in files.enumerated() {
                bytes += item.1.fileSize ?? 0
                if index >= 12 || bytes > 64 * 1_024 * 1_024 { try FileManager.default.removeItem(at: item.0) }
            }
        } catch { logger.error("保存换源缓存失败：\(error.localizedDescription, privacy: .public)") }
    }

    func remove(_ key: String) {
        guard !Task.isCancelled else { return }
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { logger.error("清理换源缓存失败：\(error.localizedDescription, privacy: .public)") }
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
}
