import Foundation
import Testing
@testable import LegadoCore

private actor ImportDownloadTransport: HTTPTransport {
    enum Result: Sendable {
        case response(Int, String)
        case failure(URLError.Code)
        case cancellation
    }
    let results: [Result]
    private(set) var requests: [URLRequest] = []

    init(_ results: [Result]) { self.results = results }

    func data(for request: URLRequest) throws -> HTTPResponse {
        let index = requests.count
        requests.append(request)
        guard index < results.count, let url = request.url else { throw URLError(.badServerResponse) }
        switch results[index] {
        case .failure(let code): throw URLError(code)
        case .cancellation: throw CancellationError()
        case .response(let status, let body):
            return .init(data: Data(body.utf8), statusCode: status, headers: [:], finalURL: url)
        }
    }
}

struct RuleImportDownloaderTests {
    private let rawURL = "https://raw.githubusercontent.com/gedoor/gedoor.github.io/master/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt"

    @Test func successfulDownloadDoesNotUseAnotherEndpoint() async throws {
        let transport = ImportDownloadTransport([.response(200, "original")])
        let request = URLRequest(url: try #require(URL(string: rawURL)))

        let response = try await RuleImportDownloader.data(for: request, using: transport)

        #expect(response.decodedText == "original")
        #expect(await transport.requests == [request])
    }

    @Test(arguments: [URLError.Code.secureConnectionFailed, .cannotFindHost, .dnsLookupFailed,
                      .cannotConnectToHost, .networkConnectionLost, .timedOut])
    func connectionFailureUsesTheSameFileAndRefWithoutCredentials(code: URLError.Code) async throws {
        let transport = ImportDownloadTransport([.failure(code), .response(200, "recovered")])
        var request = URLRequest(url: try #require(URL(string: rawURL)), timeoutInterval: 12)
        request.setValue("secret", forHTTPHeaderField: "Authorization")
        request.setValue("secret", forHTTPHeaderField: "Cookie")
        request.setValue("raw.githubusercontent.com", forHTTPHeaderField: "Host")
        request.setValue("Import Test", forHTTPHeaderField: "User-Agent")

        let response = try await RuleImportDownloader.data(for: request, using: transport)

        #expect(response.decodedText == "recovered")
        let requests = await transport.requests
        #expect(requests.count == 2)
        let alternate = try #require(requests.last)
        #expect(alternate.url?.absoluteString == "https://api.github.com/repos/gedoor/gedoor.github.io/contents/blog/2022-09-01-2213/%E6%BC%AB%E7%94%BB%E6%BA%90-haxc.txt?ref=master")
        #expect(alternate.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        #expect(alternate.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(alternate.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(alternate.value(forHTTPHeaderField: "Host") == nil)
        #expect(alternate.value(forHTTPHeaderField: "User-Agent") == "Import Test")
        #expect(alternate.timeoutInterval == 12)
    }

    @Test(arguments: [URLError.Code.cancelled, .notConnectedToInternet, .serverCertificateUntrusted, .userAuthenticationRequired])
    func otherFailuresDoNotRetry(code: URLError.Code) async throws {
        let transport = ImportDownloadTransport([.failure(code)])
        let request = URLRequest(url: try #require(URL(string: rawURL)))
        do {
            _ = try await RuleImportDownloader.data(for: request, using: transport)
            Issue.record("The failure should be preserved")
        } catch {
            let original = (error as? RuleImportDownloadError)?.originalError ?? error
            #expect((original as? URLError)?.code == code)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["https://example.com/owner/repo/main/file.json",
                      "https://raw.githubusercontent.com.evil.test/owner/repo/main/file.json",
                      "http://raw.githubusercontent.com/owner/repo/main/file.json",
                      "https://raw.githubusercontent.com/owner/repo/main/file.json?token=secret",
                      "https://user:secret@raw.githubusercontent.com/owner/repo/main/file.json",
                      "https://raw.githubusercontent.com:8443/owner/repo/main/file.json",
                      "https://raw.githubusercontent.com/owner/repo/main"])
    func onlyPublicGitHubRawFileURLsGetAnAlternate(url: String) async throws {
        let transport = ImportDownloadTransport([.failure(.secureConnectionFailed)])
        let request = URLRequest(url: try #require(URL(string: url)))
        await #expect(throws: RuleImportDownloadError.self) {
            try await RuleImportDownloader.data(for: request, using: transport)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func HTTPFailureIsNotRetried() async throws {
        let transport = ImportDownloadTransport([.response(404, "not found")])
        let request = URLRequest(url: try #require(URL(string: rawURL)))
        await #expect(throws: RuleImportDownloadError.self) {
            try await RuleImportDownloader.data(for: request, using: transport)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func alternateFailureRetainsBothErrorsAndStopsRetrying() async throws {
        let transport = ImportDownloadTransport([.failure(.secureConnectionFailed), .response(403, "rate limited")])
        let request = URLRequest(url: try #require(URL(string: rawURL)))
        do {
            _ = try await RuleImportDownloader.data(for: request, using: transport)
            Issue.record("Both download failures should be reported")
        } catch {
            let failure = try #require(error as? RuleImportDownloadError)
            #expect((failure.originalError as? URLError)?.code == .secureConnectionFailed)
            #expect(failure.localizedDescription.contains("-1200"))
            #expect(failure.localizedDescription.contains("HTTP 403"))
            #expect(failure.localizedDescription.contains("api.github.com"))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func cancellationOfAlternateIsPropagated() async throws {
        let transport = ImportDownloadTransport([.failure(.secureConnectionFailed), .cancellation])
        let request = URLRequest(url: try #require(URL(string: rawURL)))
        await #expect(throws: CancellationError.self) {
            try await RuleImportDownloader.data(for: request, using: transport)
        }
        #expect(await transport.requests.count == 2)
    }
}
