import Foundation

public struct RuleEngine: Sendable {
    private static let jsPipelineRegex = try? NSRegularExpression(pattern: #"<js>([\s\S]*?)</js>|@js:([\s\S]*)"#, options: .caseInsensitive)
    private static let captureGroupRegex = try? NSRegularExpression(pattern: #"\$(\d{1,2})"#)
    private static let dynamicRuleRegex = try? NSRegularExpression(pattern: #"@get:\{([^}]+?)\}|\{\{([\s\S]*?)\}\}"#, options: .caseInsensitive)

    private let parser: RuleExpressionParser
    private let jsonPath: JSONPathEvaluator
    private let regex: RegexEvaluator
    private let html: HTMLRuleEvaluator
    private let javaScript: JavaScriptRuleEvaluator

    public init(
        parser: RuleExpressionParser = .init(),
        jsonPath: JSONPathEvaluator = .init(),
        regex: RegexEvaluator = .init(),
        html: HTMLRuleEvaluator = .init(),
        javaScript: JavaScriptRuleEvaluator = .init()
    ) {
        self.parser = parser
        self.jsonPath = jsonPath
        self.regex = regex
        self.html = html
        self.javaScript = javaScript
    }

    /// One worker owns an entire evaluation. Nested java.getString calls use
    /// the synchronous core on that same thread, without blocking another task.
    public func evaluate(
        _ rule: String, in input: JSONValue, listMode: Bool = false, context: RuleExecutionContext = .init()
    ) async -> RuleEvaluation {
        let cancellation = context.cancellation ?? RuleExecutionCancellation()
        var execution = context
        execution.cancellation = cancellation
        let snapshot = execution
        return await withTaskCancellationHandler {
            do {
                return try await RuleExecutionWorker.runRule {
                    evaluateSynchronously(rule, in: input, listMode: listMode, context: snapshot)
                }
            } catch {
                return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)],
                             variables: context.variables, rssArticle: context.rssArticle)
            }
        } onCancel: { cancellation.cancel() }
    }

