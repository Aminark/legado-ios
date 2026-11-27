import Foundation
import Testing
@testable import LegadoCore

private actor MockWebDAVServer: HTTPTransport {
    var directories: Set<String> = ["/dav/"]
    var files: [String: (data: Data, modified: Date)] = [:]
    var expectedAuth: String
    var requestedMethods: [(method: String, path: String)] = []

    init(username: String, password: String) {
        expectedAuth = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url else { throw HTTPClientError.nonHTTPResponse }
        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        requestedMethods.append((method, path))

        if request.value(forHTTPHeaderField: "Authorization") != expectedAuth {
            return HTTPResponse(data: Data(), statusCode: 401, headers: [:], finalURL: url)
        }

        switch method {
        case "PROPFIND":
            let dirPath = path.hasSuffix("/") ? path : path + "/"
            guard directories.contains(dirPath) else {
                return HTTPResponse(data: Data(), statusCode: 404, headers: [:], finalURL: url)
            }
            let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
            let xml = buildMultistatus(directory: dirPath, includeChildren: depth != "0")
            return HTTPResponse(
                data: Data(xml.utf8),
                statusCode: 207,
                headers: ["Content-Type": "application/xml"],
                finalURL: url
            )

        case "MKCOL":
            let dirPath = path.hasSuffix("/") ? path : path + "/"
            if directories.contains(dirPath) {
                return HTTPResponse(data: Data(), statusCode: 405, headers: [:], finalURL: url)
            }
            directories.insert(dirPath)
            return HTTPResponse(data: Data(), statusCode: 201, headers: [:], finalURL: url)

        case "PUT":
            let parent = (path as NSString).deletingLastPathComponent + "/"
            guard directories.contains(parent) else {
                return HTTPResponse(data: Data(), statusCode: 409, headers: [:], finalURL: url)
            }
            files[path] = (request.httpBody ?? Data(), Date())
            return HTTPResponse(data: Data(), statusCode: 201, headers: [:], finalURL: url)

        case "GET":
            guard let item = files[path] else {
                return HTTPResponse(data: Data(), statusCode: 404, headers: [:], finalURL: url)
            }
            return HTTPResponse(data: item.data, statusCode: 200, headers: [:], finalURL: url)

        case "DELETE":
            files.removeValue(forKey: path)
            return HTTPResponse(data: Data(), statusCode: 204, headers: [:], finalURL: url)

        default:
            return HTTPResponse(data: Data(), statusCode: 405, headers: [:], finalURL: url)
        }
    }

    private func buildMultistatus(directory: String, includeChildren: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        var responses = """
        <D:response>
          <D:href>\(directory)</D:href>
          <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
        </D:response>
        """
        if includeChildren {
            for (filePath, entry) in files where filePath.hasPrefix(directory) {
                let tail = String(filePath.dropFirst(directory.count))
                guard !tail.contains("/") else { continue }
                responses += """
                <D:response>
                  <D:href>\(filePath)</D:href>
                  <D:propstat>
                    <D:prop>
                      <D:resourcetype/>
                      <D:getcontentlength>\(entry.data.count)</D:getcontentlength>
                      <D:getlastmodified>\(formatter.string(from: entry.modified))</D:getlastmodified>
                      <D:getetag>"etag-\(entry.data.count)"</D:getetag>
                    </D:prop>
                  </D:propstat>
                </D:response>
                """
            }
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\(responses)</D:multistatus>"
    }
}

struct WebDAVBackupTests {
    @Test func htmlLoginPageIsNotAnEmptyBackupDirectory() {
        let login = Data("<html><body>Sign in</body></html>".utf8)
        #expect(throws: WebDAVError.malformedListing) {
            try WebDAVPropfindParser.parseBackups(from: login)
        }
    }

    @Test func propfindParserHandlesMultipleVendorNamespacesAndSortsNewestFirst() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/dav/LegadoBackups/</href>
            <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat>
          </response>
          <response>
            <href>/dav/LegadoBackups/readme.txt</href>
            <propstat><prop><getcontentlength>12</getcontentlength></prop></propstat>
          </response>
          <response>
            <href>/dav/LegadoBackups/legado-20261125-100000.legadobackup</href>
            <propstat><prop>
              <getcontentlength>1024</getcontentlength>
              <getlastmodified>Wed, 25 Nov 2026 10:00:00 GMT</getlastmodified>
              <getetag>"old"</getetag>
            </prop></propstat>
          </response>
          <response>
            <href>/dav/LegadoBackups/legado-20261127-180000.legadobackup</href>
            <propstat><prop>
              <getcontentlength>4096</getcontentlength>
              <getlastmodified>Fri, 27 Nov 2026 18:00:00 GMT</getlastmodified>
              <getetag>"new"</getetag>
            </prop></propstat>
          </response>
        </multistatus>
        """
        let items = try WebDAVPropfindParser.parseBackups(from: Data(xml.utf8))
        #expect(items.map(\.fileName) == [
            "legado-20261127-180000.legadobackup",
            "legado-20261125-100000.legadobackup"
        ])
        #expect(items[0].sizeBytes == 4096)
        #expect(items[0].etag == "new")
    }

    @Test func autoBackupPolicySchedulesBacksOffAndPrunesOldest() {
        let now = Date(timeIntervalSince1970: 1_764_200_000)
        var settings = WebDAVBackupSettings(
            serverURL: "https://dav.example.com/dav",
            remoteDirectory: "LegadoBackups",
            username: "reader",
            autoBackupEnabled: true,
            autoBackupIntervalHours: 12,
            maxRetainedBackups: 2
        )

        #expect(!WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings: settings, hasPassword: false, now: now))
        #expect(WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings: settings, hasPassword: true, now: now))

        settings.lastBackupAt = now.addingTimeInterval(-3600)
        #expect(!WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings: settings, hasPassword: true, now: now))

        settings.lastBackupAt = now.addingTimeInterval(-13 * 3600)
        settings.lastFailureAt = now.addingTimeInterval(-600)
        #expect(!WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings: settings, hasPassword: true, now: now))

        settings.lastFailureAt = now.addingTimeInterval(-3600)
        #expect(WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings: settings, hasPassword: true, now: now))

        let list = [
            WebDAVRemoteBackup(fileName: "a.legadobackup", href: "/a", sizeBytes: 1, lastModified: now.addingTimeInterval(-300)),
            WebDAVRemoteBackup(fileName: "b.legadobackup", href: "/b", sizeBytes: 1, lastModified: now.addingTimeInterval(-100)),
            WebDAVRemoteBackup(fileName: "c.legadobackup", href: "/c", sizeBytes: 1, lastModified: now.addingTimeInterval(-200))
        ]
        let pruned = WebDAVAutoBackupPolicy.backupsToPrune(from: list, maxRetained: 2)
        #expect(pruned.map(\.fileName) == ["a.legadobackup"])

        #expect(WebDAVAutoBackupPolicy.makeBackupFileName(date: now) != WebDAVAutoBackupPolicy.makeBackupFileName(date: now))
        let protected = WebDAVAutoBackupPolicy.backupsToPrune(from: list, maxRetained: 1, keeping: "a.legadobackup")
        #expect(Set(protected.map(\.fileName)) == ["b.legadobackup", "c.legadobackup"])
    }

    @Test(arguments: [false, true])
    func endToEndWebDAVUploadListDownloadAndArchiveValidation(throwHTTPFailures: Bool) async throws {
        let server = MockWebDAVServer(username: "amin", password: "secret")
        let client = WebDAVClient(transport: throwHTTPFailures ? ThrowingTransport(server: server) : server)
        let credentials = WebDAVCredentials(
            serverURL: "https://dav.example.com/dav",
            remoteDirectory: "Backups/iOS",
            username: "amin",
            password: "secret"
        )

        try await client.testConnection(credentials: credentials)

        let badCreds = WebDAVCredentials(
            serverURL: "https://dav.example.com/dav",
            remoteDirectory: "Backups/iOS",
            username: "amin",
            password: "wrong"
        )
        await #expect(throws: WebDAVError.unauthorized) {
            try await client.testConnection(credentials: badCreds)
        }

        // Write a real .legadobackup archive, upload it, list it, download it, and verify it prepares cleanly.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("webdav-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var snapshot = LibrarySnapshot()
        snapshot.books = [Book(bookUrl: "https://book.example/1", name: "雪中悍刀行", author: "烽火戏诸侯", origin: "https://source.example")]
        snapshot.sources = [BookSource(bookSourceUrl: "https://source.example", bookSourceName: "示例书源")]

        let exportedFile = tempDir.appendingPathComponent("local.legadobackup")
        try LibraryBackupArchive.write(snapshot: snapshot, files: [:], to: exportedFile)

        let remoteName = WebDAVAutoBackupPolicy.makeBackupFileName()
        try await client.upload(fileURL: exportedFile, remoteFileName: remoteName, credentials: credentials)

        let listed = try await client.listBackups(credentials: credentials)
        #expect(listed.map(\.fileName) == [remoteName])

        let downloaded = tempDir.appendingPathComponent("downloaded.legadobackup")
        _ = try await client.download(remoteFileName: remoteName, credentials: credentials, to: downloaded)
        let prepared = try LibraryBackupArchive.prepare(downloaded)
        #expect(prepared.manifest.snapshot.books.map(\.name) == ["雪中悍刀行"])
        #expect(prepared.manifest.snapshot.sources.map(\.bookSourceName) == ["示例书源"])

        try await client.delete(remoteFileName: remoteName, credentials: credentials)
        let afterDelete = try await client.listBackups(credentials: credentials)
        #expect(afterDelete.isEmpty)
    }
}

private struct ThrowingTransport: HTTPTransport {
    let server: MockWebDAVServer

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let response = try await server.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw HTTPClientError.statusResponse(response) }
        return response
    }
}
