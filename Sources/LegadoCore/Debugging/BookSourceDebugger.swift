import Foundation

public enum SourceDebugStage: String, Codable, CaseIterable, Sendable {
    case configuration
    case search
    case detail
    case toc
    case content

    public var title: String {
        switch self {
        case .configuration: "配置"
        case .search: "搜索"
        case .detail: "详情"
        case .toc: "目录"
        case .content: "正文"
        }
    }
}

public enum SourceDebugStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

public struct SourceDebugStep: Codable, Hashable, Identifiable, Sendable {
    public var stage: SourceDebugStage
    public var status: SourceDebugStatus
    public var summary: String
    public var elapsedMilliseconds: Int
    public var diagnostics: [RuleDiagnostic]

    public var id: SourceDebugStage { stage }

    public init(
        stage: SourceDebugStage,
        status: SourceDebugStatus,
        summary: String,
        elapsedMilliseconds: Int = 0,
        diagnostics: [RuleDiagnostic] = []
    ) {
        self.stage = stage
        self.status = status
        self.summary = summary
        self.elapsedMilliseconds = elapsedMilliseconds
        self.diagnostics = diagnostics
    }
}

public struct BookSourceDebugReport: Codable, Sendable {
    public var sourceID: String
    public var keyword: String
    public var steps: [SourceDebugStep]
    public var sampleBookName: String?
    public var sampleChapterTitle: String?
    public var contentPreview: String?

    public var passed: Bool {
        !steps.contains { $0.status == .failed }
            && steps.contains { $0.stage == .content && $0.status != .skipped }
    }

    public init(sourceID: String, keyword: String, steps: [SourceDebugStep] = []) {
        self.sourceID = sourceID
        self.keyword = keyword
        self.steps = steps
    }
}

public struct BookSourceDebugger: Sendable {
    private let searchService: BookSearchService
    private let bookService: NetworkBookService

    public init(transport: any HTTPTransport = URLSessionHTTPTransport.shared) {
        searchService = BookSearchService(transport: transport)
        bookService = NetworkBookService(transport: transport)
    }

    public func run(source: BookSource, keyword: String) async -> BookSourceDebugReport {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var report = BookSourceDebugReport(sourceID: source.id, keyword: keyword)
        let missing = missingConfiguration(source)
        report.steps.append(.init(
            stage: .configuration,
            status: missing.isEmpty ? .passed : .failed,
            summary: missing.isEmpty ? "搜索、详情、目录、正文规则均已配置" : "缺少：\(missing.joined(separator: "、"))",
            diagnostics: missing.map {
                .init(severity: .error, code: "debug.configuration", message: "缺少\($0)配置", rule: source.bookSourceName)
            }
        ))
        guard !keyword.isEmpty else {
            appendSkipped(after: .configuration, to: &report, reason: "请输入调试关键词")
            return report
        }

        let searchStart = ProcessInfo.processInfo.systemUptime
        let search = await searchService.search(keyword: keyword, page: 1, source: source)
        let searchStep = step(
            stage: .search,
            hasOutput: !search.books.isEmpty,
            summary: search.books.isEmpty ? "没有解析到搜索结果" : "解析到 \(search.books.count) 条结果",
            diagnostics: search.diagnostics,
            started: searchStart
        )
        report.steps.append(searchStep)
        guard let searchBook = search.books.first else {
            appendSkipped(after: .search, to: &report, reason: "搜索阶段没有样本书籍")
            return report
        }
        report.sampleBookName = searchBook.name

        let detailStart = ProcessInfo.processInfo.systemUptime
        let detail = await bookService.loadDetail(searchBook: searchBook, source: source)
        report.steps.append(step(
            stage: .detail,
            hasOutput: !detail.book.name.isEmpty,
            summary: "样本《\(detail.book.name)》；目录地址已\(!detail.book.tocUrl.isEmpty ? "解析" : "回退")",
            diagnostics: detail.diagnostics,
            started: detailStart
        ))

        let tocStart = ProcessInfo.processInfo.systemUptime
        let toc = await bookService.loadChapters(book: detail.book, source: source, maxPages: 5)
        report.steps.append(step(
            stage: .toc,
            hasOutput: !toc.chapters.isEmpty,
            summary: toc.chapters.isEmpty ? "没有解析到章节" : "解析到 \(toc.chapters.count) 章，访问 \(toc.pagesVisited) 页",
            diagnostics: toc.diagnostics,
            started: tocStart
        ))
        guard let chapter = toc.chapters.first(where: { !$0.isVolume }) else {
            appendSkipped(after: .toc, to: &report, reason: "目录阶段没有可读取章节")
            return report
        }
        report.sampleChapterTitle = chapter.title

        let next = toc.chapters.drop(while: { $0.id != chapter.id }).dropFirst().first(where: { !$0.isVolume })?.url
        let contentStart = ProcessInfo.processInfo.systemUptime
        let content = await bookService.loadContent(
            book: detail.book,
            chapter: chapter,
            source: source,
            nextChapterURL: next,
            maxPages: 5
        )
        let cleaned = content.content.trimmingCharacters(in: .whitespacesAndNewlines)
        report.contentPreview = cleaned.isEmpty ? nil : String(cleaned.prefix(240))
        report.steps.append(step(
            stage: .content,
            hasOutput: !cleaned.isEmpty,
            summary: cleaned.isEmpty ? "没有解析到正文" : "正文 \(cleaned.count) 字，访问 \(content.pagesVisited) 页",
            diagnostics: content.diagnostics,
            started: contentStart
        ))
        return report
    }

    private func missingConfiguration(_ source: BookSource) -> [String] {
        var missing: [String] = []
        if source.searchUrl?.isEmpty != false || source.ruleSearch == nil { missing.append("搜索") }
        if source.ruleBookInfo == nil { missing.append("详情") }
        if source.ruleToc?.chapterList?.isEmpty != false { missing.append("目录") }
        if source.ruleContent?.content?.isEmpty != false { missing.append("正文") }
        return missing
    }

    private func step(
        stage: SourceDebugStage,
        hasOutput: Bool,
        summary: String,
        diagnostics: [RuleDiagnostic],
        started: TimeInterval
    ) -> SourceDebugStep {
        let containsError = diagnostics.contains { $0.severity == .error }
        let status: SourceDebugStatus = if !hasOutput {
            .failed
        } else if containsError || !diagnostics.isEmpty {
            .warning
        } else {
            .passed
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        return .init(
            stage: stage,
            status: status,
            summary: summary,
            elapsedMilliseconds: max(milliseconds, 0),
            diagnostics: diagnostics
        )
    }

    private func appendSkipped(after stage: SourceDebugStage, to report: inout BookSourceDebugReport, reason: String) {
        guard let index = SourceDebugStage.allCases.firstIndex(of: stage) else { return }
        for remaining in SourceDebugStage.allCases.dropFirst(index + 1) {
            report.steps.append(.init(stage: remaining, status: .skipped, summary: reason))
        }
    }
}
