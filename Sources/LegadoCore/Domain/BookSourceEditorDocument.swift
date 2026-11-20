import Foundation

public struct BookSourceEditorField: Identifiable, Sendable {
    public let path: String
    public let title: String
    public var id: String { path }
    public var help: String {
        switch path {
        case "bookSourceUrl": return "填写书源站点地址，例如 https://example.com；它也是书源的唯一标识。"
        case "bookSourceName": return "显示在书源列表中的名称，不能为空。"
        case "bookSourceGroup": return "多个分组可用逗号或分号分隔。"
        case "bookUrlPattern": return "匹配该书源的书籍详情 URL 的正则表达式，用于从网址添加书籍。"
        case "concurrentRate": return "1000 表示请求间隔 1000 ms；1/1000 表示每 1000 ms 最多 1 次请求。"
        case "header": return "填写请求头 JSON，或用 @js: / <js> 动态生成。User-Agent 为 null 可禁用默认 UA。"
        case "jsLib": return "填写共享 JavaScript，或以 JSON 对象配置在线脚本库。"
        case "searchUrl": return "用 {{key}} 表示关键词、{{page}} 表示页码；URL 后可用逗号附加请求选项 JSON。"
        case "exploreUrl": return "填写 名称::地址，多项用换行或 && 分隔；也支持 JSON 分类数组和 JavaScript。"
        case "loginUi": return "填写登录界面 JSON。"
        case "ruleToc.formatJs": return "目录去重后处理标题，可使用 title、index（从 1 开始）和 gInt。"
        case "ruleContent.nextContentUrl": return "提取当前章的下一分页地址，而非下一章。"
        case "ruleContent.replaceRegex": return "在多页正文合并后执行的替换规则，使用 ## 分隔正则和替换内容。"
        case "ruleContent.imageStyle": return "FULL 表示图片铺满；留空使用默认样式。"
        default:
            if isJavaScript { return "使用 JavaScript 编写，可通过更多菜单调试当前书源草稿。" }
            if path.contains(".") { return "支持 CSS / JSoup、XPath、JSONPath、正则和 JavaScript；留空表示不配置此项。" }
            return "留空表示不配置此项。"
        }
    }
    public var isJavaScript: Bool {
        path.lowercased().contains("js") || path == "jsLib" || path.hasSuffix("imageDecode") || path.hasSuffix("payAction")
    }
}

public struct BookSourceEditorSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let fields: [BookSourceEditorField]
}

