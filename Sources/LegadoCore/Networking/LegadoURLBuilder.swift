import Foundation

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case head = "HEAD"
}

public struct URLTemplateContext: Sendable {
    var cancellation: RuleExecutionCancellation?
    var nestedRuleDepth = 0
    public var key: String?
    public var page: Int?
    public var variables: [String: String]
    public var source: BookSource?
    public var book: Book?
    public var chapter: BookChapter?
    public var rssArticle: RssArticle?

    public init(
        key: String? = nil,
        page: Int? = nil,
        variables: [String: String] = [:],
        source: BookSource? = nil,
        book: Book? = nil,
        chapter: BookChapter? = nil,
        rssArticle: RssArticle? = nil
    ) {
        self.key = key
        self.page = page
        self.variables = rssArticle?.variableMap.merging(variables) { _, current in current } ?? variables
        self.source = source
        self.book = book
        self.chapter = chapter
        self.rssArticle = rssArticle
    }

    fileprivate func value(for expression: String) -> String? {
        switch expression.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "key", "searchKey": key
        case "page", "searchPage": page.map(String.init)
        default: variables[expression.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
    }
}

public struct PreparedRequest: Sendable {
    public var suppressesUserAgent: Bool
    public var ruleURL: String
    /// Expanded URL rule including options, for replaying a detail page that
    /// arrived through search without re-running key/page template scripts.
    public var resolvedRuleURL: String
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var charset: String?
    public var retry: Int
    public var useWebView: Bool
    public var webJavaScript: String?
    /// Content-rule resource URL matcher, used only for a WebView request.
    public var sourceRegex: String?
    /// A POST response fetched by the configured transport for WebView parsing.
    public var webViewHTML: String?
    public var bodyJavaScript: String?
    public var webViewDelayMilliseconds: Int
    public var responseType: String?
    public var proxy: String?
    public var dnsIP: String?
    public var serverID: Int64?
    public var variables: [String: String]
    public var key: String?
    public var page: Int?
    public var book: Book?
    public var chapter: BookChapter?
    public var rssArticle: RssArticle?

    public init(
        ruleURL: String,
        url: URL,
        method: HTTPMethod,
        headers: [String: String],
        body: Data?,
        charset: String?,
        retry: Int,
        useWebView: Bool,
        webJavaScript: String?,
        bodyJavaScript: String?,
        webViewDelayMilliseconds: Int = 0,
        responseType: String? = nil,
        proxy: String? = nil,
        dnsIP: String? = nil,
        serverID: Int64? = nil,
        variables: [String: String] = [:],
        key: String? = nil,
        page: Int? = nil,
        book: Book? = nil,
        chapter: BookChapter? = nil,
        rssArticle: RssArticle? = nil,
        suppressesUserAgent: Bool = false,
        resolvedRuleURL: String? = nil,
        sourceRegex: String? = nil,
        webViewHTML: String? = nil
    ) {
        self.suppressesUserAgent = suppressesUserAgent
        self.ruleURL = ruleURL
        self.resolvedRuleURL = resolvedRuleURL ?? ruleURL
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.charset = charset
        self.retry = retry
        self.useWebView = useWebView
        self.webJavaScript = webJavaScript
        self.sourceRegex = sourceRegex
        self.webViewHTML = webViewHTML
        self.bodyJavaScript = bodyJavaScript
        self.webViewDelayMilliseconds = webViewDelayMilliseconds
        self.responseType = responseType
        self.proxy = proxy
        self.dnsIP = dnsIP
        self.serverID = serverID
        self.variables = variables
        self.key = key
        self.page = page
        self.book = book
        self.chapter = chapter
        self.rssArticle = rssArticle
    }

    public func urlRequest(timeout: TimeInterval = 30, handleCookies: Bool = true) -> URLRequest {
        let override = ApplicationSettingsStore.shared.settings.timeoutSeconds
        var request = URLRequest(url: url, timeoutInterval: override > 0 ? Double(override) : timeout)
        request.httpMethod = method.rawValue
        request.httpBody = method == .post ? body : nil
        request.httpShouldHandleCookies = handleCookies
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if suppressesUserAgent {
            let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
            URLProtocol.setProperty(true, forKey: "LegadoSuppressUserAgent", in: mutable)
            return mutable as URLRequest
        }
        return request
    }
}

public struct LegadoURLBuilder: Sendable {
    public static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    var rssVariableStore: RSSVariableStore

    public init(rssVariableStore: RSSVariableStore = .shared) { self.rssVariableStore = rssVariableStore }

