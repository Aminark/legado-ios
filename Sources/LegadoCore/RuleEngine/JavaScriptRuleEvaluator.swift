import CryptoKit
import CommonCrypto
import Foundation
import JavaScriptCore
import SwiftSoup

public struct RuleExecutionContext: Sendable {
    var nestedRuleDepth = 0
    var replacesEachListItem = false
    var cancellation: RuleExecutionCancellation?

    func checkCancellation() throws {
        try cancellation?.check()
        try Task.checkCancellation()
    }
    public var variables: [String: String]
    public var baseURL: String
    public var key: String?
    public var page: Int?
    public var source: BookSource?
    public var book: Book?
    public var chapter: BookChapter?
    public var rssArticle: RssArticle?
    public var isHTMLFragment: Bool
    public var content: JSONValue?

    public init(
        variables: [String: String] = [:],
        baseURL: String = "",
        key: String? = nil,
        page: Int? = nil,
        source: BookSource? = nil,
        book: Book? = nil,
        chapter: BookChapter? = nil,
        rssArticle: RssArticle? = nil,
        isHTMLFragment: Bool = false,
        content: JSONValue? = nil
    ) {
        self.variables = rssArticle?.variableMap.merging(variables) { _, current in current } ?? variables
        self.baseURL = baseURL
        self.key = key
        self.page = page
        self.source = source
        self.book = book
        self.chapter = chapter
        self.rssArticle = rssArticle
        self.isHTMLFragment = isHTMLFragment
        self.content = content
    }
}

/// Carries cancellation across the synchronous worker and all nested rules.
/// It checks cooperative boundaries; it cannot interrupt a running JS opcode.
final class RuleExecutionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

public struct JavaScriptRuleResult: Sendable {
    public var value: JSONValue
    public var variables: [String: String]
    public var rssArticle: RssArticle? = nil
}

/// JavaScript's synchronous network bridges can block. Keep those calls off
/// Swift's cooperative executor and off shared actors such as the cookie policy.
enum RuleExecutionWorker {
    private static let rulePool = RuleExecutionThreadPool()

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
        try Task.checkCancellation()
        return result
    }

    static func runRule<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { continuation in
            rulePool.submit { continuation.resume(with: Result { try operation() }) }
        }
        try Task.checkCancellation()
        return result
    }

    static func nestedRule<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) throws -> Value {
        if RuleExecutionThreadPool.isCurrentWorker { return try operation() }
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var output: Result<Value, Error>?
        rulePool.submit {
            let result = Result { try operation() }
            lock.withLock { output = result }
            ready.signal()
        }
        ready.wait()
        return try lock.withLock { try output!.get() }
    }
}

/// SwiftSoup and nested JSC calls need more stack than GCD's small default.
/// A fixed pool bounds memory/thread growth; nested calls reuse their worker.
private final class RuleExecutionThreadPool: @unchecked Sendable {
    private static let marker = "Legado.RuleExecutionWorker"
    static var isCurrentWorker: Bool { Thread.current.threadDictionary[marker] as? Bool == true }
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var threads: [Thread] = []

    init() {
        for index in 0..<min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8) {
            let thread = Thread { [self] in
                Thread.current.threadDictionary[Self.marker] = true
                while true {
                    condition.lock()
                    while jobs.isEmpty { condition.wait() }
                    let job = jobs.removeFirst()
                    condition.unlock()
                    autoreleasepool { job() }
                }
            }
            thread.name = "Legado.RuleWorker.\(index)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 8 * 1_024 * 1_024
            threads.append(thread)
            thread.start()
        }
    }

    func submit(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }
}

public protocol JavaScriptNetworkLoading: Sendable {
    func load(_ request: URLRequest) throws -> HTTPResponse
}

public protocol JavaScriptRedirectNetworkLoading: JavaScriptNetworkLoading {
    func load(_ request: URLRequest, followRedirects: Bool) throws -> HTTPResponse
}

public final class SynchronousJavaScriptNetworkLoader: JavaScriptRedirectNetworkLoading, @unchecked Sendable {
    public init() {}

    public func load(_ request: URLRequest) throws -> HTTPResponse {
        try load(request, followRedirects: true)
    }

    public func load(_ original: URLRequest, followRedirects: Bool) throws -> HTTPResponse {
        let settings = ApplicationSettingsStore.shared.settings
        let request = settings.configure(original)
        let address = try ApplicationSettings.parseHosts(settings.hosts)[request.url?.host?.lowercased() ?? ""]
        if followRedirects || (settings.proxy.isEmpty && address != nil) {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            nonisolated(unsafe) var result: Result<HTTPResponse, Error>?
            // The synchronous JS caller waits for this request. Detached tasks
            // otherwise default to medium priority and cause priority inversion
            // during interactive search/source switching.
            let task = Task.detached(priority: Task.currentPriority) {
                let value: Result<HTTPResponse, Error>
                do {
                    let response: HTTPResponse
                    if followRedirects { response = try await URLSessionHTTPTransport.shared.data(for: request) }
                    else { response = try await HostsHTTPTransport.data(for: request, address: address!, ignoreCertificateErrors: settings.ignoreCertificateErrors) }
                    value = .success(response)
                } catch HTTPClientError.statusResponse(let response) { value = .success(response) }
                catch { value = .failure(error) }
                lock.withLock { result = value }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + max(1, request.timeoutInterval) + 1) == .success else {
                task.cancel()
                throw URLError(.timedOut)
            }
            lock.lock(); let value = result; lock.unlock()
            return try value?.get() ?? { throw HTTPClientError.nonHTTPResponse }()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        try settings.configure(configuration)
        let delegate: any URLSessionDelegate = followRedirects ? LegadoUnsafeTrustDelegate.shared : JavaScriptRedirectBlocker()
        let callbackQueue = OperationQueue()
        callbackQueue.qualityOfService = Thread.current.qualityOfService
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: callbackQueue)
        defer { session.finishTasksAndInvalidate() }
        let started = Date()
        do {
            let response = try load(request, session: session)
            DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
            return response
        } catch {
            DiagnosticLog.shared.network(request, error: error, startedAt: started)
            throw error
        }
    }

    private func load(_ request: URLRequest, session: URLSession) throws -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var output: Result<HTTPResponse, Error>?
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<HTTPResponse, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, let url = http.url {
                result = .success(.init(
                    data: data ?? Data(),
                    statusCode: http.statusCode,
                    headers: http.allHeaderFields.reduce(into: [:]) { values, entry in
                        values[String(describing: entry.key)] = String(describing: entry.value)
                    },
                    finalURL: url
                ))
            } else {
                result = .failure(HTTPClientError.nonHTTPResponse)
            }
            lock.lock()
            output = result
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        let timeout = min(max(request.timeoutInterval, 1), 180)
        guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            throw URLError(.timedOut)
        }
        lock.lock()
        let result = output
        lock.unlock()
        return try result?.get() ?? { throw HTTPClientError.nonHTTPResponse }()
    }
}

