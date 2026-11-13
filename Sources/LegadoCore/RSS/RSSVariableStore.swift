import CryptoKit
import Foundation

/// RSS rule data survives article reloads and is separate from disposable caches.
/// Android uses the same source/article/key partitioning for RuleBigDataHelp.
public final class RSSVariableStore: @unchecked Sendable {
    public static let shared = RSSVariableStore()
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = LegadoDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("ruleData/rss", isDirectory: true)) {
        self.directory = directory
    }

    public func get(origin: String, link: String, key: String) throws -> String? {
        try lock.withLock { try read(origin: origin, link: link)?[key] }
    }

    public func put(origin: String, link: String, key: String, value: String?) throws {
        try apply(origin: origin, link: link, changes: [key: value.map(RSSVariableState.Change.value) ?? .remove])
    }

    func apply(origin: String, link: String, changes: [String: RSSVariableState.Change]) throws {
        guard !changes.isEmpty else { return }
        try lock.withLock {
            let existing = try read(origin: origin, link: link)
            var values = existing ?? [:]
            for (key, change) in changes {
                switch change {
                case .value(let value): values[key] = value
                case .remove: values.removeValue(forKey: key)
                }
            }
            guard existing != nil || !values.isEmpty else { return }
            let url = fileURL(origin: origin, link: link)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Commit the whole article together. A failed later key must never
            // leave an earlier key from the same rule partially written.
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        }
    }

    private func read(origin: String, link: String) throws -> [String: String]? {
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL(origin: origin, link: link)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func fileURL(origin: String, link: String) -> URL {
        directory.appendingPathComponent(Self.digest(origin), isDirectory: true)
            .appendingPathComponent(Self.digest(link) + ".json")
    }

    private static func digest(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Transient rule state. List parsing cannot write until the final article URL
/// is known; content parsing keeps the identity of the article the user opened.
struct RSSVariableState: Sendable {
    enum Change: Sendable { case value(String), remove }
    let store: RSSVariableStore
    var identity: (origin: String, link: String)?
    var changes: [String: Change] = [:]
    var defersCommit = false

    init(store: RSSVariableStore, article: RssArticle) {
        self.store = store
        if !article.origin.isEmpty && !article.link.isEmpty { identity = (article.origin, article.link) }
    }

    func get(_ key: String) throws -> String? {
        if let change = changes[key] {
            switch change { case .value(let value): return value; case .remove: return nil }
        }
        guard let identity else { return nil }
        return try store.get(origin: identity.origin, link: identity.link, key: key)
    }

    mutating func put(_ key: String, _ value: String?) {
        changes[key] = value.map(Change.value) ?? .remove
    }

    mutating func commit() throws {
        guard let identity, !defersCommit else { return }
        try store.apply(origin: identity.origin, link: identity.link, changes: changes)
        changes.removeAll()
    }
}
