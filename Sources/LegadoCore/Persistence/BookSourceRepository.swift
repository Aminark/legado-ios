import Foundation

public protocol BookSourceRepository: Sendable {
    func load() async throws -> [BookSource]
    func save(_ sources: [BookSource]) async throws
    func saveUpdate(_ source: BookSource, in sources: [BookSource]) async throws
}

public extension BookSourceRepository {
    func saveUpdate(_ source: BookSource, in sources: [BookSource]) async throws {
        try await save(sources)
    }
}

public actor FileBookSourceRepository: BookSourceRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> [BookSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([BookSource].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ sources: [BookSource]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(sources)
        try data.write(to: fileURL, options: .atomic)
    }
}

public actor InMemoryBookSourceRepository: BookSourceRepository {
    private var sources: [BookSource]

    public init(sources: [BookSource] = []) {
        self.sources = sources
    }

    public func load() -> [BookSource] { sources }

    public func save(_ sources: [BookSource]) {
        self.sources = sources
    }
}

