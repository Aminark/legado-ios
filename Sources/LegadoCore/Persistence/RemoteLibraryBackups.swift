import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

public struct RemoteLibraryBackup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let date: Date?
    public let bytes: Int64
    public init(id: String, name: String, date: Date?, bytes: Int64) {
        self.id = id; self.name = name; self.date = date; self.bytes = bytes
    }
}

public protocol RemoteLibraryBackupStore: Sendable {
    func listBackups() async throws -> [RemoteLibraryBackup]
    func uploadBackup(_ file: URL) async throws
    func downloadBackup(_ backup: RemoteLibraryBackup) async throws -> URL
}

public enum RemoteLibraryError: Error, LocalizedError, Equatable {
    case invalidAddress, authentication, accessDenied, status(Int), invalidResponse, unsafeRedirect, versionUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请填写有效的 HTTPS WebDAV 地址，不包含账号、密码或查询参数。"
        case .authentication: "云端授权已失效或账号、应用密码不正确，请重新连接。"
        case .accessDenied: "云服务拒绝访问（HTTP 403），请检查账号权限和应用授权。"
        case .status(let code): "云服务请求未完成（HTTP \(code)），请检查访问权限和网络。"
        case .invalidResponse: "云端返回的数据格式不正确，未修改本机数据。"
        case .unsafeRedirect: "云服务要求跳转地址；请填写最终的 HTTPS 地址后重新连接。"
        case .versionUnavailable: "此 WebDAV 服务未提供安全同步所需的版本标记，仍可使用手动备份。"
        }
    }
    static func check(_ response: HTTPResponse, allowing codes: Set<Int>) throws {
        if response.statusCode == 401 { throw Self.authentication }
        if response.statusCode == 403 { throw Self.accessDenied }
        if (300..<400).contains(response.statusCode) { throw Self.unsafeRedirect }
        guard codes.contains(response.statusCode) else { throw Self.status(response.statusCode) }
    }
}

/// Cloud credentials never use the reader's optional unsafe TLS or cookie settings.
public struct LibraryCloudHTTPTransport: HTTPTransport {
    public static let maximumBytes = 32 * 1024 * 1024
    public init() {}
    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: NoCloudRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else { throw RemoteLibraryError.invalidResponse }
        guard response.expectedContentLength <= Self.maximumBytes else { throw LibraryBackupError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw LibraryBackupError.tooLarge }
            data.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return .init(data: data, statusCode: response.statusCode, headers: headers, finalURL: url)
    }
}

private final class NoCloudRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum RemoteBackupFiles {
    static func validName(_ name: String) -> Bool {
        name.hasPrefix("legado-") && name.hasSuffix(".legadobackup") && name.utf8.count <= 180
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
    static func newName() -> String { "legado-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).legadobackup" }
    static func read(_ file: URL) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= LibraryCloudHTTPTransport.maximumBytes else { throw LibraryBackupError.tooLarge }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size else { throw LibraryBackupError.changed }
        return data
    }
    static func temporary(_ data: Data) throws -> URL {
        guard !data.isEmpty, data.count <= LibraryCloudHTTPTransport.maximumBytes else { throw LibraryBackupError.tooLarge }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(newName())
        try data.write(to: url, options: .atomic); return url
    }
}

