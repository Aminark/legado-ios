import Foundation

public struct WebDAVCredentials: Equatable, Sendable {
    public var serverURL: String
    public var remoteDirectory: String
    public var username: String
    public var password: String

    public init(serverURL: String, remoteDirectory: String = "LegadoBackups", username: String, password: String) {
        self.serverURL = serverURL
        self.remoteDirectory = remoteDirectory
        self.username = username
        self.password = password
    }

    public var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}

public struct WebDAVRemoteBackup: Identifiable, Hashable, Sendable {
    public let fileName: String
    public let href: String
    public let sizeBytes: Int64
    public let lastModified: Date?
    public let etag: String?

    public var id: String { fileName }

    public init(fileName: String, href: String, sizeBytes: Int64, lastModified: Date?, etag: String? = nil) {
        self.fileName = fileName
        self.href = href
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.etag = etag
    }
}

public enum WebDAVError: LocalizedError, Equatable, Sendable {
    case invalidAddress(String)
    case unauthorized
    case notFound(String)
    case insufficientStorage
    case unexpectedStatus(Int, String)
    case malformedListing

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let detail):
            return "WebDAV 地址无效：\(detail)"
        case .unauthorized:
            return "WebDAV 认证失败，请检查账号或应用专用密码"
        case .notFound(let path):
            return "远端路径不存在：\(path)"
        case .insufficientStorage:
            return "WebDAV 云端存储空间不足"
        case .unexpectedStatus(let code, let detail):
            return detail.isEmpty ? "WebDAV 请求失败（HTTP \(code)）" : "WebDAV 请求失败（HTTP \(code)）：\(detail)"
        case .malformedListing:
            return "无法解析 WebDAV 返回的目录列表"
        }
    }
}

/// Normalizes and validates WebDAV base URLs, directory segments, and file URLs.
public struct WebDAVEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let directorySegments: [String]

    public init(serverURL: String, remoteDirectory: String) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            throw WebDAVError.invalidAddress("请填写以 https:// 或 http:// 开头的完整服务器地址")
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.query = nil
        components.fragment = nil
        guard let normalized = components.url else {
            throw WebDAVError.invalidAddress("服务器地址格式不正确")
        }

        let segments = remoteDirectory
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." }
        if segments.contains("..") {
            throw WebDAVError.invalidAddress("备份目录不能包含 .. 路径片段")
        }
        self.baseURL = normalized
        self.directorySegments = segments
    }

    public var directoryURL: URL {
        var current = baseURL
        for segment in directorySegments {
            current.appendPathComponent(segment, isDirectory: true)
        }
        return current
    }

    public func ancestorDirectoryURLs() -> [URL] {
        var urls: [URL] = []
        var current = baseURL
        for segment in directorySegments {
            current.appendPathComponent(segment, isDirectory: true)
            urls.append(current)
        }
        return urls
    }

    public func fileURL(named fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), trimmed != "..", trimmed != "." else {
            throw WebDAVError.invalidAddress("远端文件名非法")
        }
        return directoryURL.appendingPathComponent(trimmed, isDirectory: false)
    }
}

