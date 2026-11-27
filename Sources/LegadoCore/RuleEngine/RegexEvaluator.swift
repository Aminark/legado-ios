import Foundation

public struct RegexLimits: Sendable {
    public var maximumInputLength: Int
    public var maximumPatternLength: Int
    public var maximumMatches: Int

    public init(
        maximumInputLength: Int = 2_000_000,
        maximumPatternLength: Int = 8_192,
        maximumMatches: Int = 10_000
    ) {
        self.maximumInputLength = maximumInputLength
        self.maximumPatternLength = maximumPatternLength
        self.maximumMatches = maximumMatches
    }
}

private final class RegexExpressionCache: @unchecked Sendable {
    static let shared = RegexExpressionCache()
    private let compiled = NSCache<NSString, NSRegularExpression>()
    private let lock = NSLock()
    private var nestedCheckCache: [String: Bool] = [:]

    private init() {
        compiled.countLimit = 512
    }

    func expression(for pattern: String) throws -> NSRegularExpression {
        let key = pattern as NSString
        if let cached = compiled.object(forKey: key) { return cached }
        let created = try NSRegularExpression(pattern: pattern)
        compiled.setObject(created, forKey: key)
        return created
    }

    func isNestedQuantifier(_ pattern: String, compute: () -> Bool) -> Bool {
        lock.lock()
        if let cached = nestedCheckCache[pattern] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        if nestedCheckCache.count >= 1024 { nestedCheckCache.removeAll(keepingCapacity: true) }
        nestedCheckCache[pattern] = value
        lock.unlock()
        return value
    }
}

