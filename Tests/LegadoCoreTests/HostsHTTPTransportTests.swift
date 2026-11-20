import Foundation
import Network
import Testing
@testable import LegadoCore

struct HostsHTTPTransportTests {
    let url = URL(string: "https://books.example.com/chapter")!

    @Test func handlesPartialContentLengthAndHeadResponses() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8)
        #expect(try HostsHTTPResponseDecoder.decode(partial, url: url) == nil)
        var complete = partial
        complete.append(Data("lo".utf8))
        let response = try HostsHTTPResponseDecoder.decode(complete, url: url)
        #expect(response?.decodedText == "hello")
        #expect(response?.finalURL == url)
        #expect(try HostsHTTPResponseDecoder.decode(partial, url: url, method: "HEAD")?.data.isEmpty == true)
    }

    @Test func handlesChunkExtensionsTrailersAndInterimResponses() throws {
        let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=a\r\nhel\r\n2\r\nlo\r\n0\r\nX-Trailer: yes\r\n\r\n"
        #expect(try HostsHTTPResponseDecoder.decode(Data(raw.utf8), url: url)?.decodedText == "hello")
        #expect(try HostsHTTPResponseDecoder.decode(Data(raw.dropLast(2).utf8), url: url) == nil)
    }

    @Test func rejectsMalformedFramesAndHandlesConnectionClose() throws {
        let raw = "HTTP/1.1 200 OK\r\n\r\nbody"
        #expect(try HostsHTTPResponseDecoder.decode(Data(raw.utf8), url: url) == nil)
        #expect(try HostsHTTPResponseDecoder.decode(Data(raw.utf8), url: url, complete: true)?.decodedText == "body")
        for malformed in ["Content-Length: -1\r\n\r\n", "Transfer-Encoding: chunked\r\n\r\n\r\n", "Transfer-Encoding: chunked\r\n\r\n-1\r\n", "Transfer-Encoding: chunked\r\n\r\n1\r\nxXX"] {
            #expect(throws: (any Error).self) {
                _ = try HostsHTTPResponseDecoder.decode(Data(("HTTP/1.1 200 OK\r\n" + malformed).utf8), url: url)
            }
        }
    }

    @Test func hostsOverrideConnectsToIPAndRetainsOriginHost() async throws {
        let server = try HostsLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let origin = URL(string: "http://books.invalid:\(port)/chapter?lang=zh")!
        let response = try await HostsHTTPTransport.data(for: URLRequest(url: origin, timeoutInterval: 3), address: "127.0.0.1", ignoreCertificateErrors: false)
        #expect(response.finalURL == origin)
        #expect(response.decodedText.contains("GET /chapter?lang=zh HTTP/1.1"))
        #expect(response.decodedText.contains("Host: books.invalid:\(port)"))
    }

    @Test func redirectIntoHostsUsesOverrideAndDropsCrossOriginCredentials() async throws {
        let server = try HostsLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "legado.hosts.redirect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        var settings = ApplicationSettings()
        settings.hosts = "127.0.0.1 books.invalid"
        try store.save(settings)
        let transport = URLSessionHTTPTransport(settingsStore: store)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/redirect")!, timeoutInterval: 3)
        request.setValue("Bearer PRIVATE", forHTTPHeaderField: "Authorization")
        request.setValue("origin=PRIVATE", forHTTPHeaderField: "Cookie")
        let response = try await transport.data(for: request)
        #expect(response.finalURL.host == "books.invalid")
        #expect(response.finalURL.path == "/chapter")
        #expect(response.decodedText.contains("Host: books.invalid:\(port)"))
        #expect(!response.decodedText.contains("PRIVATE"))
    }

    @Test func commentPaginationStopsBeforeFollowingCrossOriginRedirect() async throws {
        let server = try HostsLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "legado.comments.redirect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        var settings = ApplicationSettings()
        settings.hosts = "127.0.0.1 books.invalid"
        try store.save(settings)
        let transport = URLSessionHTTPTransport(settingsStore: store)
        var page = try LegadoURLBuilder().prepare("http://127.0.0.1:\(port)/redirect",
                                                  defaultHeaders: ["X-Reader-Token": "private"])
        page.redirectOrigin = page.url
        do {
            _ = try await transport.data(for: page.urlRequest(timeout: 3))
            Issue.record("不应跟随跨域分页重定向")
        } catch HTTPClientError.statusResponse(let redirect) {
            #expect(redirect.statusCode == 302)
            #expect(redirect.finalURL == page.url)
        }
    }

    @Test func databaseCompactionPreservesUserData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "test.sqlite3"))
        let sources = [BookSource(bookSourceUrl: "https://example.com", bookSourceName: "test")]
        try await database.replaceBookSources(sources)
        try await database.compact()
        #expect(try await database.loadBookSources() == sources)
    }
}

private final class HostsLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "legado.hosts.loopback.test")
    private let listener: NWListener
    private var continuation: CheckedContinuation<UInt16, Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let continuation = self.continuation else { return }
                    if case .ready = state, let port = self.listener.port {
                        self.continuation = nil
                        continuation.resume(returning: port.rawValue)
                    } else if case .failed(let error) = state {
                        self.continuation = nil
                        continuation.resume(throwing: error)
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    connection.start(queue: self.queue)
                    Self.receive(connection, buffer: Data())
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard let continuation = self.continuation else { return }
                    self.continuation = nil
                    self.listener.cancel()
                    continuation.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                let text = String(decoding: buffer, as: UTF8.self)
                var response: Data
                if text.hasPrefix("GET /redirect "), let port = connection.currentPath?.localEndpoint,
                   case .hostPort(_, let localPort) = port {
                    response = Data("HTTP/1.1 302 Found\r\nLocation: http://books.invalid:\(localPort.rawValue)/chapter\r\nContent-Length: 0\r\n\r\n".utf8)
                } else {
                    response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(buffer.count)\r\n\r\n".utf8)
                    response.append(buffer)
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil || buffer.count > 65536 { connection.cancel() }
            else { receive(connection, buffer: buffer) }
        }
    }
}