/// Namespace-tolerant XML parser for WebDAV `PROPFIND` `multistatus` responses
/// (handles `D:`, `d:`, `DAV:`, and default-namespace XML from Jianguoyun,
/// Nextcloud, OwnCloud, Alist, Synology, Caddy, and Apache `mod_dav`).
public enum WebDAVPropfindParser {
    public static func parseBackups(from data: Data, fileExtension: String = "legadobackup") throws -> [WebDAVRemoteBackup] {
        let delegate = ParserDelegate(targetExtension: fileExtension.lowercased())
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.isMultistatus else {
            throw WebDAVError.malformedListing
        }
        return delegate.backups.sorted { lhs, rhs in
            let leftDate = lhs.lastModified ?? .distantPast
            let rightDate = rhs.lastModified ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.fileName > rhs.fileName
        }
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let targetExtension: String
        var backups: [WebDAVRemoteBackup] = []
        private(set) var isMultistatus = false
        private var sawRoot = false

        private var inResponse = false
        private var buffer = ""

        private var href = ""
        private var contentLength: Int64 = 0
        private var lastModified: Date?
        private var etag: String?
        private var isCollection = false

        init(targetExtension: String) {
            self.targetExtension = targetExtension
        }

        private static func localName(_ qualified: String) -> String {
            if let colon = qualified.lastIndex(of: ":") {
                return String(qualified[qualified.index(after: colon)...]).lowercased()
            }
            return qualified.lowercased()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = Self.localName(elementName)
            if !sawRoot {
                sawRoot = true
                isMultistatus = name == "multistatus"
            }
            if name == "response" {
                inResponse = true
                href = ""
                contentLength = 0
                lastModified = nil
                etag = nil
                isCollection = false
            } else if inResponse {
                if name == "collection" {
                    isCollection = true
                }
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inResponse else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = Self.localName(elementName)
            guard inResponse else { return }
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href":
                href = value
            case "getcontentlength":
                if let bytes = Int64(value), bytes >= 0 { contentLength = bytes }
            case "getlastmodified":
                lastModified = Self.parseDate(value)
            case "getetag":
                if !value.isEmpty { etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            case "response":
                finalizeResponse()
                inResponse = false
            default:
                break
            }
            buffer = ""
        }

        private func finalizeResponse() {
            guard !isCollection, !href.isEmpty, !href.hasSuffix("/") else { return }
            let decodedPath = href.removingPercentEncoding ?? href
            let lastSegment = URL(fileURLWithPath: decodedPath).lastPathComponent
            guard !lastSegment.isEmpty,
                  URL(fileURLWithPath: lastSegment).pathExtension.lowercased() == targetExtension else {
                return
            }
            backups.append(WebDAVRemoteBackup(
                fileName: lastSegment,
                href: href,
                sizeBytes: contentLength,
                lastModified: lastModified,
                etag: etag
            ))
        }

        private static func parseDate(_ raw: String) -> Date? {
            guard !raw.isEmpty else { return nil }
            for format in [
                "EEE, dd MMM yyyy HH:mm:ss zzz",
                "EEEE, dd-MMM-yy HH:mm:ss zzz",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
            ] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { return date }
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: raw)
        }
    }
}

/// Backup credentials and archives use system TLS validation, independently
/// of the networking exceptions configured for book sources.
private final class WebDAVSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
    private let session = URLSession(configuration: .ephemeral)

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            throw HTTPClientError.nonHTTPResponse
        }
        return HTTPResponse(data: data, statusCode: http.statusCode, headers: [:], finalURL: url)
    }

    func upload(_ file: URL, for request: URLRequest) async throws -> Int {
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.nonHTTPResponse }
        return http.statusCode
    }

    func download(for request: URLRequest) async throws -> (URL, Int) {
        let (file, response) = try await session.download(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            throw HTTPClientError.nonHTTPResponse
        }
        return (file, http.statusCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.currentRequest, let base = original.url, let target = request.url,
              ReviewPageAddress.sameOrigin(target, base), original.httpMethod == request.httpMethod else {
            completionHandler(nil)
            return
        }
        var redirected = original
        redirected.url = target
        completionHandler(redirected)
    }
}

