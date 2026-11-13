import Foundation

public struct RuleDiagnostic: Codable, Hashable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var code: String
    public var message: String
    public var rule: String

    public var id: String { "\(severity.rawValue):\(code):\(rule):\(message)" }

    public init(severity: Severity, code: String, message: String, rule: String) {
        self.severity = severity
        self.code = code
        self.message = message
        self.rule = rule
    }
}

public enum RuleEngineError: Error, Equatable, LocalizedError, Sendable {
    case malformedRule(rule: String, detail: String)
    case unsupportedRule(rule: String, feature: String)
    case invalidInput(rule: String, expected: String)
    case resourceLimit(rule: String, detail: String)

    public var code: String {
        switch self {
        case .malformedRule: "rule.malformed"
        case .unsupportedRule: "rule.unsupported"
        case .invalidInput: "rule.invalid_input"
        case .resourceLimit: "rule.resource_limit"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .malformedRule(_, let detail),
             .invalidInput(_, let detail),
             .resourceLimit(_, let detail):
            detail
        case .unsupportedRule(_, let feature):
            "当前规则后端尚不支持：\(feature)"
        }
    }

    public var rule: String {
        switch self {
        case .malformedRule(let rule, _),
             .unsupportedRule(let rule, _),
             .invalidInput(let rule, _),
             .resourceLimit(let rule, _):
            rule
        }
    }

    public var diagnostic: RuleDiagnostic {
        .init(severity: .error, code: code, message: localizedDescription, rule: rule)
    }
}

public struct RuleEvaluation: Sendable {
    public var values: [JSONValue]
    public var diagnostics: [RuleDiagnostic]
    public var variables: [String: String]
    public var rssArticle: RssArticle?

    public init(
        values: [JSONValue] = [],
        diagnostics: [RuleDiagnostic] = [],
        variables: [String: String] = [:],
        rssArticle: RssArticle? = nil
    ) {
        self.values = values
        self.diagnostics = diagnostics
        self.variables = variables
        self.rssArticle = rssArticle
        if self.rssArticle != nil {
            self.rssArticle?.variable = String(decoding: (try? JSONEncoder().encode(variables)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    public var strings: [String] {
        values.flatMap { value in
            if case .array(let items) = value { return items.map(\.stringValue) }
            return [value.stringValue]
        }
    }

    func listItems(rule: String) -> [JSONValue] {
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":") { return values }
        return values.flatMap { value in
            if case .array(let items) = value { return items }
            return [value]
        }
    }
    public var firstString: String? { strings.first(where: { !$0.isEmpty }) }
    public var leadingString: String? {
        guard let value = strings.first, !value.isEmpty else { return nil }
        return value
    }
    public var joinedString: String? {
        let value = strings.joined(separator: "\n")
        return value.isEmpty ? nil : value
    }
}
