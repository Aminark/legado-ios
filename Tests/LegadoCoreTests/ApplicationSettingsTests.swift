import Foundation
import Testing
@testable import LegadoCore

struct ApplicationSettingsTests {
    @Test func upgradesTheOldPreloadDefaultOnceAndKeepsLaterChoices() throws {
        let suite = "legado.settings.preload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ApplicationSettings()
        old.prefetchChapters = 1
        old.userAgent = "Keep this setting"
        defaults.set(try JSONEncoder().encode(old), forKey: ApplicationSettingsStore.key)
        let store = ApplicationSettingsStore(defaults: defaults)
        #expect(ApplicationSettings().prefetchChapters == 10)
        #expect(store.settings.prefetchChapters == 10)
        #expect(store.settings.userAgent == old.userAgent)
        var chosen = store.settings
        chosen.prefetchChapters = 1
        try store.save(chosen)
        #expect(ApplicationSettingsStore(defaults: defaults).settings.prefetchChapters == 1)
    }

    @Test func preloadDefaultMigrationPreservesDisabledOrCustomCounts() throws {
        for count in [0, 5, 20] {
            let suite = "legado.settings.preload.custom.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var old = ApplicationSettings()
            old.prefetchChapters = count
            defaults.set(try JSONEncoder().encode(old), forKey: ApplicationSettingsStore.key)
            #expect(ApplicationSettingsStore(defaults: defaults).settings.prefetchChapters == count)
        }
    }

    @Test func validatesAndPersistsWithoutOverwritingOnFailure() throws {
        let suite = "legado.settings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        #expect(store.settings == ApplicationSettings())
        var value = ApplicationSettings()
        value.userAgent = "  Test Browser  "
        value.timeoutSeconds = 60
        value.concurrentSources = 3
        value.hosts = "127.0.0.1 books.example.com"
        try store.save(value)
        #expect(store.settings.userAgent == "Test Browser")
        #expect(store.settings.timeoutSeconds == 60)
        value.userAgent = "invalid\r\nHeader: injected"
        #expect(throws: SettingsError.self) { try store.save(value) }
        #expect(store.settings.userAgent == "Test Browser")
    }

    @Test func parsesIPv4IPv6CommentsAndMultipleDomains() throws {
        let hosts = try ApplicationSettings.parseHosts("""
        # local mirror
        127.0.0.1 Books.Example.com mirror.example.com # comment
        ::1 ipv6.example.com
        192.168.0.2 books.example.com
        """)
        #expect(hosts["books.example.com"] == "192.168.0.2")
        #expect(hosts["mirror.example.com"] == "127.0.0.1")
        #expect(hosts["ipv6.example.com"] == "::1")
        for invalid in ["no-ip example.com", "256.0.0.1 example.com", "127.0.0.1 https://example.com", "127.0.0.1 bad..example", "127.0.0.1 -bad.com"] {
            #expect(throws: SettingsError.self) { _ = try ApplicationSettings.parseHosts(invalid) }
        }
    }

    @Test func proxyAndRequestPrecedence() throws {
        var settings = ApplicationSettings()
        settings.proxy = "socks5://127.0.0.1:1089"
        settings.userAgent = "Global UA"
        settings.timeoutSeconds = 45
        let config = URLSessionConfiguration.ephemeral
        try settings.configure(config)
        #expect(config.connectionProxyDictionary?["SOCKSPort"] as? Int == 1089)
        try settings.configure(config, proxyOverride: "http://localhost:8000")
        #expect(config.connectionProxyDictionary?["HTTPPort"] as? Int == 8000)
        var request = URLRequest(url: URL(string: "https://example.com")!, timeoutInterval: 5)
        #expect(settings.configure(request).value(forHTTPHeaderField: "User-Agent") == "Global UA")
        request.setValue("Source UA", forHTTPHeaderField: "user-agent")
        #expect(settings.configure(request).value(forHTTPHeaderField: "User-Agent") == "Source UA")
        #expect(settings.configure(request).timeoutInterval == 45)
        request.setValue("", forHTTPHeaderField: "User-Agent")
        #expect(settings.configure(request).value(forHTTPHeaderField: "User-Agent") == "")
        for invalid in ["ftp://localhost:3", "http://localhost:0", "http://localhost:65536", "http://localhost/path", "http://user:pass@localhost:3"] {
            #expect(throws: SettingsError.self) { _ = try ApplicationSettings.proxyDictionary(invalid) }
        }
    }

    @Test func existingTransportUsesSavedSettingsOnNextRequest() async throws {
        let suite = "legado.transport.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsEchoURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: config, settingsStore: store)
        let request = URLRequest(url: URL(string: "https://settings.example/test")!)
        var settings = ApplicationSettings()
        settings.userAgent = "First UA"
        try store.save(settings)
        #expect(try await transport.data(for: request).decodedText == "First UA")
        settings.userAgent = "Second UA"
        settings.timeoutSeconds = 15
        try store.save(settings)
        #expect(try await transport.data(for: request).decodedText == "Second UA")
        var explicit = request
        explicit.setValue("Source UA", forHTTPHeaderField: "User-Agent")
        #expect(try await transport.data(for: explicit).decodedText == "Source UA")
    }

    @Test func suppressedSourceUAStaysSuppressedInURLRequest() throws {
        let prepared = try LegadoURLBuilder().prepare(#"https://example.com,{headers:{'User-Agent':'null'}}"#)
        #expect(prepared.headers["User-Agent"] == nil)
        #expect(prepared.urlRequest().value(forHTTPHeaderField: "User-Agent") == nil)
        var settings = ApplicationSettings()
        settings.userAgent = "Global UA"
        #expect(settings.configure(prepared.urlRequest()).value(forHTTPHeaderField: "User-Agent") == nil)
    }
}

private final class SettingsEchoURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "User-Agent") ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