public struct WebDAVLibraryCloud: LibraryCloudTransport, RemoteLibraryBackupStore {
    private let base: URL
    private let username: String
    private let authorization: String
    private let http: any HTTPTransport
    public init(address: String, username: String, password: String, http: any HTTPTransport = LibraryCloudHTTPTransport()) throws {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url, !username.contains(":"), !username.isEmpty, !password.isEmpty,
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw RemoteLibraryError.invalidAddress }
        self.base = url.appendingPathComponent("Legado", isDirectory: true)
        self.username = username
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.http = http
    }
    public func accountIdentifier() async throws -> String {
        SHA256.hash(data: Data((base.absoluteString + "\n" + username).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func connect() async throws { try await ensureFolder(base); _ = try await listBackups() }
    public func fetch() async throws -> LibraryCloudVersion {
        let response = try await request("GET", url: base.appendingPathComponent("library-v1.json"))
        if response.statusCode == 404 { return .init() }
        try RemoteLibraryError.check(response, allowing: [200])
        guard let etag = response.headers.first(where: { $0.key.lowercased() == "etag" })?.value,
              etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\r"), !etag.contains("\n") else { throw RemoteLibraryError.versionUnavailable }
        let document = try JSONDecoder().decode(LibrarySyncDocument.self, from: response.data)
        _ = try document.snapshot
        return .init(document: document, token: Data(etag.utf8))
    }
    public func save(_ document: LibrarySyncDocument, replacing token: Data?) async throws {
        let data = try LibrarySnapshot.encode(document)
        guard data.count <= LibraryCloudHTTPTransport.maximumBytes else { throw LibraryBackupError.tooLarge }
        var headers = ["Content-Type": "application/json"]
        if let token {
            guard let etag = String(data: token, encoding: .utf8), etag.hasPrefix("\""), etag.hasSuffix("\""),
                  !etag.contains("\r"), !etag.contains("\n") else { throw RemoteLibraryError.invalidResponse }
            headers["If-Match"] = etag
        } else { headers["If-None-Match"] = "*" }
        let response = try await request("PUT", url: base.appendingPathComponent("library-v1.json"), body: data, headers: headers)
        if [409, 412].contains(response.statusCode) { throw LibraryCloudError.conflict }
        try RemoteLibraryError.check(response, allowing: [200, 201, 204])
    }
    public func listBackups() async throws -> [RemoteLibraryBackup] {
        let folder = base.appendingPathComponent("backups", isDirectory: true)
        try await ensureFolder(folder)
        let xml = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let response = try await request("PROPFIND", url: folder, body: xml, headers: ["Depth": "1", "Content-Type": "application/xml"])
        try RemoteLibraryError.check(response, allowing: [207])
        let parser = WebDAVBackupListing(folder: folder)
        return try parser.parse(response.data).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    public func uploadBackup(_ file: URL) async throws {
        let folder = base.appendingPathComponent("backups", isDirectory: true)
        try await ensureFolder(folder)
        let response = try await request("PUT", url: folder.appendingPathComponent(RemoteBackupFiles.newName()),
                                         body: RemoteBackupFiles.read(file), headers: ["If-None-Match": "*", "Content-Type": "application/octet-stream"])
        try RemoteLibraryError.check(response, allowing: [200, 201, 204])
    }
    public func downloadBackup(_ backup: RemoteLibraryBackup) async throws -> URL {
        guard RemoteBackupFiles.validName(backup.id), backup.bytes <= LibraryCloudHTTPTransport.maximumBytes else { throw RemoteLibraryError.invalidResponse }
        let response = try await request("GET", url: base.appendingPathComponent("backups").appendingPathComponent(backup.id))
        try RemoteLibraryError.check(response, allowing: [200])
        return try RemoteBackupFiles.temporary(response.data)
    }
    private func ensureFolder(_ url: URL) async throws {
        let response = try await request("MKCOL", url: url)
        try RemoteLibraryError.check(response, allowing: [200, 201, 204, 405])
    }
    private func request(_ method: String, url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let response = try await http.data(for: request)
        guard response.finalURL == url else { throw RemoteLibraryError.unsafeRedirect }
        guard response.data.count <= LibraryCloudHTTPTransport.maximumBytes else { throw LibraryBackupError.tooLarge }
        return response
    }
}

private final class WebDAVBackupListing: NSObject, XMLParserDelegate {
    private let folder: URL
    private var items: [RemoteLibraryBackup] = []
    private var fields: [String: String] = [:]
    private var active = ""
    private var inResponse = false
    private var invalid = false
    init(folder: URL) { self.folder = folder }
    func parse(_ data: Data) throws -> [RemoteLibraryBackup] {
        guard data.count <= 4 * 1024 * 1024 else { throw LibraryBackupError.tooLarge }
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), !invalid else { throw RemoteLibraryError.invalidResponse }
        return items
    }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "response" { inResponse = true; fields = [:] }
        if inResponse, ["href", "getcontentlength", "getlastmodified"].contains(element) { active = element }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !active.isEmpty { fields[active, default: ""] += string } }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == active { active = "" }
        guard element == "response" else { return }
        inResponse = false
        guard let href = fields["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: href, relativeTo: folder)?.absoluteURL,
              url.scheme == folder.scheme, url.host == folder.host, url.port == folder.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == folder.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              RemoteBackupFiles.validName(url.lastPathComponent),
              let size = fields["getcontentlength"].flatMap({ Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              size > 0, size <= LibraryCloudHTTPTransport.maximumBytes else { return }
        guard items.count < 10_000, !items.contains(where: { $0.id == url.lastPathComponent }) else { invalid = true; parser.abortParsing(); return }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        items.append(.init(id: url.lastPathComponent, name: url.lastPathComponent, date: fields["getlastmodified"].flatMap(format.date), bytes: size))
    }
}
