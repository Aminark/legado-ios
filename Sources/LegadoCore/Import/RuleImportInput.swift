import Foundation

public enum RuleImportInput: Sendable, Equatable {
    case json(String)
    case remote(URL, withoutUserAgent: Bool)

    public static func isDeepLink(_ url: URL, kind: String = "bookSource") -> Bool {
        switch url.scheme?.lowercased() {
        case "legado":
            return url.host?.lowercased() == "import" && url.path.lowercased() == "/" + kind.lowercased()
        case "yuedu":
            return url.host?.lowercased() == kind.lowercased() && url.path.lowercased() == "/importonline"
        default:
            return false
        }
    }

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
            guard isDeepLink(url, kind: kind),
                  let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value,
                  !["legado:", "yuedu:"].contains(where: src.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix) else {
                throw BookSourceImportError.invalidDocument("二维码或深链类型不匹配，需要 \(kind)")
            }
            return try parse(src, kind: kind)
        }
        let marker = "#requestWithoutUA"
        let withoutUA = value.hasSuffix(marker)
        if withoutUA { value = String(value.dropLast(marker.count)) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw BookSourceImportError.invalidDocument("请输入 JSON、HTTP(S) 地址或阅读导入链接")
        }
        return .remote(url, withoutUserAgent: withoutUA)
    }

    public func request() -> URLRequest? {
        guard case .remote(let url, let withoutUA) = self else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if withoutUA { request.setValue("null", forHTTPHeaderField: "User-Agent") }
        return request
    }
}
