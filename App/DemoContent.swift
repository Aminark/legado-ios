import Foundation

#if DEBUG
struct ReaderCacheTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if chapter.index.isMultiple(of: 11) {
            return .init(diagnostics: [.init(severity: .error, code: "cache.fixture", message: "缓存测试：模拟 HTTP 403", rule: chapter.url)])
        }
        return .init(title: chapter.title, content: DemoContent.readerText)
    }
}
#endif

enum DemoContent {
    static let sources: [BookSource] = {
        var classic = BookSource(bookSourceUrl: "https://classic.example", bookSourceName: "经典文学馆")
        classic.bookSourceGroup = "文学"
        classic.exploreUrl = "编辑推荐::/explore/recommended?page={{page}}\n热门连载::/explore/serial?page={{page}}\n完结佳作::/explore/finished?page={{page}}"
        classic.searchUrl = "/search?q={{key}}"
        classic.ruleExplore = BookListRule(bookList: "$.books", name: "$.name", author: "$.author", kind: "$.kind", bookUrl: "$.url", coverUrl: "$.cover")
        classic.ruleSearch = SearchRule(bookList: "$.books", name: "$.name", author: "$.author", bookUrl: "$.url")
        classic.ruleBookInfo = BookInfoRule()
        classic.ruleToc = TocRule()
        classic.ruleContent = ContentRule()

        var science = BookSource(bookSourceUrl: "https://science.example", bookSourceName: "远方书库")
        science.bookSourceGroup = "科幻 · 悬疑"
        science.exploreUrl = "星际远征::/explore/space?page={{page}}&&悬疑推理::/explore/mystery?page={{page}}"
        science.searchUrl = "/api/search?key={{key}}"
        science.ruleSearch = SearchRule(bookList: "$.data", name: "$.title", author: "$.writer", bookUrl: "$.href")
        science.ruleExplore = BookListRule(bookList: "$.data", name: "$.title", author: "$.writer", kind: "$.tags", bookUrl: "$.href")
        science.ruleToc = TocRule()
        science.ruleContent = ContentRule()

        var audio = BookSource(bookSourceUrl: "https://audio.example", bookSourceName: "听见故事")
        audio.bookSourceGroup = "听书"
        audio.bookSourceType = 1
        audio.searchUrl = "/search, {\"method\":\"POST\",\"body\":{\"title\":\"searchKey\"}}"
        audio.ruleSearch = SearchRule(bookList: "$.content", name: "$.title", author: "$.anchor", bookUrl: "$.id@js:'/book/' + result")
        audio.ruleToc = TocRule()
        audio.ruleContent = ContentRule()
        return [classic, science, audio]
    }()

    static let exploreBooks: [SearchBook] = [
        ("11", "潮汐来信", "周暮", "治愈 · 成长"),
        ("12", "银河邮差", "许野", "科幻 · 冒险"),
        ("13", "风从旧城来", "沈灯", "都市 · 悬疑"),
        ("14", "万物有声", "唐溪", "自然 · 随笔"),
        ("15", "雾中航线", "江屿", "推理 · 剧情"),
        ("16", "春山可望", "苏禾", "古风 · 群像")
    ].map { id, name, author, kind in
        var book = SearchBook(
            bookURL: "https://classic.example/book/\(id)",
            origin: sources[0].bookSourceUrl,
            originName: sources[0].bookSourceName,
            type: 0,
            name: name,
            author: author
        )
        book.kind = kind
        return book
    }

    static let books: [Book] = {
        var first = Book(bookUrl: "https://classic.example/book/1", name: "长夜里的灯", author: "林舟", origin: sources[0].bookSourceUrl)
        first.originName = sources[0].bookSourceName
        first.kind = "当代文学"
        first.latestChapterTitle = "第十八章 · 微光"
        first.totalChapterNum = 42
        first.durChapterIndex = 17
        first.lastCheckCount = 3

        var second = Book(bookUrl: "https://science.example/book/2", name: "群星沉默时", author: "顾屿", origin: sources[1].bookSourceUrl)
        second.originName = sources[1].bookSourceName
        second.kind = "科幻"
        second.latestChapterTitle = "第七卷 · 返航"
        second.totalChapterNum = 96
        second.durChapterIndex = 63

        var third = Book(bookUrl: "https://audio.example/book/3", name: "山海入梦来", author: "南声", origin: sources[2].bookSourceUrl)
        third.originName = sources[2].bookSourceName
        third.type = 1
        third.latestChapterTitle = "第十二集 · 海上月"
        third.totalChapterNum = 30
        third.durChapterIndex = 4
        return [first, second, third]
    }()

    static let readerChapters: [BookChapter] = (0..<5).map { index in
        BookChapter(
            url: "demo://chapter/\(index)",
            title: ["第一章 · 雨夜", "第二章 · 灯塔", "第三章 · 潮声", "第四章 · 来信", "第五章 · 天明"][index],
            bookUrl: books[0].bookUrl,
            index: index
        )
    }