private final class JavaScriptRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        LegadoUnsafeTrustDelegate.resolution(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct JavaScriptRuleEvaluator: Sendable {
    public var maximumScriptLength: Int
    public var maximumResultLength: Int
    private let networkLoader: any JavaScriptNetworkLoading
    private let urlBuilder: LegadoURLBuilder
    private let rssVariableStore: RSSVariableStore

    public func evaluateAsync(script: String, result: JSONValue, executionContext: RuleExecutionContext) async throws -> JavaScriptRuleResult {
        try await RuleExecutionWorker.run {
            try evaluate(script: script, result: result, executionContext: executionContext)
        }
    }

    public init(
        maximumScriptLength: Int = 64 * 1_024,
        maximumResultLength: Int = 2 * 1_024 * 1_024,
        networkLoader: any JavaScriptNetworkLoading = SynchronousJavaScriptNetworkLoader(),
        urlBuilder: LegadoURLBuilder = .init(),
        rssVariableStore: RSSVariableStore = .shared
    ) {
        self.maximumScriptLength = maximumScriptLength
        self.maximumResultLength = maximumResultLength
        self.networkLoader = networkLoader
        self.urlBuilder = urlBuilder
        self.rssVariableStore = rssVariableStore
    }

    public func evaluate(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext
    ) throws -> JavaScriptRuleResult {
        try evaluate(script: script, result: result, executionContext: executionContext,
                     virtualMachine: JSVirtualMachine(), stringifyResult: false)
    }

    func settingVariable(_ key: String, value: String, context: RuleExecutionContext) throws -> RuleExecutionContext {
        try context.checkCancellation()
        var context = context
        guard var article = context.rssArticle else {
            context.variables[key] = value
            return context
        }
        let box = JSVariableBox(context.variables)
        box.rssState = article.ruleVariableState ?? RSSVariableState(store: rssVariableStore, article: article)
        box.putVariable(key, value)
        try box.rssState?.commit()
        article.variable = String(decoding: try JSONEncoder().encode(box.values), as: UTF8.self)
        article.ruleVariableState = box.rssState
        context.variables = box.values
        context.rssArticle = article
        return context
    }

    func variable(_ key: String, context: RuleExecutionContext) throws -> String {
        try context.checkCancellation()
        if let value = context.variables[key] { return value }
        guard let article = context.rssArticle else { return "" }
        let state = article.ruleVariableState ?? RSSVariableState(store: rssVariableStore, article: article)
        return try state.get(key) ?? ""
    }

    func evaluateBookUpdateAsync(
        script: String, book: Book, source: BookSource, refresher: any BookUpdateJavaScriptRefreshing
    ) async throws -> Book {
        try await RuleExecutionWorker.run {
            let variables = book.variable.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
            let result = try evaluate(
                script: script + "\n;JSON.stringify(book)", result: .null,
                executionContext: .init(variables: variables, baseURL: book.bookUrl, source: source, book: book),
                virtualMachine: JSVirtualMachine(), stringifyResult: false, bookRefresher: refresher
            )
            var updated: Book
            do { updated = try JSONDecoder().decode(Book.self, from: Data(result.value.stringValue.utf8)) }
            catch { throw RuleEngineError.invalidInput(rule: script, expected: "更新前脚本产生了无效书籍字段：\(error.localizedDescription)") }
            updated.variable = result.variables.isEmpty ? nil : String(decoding: try JSONEncoder().encode(result.variables), as: UTF8.self)
            return updated
        }
    }

    /// TOC formatJs runs after deduplication in reading order. Android reuses
    /// its script bindings so gInt and other script globals survive each title.
    func formatChapterTitles(
        script: String,
        chapters: [BookChapter]
    ) async throws -> (chapters: [BookChapter], diagnostics: [RuleDiagnostic]) {
        try await RuleExecutionWorker.run {
            guard script.utf8.count <= maximumScriptLength else {
                throw RuleEngineError.resourceLimit(rule: script, detail: "JavaScript 规则超过长度上限")
            }
            try rejectUnboundedExecution(script)
            guard let context = JSContext() else {
                throw RuleEngineError.invalidInput(rule: script, expected: "无法创建 JavaScriptCore 上下文")
            }
            var exceptionMessage: String?
            var handlingException = false
            context.exceptionHandler = { _, exception in
                guard !handlingException else {
                    exceptionMessage = exceptionMessage ?? "JavaScript 异常（异常对象无法转换为文本）"
                    return
                }
                handlingException = true
                defer { handlingException = false }
                exceptionMessage = exception?.toString() ?? exceptionMessage ?? "未知 JavaScript 异常"
            }
            context.setObject(0, forKeyedSubscript: "gInt" as NSString)
            var formatted = chapters
            var diagnostics: [RuleDiagnostic] = []
            for index in formatted.indices {
                autoreleasepool {
                    exceptionMessage = nil
                    context.exception = nil
                    installChapter(in: context, chapter: formatted[index])
                    context.setObject(index + 1, forKeyedSubscript: "index" as NSString)
                    let value = context.evaluateScript(script)
                    // Rhino unwraps null/undefined to null: keep the old title.
                    let title = value.flatMap { $0.isNull || $0.isUndefined ? nil : $0.toString() }
                    if let exceptionMessage {
                        diagnostics.append(.init(severity: .warning, code: "toc.format",
                            message: "第\(index + 1)项标题处理失败：\(exceptionMessage)", rule: script))
                    } else if let title {
                        if title.utf8.count <= maximumResultLength {
                            formatted[index].title = title
                        } else {
                            diagnostics.append(.init(severity: .warning, code: "toc.format",
                                message: "第\(index + 1)项标题处理结果超过长度上限", rule: script))
                        }
                    }
                }
            }
            return (formatted, diagnostics)
        }
    }

    /// A rule shares java.get/put storage, but each match gets fresh JS globals.
    /// Keep this closure on the synchronous replacement call's thread.
    func replacementEvaluator(script: String, book: Book, chapter: BookChapter) -> (String) throws -> String {
        var virtualMachine: JSVirtualMachine?
        var executionContext = RuleExecutionContext(book: book, chapter: chapter)
        return { match in
            if virtualMachine == nil { virtualMachine = JSVirtualMachine() }
            let result = try autoreleasepool {
                try evaluate(script: script, result: .string(match), executionContext: executionContext,
                             virtualMachine: virtualMachine!, stringifyResult: true)
            }
            executionContext.variables = result.variables
            return result.value.stringValue
        }
    }

    private func evaluate(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext,
        virtualMachine: JSVirtualMachine,
        stringifyResult: Bool,
        bookRefresher: (any BookUpdateJavaScriptRefreshing)? = nil
    ) throws -> JavaScriptRuleResult {
        try executionContext.checkCancellation()
        guard script.utf8.count <= maximumScriptLength else {
            throw RuleEngineError.resourceLimit(rule: script, detail: "JavaScript 规则超过长度上限")
        }
        try rejectUnboundedExecution(script)

        let box = JSVariableBox(executionContext.rssArticle?.variableMap.merging(executionContext.variables) { _, current in current }
            ?? executionContext.variables)
        if let article = executionContext.rssArticle {
            box.rssState = article.ruleVariableState ?? RSSVariableState(store: rssVariableStore, article: article)
        }
        guard let context = JSContext(virtualMachine: virtualMachine) else {
            throw RuleEngineError.invalidInput(rule: script, expected: "无法创建 JavaScriptCore 上下文")
        }
        var exceptionMessage: String?
        var handlingException = false
        context.exceptionHandler = { _, exception in
            guard !handlingException else {
                exceptionMessage = exceptionMessage ?? "JavaScript 异常（异常对象无法转换为文本）"
                return
            }
            handlingException = true
            defer { handlingException = false }
            exceptionMessage = exception?.toString() ?? exceptionMessage ?? "未知 JavaScript 异常"
            DiagnosticLog.shared.record(.error, category: "JS", message: exceptionMessage ?? "未知 JavaScript 异常")
        }
        box.onError = { [weak context] error in
            context?.exception = JSValue(newErrorFromMessage: "RSS 变量存储失败：\(error.localizedDescription)", in: context)
        }
        context.setObject(result.foundationObject, forKeyedSubscript: "result" as NSString)
        context.setObject((executionContext.content ?? result).foundationObject, forKeyedSubscript: "src" as NSString)
        context.setObject(result.foundationObject, forKeyedSubscript: "$" as NSString)
        context.setObject(executionContext.baseURL, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(executionContext.key ?? "", forKeyedSubscript: "key" as NSString)
        context.setObject(executionContext.page ?? 0, forKeyedSubscript: "page" as NSString)
        installJava(in: context, variables: box, result: result, executionContext: executionContext)
        installCookie(in: context)
        installJavaImporterCompatibility(in: context)
        installSource(in: context, source: executionContext.source, variables: box)
        installBook(in: context, book: executionContext.book)
        if let bookRefresher, let book = executionContext.book {
            try installUpdatableBook(in: context, book: book, variables: box, refresher: bookRefresher)
        }
        installChapter(in: context, chapter: executionContext.chapter)
        let articleObject = installRSSArticle(in: context, article: executionContext.rssArticle, variables: box)
        context.evaluateScript("""
            (function () {
              var nativeParse = JSON.parse;
              JSON.parse = function (value) {
                if (typeof value !== 'string') return value;
                var text = value;
                if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
                text = text.trim();
                if (!text || '[{"-0123456789tfn'.indexOf(text.charAt(0)) < 0) return value;
                return nativeParse(text);
              };
            })();
            """)

        if let library = executionContext.source?.jsLib?.trimmingCharacters(in: .whitespacesAndNewlines),
           !library.isEmpty {
            guard library.utf8.count <= maximumScriptLength else {
                throw RuleEngineError.resourceLimit(rule: library, detail: "书源 jsLib 超过长度上限")
            }
            try rejectUnboundedExecution(library)
            context.evaluateScript(library)
            if let exceptionMessage {
                throw RuleEngineError.malformedRule(rule: library, detail: "书源 jsLib 执行失败：\(exceptionMessage)")
            }
        }

        let evaluated = context.evaluateScript(script)
        if let exceptionMessage {
            throw RuleEngineError.malformedRule(rule: script, detail: "JavaScript 执行失败：\(exceptionMessage)")
        }
        // JavaString supplies getBytes() on a boxed JS String. JSC otherwise
        // bridges it as {"0":"第", "1":"一", ...}, corrupting decrypted text.
        let normalized = evaluated.flatMap {
            context.objectForKeyedSubscript("__legadoUnboxString")?.call(withArguments: [$0])
        }
        let value: JSONValue
        if stringifyResult {
            // Rhino unwraps undefined to null before RegexExtensions.kt calls
            // toString(). Preserve strings directly, rather than JSON encoding.
            if let evaluated, !evaluated.isUndefined, !evaluated.isNull {
                let text = evaluated.toString() ?? "null"
                if evaluated.isNumber {
                    // The reference runs Rhino in interpreted mode, yielding JVM Doubles.
                    let number = evaluated.toDouble()
                    value = .string(number.isFinite ? String(number) : text)
                } else {
                    value = .string(text)
                }
            } else {
                value = .string("null")
            }
        } else {
            value = JSONValue.bridge(normalized?.toObject())
        }
        if let exceptionMessage {
            throw RuleEngineError.malformedRule(rule: script, detail: "JavaScript 执行失败：\(exceptionMessage)")
        }
        guard value.stringValue.utf8.count <= maximumResultLength else {
            throw RuleEngineError.resourceLimit(rule: script, detail: "JavaScript 结果超过长度上限")
        }
        if let error = box.error { throw error }
        try executionContext.checkCancellation()
        var article = try updatedRSSArticle(articleObject, original: executionContext.rssArticle, variables: box.values, variableState: box.rssState)
        try executionContext.checkCancellation()
        try box.rssState?.commit()
        article?.ruleVariableState = box.rssState
        return .init(value: value, variables: box.values, rssArticle: article)
    }

    private func installJava(
        in context: JSContext,
        variables: AnyObject,
        result: JSONValue,
        executionContext: RuleExecutionContext
    ) {
        guard let box = variables as? JSVariableBox else { return }
        installJavaBlocks(
            in: context,
            get: { key in
                if key == "bookName", let book = executionContext.book { return book.name }
                if key == "title", let chapter = executionContext.chapter { return chapter.title }
                return box.get(key)
            },
            put: { box.put($0, $1) },
            result: result,
            executionContext: executionContext,
            currentContext: { [weak context] in
                try executionContext.checkCancellation()
                var current = executionContext
                current.variables = box.values
                current.rssArticle = try self.updatedRSSArticle(
                    context?.objectForKeyedSubscript("rssArticle"), original: executionContext.rssArticle,
                    variables: box.values, variableState: box.rssState
                )
                return current
            },
            applyState: { [weak context] values, updatedArticle in
                box.values = values
                guard let article = updatedArticle else { return }
                box.rssState = article.ruleVariableState
                // Keep the same JS object: scripts may hold aliases to it.
                if let object = context?.objectForKeyedSubscript("rssArticle") {
                    self.setRSSArticleFields(article, on: object)
                }
            }
        )
    }

    private func installCookie(in context: JSContext) {
        let object = JSValue(newObjectIn: context)
        let getCookie: @convention(block) (String) -> String = {
            LegadoCookieStore.shared.cookieHeader(for: $0)
        }
        let getKey: @convention(block) (String, String) -> String = {
            LegadoCookieStore.shared.cookie(for: $0, key: $1)
        }
        let setCookie: @convention(block) (String, String?) -> Void = { url, value in
            LegadoCookieStore.shared.setCookie(value ?? "", for: url)
        }
        let removeCookie: @convention(block) (String) -> Void = {
            LegadoCookieStore.shared.removeCookies(for: $0)
        }
        object?.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)
        object?.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        object?.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)
        object?.setObject(setCookie, forKeyedSubscript: "replaceCookie" as NSString)
        object?.setObject(setCookie, forKeyedSubscript: "setWebCookie" as NSString)
        object?.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)
        context.setObject(object, forKeyedSubscript: "cookie" as NSString)
        context.evaluateScript("""
            (function () {
              cookie.cookieToMap = function (header) {
                var map = {};
                String(header || '').split(';').forEach(function (part) {
                  var separator = part.indexOf('=');
                  if (separator <= 0) return;
                  var key = part.slice(0, separator).trim();
                  var value = part.slice(separator + 1).trim();
                  if (value || value === 'null') map[key] = value;
                });
                return map;
              };
              cookie.mapToCookie = function (map) {
                if (!map) return null;
                var values = [];
                for (var key in map) {
                  if (Object.prototype.hasOwnProperty.call(map, key)) {
                    values.push(key + '=' + map[key]);
                  }
                }
                return values.length ? values.join('; ') : null;
              };
            })();
            """)
    }

    private func installJavaImporterCompatibility(in context: JSContext) {
        let utf8Bytes: @convention(block) (String) -> [Int] = { value in
            Data(value.utf8).map { Int(Int8(bitPattern: $0)) }
        }
        let utf8String: @convention(block) (Any?) -> String = { value in
            String(decoding: Self.byteData(from: value), as: UTF8.self)
        }
        let maximumBytes = maximumResultLength
        let aesCBC: @convention(block) (Int, Any?, Any?, Any?) -> [Int]? = { operation, keyValue, ivValue, dataValue in
            let key = Self.byteData(from: keyValue)
            let iv = Self.byteData(from: ivValue)
            let input = Self.byteData(from: dataValue)
            guard [1, 2].contains(operation), [16, 24, 32].contains(key.count),
                  iv.count == kCCBlockSizeAES128, input.count <= maximumBytes else { return nil }
            var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
            let capacity = output.count
            var written = 0
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    input.withUnsafeBytes { inputBytes in
                        CCCrypt(operation == 1 ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inputBytes.baseAddress, input.count, &output, capacity, &written)
                    }
                }
            }
            guard status == kCCSuccess else { return nil }
            return output.prefix(written).map { Int(Int8(bitPattern: $0)) }
        }
        let base64EncodeBytes: @convention(block) (Any?) -> String = { value in
            Self.byteData(from: value).base64EncodedString()
        }
        let base64DecodeBytes: @convention(block) (String) -> [Int] = { value in
            guard let data = Data(base64Encoded: value) else { return [] }
            return data.map { Int(Int8(bitPattern: $0)) }
        }
        let hexEncodeBytes: @convention(block) (Any?) -> String = { value in
            Self.byteData(from: value).map { String(format: "%02X", $0) }.joined()
        }
        let hmacSHA1: @convention(block) (Any?, Any?) -> [Int] = { keyValue, dataValue in
            let key = SymmetricKey(data: Self.byteData(from: keyValue))
            let authentication = HMAC<Insecure.SHA1>.authenticationCode(
                for: Self.byteData(from: dataValue),
                using: key
            )
            return authentication.map { Int(Int8(bitPattern: $0)) }
        }
        let formURLEncode: @convention(block) (String) -> String = { Self.formURLEncode($0) }
        context.setObject(utf8Bytes, forKeyedSubscript: "__legadoUTF8Bytes" as NSString)
        context.setObject(utf8String, forKeyedSubscript: "__legadoUTF8String" as NSString)
        context.setObject(aesCBC, forKeyedSubscript: "__legadoAESCBC" as NSString)
        context.setObject(base64EncodeBytes, forKeyedSubscript: "__legadoBase64EncodeBytes" as NSString)
        context.setObject(base64DecodeBytes, forKeyedSubscript: "__legadoBase64DecodeBytes" as NSString)
        context.setObject(hexEncodeBytes, forKeyedSubscript: "__legadoHexEncodeBytes" as NSString)
        context.setObject(hmacSHA1, forKeyedSubscript: "__legadoHmacSHA1" as NSString)
        context.setObject(formURLEncode, forKeyedSubscript: "__legadoFormURLEncode" as NSString)
        context.evaluateScript(Self.javaImporterBootstrap)
    }

    private func installJavaBlocks(
        in context: JSContext,
        get: @escaping (String) -> String,
        put: @escaping (String, String) -> String,
        result: JSONValue,
        executionContext: RuleExecutionContext,
        currentContext: @escaping () throws -> RuleExecutionContext,
        applyState: @escaping ([String: String], RssArticle?) -> Void
    ) {
        let java = JSValue(newObjectIn: context)
        let getBlock: @convention(block) (String) -> String = { key in get(key) }
        let putBlock: @convention(block) (String, Any?) -> String = { key, value in
            put(key, Self.stringify(value))
        }
        let putVolumeBlock: @convention(block) (Any?) -> String = { value in
            let title = Self.stringify(value)
            var volumes = (try? JSONDecoder().decode([String].self, from: Data(get("__legadoVolumes").utf8))) ?? []
            volumes.append(title)
            if let data = try? JSONEncoder().encode(volumes) {
                _ = put("__legadoVolumes", String(decoding: data, as: UTF8.self))
            }
            return title
        }
        let getRuleBlock: @convention(block) (String, Any?, String, Bool, Bool, Bool) -> [String: Any] = { rule, content, mode, isURL, isFragment, unescape in
            do {
                var current = try currentContext()
                current.isHTMLFragment = isFragment || current.isHTMLFragment
                let input = content.map(JSONValue.bridge) ?? current.content ?? result
                let evaluation = try self.evaluateNestedRule(rule, content: input, mode: mode, executionContext: current)
                let value = self.nestedRuleValue(evaluation, rule: rule, mode: mode, isURL: isURL, unescape: unescape, context: current)
                applyState(evaluation.variables, evaluation.rssArticle)
                return ["value": value.foundationObject]
            } catch {
                return ["error": error.localizedDescription]
            }
        }
        let md5Block: @convention(block) (String) -> String = { value in
            Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let base64Encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let base64Decode: @convention(block) (String) -> String = {
            Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let base64DecodeToByteArray: @convention(block) (String) -> [Int] = {
            guard let data = Data(base64Encoded: $0) else { return [] }
            return data.map { Int(Int8(bitPattern: $0)) }
        }
        let strToBytes: @convention(block) (String) -> [Int] = {
            Array($0.utf8).map { Int(Int8(bitPattern: $0)) }
        }
        let bytesToStr: @convention(block) (Any?) -> String = { value in
            guard let values = value as? [Any] else { return "" }
            let bytes = values.compactMap { item -> UInt8? in
                if let number = item as? NSNumber { return UInt8(truncatingIfNeeded: number.intValue) }
                if let number = Int(Self.stringify(item)) { return UInt8(truncatingIfNeeded: number) }
                return nil
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let hexDecodeToByteArray: @convention(block) (String) -> [Int] = { value in
            Self.hexBytes(value).map { Int(Int8(bitPattern: $0)) }
        }
        let hexDecodeToString: @convention(block) (String) -> String = { value in
            String(decoding: Self.hexBytes(value), as: UTF8.self)
        }
        let hexEncodeToString: @convention(block) (String) -> String = { value in
            Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        }
        let timeFormatUTC: @convention(block) (Double, String, Int) -> String = { milliseconds, format, offset in
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone(secondsFromGMT: offset / 1_000)
            formatter.dateFormat = format
            return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
        }
        let timeFormat: @convention(block) (Double) -> String = { milliseconds in
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
        }
        let randomUUID: @convention(block) () -> String = { UUID().uuidString }
        let deviceID: @convention(block) () -> String = {
            let key = "ios.installation.identifier"
            let stored = BookSourceRuntimeStore.shared.get(sourceID: "__app__", key: key)
            if !stored.isEmpty { return stored }
            let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            BookSourceRuntimeStore.shared.put(sourceID: "__app__", key: key, value: value)
            return value
        }
        let getTag: @convention(block) () -> String = { executionContext.source?.id ?? "" }
        let logValue: @convention(block) (Any?) -> Any? = { value in
            DiagnosticLog.shared.record(category: "JS", message: String(describing: value ?? "null"))
            return value
        }
        context.setObject(logValue, forKeyedSubscript: "__legadoLog" as NSString)
        context.evaluateScript("var console = { log: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); }, warn: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); }, error: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); } };")
        let urlEncode: @convention(block) (String) -> String = {
            Self.formURLEncode($0)
        }
        let getCookieHeader: @convention(block) (String) -> String = {
            LegadoCookieStore.shared.cookieHeader(for: $0)
        }
        let getCookieValue: @convention(block) (String, String) -> String = {
            LegadoCookieStore.shared.cookie(for: $0, key: $1)
        }
        let setCookie: @convention(block) (String, String) -> Void = {
            LegadoCookieStore.shared.setCookie($1, for: $0)
        }
        let ajax: @convention(block) (Any?, Any?) -> String = { value, timeoutValue in
            let rawURL = Self.firstURL(value)
            do {
                let response = try self.loadJavaScriptRequest(
                    rawURL,
                    extraHeaders: [:],
                    timeoutValue: timeoutValue,
                    executionContext: try currentContext()
                )
                applyState(response.requestVariables, response.rssArticle)
                return response.decodedText
            } catch {
                return error.localizedDescription
            }
        }
        let ajaxAll: @convention(block) (Any?, Any?) -> [[String: Any]] = { value, _ in
            let urls: [String]
            if let values = value as? [Any] {
                urls = values.map(Self.stringify)
            } else {
                urls = [Self.stringify(value)]
            }
            return urls.map { rawURL in
                do {
                    let response = try self.loadJavaScriptRequest(
                        rawURL,
                        extraHeaders: [:],
                        timeoutValue: nil,
                        executionContext: try currentContext()
                    )
                    applyState(response.requestVariables, response.rssArticle)
                    return [
                        "url": response.finalURL.absoluteString,
                        "body": response.decodedText,
                        "code": response.statusCode,
                        "headers": response.headers
                    ]
                } catch {
                    return [
                        "url": rawURL,
                        "body": error.localizedDescription,
                        "code": 0,
                        "headers": [:]
                    ]
                }
            }
        }
        let directRequest: @convention(block) (String, String, Any?, Any?, Any?) -> [String: Any] = {
            method, rawURL, body, headers, timeout in
            do {
                let response = try self.loadDirectJavaScriptRequest(
                    method: method,
                    rawURL: rawURL,
                    body: body.map { Self.stringify($0) },
                    headers: Self.headerMap(headers),
                    timeoutValue: timeout,
                    executionContext: try currentContext()
                )
                return [
                    "urlText": response.finalURL.absoluteString,
                    "bodyText": response.decodedText,
                    "code": response.statusCode,
                    "headers": response.headers
                ]
            } catch {
                return ["error": error.localizedDescription]
            }
        }
        let connect: @convention(block) (Any?, Any?, Any?) -> [String: Any] = { value, headerValue, timeoutValue in
            let rawURL = Self.firstURL(value)
            do {
                let response = try self.loadJavaScriptRequest(
                    rawURL,
                    extraHeaders: Self.headerMap(headerValue),
                    timeoutValue: timeoutValue,
                    executionContext: try currentContext()
                )
                applyState(response.requestVariables, response.rssArticle)
                return [
                    "url": response.finalURL.absoluteString,
                    "body": response.decodedText,
                    "code": response.statusCode,
                    "message": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                    "headers": response.headers,
                    "successful": (200 ... 299).contains(response.statusCode),
                    "callTime": 0
                ]
            } catch {
                return [
                    "url": rawURL,
                    "body": error.localizedDescription,
                    "code": 0,
                    "message": error.localizedDescription,
                    "headers": [:],
                    "successful": false,
                    "callTime": 0
                ]
            }
        }
        java?.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        java?.setObject(putBlock, forKeyedSubscript: "put" as NSString)
        java?.setObject(putVolumeBlock, forKeyedSubscript: "putVolume" as NSString)
        java?.setObject(getRuleBlock, forKeyedSubscript: "__getRule" as NSString)
        java?.setObject(md5Block, forKeyedSubscript: "md5Encode" as NSString)
        java?.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)
        java?.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)
        java?.setObject(base64DecodeToByteArray, forKeyedSubscript: "base64DecodeToByteArray" as NSString)
        java?.setObject(strToBytes, forKeyedSubscript: "strToBytes" as NSString)
        java?.setObject(bytesToStr, forKeyedSubscript: "bytesToStr" as NSString)
        java?.setObject(hexDecodeToByteArray, forKeyedSubscript: "hexDecodeToByteArray" as NSString)
        java?.setObject(hexDecodeToString, forKeyedSubscript: "hexDecodeToString" as NSString)
        java?.setObject(hexEncodeToString, forKeyedSubscript: "hexEncodeToString" as NSString)
        java?.setObject(timeFormatUTC, forKeyedSubscript: "timeFormatUTC" as NSString)
        java?.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)
        java?.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)
        java?.setObject(deviceID, forKeyedSubscript: "androidId" as NSString)
        java?.setObject(getTag, forKeyedSubscript: "getTag" as NSString)
        java?.setObject(logValue, forKeyedSubscript: "log" as NSString)
        java?.setObject(logValue, forKeyedSubscript: "logType" as NSString)
        java?.setObject(logValue, forKeyedSubscript: "toast" as NSString)
        java?.setObject(urlEncode, forKeyedSubscript: "encodeURI" as NSString)
        java?.setObject(getCookieHeader, forKeyedSubscript: "getCookieHeader" as NSString)
        java?.setObject(getCookieValue, forKeyedSubscript: "__getCookieValue" as NSString)
        java?.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)
        java?.setObject(ajax, forKeyedSubscript: "ajax" as NSString)
        java?.setObject(ajaxAll, forKeyedSubscript: "ajaxAll" as NSString)
        java?.setObject(connect, forKeyedSubscript: "connect" as NSString)
        java?.setObject(directRequest, forKeyedSubscript: "__directRequest" as NSString)
        context.setObject(java, forKeyedSubscript: "java" as NSString)
        context.evaluateScript("""
            (function () {
              var getVariable = java.get;
              function responseOf(raw) {
                if (raw.error) throw new Error(raw.error);
                return {
                  statusCode: function () { return raw.code; },
                  body: function () { return raw.bodyText; },
                  header: function (name) {
                    var wanted = String(name).toLowerCase();
                    for (var key in raw.headers) if (key.toLowerCase() === wanted) return raw.headers[key];
                    return null;
                  },
                  headers: function () { return raw.headers; },
                  url: function () { return { toString: function () { return raw.urlText; } }; }
                };
              }
              java.get = function (url, headers, timeout) {
                var target = String(url);
                var networkURL = /^(https?:|data:)/i.test(target) || target[0] === '/' ||
                  target.indexOf('./') === 0 || target.indexOf('../') === 0;
                if (arguments.length === 1 && !networkURL) {
                  return getVariable(target);
                }
                return responseOf(java.__directRequest('GET', target, null, headers || {}, timeout));
              };
              function extractRule(rule, content, mode, isUrl, unescape) {
                var fragment = content && typeof content === 'object' && typeof content.__legadoHTML === 'string';
                var response = java.__getRule(String(rule == null ? '' : rule), fragment ? content.__legadoHTML : content == null ? src : content,
                  mode, Boolean(isUrl), Boolean(fragment), unescape !== false);
                if (response.error) throw new Error(response.error);
                return response.value;
              }
              function listOf(values) {
                if (!Array.isArray(values)) return values;
                Object.defineProperties(values, {
                  get: {value: function (index) { return this[index]; }},
                  size: {value: function () { return this.length; }},
                  isEmpty: {value: function () { return this.length === 0; }}
                });
                return values;
              }
              function elementOf(value) {
                if (Array.isArray(value)) return listOf(value.map(elementOf));
                if (typeof value !== 'string' || !/^\\s*</.test(value)) return value;
                // HTML fragments come from the real HTML parser. Keep them
                // usable as explicit content for subsequent nested rules.
                return {
                  __legadoHTML: value,
                  toString: function () { return this.__legadoHTML; },
                  outerHtml: function () { return this.__legadoHTML; },
                  text: function () { return extractRule('@CSS:@text', this, 'string', false); },
                  ownText: function () { return extractRule('@CSS:@ownText', this, 'string', false); },
                  attr: function (name) { return extractRule('@CSS:@' + String(name), this, 'string', false); },
                  select: function (rule) { return elementOf(extractRule('@CSS:' + rule, this, 'elements', false)); }
                };
              }
              java.getString = function (rule, content, isUrl) {
                if (arguments.length === 2 && typeof content === 'boolean') return extractRule(rule, null, 'string', false, content);
                return extractRule(rule, content, 'string', isUrl);
              };
              java.getStringList = function (rule, content, isUrl) { return listOf(extractRule(rule, content, 'strings', isUrl)); };
              java.getElement = function (rule, content) { return elementOf(extractRule(rule, content, 'element', false)); };
              java.getElements = function (rule, content) { return elementOf(extractRule(rule, content, 'elements', false)); };
              java.head = function (url, headers, timeout) {
                return responseOf(java.__directRequest('HEAD', String(url), null, headers || {}, timeout));
              };
              java.post = function (url, body, headers, timeout) {
                return responseOf(java.__directRequest('POST', String(url), body, headers || {}, timeout));
              };
              java.getCookie = function (tag, key) {
                return arguments.length < 2 || key == null
                  ? java.getCookieHeader(String(tag))
                  : java.__getCookieValue(String(tag), String(key));
              };
              java.getSource = function () { return typeof source === 'undefined' ? null : source; };
              java.getWebViewUA = function () { return '\(LegadoURLBuilder.defaultUserAgent)'; };
              java.getHeaderMap = function () {
                var map = typeof source === 'undefined' ? {} : source.getHeaderMap(true);
                map.put = function (key, value) { map[String(key)] = String(value); return value; };
                map.putAll = function (other) { for (var key in other) if (typeof other[key] !== 'function') map[key] = other[key]; };
                return map;
              };
              java.ajaxTestAll = function (urls, timeout) {
                return java.ajaxAll(urls, timeout).map(function (raw) {
                  var bodyText = raw.body;
                  raw.callTime = function () { return raw.code >= 200 && raw.code < 300 ? 0 : -1; };
                  raw.body = function () { return bodyText; };
                  return raw;
                });
              };
              java.clearTtsCache = function () { return true; };
            })();
            """)
    }

    private func loadDirectJavaScriptRequest(
        method: String,
        rawURL: String,
        body: String?,
        headers: [String: String],
        timeoutValue: Any?,
        executionContext: RuleExecutionContext
    ) throws -> HTTPResponse {
        let baseText = executionContext.baseURL.isEmpty
            ? executionContext.source?.bookSourceUrl ?? ""
            : executionContext.baseURL
        let baseURL = URL(string: baseText)
        guard let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw RuleEngineError.invalidInput(rule: rawURL, expected: "java.get/head/post URL")
        }
        let milliseconds = Self.number(timeoutValue) ?? 30_000
        var request = URLRequest(url: url, timeoutInterval: min(max(milliseconds / 1_000, 1), 180))
        request.httpMethod = method.uppercased()
        request.httpShouldHandleCookies = executionContext.source?.enabledCookieJar == true
        var requestHeaders = try executionContext.source.map { try BookSourceHeaderResolver().resolve($0) } ?? [:]
        requestHeaders.merge(headers) { _, explicit in explicit }
        if !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            requestHeaders["User-Agent"] = ApplicationSettingsStore.shared.settings.effectiveUserAgent
        }
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if method.caseInsensitiveCompare("POST") == .orderedSame {
            request.httpBody = Data((body ?? "").utf8)
        }
        if executionContext.source?.enabledCookieJar == true {
            let stored = LegadoCookieStore.shared.cookieHeader(for: rawURL)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = Self.mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }
        let response: HTTPResponse
        if let redirectLoader = networkLoader as? any JavaScriptRedirectNetworkLoading {
            response = try redirectLoader.load(request, followRedirects: false)
        } else {
            response = try networkLoader.load(request)
        }
        if let cookie = response.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value {
            LegadoCookieStore.shared.setCookie(cookie, for: response.finalURL.absoluteString)
        }
        return response
    }

    private func loadJavaScriptRequest(
        _ rawURL: String,
        extraHeaders: [String: String],
        timeoutValue: Any?,
        executionContext: RuleExecutionContext
    ) throws -> HTTPResponse {
        try executionContext.checkCancellation()
        guard !rawURL.isEmpty else {
            throw RuleEngineError.invalidInput(rule: rawURL, expected: "java.ajax/connect URL")
        }
        let source = executionContext.source
        var headers = try source.map { try BookSourceHeaderResolver().resolve($0) } ?? [:]
        headers.merge(extraHeaders) { _, extra in extra }
        let base = URL(string: executionContext.baseURL.isEmpty ? source?.bookSourceUrl ?? "" : executionContext.baseURL)
        var requestBuilder = urlBuilder
        requestBuilder.rssVariableStore = rssVariableStore
        var requestContext = URLTemplateContext(
            key: executionContext.key, page: executionContext.page, variables: executionContext.variables,
            source: source, book: executionContext.book, chapter: executionContext.chapter, rssArticle: executionContext.rssArticle
        )
        requestContext.cancellation = executionContext.cancellation
        requestContext.nestedRuleDepth = executionContext.nestedRuleDepth
        let prepared = try requestBuilder.prepare(rawURL, context: requestContext, baseURL: base, defaultHeaders: headers)
        if prepared.useWebView {
            throw RuleEngineError.unsupportedRule(rule: rawURL, feature: "JS 内 WKWebView 请求")
        }
        let milliseconds = Self.number(timeoutValue)
        let timeout = milliseconds.map { min(max($0 / 1_000, 1), 180) }
            ?? min(max(Double(source?.respondTime ?? 30_000) / 1_000, 5), 180)
        var request = prepared.urlRequest(timeout: timeout, handleCookies: source?.enabledCookieJar == true)
        if source?.enabledCookieJar == true {
            let stored = LegadoCookieStore.shared.cookieHeader(for: prepared.url.absoluteString)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = Self.mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }
        let retryCount = max(prepared.retry, 0)
        let attempts = retryCount == Int.max ? Int.max : retryCount + 1
        var lastError: Error = HTTPClientError.nonHTTPResponse
        for attempt in 0..<attempts {
            try executionContext.checkCancellation()
            do {
                var response = try networkLoader.load(request)
                try executionContext.checkCancellation()
                response.requestedCharset = prepared.charset
                response.requestVariables = prepared.variables
                response.rssArticle = prepared.rssArticle
                if let cookie = response.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value {
                    LegadoCookieStore.shared.setCookie(cookie, for: response.finalURL.absoluteString)
                }
                guard (200 ... 299).contains(response.statusCode) else {
                    throw HTTPClientError.statusResponse(response)
                }
                if prepared.responseType != nil {
                    response.data = Data(response.data.map { String(format: "%02x", $0) }.joined().utf8)
                    response.requestedCharset = "utf-8"
                } else if let bodyScript = prepared.bodyJavaScript {
                    var bodyContext = executionContext
                    bodyContext.variables = prepared.variables
                    bodyContext.baseURL = response.finalURL.absoluteString
                    bodyContext.rssArticle = prepared.rssArticle
                    let transformed = try JavaScriptRuleEvaluator(
                        maximumScriptLength: maximumScriptLength,
                        maximumResultLength: maximumResultLength,
                        networkLoader: networkLoader,
                        urlBuilder: requestBuilder,
                        rssVariableStore: rssVariableStore
                    ).evaluate(
                        script: bodyScript,
                        result: .string(response.decodedText),
                        executionContext: bodyContext
                    )
                    response.data = Data(transformed.value.stringValue.utf8)
                    response.requestedCharset = "utf-8"
                    response.requestVariables = transformed.variables
                    response.rssArticle = transformed.rssArticle
                }
                return response
            } catch {
                lastError = error
                guard case HTTPClientError.statusResponse = error, attempt + 1 < attempts else {
                    throw error
                }
            }
        }
        throw lastError
    }

    private func installSource(in context: JSContext, source: BookSource?, variables: AnyObject) {
        guard variables is VariableBoxProxy else { return }
        let sourceID = source?.bookSourceUrl ?? ""
        let object = JSValue(newObjectIn: context)
        let get: @convention(block) (String) -> String = { key in
            BookSourceRuntimeStore.shared.get(sourceID: sourceID, key: key)
        }
        let put: @convention(block) (String, Any?) -> String = { key, value in
            let text = Self.stringify(value)
            BookSourceRuntimeStore.shared.put(sourceID: sourceID, key: key, value: text)
            return text
        }
        let getLoginHeader: @convention(block) () -> Any? = {
            let value = BookSourceRuntimeStore.shared.get(sourceID: sourceID, key: "loginHeader")
            return value.isEmpty ? nil : value
        }
        let putLoginHeader: @convention(block) (Any?) -> String = {
            let value = Self.stringify($0)
            BookSourceRuntimeStore.shared.put(sourceID: sourceID, key: "loginHeader", value: value)
            return value
        }
        let getLoginInfo: @convention(block) () -> [String: Any] = {
            let value = BookSourceRuntimeStore.shared.get(sourceID: sourceID, key: "loginInfo")
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        let putLoginInfo: @convention(block) (Any?) -> String = {
            let value = Self.stringify($0)
            BookSourceRuntimeStore.shared.put(sourceID: sourceID, key: "loginInfo", value: value)
            return value
        }
        let getHeaderMap: @convention(block) (Bool) -> [String: String] = { includeLogin in
            var headers: [String: String] = [:]
            if let raw = source?.header?.trimmingCharacters(in: .whitespacesAndNewlines),
               raw.hasPrefix("{"),
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                headers = object.mapValues { Self.stringify($0) }
            }
            if includeLogin {
                headers.merge(BookSourceRuntimeStore.shared.loginHeaders(sourceID: sourceID)) { _, login in login }
            }
            return headers
        }
        object?.setObject(get, forKeyedSubscript: "get" as NSString)
        object?.setObject(put, forKeyedSubscript: "put" as NSString)
        object?.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)
        object?.setObject(putLoginHeader, forKeyedSubscript: "putLoginHeader" as NSString)
        object?.setObject(getLoginInfo, forKeyedSubscript: "__getLoginInfoMap" as NSString)
        object?.setObject(putLoginInfo, forKeyedSubscript: "putLoginInfo" as NSString)
        object?.setObject(getHeaderMap, forKeyedSubscript: "getHeaderMap" as NSString)
        object?.setObject(source?.bookSourceName ?? "", forKeyedSubscript: "bookSourceName" as NSString)
        object?.setObject(source?.bookSourceUrl ?? "", forKeyedSubscript: "bookSourceUrl" as NSString)
        object?.setObject(source?.bookSourceGroup ?? "", forKeyedSubscript: "bookSourceGroup" as NSString)
        object?.setObject(source?.bookSourceType ?? 0, forKeyedSubscript: "bookSourceType" as NSString)
        object?.setObject(source?.bookUrlPattern ?? "", forKeyedSubscript: "bookUrlPattern" as NSString)
        object?.setObject(source?.customOrder ?? 0, forKeyedSubscript: "customOrder" as NSString)
        object?.setObject(source?.enabled ?? false, forKeyedSubscript: "enabled" as NSString)
        object?.setObject(source?.enabledExplore ?? false, forKeyedSubscript: "enabledExplore" as NSString)
        object?.setObject(source?.header ?? "", forKeyedSubscript: "header" as NSString)
        object?.setObject(source?.loginUrl ?? "", forKeyedSubscript: "loginUrl" as NSString)
        object?.setObject(source?.searchUrl ?? "", forKeyedSubscript: "searchUrl" as NSString)
        object?.setObject(source?.exploreUrl ?? "", forKeyedSubscript: "exploreUrl" as NSString)
        object?.setObject(source?.respondTime ?? 0, forKeyedSubscript: "respondTime" as NSString)
        object?.setObject(source?.weight ?? 0, forKeyedSubscript: "weight" as NSString)
        context.setObject(object, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("""
            (function () {
              source.getKey = function () { return source.bookSourceUrl; };
              source.getTag = function () { return source.bookSourceName; };
              source.getLoginInfoMap = function () {
                var map = source.__getLoginInfoMap() || {};
                map.get = function (key) { return map[String(key)]; };
                map.put = function (key, value) { map[String(key)] = value; return value; };
                map.putAll = function (other) { for (var key in other) if (typeof other[key] !== 'function') map[key] = other[key]; };
                return map;
              };
              source.login = function () {
                if (!source.loginUrl) return null;
                (0, eval)(String(source.loginUrl));
                return typeof login === 'function' ? login() : null;
              };
            })();
            """)
    }

    private func installBook(in context: JSContext, book: Book?) {
        let object = JSValue(newObjectIn: context)
        let getName: @convention(block) () -> String = { book?.name ?? "" }
        let getAuthor: @convention(block) () -> String = { book?.author ?? "" }
        let getBookURL: @convention(block) () -> String = { book?.bookUrl ?? "" }
        let getCoverURL: @convention(block) () -> String = { book?.coverUrl ?? "" }
        let getTotal: @convention(block) () -> Int = { book?.totalChapterNum ?? 0 }
        object?.setObject(getName, forKeyedSubscript: "getName" as NSString)
        object?.setObject(getAuthor, forKeyedSubscript: "getAuthor" as NSString)
        object?.setObject(getBookURL, forKeyedSubscript: "getBookUrl" as NSString)
        object?.setObject(getCoverURL, forKeyedSubscript: "getCoverUrl" as NSString)
        object?.setObject(getTotal, forKeyedSubscript: "getTotalChapterNum" as NSString)
        object?.setObject(book?.name ?? "", forKeyedSubscript: "name" as NSString)
        object?.setObject(book?.author ?? "", forKeyedSubscript: "author" as NSString)
        object?.setObject(book?.bookUrl ?? "", forKeyedSubscript: "bookUrl" as NSString)
        object?.setObject(book?.tocUrl ?? "", forKeyedSubscript: "tocUrl" as NSString)
        object?.setObject(book?.origin ?? "", forKeyedSubscript: "origin" as NSString)
        object?.setObject(book?.originName ?? "", forKeyedSubscript: "originName" as NSString)
        object?.setObject(book?.kind ?? "", forKeyedSubscript: "kind" as NSString)
        object?.setObject(book?.coverUrl ?? "", forKeyedSubscript: "coverUrl" as NSString)
        object?.setObject(book?.intro ?? "", forKeyedSubscript: "intro" as NSString)
        object?.setObject(book?.type ?? 0, forKeyedSubscript: "type" as NSString)
        object?.setObject(book?.group ?? 0, forKeyedSubscript: "group" as NSString)
        object?.setObject(book?.latestChapterTitle ?? "", forKeyedSubscript: "latestChapterTitle" as NSString)
        object?.setObject(book?.totalChapterNum ?? 0, forKeyedSubscript: "totalChapterNum" as NSString)
        object?.setObject(book?.durChapterIndex ?? 0, forKeyedSubscript: "durChapterIndex" as NSString)
        object?.setObject(book?.durChapterTitle ?? "", forKeyedSubscript: "durChapterTitle" as NSString)
        object?.setObject(book?.durChapterPos ?? 0, forKeyedSubscript: "durChapterPos" as NSString)
        object?.setObject(book?.wordCount ?? "", forKeyedSubscript: "wordCount" as NSString)
        object?.setObject(book?.variable ?? "", forKeyedSubscript: "variable" as NSString)
        context.setObject(object, forKeyedSubscript: "book" as NSString)
    }

    private func installUpdatableBook(
        in context: JSContext, book: Book, variables: JSVariableBox, refresher: any BookUpdateJavaScriptRefreshing
    ) throws {
        let data = try JSONEncoder().encode(book)
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuleEngineError.invalidInput(rule: "preUpdateJs", expected: "书籍字段")
        }
        // Codable omits nil fields; the native Android book still has their
        // getters/setters, so expose those properties as null as well.
        for key in ["kind", "customTag", "coverUrl", "customCoverUrl", "intro", "customIntro", "charset",
                    "latestChapterTitle", "durChapterTitle", "wordCount", "variable", "readConfig"] where fields[key] == nil {
            fields[key] = NSNull()
        }
        context.setObject(fields, forKeyedSubscript: "book" as NSString)
        let object = context.objectForKeyedSubscript("book")
        let get: @convention(block) (String) -> String = { variables.get($0) }
        let put: @convention(block) (String, Any?) -> Bool = { key, value in
            if value == nil || value is NSNull { variables.values.removeValue(forKey: key) }
            else { variables.values[key] = Self.stringify(value) }
            return true
        }
        let snapshot: @convention(block) () -> [String: String] = { variables.values }
        let replace: @convention(block) (String?) -> Void = { raw in
            variables.values = raw.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        }
        let refresh: @convention(block) (String, Bool) -> String? = { [weak context] raw, research in
            do {
                guard raw.utf8.count <= self.maximumResultLength else {
                    throw RuleEngineError.resourceLimit(rule: "preUpdateJs", detail: "书籍字段超过长度上限")
                }
                let current = try JSONDecoder().decode(Book.self, from: Data(raw.utf8))
                let updated = try refresher.refreshBook(current, research: research)
                variables.values = updated.variable.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
                return String(decoding: try JSONEncoder().encode(updated), as: UTF8.self)
            } catch {
                context?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                return nil
            }
        }
        object?.setObject(get, forKeyedSubscript: "__getVariable" as NSString)
        object?.setObject(put, forKeyedSubscript: "putVariable" as NSString)
        object?.setObject(snapshot, forKeyedSubscript: "__variables" as NSString)
        object?.setObject(replace, forKeyedSubscript: "__replaceVariables" as NSString)
        context.setObject(refresh, forKeyedSubscript: "__legadoRefreshBook" as NSString)
        context.evaluateScript("""
            (function (current) {
              Object.keys(current).forEach(function (key) {
                if (typeof current[key] === 'function') return;
                var suffix = key.charAt(0).toUpperCase() + key.slice(1);
                current['get' + suffix] = function () { return current[key]; };
                current['set' + suffix] = function (value) { current[key] = value; };
              });
              Object.defineProperty(current, 'variable', {
                enumerable: true, configurable: true,
                get: function () { return JSON.stringify(current.__variables()); },
                set: function (value) { current.__replaceVariables(value); }
              });
              current.getVariable = function (key) { return arguments.length ? current.__getVariable(String(key)) : current.variable; };
              current.setVariable = function (value) { current.variable = value; };
              var methods = {
                get: function (key) { var values = current.__variables(); return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : null; },
                put: function (key, value) { var old = methods.get(key); current.putVariable(String(key), value); return old; },
                remove: function (key) { var old = methods.get(key); current.putVariable(String(key), null); return old; },
                containsKey: function (key) { return Object.prototype.hasOwnProperty.call(current.__variables(), key); },
                size: function () { return Object.keys(current.__variables()).length; },
                isEmpty: function () { return methods.size() === 0; },
                clear: function () { current.variable = '{}'; },
                keySet: function () { return Object.keys(current.__variables()); },
                values: function () { var values = current.__variables(); return Object.keys(values).map(function (key) { return values[key]; }); },
                putAll: function (other) { Object.keys(other).forEach(function (key) { current.putVariable(key, other[key]); }); }
              };
              var map = new Proxy({}, {
                get: function (_, key) { return Object.prototype.hasOwnProperty.call(methods, key) ? methods[key] : methods.get(key); },
                set: function (_, key, value) { current.putVariable(String(key), value); return true; },
                deleteProperty: function (_, key) { current.putVariable(String(key), null); return true; },
                ownKeys: function () { return Object.keys(current.__variables()); },
                getOwnPropertyDescriptor: function () { return {enumerable: true, configurable: true}; }
              });
              Object.defineProperty(current, 'variableMap', { get: function () { return map; } });
              current.getVariableMap = function () { return map; };
              function refresh(research) {
                var updated = JSON.parse(__legadoRefreshBook(JSON.stringify(current), research));
                Object.keys(current).forEach(function (key) {
                  if (typeof current[key] !== 'function' && !Object.prototype.hasOwnProperty.call(updated, key)) current[key] = null;
                });
                Object.keys(updated).forEach(function (key) { current[key] = updated[key]; });
              }
              java.refreshTocUrl = function () { refresh(false); };
              java.reGetBook = function () { refresh(true); };
            })(book);
            """)
    }

    private func installRSSArticle(in context: JSContext, article: RssArticle?, variables: JSVariableBox) -> JSValue? {
        guard let article else {
            context.setObject(NSNull(), forKeyedSubscript: "rssArticle" as NSString)
            return nil
        }
        let object = JSValue(newObjectIn: context)
        if let object { setRSSArticleFields(article, on: object) }
        let get: @convention(block) (String) -> String = { variables.get($0) }
        let put: @convention(block) (String, Any?) -> Bool = { key, value in
            variables.putVariable(key, value == nil || value is NSNull ? nil : Self.stringify(value))
            return true
        }
        let getBig: @convention(block) (String) -> String? = { variables.getBig($0) }
        let putBig: @convention(block) (String, Any?) -> Void = { key, value in
            variables.rssState?.put(key, value == nil || value is NSNull ? nil : Self.stringify(value))
        }
        let putMap: @convention(block) (String, Any?) -> Void = { key, value in
            variables.values[key] = value == nil || value is NSNull ? nil : Self.stringify(value)
        }
        let snapshot: @convention(block) () -> [String: String] = { variables.values }
        let replace: @convention(block) (Any?) -> Void = { value in
            let raw = Self.stringify(value)
            var updated = RssArticle()
            updated.variable = raw
            variables.values = updated.variableMap
        }
        object?.setObject(get, forKeyedSubscript: "__getVariable" as NSString)
        object?.setObject(put, forKeyedSubscript: "putVariable" as NSString)
        object?.setObject(getBig, forKeyedSubscript: "__getBigVariable" as NSString)
        object?.setObject(putBig, forKeyedSubscript: "putBigVariable" as NSString)
        object?.setObject(putMap, forKeyedSubscript: "__putMap" as NSString)
        object?.setObject(snapshot, forKeyedSubscript: "__variables" as NSString)
        object?.setObject(replace, forKeyedSubscript: "__replaceVariables" as NSString)
        context.setObject(object, forKeyedSubscript: "rssArticle" as NSString)
        context.evaluateScript(rssArticleBridgeScript)
        return object
    }

    private func setRSSArticleFields(_ article: RssArticle, on object: JSValue) {
        let fields: [String: Any] = [
            "origin": article.origin, "sort": article.sort, "title": article.title,
            "order": article.order, "link": article.link, "pubDate": article.pubDate as Any? ?? NSNull(),
            "description": article.description as Any? ?? NSNull(), "content": article.content as Any? ?? NSNull(),
            "image": article.image as Any? ?? NSNull(), "group": article.group,
            "read": article.read, "type": article.type, "durPos": article.durPos
        ]
        for (key, value) in fields { object.setObject(value, forKeyedSubscript: key as NSString) }
    }

    private var rssArticleBridgeScript: String {
        """
            (function (article) {
              Object.keys(article).forEach(function (key) {
                if (typeof article[key] === 'function') return;
                var suffix = key.charAt(0).toUpperCase() + key.slice(1);
                article['get' + suffix] = function () { return article[key]; };
                article['set' + suffix] = function (value) { article[key] = value; };
              });
              Object.defineProperty(article, 'variable', {
                enumerable: true,
                get: function () { return JSON.stringify(article.__variables()); },
                set: function (value) { article.__replaceVariables(value); }
              });
              article.getVariable = function (key) {
                return arguments.length ? article.__getVariable(String(key)) : article.variable;
              };
              article.getBigVariable = function (key) {
                // JSC bridges a nil String? block result as undefined; Kotlin
                // exposes null, which scripts commonly compare strictly.
                var value = article.__getBigVariable(String(key));
                return value == null ? null : value;
              };
              article.setVariable = function (value) { article.variable = value; };
              var methods = {
                get: function (key) { var values = article.__variables(); return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : null; },
                put: function (key, value) { var old = methods.get(key); article.__putMap(String(key), value); return old; },
                remove: function (key) { var old = methods.get(key); article.__putMap(String(key), null); return old; },
                containsKey: function (key) { return Object.prototype.hasOwnProperty.call(article.__variables(), key); },
                size: function () { return Object.keys(article.__variables()).length; },
                isEmpty: function () { return methods.size() === 0; },
                clear: function () { article.__replaceVariables('{}'); },
                putAll: function (other) { Object.keys(other).forEach(function (key) { article.__putMap(key, other[key]); }); },
                keySet: function () { return Object.keys(article.__variables()); },
                values: function () { var values = article.__variables(); return Object.keys(values).map(function (key) { return values[key]; }); }
              };
              var map = new Proxy({}, {
                get: function (_, key) { return Object.prototype.hasOwnProperty.call(methods, key) ? methods[key] : methods.get(key); },
                set: function (_, key, value) { article.__putMap(String(key), value); return true; },
                deleteProperty: function (_, key) { article.__putMap(String(key), null); return true; },
                ownKeys: function () { return Object.keys(article.__variables()); },
                getOwnPropertyDescriptor: function () { return {enumerable: true, configurable: true}; }
              });
              Object.defineProperty(article, 'variableMap', { get: function () { return map; } });
              article.getVariableMap = function () { return map; };
            })(rssArticle);
            """
    }

    private func updatedRSSArticle(_ object: JSValue?, original: RssArticle?, variables: [String: String], variableState: RSSVariableState?) throws -> RssArticle? {
        guard let object, let original else { return nil }
        let fields = ["origin", "sort", "title", "order", "link", "pubDate", "description", "content", "image", "group", "read", "type", "durPos"]
        var values: [String: JSONValue] = [:]
        for field in fields { values[field] = JSONValue.bridge(object.forProperty(field)?.toObject()) }
        var article = try JSONDecoder().decode(RssArticle.self, from: JSONEncoder().encode(JSONValue.object(values)))
        article.variable = variables.isEmpty && original.variable == nil
            ? nil : String(decoding: try JSONEncoder().encode(variables), as: UTF8.self)
        article.ruleVariableState = variableState
        return article
    }

    private func installChapter(in context: JSContext, chapter: BookChapter?) {
        let object = JSValue(newObjectIn: context)
        let getTitle: @convention(block) () -> String = { chapter?.title ?? "" }
        let getIndex: @convention(block) () -> Int = { chapter?.index ?? 0 }
        let getURL: @convention(block) () -> String = { chapter?.url ?? "" }
        object?.setObject(getTitle, forKeyedSubscript: "getTitle" as NSString)
        object?.setObject(getIndex, forKeyedSubscript: "getIndex" as NSString)
        object?.setObject(getURL, forKeyedSubscript: "getUrl" as NSString)
        object?.setObject(chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
        object?.setObject(chapter?.index ?? 0, forKeyedSubscript: "index" as NSString)
        object?.setObject(chapter?.url ?? "", forKeyedSubscript: "url" as NSString)
        object?.setObject(chapter?.baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        object?.setObject(chapter?.bookUrl ?? "", forKeyedSubscript: "bookUrl" as NSString)
        object?.setObject(chapter?.isVolume ?? false, forKeyedSubscript: "isVolume" as NSString)
        object?.setObject(chapter?.isVip ?? false, forKeyedSubscript: "isVip" as NSString)
        object?.setObject(chapter?.isPay ?? false, forKeyedSubscript: "isPay" as NSString)
        object?.setObject(chapter?.resourceUrl ?? "", forKeyedSubscript: "resourceUrl" as NSString)
        object?.setObject(chapter?.tag ?? "", forKeyedSubscript: "tag" as NSString)
        object?.setObject(chapter?.wordCount ?? "", forKeyedSubscript: "wordCount" as NSString)
        object?.setObject(chapter?.variable ?? "", forKeyedSubscript: "variable" as NSString)
        context.setObject(object, forKeyedSubscript: "chapter" as NSString)
        context.setObject(chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
    }

    private func evaluateNestedRule(
        _ rule: String, content: JSONValue, mode: String, executionContext: RuleExecutionContext
    ) throws -> RuleEvaluation {
        try RuleExecutionWorker.nestedRule {
            try evaluateNestedRuleOnWorker(rule, content: content, mode: mode, executionContext: executionContext)
        }
    }

    private func evaluateNestedRuleOnWorker(
        _ rule: String, content: JSONValue, mode: String, executionContext: RuleExecutionContext
    ) throws -> RuleEvaluation {
        try executionContext.checkCancellation()
        guard executionContext.nestedRuleDepth < 16 else {
            throw RuleEngineError.resourceLimit(rule: rule, detail: "嵌套规则超过深度上限")
        }
        var execution = executionContext
        execution.nestedRuleDepth += 1
        execution.replacesEachListItem = mode == "strings"
        let wasDeferred = execution.rssArticle?.ruleVariableState?.defersCommit ?? false
        execution.rssArticle?.ruleVariableState?.defersCommit = true
        let listMode = mode == "element" || mode == "elements"
        let evaluation: RuleEvaluation
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evaluation = .init(variables: execution.variables, rssArticle: execution.rssArticle)
        } else if case .object(let object) = content, let direct = object[rule] {
            evaluation = .init(values: [direct], variables: execution.variables, rssArticle: execution.rssArticle)
        } else {
            let engine = RuleEngine(javaScript: self)
            if case .string(let text) = content {
                evaluation = engine.evaluateSynchronously(rule, inText: text, baseURL: execution.baseURL, listMode: listMode, context: execution)
            } else {
                evaluation = engine.evaluateSynchronously(rule, in: content, listMode: listMode, context: execution)
            }
        }
        if let error = evaluation.diagnostics.first(where: { $0.severity == .error }) {
            throw RuleEngineError.malformedRule(rule: rule, detail: error.message)
        }
        var completed = evaluation
        completed.rssArticle?.ruleVariableState?.defersCommit = wasDeferred
        return completed
    }

    private func nestedRuleValue(
        _ evaluation: RuleEvaluation, rule: String, mode: String, isURL: Bool, unescape: Bool, context: RuleExecutionContext
    ) -> JSONValue {
        switch mode {
        case "strings":
            guard !rule.isEmpty else { return .null }
            if evaluation.values == [.null] { return .null }
            let strings: [String]
            if evaluation.values.count == 1, case .string(let value) = evaluation.values[0] {
                strings = value.components(separatedBy: "\n")
            } else { strings = evaluation.strings }
            if !isURL { return .array(strings.map(JSONValue.string)) }
            var seen = Set<String>()
            return .array(strings.compactMap {
                let url = resolveJavaScriptRuleURL($0, enabled: true, context: context)
                return !url.isEmpty && seen.insert(url).inserted ? .string(url) : nil
            })
        case "element":
            guard let first = evaluation.values.first else { return .null }
            if case .string(let value) = first, value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                return .array(evaluation.listItems(rule: rule))
            }
            return first
        case "elements": return .array(evaluation.listItems(rule: rule))
        default:
            guard !rule.isEmpty else { return .string("") }
            var value = evaluation.strings.joined(separator: "\n")
            if unescape, value.contains("&") { value = (try? Parser.unescapeEntities(value, false)) ?? value }
            if isURL, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .string(context.baseURL) }
            return .string(resolveJavaScriptRuleURL(value, enabled: isURL, context: context))
        }
    }

    private func resolveJavaScriptRuleURL(
        _ value: String,
        enabled: Bool,
        context: RuleExecutionContext
    ) -> String {
        guard enabled else { return value }
        let baseText = context.baseURL.isEmpty ? context.source?.bookSourceUrl ?? "" : context.baseURL
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return baseText }
        guard let baseURL = URL(string: baseText),
              let absolute = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return value }
        return absolute.absoluteString
    }

    private func rejectUnboundedExecution(_ script: String) throws {
        let compact = script.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
        let rejected = ["while(true)", "while(1)", "for(;;)", "eval(", "functionconstructor("]
        if let token = rejected.first(where: compact.contains) {
            throw RuleEngineError.resourceLimit(rule: script, detail: "JavaScript 包含未受控执行结构：\(token)")
        }
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let value = value as? String { return value }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) { return string }
        return String(describing: value)
    }

    private static func firstURL(_ value: Any?) -> String {
        if let values = value as? [Any], let first = values.first { return stringify(first) }
        return stringify(value)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return Double(stringify(value))
    }

    private static func hexBytes(_ value: String) -> [UInt8] {
        let characters = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.count.isMultiple(of: 2) else { return [] }
        return stride(from: 0, to: characters.count, by: 2).compactMap { index in
            UInt8(String(characters[index ... index + 1]), radix: 16)
        }
    }

    private static func byteData(from value: Any?) -> Data {
        let values: [Any]
        if let value = value as? [Any] {
            values = value
        } else if let value = value as? NSArray {
            values = value.map { $0 }
        } else {
            return Data()
        }
        return Data(values.compactMap { item in
            if let number = item as? NSNumber { return UInt8(truncatingIfNeeded: number.intValue) }
            if let number = Int(stringify(item)) { return UInt8(truncatingIfNeeded: number) }
            return nil
        })
    }

    private static let javaImporterBootstrap = #"""
        (function (global) {
          'use strict';
          var NativeString = global.String;
          global.__legadoUnboxString = function (value) {
            return Object.prototype.toString.call(value) === '[object String]' ? NativeString(value) : value;
          };
          function javaClass(name, value) {
            Object.defineProperty(value, '__javaSimpleName', { value: name });
            return Object.freeze(value);
          }
          function checkedBytes(value) {
            if (!Array.isArray(value)) throw new TypeError('Java byte[] required');
            return value;
          }
          function JavaString(value) {
            var text = new NativeString(Array.isArray(value) ? __legadoUTF8String(value) : (value == null ? '' : value));
            Object.defineProperty(text, 'getBytes', {
              value: function (charset) {
                if (charset && !/^utf-?8$/i.test(NativeString(charset))) {
                  throw new Error('Unsupported charset: ' + charset);
                }
                return __legadoUTF8Bytes(NativeString(this));
              }
            });
            return text;
          }
          function SecretKeySpec(bytes, algorithm) {
            if (!(this instanceof SecretKeySpec)) return new SecretKeySpec(bytes, algorithm);
            this.key = checkedBytes(bytes).slice();
            this.algorithm = NativeString(algorithm || '');
            Object.freeze(this.key);
            Object.freeze(this);
          }
          function IvParameterSpec(bytes) {
            if (!(this instanceof IvParameterSpec)) return new IvParameterSpec(bytes);
            this.bytes = checkedBytes(bytes).slice();
            if (this.bytes.length !== 16) throw new Error('AES IV must contain 16 bytes');
            Object.freeze(this.bytes);
            Object.freeze(this);
          }
          var Cipher = javaClass('Cipher', {
            ENCRYPT_MODE: 1,
            DECRYPT_MODE: 2,
            getInstance: function (algorithm) {
              if (NativeString(algorithm).toUpperCase() !== 'AES/CBC/PKCS5PADDING') {
                throw new Error('Unsupported Cipher algorithm: ' + algorithm);
              }
              var key = null, iv = null, operation = null;
              return {
                init: function (mode, spec, parameters) {
                  if ((mode !== 1 && mode !== 2) || !(spec instanceof SecretKeySpec) ||
                      spec.algorithm.toUpperCase() !== 'AES' || !(parameters instanceof IvParameterSpec)) {
                    throw new TypeError('AES key, IV and cipher mode required');
                  }
                  operation = mode; key = spec.key; iv = parameters.bytes;
                },
                doFinal: function (bytes) {
                  if (key === null) throw new Error('Cipher not initialized');
                  var result = __legadoAESCBC(operation, key, iv, checkedBytes(bytes));
                  if (!Array.isArray(result)) throw new Error('AES/CBC operation failed');
                  return result;
                }
              };
            }
          });
          var Mac = javaClass('Mac', {
            getInstance: function (algorithm) {
              if (NativeString(algorithm).toUpperCase() !== 'HMACSHA1') {
                throw new Error('Unsupported Mac algorithm: ' + algorithm);
              }
              var key = null;
              return {
                init: function (spec) {
                  if (!(spec instanceof SecretKeySpec) || spec.algorithm.toUpperCase() !== 'HMACSHA1') {
                    throw new TypeError('HmacSHA1 SecretKeySpec required');
                  }
                  key = spec.key;
                },
                doFinal: function (bytes) {
                  if (key === null) throw new Error('Mac not initialized');
                  return __legadoHmacSHA1(key, checkedBytes(bytes));
                }
              };
            }
          });
          javaClass('SecretKeySpec', SecretKeySpec);
          javaClass('IvParameterSpec', IvParameterSpec);
          javaClass('String', JavaString);
          var Base64 = javaClass('Base64', {
            DEFAULT: 0,
            NO_WRAP: 2,
            encodeToString: function (bytes) { return __legadoBase64EncodeBytes(checkedBytes(bytes)); },
            decode: function (value) { return __legadoBase64DecodeBytes(NativeString(value)); },
            getDecoder: function () { return Object.freeze({ decode: this.decode }); },
            getEncoder: function () { return Object.freeze({ encodeToString: this.encodeToString }); }
          });
          var Arrays = javaClass('Arrays', {
            copyOfRange: function (bytes, from, to) {
              checkedBytes(bytes);
              if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || from > bytes.length || to < from || to - from > 2097152) {
                throw new RangeError('Invalid byte array range');
              }
              var copied = bytes.slice(from, to);
              while (copied.length < to - from) copied.push(0);
              return copied;
            }
          });
          var URLEncoder = javaClass('URLEncoder', {
            encode: function (value, charset) {
              if (charset && !/^utf-?8$/i.test(NativeString(charset))) {
                throw new Error('Unsupported charset: ' + charset);
              }
              return __legadoFormURLEncode(NativeString(value));
            }
          });
          var DatatypeConverter = javaClass('DatatypeConverter', {
            printBase64Binary: function (bytes) { return __legadoBase64EncodeBytes(checkedBytes(bytes)); },
            parseBase64Binary: function (value) { return __legadoBase64DecodeBytes(NativeString(value)); },
            printHexBinary: function (bytes) { return __legadoHexEncodeBytes(checkedBytes(bytes)); }
          });
          var packages = {
            javax: {
              crypto: { Mac: Mac, Cipher: Cipher, spec: { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec } },
              xml: { bind: { DatatypeConverter: DatatypeConverter } }
            },
            java: { net: { URLEncoder: URLEncoder }, lang: { String: JavaString }, util: { Base64: Base64, Arrays: Arrays } },
            android: { util: { Base64: Base64 } }
          };
          Object.freeze(packages.javax.crypto.spec);
          Object.freeze(packages.javax.crypto);
          Object.freeze(packages.javax.xml.bind);
          Object.freeze(packages.javax.xml);
          Object.freeze(packages.javax);
          Object.freeze(packages.java.net);
          Object.freeze(packages.java.lang);
          Object.freeze(packages.java.util);
          Object.freeze(packages.java);
          Object.freeze(packages.android.util);
          Object.freeze(packages.android);
          global.Packages = Object.freeze(packages);
          global.JavaImporter = Object.freeze(function () {
            var imported = Object.create(null);
            var allowedPackages = [packages.java.lang, packages.java.net, packages.java.util,
              packages.javax.crypto, packages.javax.crypto.spec, packages.javax.xml.bind, packages.android.util];
            function addClass(value) {
              if (!value || typeof value.__javaSimpleName !== 'string') throw new TypeError('Unsupported Java class import');
              if (!Object.prototype.hasOwnProperty.call(imported, value.__javaSimpleName)) {
                Object.defineProperty(imported, value.__javaSimpleName, { value: value, enumerable: true });
              }
            }
            function addPackage(value) {
              if (allowedPackages.indexOf(value) < 0) throw new TypeError('Unsupported Java package import');
              Object.keys(value).forEach(function (name) {
                if (value[name] && typeof value[name].__javaSimpleName === 'string') addClass(value[name]);
              });
            }
            Object.defineProperty(imported, 'importPackage', { value: function () {
              for (var i = 0; i < arguments.length; i++) addPackage(arguments[i]);
            }});
            Object.defineProperty(imported, 'importClass', { value: function () {
              for (var i = 0; i < arguments.length; i++) addClass(arguments[i]);
            }});
            for (var index = 0; index < arguments.length; index++) {
              var value = arguments[index];
              if (allowedPackages.indexOf(value) >= 0) addPackage(value); else addClass(value);
            }
            return imported;
          });
        })(this);
        """#

    private static func formURLEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        return value.unicodeScalars.map { scalar in
            if scalar == " " { return "+" }
            if scalar.isASCII, allowed.contains(scalar) { return String(scalar) }
            return String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    private static func headerMap(_ value: Any?) -> [String: String] {
        if let values = value as? [String: String] { return values }
        if let values = value as? [String: Any] { return values.mapValues(stringify) }
        let text = stringify(value)
        guard let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values.mapValues(stringify)
    }

    private static func mergeCookieHeaders(_ stored: String, _ explicit: String) -> String {
        var order: [String] = []
        var values: [String: String] = [:]
        for header in [stored, explicit] {
            for part in header.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                if values[name] == nil { order.append(name) }
                values[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return order.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }
}

private protocol VariableBoxProxy: AnyObject {
    func get(_ key: String) -> String
    @discardableResult func put(_ key: String, _ value: String) -> String
}

private final class JSVariableBox: VariableBoxProxy {
    var values: [String: String]
    var rssState: RSSVariableState?
    var error: Error?
    var onError: ((Error) -> Void)?

    init(_ values: [String: String]) {
        self.values = values
    }

    func get(_ key: String) -> String { values[key] ?? getBig(key) ?? "" }

    func getBig(_ key: String) -> String? {
        do { return try rssState?.get(key) }
        catch { self.error = error; onError?(error); return nil }
    }

    func putVariable(_ key: String, _ value: String?) {
        guard rssState != nil else { values[key] = value; return }
        // Kotlin String.length counts UTF-16 code units, including both halves
        // of emoji, rather than Swift graphemes or UTF-8 bytes.
        if let value, value.utf16.count < 10_000 {
            rssState?.put(key, nil)
            values[key] = value
        } else {
            rssState?.put(key, value)
            values.removeValue(forKey: key)
        }
    }

    @discardableResult
    func put(_ key: String, _ value: String) -> String {
        putVariable(key, value)
        return value
    }
}

public final class BookSourceRuntimeStore: @unchecked Sendable {
    public static let shared = BookSourceRuntimeStore()

    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    private let persistent = PersistentRuntimeCache.shared

    public func get(sourceID: String, key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[sourceID]?[key] { return value }
        let cacheKey = persistentKey(sourceID: sourceID, key: key)
        let value = persistent.get(cacheKey) ?? ""
        if !value.isEmpty { values[sourceID, default: [:]][key] = value }
        return value
    }

    public func put(sourceID: String, key: String, value: String) {
        lock.lock()
        values[sourceID, default: [:]][key] = value
        lock.unlock()
        persistent.put(persistentKey(sourceID: sourceID, key: key), value: value)
    }

    public func loginHeaders(sourceID: String) -> [String: String] {
        let value = get(sourceID: sourceID, key: "loginHeader")
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func persistentKey(sourceID: String, key: String) -> String {
        key == "loginHeader" ? "loginHeader_\(sourceID)" : "v_\(sourceID)_\(key)"
    }
}
