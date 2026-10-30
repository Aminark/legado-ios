import Foundation
import Testing
@testable import LegadoCore

private struct CloudReply: Sendable {
    var status: Int
    var data = Data()
    var headers: [String: String] = [:]
    var finalURL: URL?
}
private actor CloudHTTPFixture: HTTPTransport {
    private var replies: [CloudReply]
    private var requests: [URLRequest] = []
    init(_ replies: [CloudReply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return .init(data: reply.data, statusCode: reply.status, headers: reply.headers, finalURL: reply.finalURL ?? request.url!)
    }
    func captured() -> [URLRequest] { requests }
}

@Suite struct RemoteLibraryBackupTests {
    private func dav(_ http: CloudHTTPFixture) throws -> WebDAVLibraryCloud {
        try .init(address: "https://dav.example/dav/", username: "fixture@example.com", password: "application-password", http: http)
    }
    private func file(_ data: Data = Data("synthetic archive bytes".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".legadobackup")
        try data.write(to: url); return url
    }
    @Test func webDAVRejectsUnsafeEndpointsBeforeSendingCredentials() throws {
        let http = CloudHTTPFixture([])
        for address in ["http://dav.example/", "https://user:pass@dav.example/", "https://dav.example/?query=1", "https://dav.example/#fragment", "https://dav.example/%2E%2E/"] {
            #expect(throws: RemoteLibraryError.invalidAddress) { try WebDAVLibraryCloud(address: address, username: "user", password: "secret", http: http) }
        }
        #expect(throws: RemoteLibraryError.invalidAddress) { try WebDAVLibraryCloud(address: "https://dav.example/", username: "user:invalid", password: "secret", http: http) }
    }
    @Test func webDAVUsesConditionalWritesAndPreservesConflictingCloudState() async throws {
        let document = LibrarySyncDocument()
        let encoded = try LibrarySnapshot.encode(document)
        let http = CloudHTTPFixture([.init(status: 200, data: encoded, headers: ["ETag": "\"revision-1\""]), .init(status: 412)])
        let cloud = try dav(http)
        let version = try await cloud.fetch()
        #expect(version.document == document)
        await #expect(throws: LibraryCloudError.conflict) { try await cloud.save(document, replacing: version.token) }
        let requests = await http.captured()
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "If-Match") == "\"revision-1\"")
        #expect(requests[1].httpBody == encoded)
        #expect(requests[0].url?.path == "/dav/Legado/library-v1.json")
    }
    @Test func webDAVFirstUploadCannotOverwriteAnExistingDocument() async throws {
        let http = CloudHTTPFixture([.init(status: 404), .init(status: 201)])
        let cloud = try dav(http)
        let version = try await cloud.fetch()
        #expect(version.token == nil)
        try await cloud.save(version.document, replacing: nil)
        #expect(await http.captured()[1].value(forHTTPHeaderField: "If-None-Match") == "*")
    }
    @Test func webDAVRequiresStrongVersionTagsAndRejectsRedirectedResponses() async throws {
        for headers in [[:], ["ETag": "W/\"weak\""]] {
            let http = CloudHTTPFixture([.init(status: 200, data: try LibrarySnapshot.encode(LibrarySyncDocument()), headers: headers)])
            await #expect(throws: RemoteLibraryError.versionUnavailable) { try await dav(http).fetch() }
        }
        let redirected = CloudHTTPFixture([.init(status: 200, finalURL: URL(string: "https://other.example/stolen"))])
        await #expect(throws: RemoteLibraryError.unsafeRedirect) { try await dav(redirected).fetch() }
    }
    @Test func webDAVOnly404MeansNewLibrary() async throws {
        for status in [401, 403, 500, 302] {
            let http = CloudHTTPFixture([.init(status: status)])
            await #expect(throws: (any Error).self) { try await dav(http).fetch() }
        }
    }
    @Test func webDAVListingOnlyAllowsOwnImmediateBackupFiles() async throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/Legado/backups/legado-good.legadobackup</d:href><d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength><d:getlastmodified>Wed, 28 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>https://other.example/dav/Legado/backups/legado-bad.legadobackup</d:href><d:getcontentlength>100</d:getcontentlength></d:response>
        <d:response><d:href>/dav/other/legado-bad.legadobackup</d:href><d:getcontentlength>100</d:getcontentlength></d:response>
        <d:response><d:href>/dav/Legado/backups/other.txt</d:href><d:getcontentlength>100</d:getcontentlength></d:response>
        </d:multistatus>
        """
        let http = CloudHTTPFixture([.init(status: 405), .init(status: 207, data: Data(xml.utf8))])
        let items = try await dav(http).listBackups()
        #expect(items.count == 1); #expect(items[0].id == "legado-good.legadobackup"); #expect(items[0].date != nil)
        let requests = await http.captured()
        #expect(requests[1].httpMethod == "PROPFIND")
        #expect(requests[1].value(forHTTPHeaderField: "Depth") == "1")
    }
    @Test func webDAVBackupUploadAndDownloadRoundTripBytes() async throws {
        let original = try file(); defer { try? FileManager.default.removeItem(at: original) }
        let data = try Data(contentsOf: original)
        let http = CloudHTTPFixture([.init(status: 405), .init(status: 201), .init(status: 200, data: data)])
        let store = try dav(http)
        try await store.uploadBackup(original)
        let put = await http.captured()[1]
        #expect(put.httpBody == data); #expect(put.value(forHTTPHeaderField: "If-None-Match") == "*")
        let name = put.url!.lastPathComponent
        let downloaded = try await store.downloadBackup(.init(id: name, name: name, date: nil, bytes: Int64(data.count)))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(try Data(contentsOf: downloaded) == data)
        await #expect(throws: RemoteLibraryError.invalidResponse) { try await store.downloadBackup(.init(id: "../secret", name: "", date: nil, bytes: 1)) }
        #expect(await http.captured().count == 3)
    }
    @Test func googleListsOnlyAppBackupsAcrossPages() async throws {
        let page1 = Data(#"{"files":[{"id":"good_id","name":"legado-one.legadobackup","size":"200","modifiedTime":"2026-10-28T10:00:00Z"},{"id":"skip","name":"unrelated.txt","size":"5"}],"nextPageToken":"second"}"#.utf8)
        let page2 = Data(#"{"files":[{"id":"second_id","name":"legado-two.legadobackup","size":"300"}]}"#.utf8)
        let http = CloudHTTPFixture([.init(status: 200, data: page1), .init(status: 200, data: page2)])
        let store = GoogleDriveBackupStore(http: http) { "synthetic-token" }
        let list = try await store.listBackups()
        #expect(list.count == 2)
        let requests = await http.captured()
        #expect(requests[0].url?.query?.contains("spaces=appDataFolder") == true)
        #expect(requests[1].url?.query?.contains("pageToken=second") == true)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    }
    @Test func googleStopsRepeatedPageTokensAndAuthenticationErrors() async throws {
        let page = Data(#"{"files":[],"nextPageToken":"same"}"#.utf8)
        let http = CloudHTTPFixture([.init(status: 200, data: page), .init(status: 200, data: page)])
        await #expect(throws: RemoteLibraryError.invalidResponse) { try await GoogleDriveBackupStore(http: http) { "fixture" }.listBackups() }
        let denied = CloudHTTPFixture([.init(status: 401)])
        await #expect(throws: RemoteLibraryError.authentication) { try await GoogleDriveBackupStore(http: denied) { "fixture" }.listBackups() }
    }
    @Test func googleRejectsOffsiteUploadLocationsBeforeSendingToken() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file) }
        let http = CloudHTTPFixture([.init(status: 200, headers: ["Location": "https://attacker.example/upload"])])
        await #expect(throws: RemoteLibraryError.invalidResponse) { try await GoogleDriveBackupStore(http: http) { "fixture" }.uploadBackup(file) }
        #expect(await http.captured().count == 1)
    }
    @Test func googleResumableUploadAndDownloadPreserveArchiveBytes() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)
        let http = CloudHTTPFixture([.init(status: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"]), .init(status: 201), .init(status: 200, data: data)])
        let store = GoogleDriveBackupStore(http: http) { "fixture" }
        try await store.uploadBackup(file)
        let requests = await http.captured()
        let metadata = try #require(try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(metadata["parents"] as? [String] == ["appDataFolder"])
        #expect(requests[1].httpMethod == "PUT"); #expect(requests[1].httpBody == data)
        let downloaded = try await store.downloadBackup(.init(id: "file_id", name: "legado-one.legadobackup", date: nil, bytes: Int64(data.count)))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(try Data(contentsOf: downloaded) == data)
    }
}