    public func evaluate(
        _ rule: String, inText input: String, baseURL: String = "", listMode: Bool = false, context: RuleExecutionContext = .init()
    ) async -> RuleEvaluation {
        let cancellation = context.cancellation ?? RuleExecutionCancellation()
        var execution = context
        execution.cancellation = cancellation
        let snapshot = execution
        return await withTaskCancellationHandler {
            do {
                return try await RuleExecutionWorker.runRule {
                    evaluateSynchronously(rule, inText: input, baseURL: baseURL, listMode: listMode, context: snapshot)
                }
            } catch {
                return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)],
                             variables: context.variables, rssArticle: context.rssArticle)
            }
        } onCancel: { cancellation.cancel() }
    }

    func evaluateSynchronously(
        _ rule: String,
        in input: JSONValue,
        listMode: Bool = false,
        context: RuleExecutionContext = .init()
    ) -> RuleEvaluation {
        var context = context
        do { try context.checkCancellation() }
        catch { return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)], variables: context.variables, rssArticle: context.rssArticle) }
        if context.content == nil { context.content = input }
        if let pipeline = splitJavaScriptPipeline(rule) {
            return evaluatePipeline(pipeline, input: input, listMode: listMode, context: context)
        }
        do {
            let extracted = try extractPutRules(rule)
            if !extracted.puts.isEmpty {
                var nextContext = context
                var diagnostics: [RuleDiagnostic] = []
                for key in extracted.puts.keys.sorted() {
                    guard let valueRule = extracted.puts[key] else { continue }
                    let value = evaluateSynchronously(valueRule, in: input, context: nextContext)
                    diagnostics += value.diagnostics
                    if value.rssArticle != nil { nextContext.variables = value.variables }
                    else { nextContext.variables.merge(value.variables) { _, new in new } }
                    nextContext.rssArticle = value.rssArticle ?? nextContext.rssArticle
                    nextContext = try javaScript.settingVariable(key, value: value.strings.joined(separator: "\n"), context: nextContext)
                }
                if extracted.rule.isEmpty {
                    return .init(values: [input], diagnostics: diagnostics, variables: nextContext.variables, rssArticle: nextContext.rssArticle)
                }
                var result = evaluateSynchronously(extracted.rule, in: input, listMode: listMode, context: nextContext)
                result.diagnostics = diagnostics + result.diagnostics
                if result.rssArticle == nil { result.variables = nextContext.variables.merging(result.variables) { _, new in new } }
                return result
            }
            let rendered = try renderDynamicRule(extracted.rule, result: input, context: context)
            if rendered.captureLiteral {
                return literalEvaluation(rendered.rule, context: rendered.context)
            }
            if rendered.context.variables != context.variables || rendered.context.rssArticle != nil {
                var result = evaluatePrepared(rendered.rule, in: input, listMode: listMode, context: rendered.context)
                if result.rssArticle == nil { result.variables = rendered.context.variables.merging(result.variables) { _, new in new } }
                return result
            }
            return evaluatePrepared(rendered.rule, in: input, listMode: listMode, context: rendered.context)
        } catch let error as RuleEngineError {
            return .init(diagnostics: [error.diagnostic], variables: context.variables, rssArticle: context.rssArticle)
        } catch {
            return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)], variables: context.variables, rssArticle: context.rssArticle)
        }
    }

    private func evaluatePrepared(
        _ rule: String,
        in input: JSONValue,
        listMode: Bool,
        context: RuleExecutionContext
    ) -> RuleEvaluation {
        do {
            let plan = try parser.parse(rule, inputLooksLikeJSON: true)
            var results: [[JSONValue]] = []
            var diagnostics: [RuleDiagnostic] = []
            var execution = context
            for branch in plan.branches {
                try execution.checkCancellation()
                do {
                    let evaluation = try evaluateSynchronously(branch, in: input, context: execution)
                    execution.variables = evaluation.variables
                    execution.rssArticle = evaluation.rssArticle ?? execution.rssArticle
                    var values = evaluation.values
                    if plan.combination == .fallback, isEmpty(values, listMode: listMode) { values = [] }
                    results.append(values)
                    if plan.combination == .fallback, !values.isEmpty { break }
                } catch let error as RuleEngineError {
                    diagnostics.append(error.diagnostic)
                    results.append([])
                } catch {
                    diagnostics.append(.init(
                        severity: .error,
                        code: "rule.unexpected",
                        message: error.localizedDescription,
                        rule: branch.expression
                    ))
                    results.append([])
                }
            }
            return .init(
                values: try applyingReplacement(to: combine(results, with: plan.combination), plan: plan, listMode: listMode || context.replacesEachListItem),
                diagnostics: diagnostics,
                variables: execution.variables,
                rssArticle: execution.rssArticle
            )
        } catch let error as RuleEngineError {
            return .init(diagnostics: [error.diagnostic], variables: context.variables, rssArticle: context.rssArticle)
        } catch {
            return .init(diagnostics: [.init(
                severity: .error,
                code: "rule.unexpected",
                message: error.localizedDescription,
                rule: rule
            )], variables: context.variables, rssArticle: context.rssArticle)
        }
    }

    public func evaluateJSONPath(_ rule: String, in input: JSONValue) throws -> [JSONValue] {
        try jsonPath.evaluate(path: rule, in: input)
    }

    func evaluateSynchronously(
        _ rule: String,
        inText input: String,
        baseURL: String = "",
        listMode: Bool = false,
        context: RuleExecutionContext = .init()
    ) -> RuleEvaluation {
        var context = context
        do { try context.checkCancellation() }
        catch { return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)], variables: context.variables, rssArticle: context.rssArticle) }
        if context.baseURL.isEmpty { context.baseURL = baseURL }
        if context.content == nil { context.content = .string(input) }
        if let pipeline = splitJavaScriptPipeline(rule) {
            return evaluatePipeline(pipeline, input: .string(input), listMode: listMode, context: context)
        }
        do {
            let extracted = try extractPutRules(rule)
            if !extracted.puts.isEmpty {
                var nextContext = context
                var diagnostics: [RuleDiagnostic] = []
                for key in extracted.puts.keys.sorted() {
                    guard let valueRule = extracted.puts[key] else { continue }
                    let value = evaluateSynchronously(valueRule, inText: input, baseURL: baseURL, listMode: false, context: nextContext)
                    diagnostics += value.diagnostics
                    if value.rssArticle != nil { nextContext.variables = value.variables }
                    else { nextContext.variables.merge(value.variables) { _, new in new } }
                    nextContext.rssArticle = value.rssArticle ?? nextContext.rssArticle
                    nextContext = try javaScript.settingVariable(key, value: value.strings.joined(separator: "\n"), context: nextContext)
                }
                if extracted.rule.isEmpty {
                    return .init(values: [.string(input)], diagnostics: diagnostics, variables: nextContext.variables, rssArticle: nextContext.rssArticle)
                }
                var result = evaluateSynchronously(extracted.rule, inText: input, baseURL: baseURL, listMode: listMode, context: nextContext)
                result.diagnostics = diagnostics + result.diagnostics
                if result.rssArticle == nil { result.variables = nextContext.variables.merging(result.variables) { _, new in new } }
                return result
            }
            let rendered = try renderDynamicRule(extracted.rule, result: .string(input), context: context)
            if rendered.captureLiteral {
                return literalEvaluation(rendered.rule, context: rendered.context)
            }
            if rendered.context.variables != context.variables || rendered.context.rssArticle != nil {
                var result = evaluatePrepared(rendered.rule, inText: input, baseURL: baseURL, listMode: listMode, context: rendered.context)
                if result.rssArticle == nil { result.variables = rendered.context.variables.merging(result.variables) { _, new in new } }
                return result
            }
            return evaluatePrepared(rendered.rule, inText: input, baseURL: baseURL, listMode: listMode, context: rendered.context)
        } catch let error as RuleEngineError {
            return .init(diagnostics: [error.diagnostic], variables: context.variables, rssArticle: context.rssArticle)
        } catch {
            return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)], variables: context.variables, rssArticle: context.rssArticle)
        }
    }

    private func evaluatePrepared(
        _ rule: String,
        inText input: String,
        baseURL: String,
        listMode: Bool,
        context: RuleExecutionContext
    ) -> RuleEvaluation {
        let decodedJSON = HTTPResponse.decodeJSON(from: input)
        if let root = decodedJSON,
           let plan = try? parser.parse(rule, inputLooksLikeJSON: true),
           plan.branches.allSatisfy({ $0.mode == .jsonPath }) {
            return evaluatePrepared(rule, in: root, listMode: listMode, context: context)
        }
        if rule.hasPrefix(":"), rule.count > 1 {
            do {
                let patterns = rule.dropFirst().components(separatedBy: "&&").filter { !$0.isEmpty }
                guard !patterns.isEmpty else { return .init(variables: context.variables, rssArticle: context.rssArticle) }
                var stage = input
                var captures: [[String]] = []
                for (index, pattern) in patterns.enumerated() {
                    captures = try regex.captureGroups(pattern: pattern, input: stage)
                    if index + 1 < patterns.count {
                        stage = captures.compactMap(\.first).joined()
                    }
                }
                return .init(
                    values: captures.map { .array($0.map(JSONValue.string)) },
                    variables: context.variables,
                    rssArticle: context.rssArticle
                )
            } catch let error as RuleEngineError {
                return .init(diagnostics: [error.diagnostic], variables: context.variables, rssArticle: context.rssArticle)
            } catch {
                return .init(diagnostics: [.init(severity: .error, code: "rule.unexpected", message: error.localizedDescription, rule: rule)], variables: context.variables, rssArticle: context.rssArticle)
            }
        }
        do {
            let plan = try parser.parse(rule, inputLooksLikeJSON: decodedJSON != nil)
            var results: [[JSONValue]] = []
            var diagnostics: [RuleDiagnostic] = []
            var execution = context
            for branch in plan.branches {
                try execution.checkCancellation()
                do {
                    let evaluation = try evaluateTextBranch(
                        branch,
                        input: input,
                        baseURL: baseURL,
                        listMode: listMode,
                        context: execution
                    )
                    execution.variables = evaluation.variables
                    execution.rssArticle = evaluation.rssArticle ?? execution.rssArticle
                    results.append(evaluation.values)
                    if plan.combination == .fallback, !evaluation.values.isEmpty { break }
                } catch let error as RuleEngineError {
                    diagnostics.append(error.diagnostic)
                    results.append([])
                }
            }
            return .init(
                values: try applyingReplacement(to: combine(results, with: plan.combination), plan: plan, listMode: listMode || context.replacesEachListItem),
                diagnostics: diagnostics,
                variables: execution.variables,
                rssArticle: execution.rssArticle
            )
        } catch let error as RuleEngineError {
            return .init(diagnostics: [error.diagnostic], variables: context.variables, rssArticle: context.rssArticle)
        } catch {
            return .init(diagnostics: [.init(
                severity: .error,
                code: "rule.unexpected",
                message: error.localizedDescription,
                rule: rule
            )], variables: context.variables, rssArticle: context.rssArticle)
        }
    }

    private func evaluateSynchronously(
        _ branch: RuleBranch,
        in input: JSONValue,
        context: RuleExecutionContext
    ) throws -> RuleEvaluation {
        try context.checkCancellation()
        let rawValues: [JSONValue]
        if branch.expression.isEmpty {
            return .init(values: [input], variables: context.variables, rssArticle: context.rssArticle)
        }
        switch branch.mode {
        case .jsonPath:
            rawValues = try jsonPath.evaluateRule(branch.expression, in: input)
        case .regex:
            let matches = try regex.captureGroups(pattern: branch.expression, input: input.stringValue)
            rawValues = matches.map { .array($0.map(JSONValue.string)) }
        case .css:
            throw RuleEngineError.unsupportedRule(rule: branch.expression, feature: "CSS selector")
        case .xpath:
            throw RuleEngineError.unsupportedRule(rule: branch.expression, feature: "XPath")
        case .javaScript:
            let result = try javaScript.evaluate(
                script: branch.expression,
                result: input,
                executionContext: context
            )
            return .init(values: [result.value], variables: result.variables, rssArticle: result.rssArticle)
        case .webJavaScript:
            throw RuleEngineError.unsupportedRule(rule: branch.expression, feature: "WKWebView JavaScript")
        }
        return .init(values: rawValues, variables: context.variables, rssArticle: context.rssArticle)
    }

    private func evaluateTextBranch(
        _ branch: RuleBranch,
        input: String,
        baseURL: String,
        listMode: Bool,
        context: RuleExecutionContext
    ) throws -> RuleEvaluation {
        try context.checkCancellation()
        let raw: [String]
        if branch.expression.isEmpty {
            return .init(values: [.string(input)], variables: context.variables, rssArticle: context.rssArticle)
        }
        switch branch.mode {
        case .css:
            raw = try listMode
                ? html.selectCSSFragments(branch.expression, html: input, baseURL: baseURL, isFragment: context.isHTMLFragment)
                : html.extractCSS(branch.expression, html: input, baseURL: baseURL, isFragment: context.isHTMLFragment)
        case .xpath:
            raw = try listMode
                ? html.selectXPathFragments(branch.expression, html: input, isFragment: context.isHTMLFragment)
                : html.extractXPath(branch.expression, html: input, isFragment: context.isHTMLFragment)
        case .jsonPath:
            let root: JSONValue
            do {
                root = try JSONValue.decode(data: Data(input.utf8))
            } catch {
                throw RuleEngineError.invalidInput(rule: branch.expression, expected: "JSON")
            }
            raw = try jsonPath.evaluateRule(branch.expression, in: root).map(\.stringValue)
        case .regex:
            raw = try regex.captureGroups(pattern: branch.expression, input: input).map { captures in
                captures.count > 1 ? captures.dropFirst().joined() : captures.first ?? ""
            }
        case .javaScript:
            let result = try javaScript.evaluate(
                script: branch.expression,
                result: .string(input),
                executionContext: context
            )
            return .init(values: [result.value], variables: result.variables, rssArticle: result.rssArticle)
        case .webJavaScript:
            throw RuleEngineError.unsupportedRule(rule: branch.expression, feature: "WKWebView JavaScript")
        }
        return .init(values: raw.map(JSONValue.string), variables: context.variables, rssArticle: context.rssArticle)
    }

    private func isEmpty(_ values: [JSONValue], listMode: Bool) -> Bool {
        let result = RuleEvaluation(values: values)
        return listMode
            ? result.listItems(rule: "").filter { $0 != .null }.isEmpty
            : result.strings.joined(separator: "\n").isEmpty
    }

    private func applyingReplacement(to values: [JSONValue], plan: RulePlan, listMode: Bool) throws -> [JSONValue] {
        guard let branch = plan.branches.first, let pattern = branch.replacePattern, !pattern.isEmpty else { return values }
        let strings = RuleEvaluation(values: values).strings
        let inputs = listMode ? strings : [strings.joined(separator: "\n")]
        return try inputs.map {
            .string(try regex.replacing(pattern: pattern, in: $0, with: branch.replacement, firstOnly: branch.replaceFirst))
        }
    }

    private func combine(_ results: [[JSONValue]], with combination: RuleCombination) -> [JSONValue] {
        switch combination {
        case .single, .concatenate:
            return results.flatMap { $0 }
        case .fallback:
            return results.first(where: { !$0.isEmpty }) ?? []
        case .interleave:
            guard let firstCount = results.first?.count else { return [] }
            return (0 ..< firstCount).flatMap { index in
                results.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        }
    }

    private func evaluatePipeline(
        _ pipeline: JavaScriptPipeline,
        input: JSONValue,
        listMode: Bool,
        context: RuleExecutionContext
    ) -> RuleEvaluation {
        var execution = context
        let initial: RuleEvaluation
        if pipeline.prefix.isEmpty {
            initial = .init(values: [input], variables: context.variables, rssArticle: context.rssArticle)
        } else {
            initial = evaluateValue(pipeline.prefix, input: input, listMode: listMode, context: context)
        }
        execution.variables = initial.variables
        execution.rssArticle = initial.rssArticle ?? execution.rssArticle
        var diagnostics = initial.diagnostics
        let scriptInput: JSONValue
        if pipeline.prefix.isEmpty {
            scriptInput = input
        } else if listMode {
            if initial.values.count == 1, case .array = initial.values[0] {
                scriptInput = initial.values[0]
            } else {
                scriptInput = .array(initial.values)
            }
        } else {
            scriptInput = .string(initial.strings.joined(separator: "\n"))
        }
        do {
            // A discovery script produces URL templates for a subsequent request.
            // Interpreting their braces inside the JavaScript string changes its source.
            let rendered = execution.isGeneratingExploreKinds
                ? (rule: pipeline.script, context: execution, captureLiteral: false)
                : try renderDynamicRule(pipeline.script, result: scriptInput, context: execution)
            let result = try javaScript.evaluate(
                script: rendered.rule, result: scriptInput, executionContext: rendered.context
            )
            execution.variables = result.variables
            execution.rssArticle = result.rssArticle ?? execution.rssArticle
            guard !pipeline.suffix.isEmpty else {
                return .init(values: result.value == .null ? [] : [result.value], diagnostics: diagnostics, variables: execution.variables, rssArticle: execution.rssArticle)
            }
            execution.isHTMLFragment = false
            var next = evaluateValue(pipeline.suffix, input: result.value, listMode: listMode, context: execution)
            next.diagnostics = diagnostics + next.diagnostics
            return next
        } catch let error as RuleEngineError {
            diagnostics.append(error.diagnostic)
        } catch {
            diagnostics.append(.init(severity: .error, code: "rule.javascript", message: error.localizedDescription, rule: pipeline.script))
        }
        return .init(diagnostics: diagnostics, variables: execution.variables, rssArticle: execution.rssArticle)
    }

    private func evaluateValue(_ rule: String, input: JSONValue, listMode: Bool, context: RuleExecutionContext) -> RuleEvaluation {
        if case .string(let text) = input {
            return evaluateSynchronously(rule, inText: text, baseURL: context.baseURL, listMode: listMode, context: context)
        }
        return evaluateSynchronously(rule, in: input, listMode: listMode, context: context)
    }

    private func splitJavaScriptPipeline(_ rule: String) -> JavaScriptPipeline? {
        guard rule.range(of: "<js>", options: .caseInsensitive) != nil
            || rule.range(of: "@js:", options: .caseInsensitive) != nil else { return nil }
        // @put values can themselves contain JS rules. They belong to the put
        // operation, not to the surrounding rule's pipeline.
        let masked = NSMutableString(string: rule)
        for range in (try? putRuleRanges(rule))?.reversed() ?? [] {
            let span = NSRange(range.full, in: rule)
            masked.replaceCharacters(in: span, with: String(repeating: " ", count: span.length))
        }
        guard let pattern = Self.jsPipelineRegex,
              let match = pattern.firstMatch(in: masked as String, range: NSRange(location: 0, length: masked.length)),
              let full = Range(match.range, in: rule) else { return nil }
        let isInlineAtJS = match.range(at: 2).location != NSNotFound
        guard let scriptRange = Range(match.range(at: isInlineAtJS ? 2 : 1), in: rule) else { return nil }
        var scriptText = String(rule[scriptRange])
        var suffixText = String(rule[full.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if isInlineAtJS, suffixText.isEmpty,
           let split = splitTrailingReplacementFromJavaScript(scriptText) {
            scriptText = split.script
            suffixText = split.replacementSuffix
        }
        return .init(
            prefix: String(rule[..<full.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
            script: scriptText,
            suffix: suffixText
        )
    }

    /// Splits a Legado trailing `##regex##replacement` suffix off an `@js:` body
    /// without touching `##` sequences inside JS string literals, template
    /// literals, regex literals, or comments.
    private func splitTrailingReplacementFromJavaScript(_ source: String) -> (script: String, replacementSuffix: String)? {
        guard source.contains("##") else { return nil }

        enum LexState {
            case code
            case singleQuote
            case doubleQuote
            case template
            case regexLiteral(inCharClass: Bool)
            case lineComment
            case blockComment
        }

        var state: LexState = .code
        var templateBraceDepths: [Int] = []
        var escaped = false
        var lastSignificant: Character? = nil
        var index = source.startIndex

        func allowsRegexStart(after previous: Character?) -> Bool {
            guard let previous else { return true }
            return "(=,[!&|?:;{}\n+-*%^~<>".contains(previous)
        }

        while index < source.endIndex {
            let ch = source[index]
            let nextIndex = source.index(after: index)
            let nextChar: Character? = nextIndex < source.endIndex ? source[nextIndex] : nil

            switch state {
            case .code:
                if ch.isLetter || ch == "_" || ch == "$" {
                    let word = source[index...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
                    // A slash can begin an expression after these keywords, as in
                    // `return /##/.test(value)`, but follows a value after an identifier.
                    let expectsExpression = ["return", "throw", "case", "delete", "typeof", "void",
                                             "new", "in", "instanceof", "yield", "await", "else", "do"].contains(word)
                    let isProperty = lastSignificant == "."
                    lastSignificant = expectsExpression && !isProperty ? nil : word.last
                    index = word.endIndex
                    continue
                }
                if ch == "#", nextChar == "#", templateBraceDepths.isEmpty {
                    let body = String(source[..<index])
                    let suffix = String(source[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return (body, suffix)
                }
                if ch == "'" {
                    state = .singleQuote
                } else if ch == "\"" {
                    state = .doubleQuote
                } else if ch == "`" {
                    state = .template
                } else if ch == "/", nextChar == "/" {
                    state = .lineComment
                    index = source.index(after: nextIndex)
                    continue
                } else if ch == "/", nextChar == "*" {
                    state = .blockComment
                    index = source.index(after: nextIndex)
                    continue
                } else if ch == "/", allowsRegexStart(after: lastSignificant) {
                    state = .regexLiteral(inCharClass: false)
                } else if ch == "{", !templateBraceDepths.isEmpty {
                    templateBraceDepths[templateBraceDepths.count - 1] += 1
                    lastSignificant = ch
                } else if ch == "}", !templateBraceDepths.isEmpty {
                    let depth = templateBraceDepths[templateBraceDepths.count - 1] - 1
                    if depth == 0 {
                        templateBraceDepths.removeLast()
                        state = .template
                    } else {
                        templateBraceDepths[templateBraceDepths.count - 1] = depth
                    }
                    lastSignificant = ch
                } else if !ch.isWhitespace || ch == "\n" {
                    lastSignificant = ch
                }

            case .singleQuote:
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "'" { state = .code; lastSignificant = "'" }

            case .doubleQuote:
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { state = .code; lastSignificant = "\"" }

            case .template:
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "`" { state = .code; lastSignificant = "`" }
                else if ch == "$", nextChar == "{" {
                    templateBraceDepths.append(1)
                    state = .code
                    lastSignificant = "{"
                    index = source.index(after: nextIndex)
                    continue
                }

            case .regexLiteral(let inCharClass):
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "[", !inCharClass { state = .regexLiteral(inCharClass: true) }
                else if ch == "]", inCharClass { state = .regexLiteral(inCharClass: false) }
                else if ch == "/", !inCharClass { state = .code; lastSignificant = "/" }
                else if ch == "\n" { state = .code; lastSignificant = "\n" }

            case .lineComment:
                if ch == "\n" { state = .code; lastSignificant = "\n" }

            case .blockComment:
                if ch == "*", nextChar == "/" {
                    state = .code
                    index = source.index(after: nextIndex)
                    continue
                }
            }

            index = nextIndex
        }
        return nil
    }

    private func extractPutRules(_ source: String) throws -> (rule: String, puts: [String: String]) {
        let matches = try putRuleRanges(source)
        guard !matches.isEmpty else { return (source, [:]) }
        var puts: [String: String] = [:]
        var rule = source
        for match in matches.reversed() {
            if case .object(let object) = try LegadoURLBuilder.decodeLenientJSON(String(source[match.json]), quoteUnquotedValues: true) {
                puts.merge(object.mapValues(\.stringValue)) { _, new in new }
            }
            rule.removeSubrange(match.full)
        }
        return (rule.trimmingCharacters(in: .whitespacesAndNewlines), puts)
    }

    private func putRuleRanges(_ source: String) throws -> [(full: Range<String.Index>, json: Range<String.Index>)] {
        var ranges: [(full: Range<String.Index>, json: Range<String.Index>)] = []
        var cursor = source.startIndex
        while let marker = source.range(of: "@put:", options: .caseInsensitive, range: cursor..<source.endIndex) {
            var start = marker.upperBound
            while start < source.endIndex, source[start].isWhitespace { start = source.index(after: start) }
            guard start < source.endIndex, source[start] == "{" else { cursor = marker.upperBound; continue }
            var index = start
            var depth = 0
            var quote: Character?
            var escaped = false
            var end: String.Index?
            while index < source.endIndex {
                let character = source[index]
                if escaped { escaped = false }
                else if character == "\\", quote != nil { escaped = true }
                else if let active = quote { if character == active { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { end = source.index(after: index); break }
                }
                index = source.index(after: index)
            }
            guard let end else { throw RuleEngineError.malformedRule(rule: source, detail: "@put 对象缺少结束括号") }
            ranges.append((marker.lowerBound..<end, start..<end))
            cursor = end
        }
        return ranges
    }

    private func renderDynamicRule(
        _ source: String,
        result: JSONValue,
        context: RuleExecutionContext
    ) throws -> (rule: String, context: RuleExecutionContext, captureLiteral: Bool) {
        var source = source
        var captureLiteral = false
        if case .array(let captures) = result, source.contains("$"), let captureExpression = Self.captureGroupRegex {
            let captureEnd = source.range(of: "##")?.lowerBound ?? source.endIndex
            let matches = captureExpression.matches(in: source, range: NSRange(source.startIndex..<captureEnd, in: source))
            if !matches.isEmpty {
                captureLiteral = true
                for match in matches.reversed() {
                    guard let fullRange = Range(match.range(at: 0), in: source),
                          let indexRange = Range(match.range(at: 1), in: source),
                          let index = Int(source[indexRange]) else { continue }
                    source.replaceSubrange(fullRange, with: captures.indices.contains(index) ? captures[index].stringValue : "")
                }
            }
        }
        guard source.contains("{"), let expression = Self.dynamicRuleRegex else {
            return (source, context, captureLiteral)
        }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return (source, context, captureLiteral) }
        let replacementStart = source.range(of: "##")?.lowerBound ?? source.endIndex
        let selectorTemplate = source.hasPrefix("$.") || source.hasPrefix("$[")
        if !selectorTemplate, let first = matches.first,
           first.range.location < NSRange(source.startIndex..<replacementStart, in: source).length {
            captureLiteral = true
        }
        var nextContext = context
        var output = ""
        var cursor = source.startIndex
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: source) else { continue }
            output += source[cursor..<fullRange.lowerBound]
            if match.range(at: 1).location != NSNotFound,
               let keyRange = Range(match.range(at: 1), in: source) {
                let key = String(source[keyRange])
                if key == "bookName", let book = nextContext.book {
                    output += book.name
                } else if key == "title", let chapter = nextContext.chapter {
                    output += chapter.title
                } else {
                    output += try javaScript.variable(key, context: nextContext)
                }
            } else if let scriptRange = Range(match.range(at: 2), in: source) {
                let expression = String(source[scriptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if expression.hasPrefix("@") || expression.hasPrefix("$.") || expression.hasPrefix("$[") || expression.hasPrefix("//") {
                    captureLiteral = true
                    let nested = evaluateValue(expression, input: context.content ?? result, listMode: false, context: nextContext)
                    if let error = nested.diagnostics.first(where: { $0.severity == .error }) {
                        throw RuleEngineError.malformedRule(rule: expression, detail: error.message)
                    }
                    output += nested.strings.joined(separator: "\n")
                    nextContext.variables = nested.variables
                    nextContext.rssArticle = nested.rssArticle ?? nextContext.rssArticle
                } else {
                    let evaluated = try javaScript.evaluate(
                        script: expression,
                        result: result,
                        executionContext: nextContext
                    )
                    output += evaluated.value.stringValue
                    nextContext.variables = evaluated.variables
                    nextContext.rssArticle = evaluated.rssArticle ?? nextContext.rssArticle
                }
            }
            cursor = fullRange.upperBound
        }
        output += source[cursor...]
        return (output, nextContext, captureLiteral)
    }

    private func literalEvaluation(_ source: String, context: RuleExecutionContext) -> RuleEvaluation {
        let components = source.components(separatedBy: "##")
        var value = components.first ?? ""
        if components.count > 1, !components[1].isEmpty {
            value = (try? regex.replacing(
                pattern: components[1],
                in: value,
                with: components.count > 2 ? components[2] : "",
                firstOnly: components.count > 3
            )) ?? value
        }
        return .init(values: [.string(value)], variables: context.variables, rssArticle: context.rssArticle)
    }

    private struct JavaScriptPipeline {
        var prefix: String
        var script: String
        var suffix: String
    }
}
