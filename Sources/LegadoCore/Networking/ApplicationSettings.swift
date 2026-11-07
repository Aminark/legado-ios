import Foundation
import Network

public struct ApplicationSettings: Codable, Equatable, Sendable {
    public var userAgent = ""
    public var proxy = ""
    public var hosts = ""
    public var timeoutSeconds = 0
    public var concurrentSources = 32
    public var chapterCacheMB = 256
    public var prefetchChapters = 10
    public var recordLog = false
    public var ignoreCertificateErrors = true

    public init() {}

    public var effectiveUserAgent: String {
        userAgent.isEmpty ? LegadoURLBuilder.defaultUserAgent : userAgent
    }

    public func validated() throws -> Self {
        var value = self
        value.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        value.proxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.userAgent.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SettingsError.invalid("User-Agent 不能包含换行。")
        }
        if !value.proxy.isEmpty { _ = try Self.proxyDictionary(value.proxy) }
        _ = try Self.parseHosts(hosts)
        guard timeoutSeconds == 0 || (5...300).contains(timeoutSeconds),
              (1...64).contains(concurrentSources), (16...4096).contains(chapterCacheMB),
              (0...20).contains(prefetchChapters) else {
            throw SettingsError.invalid("网络或缓存设置超出允许范围。")
        }
        return value
    }

    public func configure(_ configuration: URLSessionConfiguration, proxyOverride: String? = nil) throws {
        configuration.httpMaximumConnectionsPerHost = concurrentSources
        let address = proxyOverride ?? proxy
        configuration.connectionProxyDictionary = address.isEmpty ? nil : try Self.proxyDictionary(address)
        if timeoutSeconds > 0 {
            configuration.timeoutIntervalForRequest = Double(timeoutSeconds)
            configuration.timeoutIntervalForResource = Double(timeoutSeconds)
        }
    }

    public func configure(_ request: URLRequest) -> URLRequest {
        var request = request
        if timeoutSeconds > 0 { request.timeoutInterval = Double(timeoutSeconds) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil,
           URLProtocol.property(forKey: "LegadoSuppressUserAgent", in: request) as? Bool != true {
            request.setValue(effectiveUserAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    public static func proxyDictionary(_ address: String) throws -> [AnyHashable: Any] {
        guard let url = URL(string: address), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), ["http", "https", "socks", "socks4", "socks5"].contains(scheme),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", (1...65535).contains(url.port ?? 8080) else {
            throw SettingsError.invalid("代理格式应为 http://主机:端口、https://主机:端口或 socks5://主机:端口，不含账号和密码。")
        }
        let port = url.port ?? (scheme.hasPrefix("socks") ? 1080 : scheme == "https" ? 443 : 8080)
        if scheme.hasPrefix("socks") {
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
        }
        return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
    }

    public static func parseHosts(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !fields.isEmpty else { continue }
            guard fields.count >= 2, IPv4Address(fields[0]) != nil || IPv6Address(fields[0]) != nil else {
                throw SettingsError.invalid("Hosts 第 \(index + 1) 行应为 IP地址 域名，可添加 # 注释。")
            }
            for domain in fields.dropFirst() {
                let domain = domain.lowercased()
                guard domain.utf8.count <= 253, domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                    !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                        && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                }) else { throw SettingsError.invalid("Hosts 第 \(index + 1) 行的域名无效。") }
                values[domain] = fields[0]
            }
        }
        return values
    }
}

public enum SettingsError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

public final class ApplicationSettingsStore: @unchecked Sendable {
    public static let shared = ApplicationSettingsStore()
    public static let key = "legado.applicationSettings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let migrationKey = "legado.prefetchDefault10.v1"
        if !defaults.bool(forKey: migrationKey) {
            if let data = defaults.data(forKey: Self.key),
               var old = try? JSONDecoder().decode(ApplicationSettings.self, from: data),
               old.prefetchChapters == 1 {
                old.prefetchChapters = 10
                if let validated = try? old.validated(), let updated = try? JSONEncoder().encode(validated) {
                    defaults.set(updated, forKey: Self.key)
                }
            }
            defaults.set(true, forKey: migrationKey)
        }
    }

    public var settings: ApplicationSettings {
        guard let data = defaults.data(forKey: Self.key),
              let value = try? JSONDecoder().decode(ApplicationSettings.self, from: data),
              let validated = try? value.validated() else { return .init() }
        return validated
    }

    public func save(_ settings: ApplicationSettings) throws {
        let validated = try settings.validated()
        defaults.set(try JSONEncoder().encode(validated), forKey: Self.key)
    }
}
