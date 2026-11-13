import Foundation

public protocol BookRepository: Sendable {
    func load() async throws -> [Book]
    func save(_ books: [Book]) async throws
}

/// Stores the shelf and its replacement directory in one transaction. The
/// implementation owns both tables; callers must use the matching chapter store.
public protocol SourceSwitchBookRepository: BookRepository {
    func saveSourceSwitch(_ books: [Book], chapters: [BookChapter], bookURL: String) async throws
}

public actor FileBookRepository: BookRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> [Book] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([Book].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ books: [Book]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(books).write(to: fileURL, options: .atomic)
    }
}

public actor InMemoryBookRepository: BookRepository {
    private var books: [Book]

    public init(books: [Book] = []) {
        self.books = books
    }

    public func load() -> [Book] { books }

    public func save(_ books: [Book]) {
        self.books = books
    }
}

public protocol BookGroupRepository: Sendable {
    func load() async throws -> [BookGroup]
    func save(_ groups: [BookGroup]) async throws
}

public actor FileBookGroupRepository: BookGroupRepository {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> [BookGroup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([BookGroup].self, from: Data(contentsOf: fileURL))
    }
    public func save(_ groups: [BookGroup]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(groups).write(to: fileURL, options: .atomic)
    }
}

public actor InMemoryBookGroupRepository: BookGroupRepository {
    private var groups: [BookGroup]
    public init(groups: [BookGroup] = []) { self.groups = groups }
    public func load() -> [BookGroup] { groups }
    public func save(_ groups: [BookGroup]) { self.groups = groups }
}
