import Foundation

/// Uses only Drive's appDataFolder, never the user's unrelated Drive files.
public struct GoogleDriveBackupStore: RemoteLibraryBackupStore {
    private let accessToken: @Sendable () async throws -> String
    private let http: any HTTPTransport
    public init(http: any HTTPTransport = LibraryCloudHTTPTransport(), accessToken: @escaping @Sendable () async throws -> String) {
        self.http = http; self.accessToken = accessToken
    }
    public func listBackups() async throws -> [RemoteLibraryBackup] {
        struct File: Decodable { var id: String; var name: String; var modifiedTime: Date?; var size: String? }
        struct Page: Decodable { var files: [File]; var nextPageToken: String? }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var items: [RemoteLibraryBackup] = []; var page: String?; var seen = Set<String>()
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                .init(name: "spaces", value: "appDataFolder"), .init(name: "pageSize", value: "100"),
                .init(name: "q", value: "'appDataFolder' in parents and trashed = false"),
                .init(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,size)"),
                .init(name: "orderBy", value: "modifiedTime desc")
            ]
            if let page { components.queryItems?.append(.init(name: "pageToken", value: page)) }
            let response = try await request("GET", url: components.url!)
            try RemoteLibraryError.check(response, allowing: [200])
            let value = try decoder.decode(Page.self, from: response.data)
            for file in value.files {
                guard Self.validID(file.id), RemoteBackupFiles.validName(file.name), let size = file.size.flatMap(Int64.init),
                      size > 0, size <= LibraryCloudHTTPTransport.maximumBytes else { continue }
                guard !items.contains(where: { $0.id == file.id }), items.count < 10_000 else { throw RemoteLibraryError.invalidResponse }
                items.append(.init(id: file.id, name: file.name, date: file.modifiedTime, bytes: size))
            }
            page = value.nextPageToken
            if let page { guard seen.insert(page).inserted, seen.count < 100 else { throw RemoteLibraryError.invalidResponse } }
        } while page != nil
        return items
    }
    public func uploadBackup(_ file: URL) async throws {
        let data = try RemoteBackupFiles.read(file)
        let metadata = try JSONSerialization.data(withJSONObject: ["name": RemoteBackupFiles.newName(), "parents": ["appDataFolder"]])
        let start = try await request("POST", url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!,
                                      body: metadata, headers: ["Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": String(data.count)])
        try RemoteLibraryError.check(start, allowing: [200, 201])
        guard let location = start.headers.first(where: { $0.key.lowercased() == "location" })?.value,
              let url = URL(string: location), Self.allowed(url), url.path.hasPrefix("/upload/drive/v3/files") else { throw RemoteLibraryError.invalidResponse }
        let finish = try await request("PUT", url: url, body: data, headers: ["Content-Type": "application/octet-stream"])
        try RemoteLibraryError.check(finish, allowing: [200, 201])
    }
    public func downloadBackup(_ backup: RemoteLibraryBackup) async throws -> URL {
        guard Self.validID(backup.id), backup.bytes > 0, backup.bytes <= LibraryCloudHTTPTransport.maximumBytes else { throw RemoteLibraryError.invalidResponse }
        let response = try await request("GET", url: URL(string: "https://www.googleapis.com/drive/v3/files/\(backup.id)?alt=media")!)
        try RemoteLibraryError.check(response, allowing: [200])
        return try RemoteBackupFiles.temporary(response.data)
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
    }
    private static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.googleapis.com" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    private func request(_ method: String, url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> HTTPResponse {
        guard Self.allowed(url) else { throw RemoteLibraryError.unsafeRedirect }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let response = try await http.data(for: request)
        guard response.finalURL == url else { throw RemoteLibraryError.unsafeRedirect }
        guard response.data.count <= LibraryCloudHTTPTransport.maximumBytes else { throw LibraryBackupError.tooLarge }
        return response
    }
}