/// Standards-compliant WebDAV client built directly on `HTTPTransport` so
/// every protocol step (`PROPFIND`, `MKCOL`, `PUT`, `GET`, `DELETE`) is
/// testable in memory and shares the app's existing networking abstraction.
public struct WebDAVClient: Sendable {
    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:getetag/>
      </d:prop>
    </d:propfind>
    """.utf8)

    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 45) {
        self.init(transport: WebDAVSessionTransport(), timeout: timeout)
    }

    public init(transport: any HTTPTransport, timeout: TimeInterval = 45) {
        self.transport = transport
        self.timeout = timeout
    }

    public func testConnection(credentials: WebDAVCredentials) async throws {
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        let response = try await send(
            method: "PROPFIND",
            url: endpoint.baseURL,
            credentials: credentials,
            headers: [
                "Depth": "0",
                "Content-Type": "application/xml; charset=utf-8"
            ],
            body: Self.propfindBody
        )
        try validateStatus(response.statusCode, allowed: [200, 204, 207], context: endpoint.baseURL.path)
    }

    public func ensureDirectory(credentials: WebDAVCredentials) async throws {
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        for directoryURL in endpoint.ancestorDirectoryURLs() {
            let probe = try await send(
                method: "PROPFIND",
                url: directoryURL,
                credentials: credentials,
                headers: ["Depth": "0"],
                body: nil
            )
            if [200, 204, 207].contains(probe.statusCode) { continue }
            try validateStatus(probe.statusCode, allowed: [404], context: directoryURL.path)
            let created = try await send(
                method: "MKCOL",
                url: directoryURL,
                credentials: credentials,
                headers: [:],
                body: nil
            )
            // 405 Method Not Allowed is standard when a collection already exists.
            try validateStatus(created.statusCode, allowed: [200, 201, 204, 405], context: directoryURL.path)
        }
    }

    public func listBackups(credentials: WebDAVCredentials) async throws -> [WebDAVRemoteBackup] {
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        let response = try await send(
            method: "PROPFIND",
            url: endpoint.directoryURL,
            credentials: credentials,
            headers: [
                "Depth": "1",
                "Content-Type": "application/xml; charset=utf-8"
            ],
            body: Self.propfindBody
        )
        if response.statusCode == 404 {
            return []
        }
        try validateStatus(response.statusCode, allowed: [200, 207], context: endpoint.directoryURL.path)
        return try WebDAVPropfindParser.parseBackups(from: response.data)
    }

    public func upload(
        fileURL: URL,
        remoteFileName: String,
        credentials: WebDAVCredentials
    ) async throws {
        try await ensureDirectory(credentials: credentials)
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        let destination = try endpoint.fileURL(named: remoteFileName)
        var request = makeRequest(method: "PUT", url: destination, credentials: credentials,
                                  headers: ["Content-Type": "application/octet-stream"])
        let status: Int
        if let session = transport as? WebDAVSessionTransport {
            status = try await session.upload(fileURL, for: request)
        } else {
            request.httpBody = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            status = try await send(request).statusCode
        }
        try validateStatus(status, allowed: [200, 201, 204], context: remoteFileName)
    }

    public func download(
        remoteFileName: String,
        credentials: WebDAVCredentials,
        to destination: URL
    ) async throws -> URL {
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        let source = try endpoint.fileURL(named: remoteFileName)
        let request = makeRequest(method: "GET", url: source, credentials: credentials, headers: [:])
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let session = transport as? WebDAVSessionTransport {
            let (file, status) = try await session.download(for: request)
            defer { try? manager.removeItem(at: file) }
            try validateStatus(status, allowed: [200], context: remoteFileName)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: file)
            } else {
                try manager.moveItem(at: file, to: destination)
            }
        } else {
            let response = try await send(request)
            try validateStatus(response.statusCode, allowed: [200], context: remoteFileName)
            try response.data.write(to: destination, options: .atomic)
        }
        return destination
    }

    public func delete(remoteFileName: String, credentials: WebDAVCredentials) async throws {
        let endpoint = try WebDAVEndpoint(
            serverURL: credentials.serverURL,
            remoteDirectory: credentials.remoteDirectory
        )
        let target = try endpoint.fileURL(named: remoteFileName)
        let response = try await send(
            method: "DELETE",
            url: target,
            credentials: credentials,
            headers: [:],
            body: nil
        )
        try validateStatus(response.statusCode, allowed: [200, 202, 204, 404], context: remoteFileName)
    }

    private func send(
        method: String,
        url: URL,
        credentials: WebDAVCredentials,
        headers: [String: String],
        body: Data?
    ) async throws -> HTTPResponse {
        var request = makeRequest(method: method, url: url, credentials: credentials, headers: headers)
        request.httpBody = body
        return try await send(request)
    }

    private func makeRequest(method: String, url: URL, credentials: WebDAVCredentials, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let rawAuth = "\(credentials.username):\(credentials.password)"
        let encoded = Data(rawAuth.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        request.setValue("Legado-iOS/WebDAV", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            return try await transport.data(for: request)
        } catch HTTPClientError.statusResponse(let response) {
            return response
        }
    }

    private func validateStatus(_ status: Int, allowed: Set<Int>, context: String) throws {
        if allowed.contains(status) { return }
        switch status {
        case 401, 403:
            throw WebDAVError.unauthorized
        case 404:
            throw WebDAVError.notFound(context)
        case 507:
            throw WebDAVError.insufficientStorage
        default:
            throw WebDAVError.unexpectedStatus(status, context)
        }
    }
}