public enum BookSourceEditorSchema {
    public static let sections: [BookSourceEditorSection] = [
        .init(id: "basic", title: "基础", fields: [
            .init(path: "bookSourceName", title: "书源名称"),
            .init(path: "bookSourceUrl", title: "书源地址"),
            .init(path: "bookSourceGroup", title: "分组"),
            .init(path: "bookSourceComment", title: "备注"),
            .init(path: "bookUrlPattern", title: "书籍 URL 正则"),
            .init(path: "concurrentRate", title: "并发率"),
            .init(path: "header", title: "请求头"),
            .init(path: "jsLib", title: "JavaScript 库"),
            .init(path: "variableComment", title: "变量说明"),
        ]),
        .init(id: "login", title: "登录", fields: [
            .init(path: "loginUrl", title: "登录地址 / 脚本"),
            .init(path: "loginUi", title: "自定义登录界面"),
            .init(path: "loginCheckJs", title: "登录检测脚本"),
            .init(path: "coverDecodeJs", title: "封面解密脚本"),
        ]),
        .init(id: "search", title: "搜索", fields: [
            .init(path: "searchUrl", title: "搜索地址"),
            .init(path: "ruleSearch.checkKeyWord", title: "测试关键词"),
            .init(path: "ruleSearch.bookList", title: "书籍列表"),
            .init(path: "ruleSearch.name", title: "书名"),
            .init(path: "ruleSearch.author", title: "作者"),
            .init(path: "ruleSearch.intro", title: "简介"),
            .init(path: "ruleSearch.kind", title: "分类"),
            .init(path: "ruleSearch.lastChapter", title: "最新章节"),
            .init(path: "ruleSearch.updateTime", title: "更新时间"),
            .init(path: "ruleSearch.bookUrl", title: "详情地址"),
            .init(path: "ruleSearch.coverUrl", title: "封面地址"),
            .init(path: "ruleSearch.wordCount", title: "字数"),
        ]),
        .init(id: "explore", title: "发现", fields: [
            .init(path: "exploreUrl", title: "发现分类地址"),
            .init(path: "exploreScreen", title: "发现筛选配置"),
            .init(path: "ruleExplore.bookList", title: "书籍列表"),
            .init(path: "ruleExplore.name", title: "书名"),
            .init(path: "ruleExplore.author", title: "作者"),
            .init(path: "ruleExplore.intro", title: "简介"),
            .init(path: "ruleExplore.kind", title: "分类"),
            .init(path: "ruleExplore.lastChapter", title: "最新章节"),
            .init(path: "ruleExplore.updateTime", title: "更新时间"),
            .init(path: "ruleExplore.bookUrl", title: "详情地址"),
            .init(path: "ruleExplore.coverUrl", title: "封面地址"),
            .init(path: "ruleExplore.wordCount", title: "字数"),
        ]),
        .init(id: "info", title: "详情", fields: [
            .init(path: "ruleBookInfo.init", title: "预处理"),
            .init(path: "ruleBookInfo.name", title: "书名"),
            .init(path: "ruleBookInfo.author", title: "作者"),
            .init(path: "ruleBookInfo.intro", title: "简介"),
            .init(path: "ruleBookInfo.kind", title: "分类"),
            .init(path: "ruleBookInfo.lastChapter", title: "最新章节"),
            .init(path: "ruleBookInfo.updateTime", title: "更新时间"),
            .init(path: "ruleBookInfo.coverUrl", title: "封面地址"),
            .init(path: "ruleBookInfo.tocUrl", title: "目录地址"),
            .init(path: "ruleBookInfo.wordCount", title: "字数"),
            .init(path: "ruleBookInfo.canReName", title: "允许修改书名作者"),
            .init(path: "ruleBookInfo.downloadUrls", title: "文件下载地址"),
        ]),
        .init(id: "toc", title: "目录", fields: [
            .init(path: "ruleToc.preUpdateJs", title: "更新前脚本"),
            .init(path: "ruleToc.chapterList", title: "章节列表"),
            .init(path: "ruleToc.chapterName", title: "章节名称"),
            .init(path: "ruleToc.chapterUrl", title: "章节地址"),
            .init(path: "ruleToc.formatJs", title: "标题处理脚本"),
            .init(path: "ruleToc.isVolume", title: "卷名标识"),
            .init(path: "ruleToc.isVip", title: "VIP 标识"),
            .init(path: "ruleToc.isPay", title: "已购买标识"),
            .init(path: "ruleToc.updateTime", title: "章节信息"),
            .init(path: "ruleToc.nextTocUrl", title: "目录下一页"),
        ]),
        .init(id: "content", title: "正文", fields: [
            .init(path: "ruleContent.content", title: "正文"),
            .init(path: "ruleContent.subContent", title: "副正文"),
            .init(path: "ruleContent.title", title: "正文标题"),
            .init(path: "ruleContent.nextContentUrl", title: "正文下一页"),
            .init(path: "ruleContent.webJs", title: "WebView 注入脚本"),
            .init(path: "ruleContent.sourceRegex", title: "资源正则"),
            .init(path: "ruleContent.replaceRegex", title: "合并后替换"),
            .init(path: "ruleContent.imageStyle", title: "图片样式"),
            .init(path: "ruleContent.imageDecode", title: "图片解密脚本"),
            .init(path: "ruleContent.payAction", title: "购买脚本"),
            .init(path: "ruleContent.callBackJs", title: "事件回调脚本"),
        ]),
        .init(id: "review", title: "评论", fields: [
            .init(path: "ruleReview.reviewUrl", title: "评论地址"),
            .init(path: "ruleReview.reviewList", title: "评论列表"),
            .init(path: "ruleReview.nextReviewUrl", title: "下一页评论地址"),
            .init(path: "ruleReview.idRule", title: "评论 ID"),
            .init(path: "ruleReview.authorRule", title: "发布者"),
            .init(path: "ruleReview.avatarRule", title: "头像"),
            .init(path: "ruleReview.contentRule", title: "内容"),
            .init(path: "ruleReview.postTimeRule", title: "发布时间"),
            .init(path: "ruleReview.reviewQuoteUrl", title: "回复地址"),
            .init(path: "ruleReview.voteUpUrl", title: "点赞地址"),
            .init(path: "ruleReview.voteDownUrl", title: "点踩地址"),
            .init(path: "ruleReview.postReviewUrl", title: "发布段评"),
            .init(path: "ruleReview.postQuoteUrl", title: "发布回复"),
            .init(path: "ruleReview.deleteUrl", title: "删除地址"),
        ]),
    ]
}

public struct BookSourceEditorDocument: Sendable, Equatable {
    public private(set) var fields: [String: JSONValue]

    public init(source: BookSource) throws {
        self = try Self(json: String(decoding: JSONEncoder().encode(source), as: UTF8.self))
    }

    public init(json: String) throws {
        guard case .object(let object) = try JSONValue.decode(data: Data(json.utf8)) else {
            throw BookSourceImportError.invalidDocument("编辑器需要单个书源 JSON 对象")
        }
        fields = object
        for key in Self.ruleKeys {
            if case .string(let text) = fields[key], !text.isEmpty,
               case .object(let object) = try JSONValue.decode(data: Data(text.utf8)) {
                fields[key] = .object(object)
            }
        }
    }

    public func value(at path: String) -> JSONValue? {
        let keys = path.split(separator: ".").map(String.init)
        guard let key = keys.first else { return nil }
        return keys.count == 1 ? fields[key] : fields[key]?[keys[1]]
    }

    public mutating func set(_ value: JSONValue?, at path: String) {
        let keys = path.split(separator: ".").map(String.init)
        guard let key = keys.first else { return }
        if keys.count == 1 { fields[key] = value; return }
        var object: [String: JSONValue] = [:]
        if case .object(let existing) = fields[key] { object = existing }
        object[keys[1]] = value
        fields[key] = object.isEmpty ? nil : .object(object)
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }

    public func source() throws -> BookSource {
        let source = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(fields))
        let errors = BookSourceValidator.validate(source).filter { $0.severity == .error }
        guard errors.isEmpty else { throw BookSourceImportError.invalidSources(errors) }
        return source
    }

    static let ruleKeys = ["ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent", "ruleReview"]
}

struct SourceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
