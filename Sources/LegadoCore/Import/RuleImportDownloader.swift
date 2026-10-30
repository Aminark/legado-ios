import Foundation

/// Downloads import documents, with one alternate GitHub endpoint for connection failures.
public enum RuleImportDownloader {
    public static func data(for request: URLRequest, using transport: any HTTPTransport) async throws -> HTTPResponse {
        do {
            return try await checkedResponse(for: request, using: transport)
        } catch {
            if isCancellation(error) { throw error }
            let originalError = error
            guard isConnectionFailure(error), let alternate = githubAPIRequest(for: request) else {
                throw RuleImportDownloadError(originalURL: request.url, originalError: error)
            }
            try Task.checkCancellation()
            DiagnosticLog.shared.record(.warning, category: "书源导入",
                                        message: "GitHub 文件连接失败，尝试同一仓库文件的官方 API。")
            do {
                return try await checkedResponse(for: alternate, using: transport)
            } catch {
                if isCancellation(error) { throw error }
                throw RuleImportDownloadError(originalURL: request.url, originalError: originalError,
                                              alternateURL: alternate.url, alternateError: error)
            }
        }
    }

    private static func checkedResponse(for request: URLRequest, using transport: any HTTPTransport) async throws -> HTTPResponse {
        let response = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw HTTPClientError.statusResponse(response) }
        return response
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.secureConnectionFailed, .cannotFindHost, .dnsLookupFailed,
                .cannotConnectToHost, .networkConnectionLost, .timedOut].contains(error.code)
    }

    private static func githubAPIRequest(for request: URLRequest) -> URLRequest? {
        guard request.httpMethod == nil || request.httpMethod == "GET", request.httpBody == nil,
              let url = request.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil,
              let original = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Split before decoding so an escaped character in a filename or ref stays intact.
        let parts = original.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              parts.allSatisfy({ part in
                  guard let decoded = String(part).removingPercentEncoding else { return false }
                  return !decoded.isEmpty && decoded != "." && decoded != ".."
              }), let ref = String(parts[2]).removingPercentEncoding else { return nil }
        var alternate = URLComponents()
        alternate.scheme = "https"
        alternate.host = "api.github.com"
        alternate.percentEncodedPath = "/repos/\(parts[0])/\(parts[1])/contents/\(parts.dropFirst(3).joined(separator: "/"))"
        alternate.queryItems = [URLQueryItem(name: "ref", value: ref)]
        guard let alternateURL = alternate.url else { return nil }
        // Build a fresh request rather than forwarding cookies or authorization to another host.
        var result = URLRequest(url: alternateURL, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        result.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        result.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
        return result
    }
}

public struct RuleImportDownloadError: LocalizedError {
    public let originalURL: URL?
    public let originalError: any Error
    public var alternateURL: URL? = nil
    public var alternateError: (any Error)? = nil

    public var errorDescription: String? {
        var details = ["Could not download the import file.", describe(originalError, url: originalURL)]
        if let alternateError { details.append(describe(alternateError, url: alternateURL)) }
        if (originalError as? URLError)?.code == .secureConnectionFailed {
            details.append("Check your network or proxy settings, then try again.")
        }
        return details.joined(separator: "\n")
    }

    private func describe(_ error: any Error, url: URL?) -> String {
        let nsError = error as NSError
        return "\(url?.host ?? "Download"): \(DiagnosticLog.redact(error.localizedDescription)) (\(nsError.domain) \(nsError.code))"
    }
}