public struct RegexEvaluator: Sendable {
    private static let repeatedAtomRegex = try? NSRegularExpression(
        pattern: #"^(?:\?:)?(?:\\[dDsSwW]|\\[^pPkKgG0-9]|\[(?:\\.|[^\]\\])*\]|[^\[\]()\\?*+{}|^$])(?:[+*]|\{[0-9]+,\})\??$"#
    )
    private static let unboundedRegex = try? NSRegularExpression(pattern: #"^(?:[+*]|\{[0-9]+,\})(?!\+)"#)

    public var limits: RegexLimits

    public init(limits: RegexLimits = .init()) {
        self.limits = limits
    }

    public func captureGroups(pattern: String, input: String) throws -> [[String]] {
        guard pattern.count <= limits.maximumPatternLength else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则表达式超过长度限制")
        }
        guard input.utf16.count <= limits.maximumInputLength else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则输入超过长度限制")
        }
        guard !hasObviousNestedQuantifier(pattern) else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则包含高风险嵌套量词")
        }
        let expression: NSRegularExpression
        do {
            expression = try RegexExpressionCache.shared.expression(for: pattern)
        } catch {
            throw RuleEngineError.malformedRule(rule: pattern, detail: error.localizedDescription)
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var captures: [[String]] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        var timedOut = false
        expression.enumerateMatches(in: input, options: .reportProgress, range: range) { match, _, stop in
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                timedOut = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            if captures.count >= limits.maximumMatches {
                stop.pointee = true
                return
            }
            captures.append((0 ..< match.numberOfRanges).map { group in
                let range = match.range(at: group)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else { return "" }
                return String(input[swiftRange])
            })
        }
        if timedOut { throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则匹配超时（3000 ms）") }
        if captures.count >= limits.maximumMatches {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则匹配数量超过限制")
        }
        return captures
    }

    public func replacing(
        pattern: String,
        in input: String,
        with replacement: String,
        firstOnly: Bool
    ) throws -> String {
        guard pattern.count <= limits.maximumPatternLength else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则表达式超过长度限制")
        }
        guard input.utf16.count <= limits.maximumInputLength else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则输入超过长度限制")
        }
        guard !hasObviousNestedQuantifier(pattern) else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则包含高风险嵌套量词")
        }
        let expression: NSRegularExpression
        do {
            expression = try RegexExpressionCache.shared.expression(for: pattern)
        } catch {
            if firstOnly { return replacement }
            return input.replacingOccurrences(of: pattern, with: replacement)
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        if firstOnly {
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            var first: NSTextCheckingResult?
            var timedOut = false
            expression.enumerateMatches(in: input, options: .reportProgress, range: range) { match, _, stop in
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    timedOut = true
                    stop.pointee = true
                } else if let match {
                    first = match
                    stop.pointee = true
                }
            }
            if timedOut { throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则匹配超时（3000 ms）") }
            guard let first else { return "" }
            return expression.replacementString(for: first, in: input, offset: 0, template: replacement)
        }
        return try replacingStrict(pattern: pattern, in: input, with: replacement)
    }

    public func replacingStrict(pattern: String, in input: String, with replacement: String,
                                timeoutMilliseconds: Int64 = 3_000) throws -> String {
        try replacingStrict(pattern: pattern, in: input, timeoutMilliseconds: timeoutMilliseconds) { expression, match in
            expression.replacementString(for: match, in: input, offset: 0, template: replacement)
        }
    }

    /// Legado's JS replacement still expands capture references, while quoting
    /// backslashes returned by the script (quoteReplacementJs in the reference).
    func replacingStrict(pattern: String, in input: String, timeoutMilliseconds: Int64 = 3_000,
                         replacement: (String) throws -> String) throws -> String {
        let original = input as NSString
        return try replacingStrict(pattern: pattern, in: input, timeoutMilliseconds: timeoutMilliseconds) { expression, match in
            let template = try replacement(original.substring(with: match.range))
                .replacingOccurrences(of: "\\", with: "\\\\")
            return expression.replacementString(for: match, in: input, offset: 0, template: template)
        }
    }

    private func replacingStrict(pattern: String, in input: String, timeoutMilliseconds: Int64,
                                 replacement: (NSRegularExpression, NSTextCheckingResult) throws -> String) throws -> String {
        guard pattern.count <= limits.maximumPatternLength, input.utf16.count <= limits.maximumInputLength,
              !hasObviousNestedQuantifier(pattern) else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则超过资源限制或包含高风险嵌套量词")
        }
        let expression: NSRegularExpression
        do { expression = try RegexExpressionCache.shared.expression(for: pattern) }
        catch { throw RuleEngineError.malformedRule(rule: pattern, detail: error.localizedDescription) }
        let milliseconds = timeoutMilliseconds <= 0 ? 3_000 : min(timeoutMilliseconds, 60_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
        let range = NSRange(location: 0, length: input.utf16.count)
        var matches: [NSTextCheckingResult] = []
        var timedOut = false
        var exceeded = false
        expression.enumerateMatches(in: input, options: .reportProgress, range: range) { match, _, stop in
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                timedOut = true
                stop.pointee = true
            } else if let match {
                if matches.count >= limits.maximumMatches { exceeded = true; stop.pointee = true }
                else { matches.append(match) }
            }
        }
        guard !timedOut else { throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则替换超时（\(milliseconds) ms）") }
        guard !exceeded else { throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则匹配数量超过限制") }
        guard !matches.isEmpty else { return input }
        let original = input as NSString
        var output = ""
        output.reserveCapacity(input.utf8.count)
        var offset = 0
        var outputLength = 0
        for match in matches {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则替换超时（\(milliseconds) ms）")
            }
            let untouched = original.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let replaced = try replacement(expression, match)
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw RuleEngineError.resourceLimit(rule: pattern, detail: "正则替换超时（\(milliseconds) ms）")
            }
            outputLength += untouched.utf16.count + replaced.utf16.count
            offset = NSMaxRange(match.range)
            guard outputLength <= limits.maximumInputLength * 2 else {
                throw RuleEngineError.resourceLimit(rule: pattern, detail: "替换结果超过长度限制")
            }
            output.append(untouched)
            output.append(replaced)
        }
        let tail = original.substring(from: offset)
        guard outputLength + tail.utf16.count <= limits.maximumInputLength * 2 else {
            throw RuleEngineError.resourceLimit(rule: pattern, detail: "替换结果超过长度限制")
        }
        output.append(tail)
        return output
    }

    private func hasObviousNestedQuantifier(_ pattern: String) -> Bool {
        guard pattern.contains("(") else { return false }
        return RegexExpressionCache.shared.isNestedQuantifier(pattern) {
            // Reject clear cases such as (a+)+ and (\w*)*. A '+' inside a character
            // class/escape is not a quantifier, and bounded or delimited repeated
            // groups are not proof of catastrophic backtracking. Other expressions
            // remain protected by enumerateMatches' progress/deadline checks.
            guard let repeatedAtom = Self.repeatedAtomRegex,
                  let unbounded = Self.unboundedRegex else { return false }
            var groups: [String.Index] = []
            var classDepth = 0
            var escaped = false
            for index in pattern.indices {
                let character = pattern[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "[" { classDepth += 1; continue }
                if character == "]", classDepth > 0 { classDepth -= 1; continue }
                guard classDepth == 0 else { continue }
                if character == "(" { groups.append(pattern.index(after: index)) }
                if character == ")", let start = groups.popLast() {
                    let inner = String(pattern[start..<index])
                    let suffix = String(pattern[pattern.index(after: index)...])
                    if repeatedAtom.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)) != nil,
                       unbounded.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) != nil { return true }
                }
            }
            return false
        }
    }
}