    static let sourceSwitchCandidates: [BookSourceCandidate] = {
        var science = SearchBook(
            bookURL: "https://science.example/book/long-night",
            origin: sources[1].bookSourceUrl,
            originName: sources[1].bookSourceName,
            type: 0,
            name: books[0].name,
            author: books[0].author
        )
        science.latestChapterTitle = "第四十二章 · 灯火长明"
        var audio = SearchBook(
            bookURL: "https://audio.example/book/long-night",
            origin: sources[2].bookSourceUrl,
            originName: sources[2].bookSourceName,
            type: 1,
            name: books[0].name,
            author: "主播：林舟"
        )
        audio.latestChapterTitle = "第四十集 · 归途"
        return [.init(book: science, score: 190), .init(book: audio, score: 110)]
    }()

    static var sourceSwitchBook: Book {
        var book = books[0]
        book.durChapterIndex = 1
        book.durChapterTitle = readerChapters[1].title
        book.totalChapterNum = readerChapters.count
        return book
    }

    static var sourceSwitchService: BookSourceSwitchService {
        let loader = DemoSourceSwitchLoader(body: readerText,
            sameText: ProcessInfo.processInfo.arguments.contains("-uiDemoSourceGroups"))
        return BookSourceSwitchService(detailLoader: loader, chapterLoader: loader, contentLoader: loader,
                                       chapterRepository: InMemoryBookChapterRepository())
    }

    static var sourceSwitchReferenceService: any SourceChapterReferencing {
        DemoSourceReference(value: ProcessInfo.processInfo.arguments.contains("-uiDemoSourceReference")
            ? SourceChapterReference(provider: "QQ 阅读（演示）", chapterTitle: readerChapters[1].title,
                                     url: "https://book.qq.com/book-read/1/2", content: String(readerText.prefix(240)))
            : nil)
    }

    private struct DemoSourceReference: SourceChapterReferencing {
        let value: SourceChapterReference?
        func reference(for book: Book) async -> SourceChapterReference? { value }
    }

    private struct DemoSourceSwitchLoader: BookDetailLoading, ChapterListLoading, ChapterContentLoading {
        let body: String
        var sameText = false

        func loadDetail(searchBook: SearchBook, source: BookSource) async -> BookDetailReport {
            var book = Book(bookUrl: searchBook.bookURL, name: searchBook.name, author: searchBook.author, origin: source.id)
            book.originName = source.bookSourceName
            return .init(book: book)
        }

        func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport {
            let titles = ["第一章 · 雨夜", source.bookSourceType == 1 && !sameText ? "第二节 灯塔" : "第二章 · 灯塔",
                          "第三章 · 潮声", "第四章 · 来信", "第五章 · 天明"]
            return .init(chapters: titles.enumerated().map {
                BookChapter(url: book.bookUrl + "/\($0.offset)", title: $0.element, bookUrl: book.bookUrl, index: $0.offset)
            })
        }

        func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
            .init(content: sameText ? body : source.bookSourceName + "的本章正文。\n\n" + body)
        }
    }

    static let readerText = """
    雨落在旧城的瓦檐上，细密得像一封迟到了许多年的信。
    林深推开阁楼的窗，远处的灯塔正越过雾气，一次又一次照亮沉睡的海湾。桌上的书摊开在同一页，纸边压着一枚褪色的蓝色邮票。
    他记得祖父说过，所有没有寄出的故事，最后都会顺着河流抵达海上。
    楼下传来水壶轻响。木质楼梯保存着雨天特有的气味，也保存着这里每个人走过的声音。林深把信纸翻到背面，看见一行很淡的铅笔字：等灯塔第三次亮起，就沿着潮声出发。
    窗外，第一束光穿过雨幕。
    他没有立刻动身，只是把书签夹进那一页。屋里很安静，只有雨水、钟摆，以及某个故事终于开始时微小而确定的回声。
    第二束光掠过海面时，远处出现了一艘白色小船。它没有开灯，却像知道方向一样，稳稳停在旧码头边。
    林深收好信，披上外套。门被推开的瞬间，潮湿的风涌进走廊，也把许多年前那个未完的夜晚重新带回眼前。
    """

    static let bookmarks: [Bookmark] = {
        var first = Bookmark(time: 1_786_989_000_000, bookName: books[0].name, bookAuthor: books[0].author)
        first.chapterIndex = 0
        first.chapterPosition = 48
        first.chapterName = readerChapters[0].title
        first.bookText = "远处的灯塔正越过雾气，一次又一次照亮沉睡的海湾。"
        var second = Bookmark(time: 1_786_989_100_000, bookName: books[0].name, bookAuthor: books[0].author)
        second.chapterIndex = 0
        second.chapterPosition = 186
        second.chapterName = readerChapters[0].title
        second.bookText = "等灯塔第三次亮起，就沿着潮声出发。"
        return [first, second]
    }()

    static let readRecords: [ReadRecord] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func key(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        }
        return [
            .init(
                deviceId: "ios-simulator",
                bookName: books[0].name,
                readTime: 5_460_000,
                dailyReadTimes: [key(-2): 1_020_000, key(-1): 1_440_000, key(0): 1_260_000]
            ),
            .init(
                deviceId: "ios-simulator",
                bookName: books[1].name,
                readTime: 2_220_000,
                dailyReadTimes: [key(-4): 720_000, key(-1): 540_000]
            )
        ]
    }()
}
