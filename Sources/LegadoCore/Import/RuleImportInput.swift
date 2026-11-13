import Foundation

public enum RuleImportInput: Sendable, Equatable {
    case json(String)
    case remote(URL, withoutUserAgent: Bool)

    public static func parse(_ input: String, kind: String = "bookSource") throws -> Self {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{"), value.hasSuffix("}") { return .json(value) }
        if value.hasPrefix("["), value.hasSuffix("]"), (try? JSONValue.decode(data: Data(value.utf8))) != nil {
            return .json(value)
        }
        if let start = value.range(of: "]("), value.hasSuffix(")") {
            value = String(value[start.upperBound..<value.index(before: value.endIndex)])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "*`<> \n\r\t"))
        if let url = URL(string: value), ["legado", "yuedu"].contains(url.scheme?.lowercased() ?? "") {
            guard isDeepLink(url, for: kind),
                  let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value,
                  !["legado", "yuedu"].contains(URL(string: src.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() ?? "") else {
                throw BookSourceImportError.invalidDocument("二维码或深链类型不匹配，需要 \(kind)")
            }
            return try parse(src, kind: kind)
        }
        let marker = "#requestWithoutUA"
        let withoutUA = value.hasSuffix(marker)
        if withoutUA { value = String(value.dropLast(marker.count)) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw BookSourceImportError.invalidDocument("请输入 JSON、HTTP(S) 地址或 Legado 导入二维码")
        }
        return .remote(url, withoutUserAgent: withoutUA)
    }

    /// The generic Android import routes are resolved in the existing source
    /// preview, which checks the downloaded JSON type before presenting it.
    public static func isDeepLink(_ url: URL, for kind: String) -> Bool {
        guard ["legado", "yuedu"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        let kind = kind.lowercased()
        if host == "import" {
            if path == "/" + kind { return true }
            return kind == "booksource" && ["/auto", "/importonline"].contains(path)
        }
        guard path == "/importonline" else { return false }
        switch kind {
        case "booksource": return host == "booksource"
        case "replacerule": return host == "replace"
        default: return false
        }
    }

    public func request() -> URLRequest? {
        guard case .remote(let url, let withoutUA) = self else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if withoutUA { request.setValue("null", forHTTPHeaderField: "User-Agent") }
        return request
    }
}