    public static func resolve(_ value: String, against baseURL: URL) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("javascript:") { return "" }
        guard let pattern = try? NSRegularExpression(pattern: #",\s*(?=\{)"#),
              let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value
        }
        let address = String(value[..<range.lowerBound])
        let options = String(value[range.lowerBound...])
        return (URL(string: address, relativeTo: baseURL)?.absoluteURL.absoluteString ?? address) + options
    }

    public static func decodeLenientJSON(_ source: String, quoteUnquotedValues: Bool = false) throws -> JSONValue {
        try JSONValue.decode(data: Data(lenientJSON(source, quoteUnquotedValues: quoteUnquotedValues).utf8))
    }

    public func prepare(
        _ template: String,
        context: URLTemplateContext = .init(),
        baseURL: URL? = nil,
        defaultHeaders: [String: String] = [:]
    ) throws -> PreparedRequest {
        var context = context
        let renderedResult = try renderResult(template, context: context, baseURL: baseURL)
        context.rssArticle = renderedResult.rssArticle
        let rendered = renderedResult.text
        let parsed = try parseOptions(rendered, rule: template)
        let options = parsed.options
        var urlText = parsed.url
        var variables = renderedResult.variables
        if let script = options.javaScript {
            let evaluated = try evaluateJavaScript(
                script,
                result: .string(urlText),
                context: context,
                variables: variables,
                baseURL: baseURL
            )
            urlText = evaluated.value.stringValue
            variables = evaluated.variables
            context.rssArticle = evaluated.rssArticle ?? context.rssArticle
        }
        let charsetEncoding = options.charset.flatMap(HTTPTextDecoder.encoding(named:))
        let requestURLText = encodeQueryIfNeeded(urlText, encoding: charsetEncoding)
        var urlAllowed = CharacterSet.urlFragmentAllowed
        urlAllowed.insert(charactersIn: "%")
        let encoded = requestURLText.addingPercentEncoding(withAllowedCharacters: urlAllowed) ?? requestURLText
        guard let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL else {
            throw RuleEngineError.malformedRule(rule: template, detail: "URL 无法解析：\(urlText)")
        }
        var headers = defaultHeaders
        let proxyKey = headers.keys.first { $0.caseInsensitiveCompare("proxy") == .orderedSame }
        let proxy = proxyKey.flatMap { headers.removeValue(forKey: $0) }
        for (key, value) in options.headers {
            for existing in Array(headers.keys) where existing.caseInsensitiveCompare(key) == .orderedSame {
                headers.removeValue(forKey: existing)
            }
            headers[key] = value
        }
        let userAgentKey = headers.keys.first { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }
        let suppressesUserAgent = userAgentKey.flatMap { headers[$0] } == "null"
        if suppressesUserAgent, let userAgentKey {
            headers.removeValue(forKey: userAgentKey)
        }
        if !suppressesUserAgent,
           headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }) == nil {
            headers["User-Agent"] = ApplicationSettingsStore.shared.settings.effectiveUserAgent
        }
        let bodyText = options.body?.stringValue
        let trimmedBody = bodyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isStructuredBody = trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[") || trimmedBody.hasPrefix("<")
        let hasExplicitContentType = headers.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
        let encodedBodyText = if let bodyText, !isStructuredBody, !hasExplicitContentType {
            percentEncode(bodyText, encoding: charsetEncoding ?? .utf8, preserving: Self.formDelimiters, spaceAsPlus: true)
        } else {
            bodyText
        }
        let body = options.method == .post ? (encodedBodyText?.data(using: charsetEncoding ?? .utf8) ?? Data()) : nil
        if options.method == .post, !hasExplicitContentType {
            let charsetName = options.charset ?? "utf-8"
            if trimmedBody.hasPrefix("<") {
                headers["Content-Type"] = "application/xml; charset=\(charsetName)"
            } else if isStructuredBody {
                headers["Content-Type"] = "application/json; charset=\(charsetName)"
            } else {
                headers["Content-Type"] = "application/x-www-form-urlencoded; charset=\(charsetName)"
            }
        }
        return .init(
            ruleURL: template,
            url: url,
            method: options.method,
            headers: headers,
            body: body,
            charset: options.charset,
            retry: options.retry,
            useWebView: options.useWebView,
            webJavaScript: options.webJavaScript,
            bodyJavaScript: options.bodyJavaScript,
            webViewDelayMilliseconds: options.webViewDelayMilliseconds,
            responseType: options.responseType,
            proxy: proxy,
            dnsIP: options.dnsIP,
            serverID: options.serverID,
            variables: variables,
            key: context.key,
            page: context.page,
            book: context.book,
            chapter: context.chapter,
            rssArticle: context.rssArticle,
            suppressesUserAgent: suppressesUserAgent,
            resolvedRuleURL: Self.resolve(rendered, against: baseURL ?? url)
        )
    }

    private static let queryDelimiters: CharacterSet = {
        var value = CharacterSet.alphanumerics
        value.insert(charactersIn: "-._~!$&'()*+,;=:@/?%")
        return value
    }()
    private static let formDelimiters: CharacterSet = {
        var value = CharacterSet.alphanumerics
        value.insert(charactersIn: "-._~&=;%+")
        return value
    }()

    private func encodeQueryIfNeeded(_ value: String, encoding: String.Encoding?) -> String {
        guard let encoding, encoding != .utf8, let separator = value.firstIndex(of: "?") else { return value }
        let queryStart = value.index(after: separator)
        return String(value[...separator])
            + percentEncode(String(value[queryStart...]), encoding: encoding, preserving: Self.queryDelimiters)
    }

    private func percentEncode(
        _ value: String,
        encoding: String.Encoding,
        preserving allowed: CharacterSet,
        spaceAsPlus: Bool = false
    ) -> String {
        var output = ""
        for character in value {
            let text = String(character)
            if spaceAsPlus, text == " " {
                output += "+"
                continue
            }
            if text.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) {
                output += text
                continue
            }
            let bytes = text.data(using: encoding) ?? Data(text.utf8)
            output += bytes.map { String(format: "%%%02X", $0) }.joined()
        }
        return output
    }

    public func render(_ template: String, context: URLTemplateContext) throws -> String {
        try renderResult(template, context: context, baseURL: nil).text
    }

    private func renderResult(
        _ template: String,
        context: URLTemplateContext,
        baseURL: URL?
    ) throws -> (text: String, variables: [String: String], rssArticle: RssArticle?) {
        var context = context
        var variables = context.variables
        let segments = try evaluateJavaScriptSegments(
            template,
            context: context,
            variables: variables,
            baseURL: baseURL
        )
        var result = segments.text
        variables = segments.variables
        context.rssArticle = segments.rssArticle
        let inline = try NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#)
        let matches = inline.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let expressionRange = Range(match.range(at: 1), in: result) else { continue }
            let expression = String(result[expressionRange])
            let value: String
            if let literal = context.value(for: expression) {
                value = literal
            } else {
                let evaluated = try evaluateJavaScript(
                    expression,
                    result: .string(result),
                    context: context,
                    variables: variables,
                    baseURL: baseURL
                )
                value = evaluated.value.stringValue
                variables = evaluated.variables
                context.rssArticle = evaluated.rssArticle ?? context.rssArticle
            }
            result.replaceSubrange(fullRange, with: value)
        }
        if let key = context.key {
            result = result.replacingOccurrences(of: "searchKey", with: key)
        }
        if let page = context.page {
            result = result.replacingOccurrences(of: "searchPage", with: String(page))
        }
        if let page = context.page {
            let pageExpression = try NSRegularExpression(pattern: #"<([^<>]*?)>"#)
            let pageMatches = pageExpression.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            ).reversed()
            for match in pageMatches {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let listRange = Range(match.range(at: 1), in: result) else { continue }
                let choices = result[listRange].split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !choices.isEmpty else { continue }
                let selected = choices[min(max(page - 1, 0), choices.count - 1)]
                result.replaceSubrange(fullRange, with: selected)
            }
        }
        return (result, variables, context.rssArticle)
    }

    private func evaluateJavaScriptSegments(
        _ template: String,
        context: URLTemplateContext,
        variables: [String: String],
        baseURL: URL?
    ) throws -> (text: String, variables: [String: String], rssArticle: RssArticle?) {
        var context = context
        let expression = try NSRegularExpression(
            pattern: #"<js>([\s\S]*?)</js>|@js:([\s\S]*)"#,
            options: .caseInsensitive
        )
        let matches = expression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        guard !matches.isEmpty else { return (template, variables, context.rssArticle) }
        var output = template
        var currentVariables = variables
        var cursor = template.startIndex
        for match in matches {
            guard let matchRange = Range(match.range(at: 0), in: template) else { continue }
            let prefix = String(template[cursor..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { output = prefix.replacingOccurrences(of: "@result", with: output) }
            let capture = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 1)
            guard let scriptRange = Range(capture, in: template) else { continue }
            let evaluated = try evaluateJavaScript(
                String(template[scriptRange]),
                result: .string(output),
                context: context,
                variables: currentVariables,
                baseURL: baseURL
            )
            output = evaluated.value.stringValue
            currentVariables = evaluated.variables
            context.rssArticle = evaluated.rssArticle ?? context.rssArticle
            cursor = matchRange.upperBound
        }
        let suffix = String(template[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty { output = suffix.replacingOccurrences(of: "@result", with: output) }
        return (output, currentVariables, context.rssArticle)
    }

    private func evaluateJavaScript(
        _ script: String,
        result: JSONValue,
        context: URLTemplateContext,
        variables: [String: String],
        baseURL: URL?
    ) throws -> JavaScriptRuleResult {
        var execution = RuleExecutionContext(
                variables: variables,
                baseURL: baseURL?.absoluteString ?? context.source?.bookSourceUrl ?? "",
                key: context.key,
                page: context.page,
                source: context.source,
                book: context.book,
                chapter: context.chapter,
                rssArticle: context.rssArticle
            )
        execution.cancellation = context.cancellation
        execution.nestedRuleDepth = context.nestedRuleDepth
        return try JavaScriptRuleEvaluator(rssVariableStore: rssVariableStore).evaluate(
            script: script, result: result, executionContext: execution
        )
    }

    private func splitOptions(_ value: String) -> [(url: String, options: String)] {
        guard let expression = try? NSRegularExpression(pattern: #"\s*,\s*(?=\{)"#) else {
            return [(value.trimmingCharacters(in: .whitespacesAndNewlines), "")]
        }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else {
            return [(value.trimmingCharacters(in: .whitespacesAndNewlines), "")]
        }
        return matches.reversed().compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return (
                String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func parseOptions(_ source: String, rule: String) throws -> (url: String, options: Options) {
        let candidates = splitOptions(source)
        var firstError: Error?
        for (index, candidate) in candidates.enumerated() {
            guard !candidate.options.isEmpty else {
                return (candidate.url, .init())
            }
            do {
                let value = try decodeOptions(candidate.options)
                guard case .object(let object) = value else {
                    throw RuleEngineError.malformedRule(rule: rule, detail: "URL 参数必须是 JSON 对象")
                }
                return (candidate.url, try makeOptions(object, rule: rule))
            } catch {
                if index == 0 { firstError = error }
                continue
            }
        }
        throw firstError ?? RuleEngineError.malformedRule(rule: rule, detail: "URL 参数 JSON 无效")
    }

    private func decodeOptions(_ source: String) throws -> JSONValue {
        do {
            return try JSONValue.decode(data: Data(source.utf8))
        } catch {
            do {
                return try JSONValue.decode(data: Data(Self.lenientJSON(source).utf8))
            } catch {
                throw RuleEngineError.malformedRule(rule: source, detail: "URL 参数 JSON 无效：\(error.localizedDescription)")
            }
        }
    }

    private func makeOptions(_ object: [String: JSONValue], rule: String) throws -> Options {
        var options = Options()
        if let method = object["method"]?.stringValue.uppercased() {
            options.method = HTTPMethod(rawValue: method) ?? .get
        }
        options.charset = object["charset"]?.stringValue.nilIfEmpty
        options.retry = Int(object["retry"]?.stringValue ?? "") ?? 0
        options.useWebView = object["webView"].map { value in
            switch value {
            case .bool(let enabled): enabled
            case .number(let number): number != 0
            case .string(let string): !string.isEmpty && string.lowercased() != "false"
            default: false
            }
        } ?? false
        options.webJavaScript = object["webJs"]?.stringValue.nilIfEmpty
        options.bodyJavaScript = object["bodyJs"]?.stringValue.nilIfEmpty
        options.javaScript = object["js"]?.stringValue.nilIfEmpty
        options.webViewDelayMilliseconds = min(max(Int(object["webViewDelayTime"]?.stringValue ?? "") ?? 0, 0), 30_000)
        options.responseType = object["type"]?.stringValue.nilIfEmpty
        options.dnsIP = object["dnsIp"]?.stringValue.nilIfEmpty
        options.serverID = Int64(object["serverID"]?.stringValue ?? "")
        options.body = object["body"]
        if let headerValue = object["headers"] {
            options.headers = try parseHeaders(headerValue, rule: rule)
        }
        return options
    }

    private static func lenientJSON(_ source: String, quoteUnquotedValues: Bool = false) -> String {
        let characters = Array(source)
        var output = ""
        var index = 0
        var expectingKey = true

        func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "\"":
                output.append("\"")
                while index < characters.count {
                    let inner = characters[index]
                    index += 1
                    output.append(inner)
                    if inner == "\\", index < characters.count {
                        output.append(characters[index])
                        index += 1
                        continue
                    }
                    if inner == "\"" { break }
                }
                expectingKey = false
            case "'":
                var text = ""
                while index < characters.count {
                    let inner = characters[index]
                    index += 1
                    if inner == "\\", index < characters.count {
                        let escaped = characters[index]
                        index += 1
                        text.append(escaped == "'" ? "'" : "\\\(escaped)")
                        continue
                    }
                    if inner == "'" { break }
                    text.append(inner)
                }
                output.append(escapedJSONString(text))
                expectingKey = false
            case "/":
                if peek() == "/" {
                    index += 1
                    while let value = peek(), value != "\n" { index += 1 }
                } else if peek() == "*" {
                    index += 1
                    while let value = peek() {
                        if value == "*", peek(1) == "/" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                } else {
                    output.append(character)
                }
            case "{", ",":
                output.append(character)
                expectingKey = true
            case ":", "=":
                // Gson also accepts = and => between an object key and value.
                // Quoted strings are consumed above, so Cookie/URL values stay intact.
                output.append(":")
                if character == "=", peek() == ">" { index += 1 }
                expectingKey = false
                do {
                    var start = index
                    while start < characters.count, characters[start].isWhitespace { start += 1 }
                    if start < characters.count, !["\"", "'", "{", "[", "}", ","].contains(characters[start]) {
                        var end = start
                        if quoteUnquotedValues {
                            // @put values are rules, including unquoted JSONPath expressions.
                            while end < characters.count, characters[end] != ",", characters[end] != "}" { end += 1 }
                        } else {
                            while end < characters.count, !characters[end].isWhitespace,
                                  ![",", "}", "]", "{", "[", ":", ";", "=", "/", "#", "\\"].contains(characters[end]) { end += 1 }
                        }
                        if end > start {
                            let token = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let literal = token.lowercased()
                            let isLiteral = ["true", "false", "null"].contains(literal)
                                || token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
                            output.append(!quoteUnquotedValues && isLiteral ? literal : escapedJSONString(token))
                            index = end
                        }
                    }
                }
            case "}", "]":
                while output.last == "," { output.removeLast() }
                output.append(character)
                expectingKey = false
            default:
                output.append(character)
                if expectingKey, character.isLetter || character == "_" || character == "$" {
                    var name = String(character)
                    var position = index
                    while position < characters.count {
                        let inner = characters[position]
                        guard inner.isLetter || inner.isNumber || inner == "_" || inner == "$" || inner == "-" else { break }
                        name.append(inner)
                        position += 1
                    }
                    var peekPosition = position
                    while peekPosition < characters.count, characters[peekPosition].isWhitespace {
                        peekPosition += 1
                    }
                    if peekPosition < characters.count, [":", "="].contains(characters[peekPosition]) {
                        output.removeLast()
                        output.append(escapedJSONString(name))
                        index = position
                    }
                }
                if !character.isWhitespace { expectingKey = false }
            }
        }
        return output
    }

    private static func escapedJSONString(_ value: String) -> String {
        var text = ""
        for character in value {
            switch character {
            case "\"": text.append("\\\"")
            case "\\": text.append("\\\\")
            case "\n": text.append("\\n")
            case "\r": text.append("\\r")
            case "\t": text.append("\\t")
            default: text.append(character)
            }
        }
        return "\"\(text)\""
    }

    private func parseHeaders(_ value: JSONValue, rule: String) throws -> [String: String] {
        let parsed: JSONValue
        if case .string(let source) = value {
            do {
                parsed = try Self.decodeLenientJSON(source)
            } catch {
                throw RuleEngineError.malformedRule(rule: rule, detail: "headers JSON 无效")
            }
        } else {
            parsed = value
        }
        guard case .object(let object) = parsed else {
            throw RuleEngineError.malformedRule(rule: rule, detail: "headers 必须是对象")
        }
        return object.mapValues(\.stringValue)
    }

    private struct Options {
        var method: HTTPMethod = .get
        var charset: String?
        var headers: [String: String] = [:]
        var body: JSONValue?
        var retry = 0
        var useWebView = false
        var webJavaScript: String?
        var bodyJavaScript: String?
        var javaScript: String?
        var webViewDelayMilliseconds = 0
        var responseType: String?
        var dnsIP: String?
        var serverID: Int64?
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
