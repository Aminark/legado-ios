import Foundation
import Testing
@testable import LegadoCore

struct LegadoDatabaseTests {
    @Test func decodesBookAndChapterFieldsWithoutBreakingLegacyPayloads() throws {
        let payload = Data(#"""
        {
          "bookUrl":"book","name":"书","durVolumeIndex":2,"chapterInVolumeIndex":4,
          "readConfig":{"reverseToc":true,"dailyChapters":5,"playSpeed":1.25}
        }
        """#.utf8)
        let book = try JSONDecoder().decode(Book.self, from: payload)
        #expect(book.durVolumeIndex == 2)
        #expect(book.chapterInVolumeIndex == 4)
        #expect(book.readConfig?.reverseToc == true)
        #expect(book.readConfig?.dailyChapters == 5)

        let chapter = try JSONDecoder().decode(
            BookChapter.self,
            from: Data(#"{"url":"/1","bookUrl":"book","startFragmentId":"a","endFragmentId":"b","imgUrl":"cover"}"#.utf8)
        )
        #expect(chapter.startFragmentId == "a")
        #expect(chapter.endFragmentId == "b")
        #expect(chapter.imageURL == "cover")
        let encoded = String(decoding: try JSONEncoder().encode(chapter), as: UTF8.self)
        #expect(encoded.contains("\"imgUrl\":\"cover\""))
    }

    @Test func storesSourcesBooksAndChapterKeys() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let sources = SQLiteBookSourceRepository(database: database)
        let books = SQLiteBookRepository(database: database)
        let chapters = SQLiteBookChapterRepository(database: database)

        var source = BookSource(bookSourceUrl: "https://source.example", bookSourceName: "示例")
        source.customOrder = 7
        try await sources.save([source])

        var book = Book(bookUrl: "https://source.example/book/1", name: "书", author: "作者", origin: source.bookSourceUrl)
        book.durChapterPos = 42
        try await books.save([book])

        var first = BookChapter(url: "/1", title: "第一章", bookUrl: book.bookUrl, index: 99)
        first.variable = #"{"token":"x"}"#
        let second = BookChapter(url: "/2", title: "第二章", bookUrl: book.bookUrl, index: 100)
        try await chapters.save([first, second], bookURL: book.bookUrl)

        #expect(try await sources.load() == [source])
        #expect(try await books.load() == [book])
        let stored = try await chapters.load(bookURL: book.bookUrl)
        #expect(stored.map(\.index) == [0, 1])
        #expect(stored.first?.variable == first.variable)

        try await books.save([])
        #expect(try await chapters.load(bookURL: book.bookUrl).isEmpty)
    }

    @Test func importsLegacyJSONOnlyIntoEmptyTables() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appending(path: "book-sources.json")
        let booksURL = directory.appending(path: "books.json")
        let source = BookSource(bookSourceUrl: "https://legacy.example", bookSourceName: "旧源")
        let book = Book(bookUrl: "https://legacy.example/1", name: "旧书", origin: source.bookSourceUrl)
        try JSONEncoder().encode([source]).write(to: sourceURL)
        try JSONEncoder().encode([book]).write(to: booksURL)

        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        try await database.importLegacyJSON(bookSourcesURL: sourceURL, booksURL: booksURL)
        #expect(try await database.loadBookSources() == [source])
        #expect(try await database.loadBooks() == [book])

        try JSONEncoder().encode([BookSource(bookSourceUrl: "https://ignored", bookSourceName: "忽略")])
            .write(to: sourceURL)
        try await database.importLegacyJSON(bookSourcesURL: sourceURL, booksURL: booksURL)
        #expect(try await database.loadBookSources() == [source])
    }

    @Test func doesNotReimportLegacyChaptersAfterRemovingBook() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyDirectory = directory.appending(path: "Chapters", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let book = Book(bookUrl: "https://source.example/book", name: "书", origin: "https://source.example")
        let stale = BookChapter(url: "https://source.example/old", title: "后记", bookUrl: book.bookUrl, index: 0)
        try JSONEncoder().encode([stale]).write(to: legacyDirectory.appending(path: "old.json"))

        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let books = SQLiteBookRepository(database: database)
        let chapters = SQLiteBookChapterRepository(database: database, legacyDirectory: legacyDirectory)
        try await books.save([book])
        #expect(try await chapters.load(bookURL: book.bookUrl).map(\.title) == ["后记"])

        try await books.save([])
        try await books.save([book])
        #expect(try await chapters.load(bookURL: book.bookUrl).isEmpty)
    }

    @Test func storesBookmarksAndCompositeReadRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let repository = SQLiteReadingActivityRepository(database: database)
        let bookmark = Bookmark(time: 123, bookName: "书", bookAuthor: "作者")
        let records = [
            ReadRecord(deviceId: "A", bookName: "书", readTime: 10, lastRead: 100),
            ReadRecord(deviceId: "B", bookName: "书", readTime: 20, lastRead: 200)
        ]
        try await repository.saveBookmarks([bookmark])
        try await repository.saveReadRecords(records)
        #expect(try await repository.loadBookmarks() == [bookmark])
        #expect(try await repository.loadReadRecords() == Array(records.reversed()))
    }

    @Test func storesBookGroupsInExplicitOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let repository = SQLiteBookGroupRepository(database: database)
        let groups = [
            BookGroup(groupId: 2, groupName: "二", order: 9),
            BookGroup(groupId: 1, groupName: "一", order: 1)
        ]
        try await repository.save(groups)
        #expect(try await repository.load() == groups)
    }

    @Test func searchKeywordUsageOrderingUsesCountAndTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let repository = SQLiteSearchKeywordRepository(database: database, legacyWords: ["旧词"])

        #expect(try await repository.load(order: .lastUseTime).map(\.word) == ["旧词"])
        _ = try await repository.record("甲", at: 100)
        _ = try await repository.record("乙", at: 200)
        let updated = try await repository.record("甲", at: 300)
        #expect(updated.usage == 2)
        #expect(try await repository.load(order: .usage).map(\.word).first == "甲")
        #expect(try await repository.load(order: .lastUseTime).map(\.word).first == "甲")
        try await repository.delete("甲")
        #expect(try await repository.load(order: .usage).allSatisfy { $0.word != "甲" })
    }

    @Test func preservesCacheDeadlinesSourceCleanupAndCookieKeys() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let caches = SQLiteLegadoCacheRepository(database: database)
        let cookies = SQLiteLegadoCookieRepository(database: database)

        try await caches.put(.init(key: "alive", value: "A", deadline: 200))
        try await caches.put(.init(key: "expired", value: "E", deadline: 50))
        try await caches.put(.init(key: "loginHeader_source", value: "H"))
        #expect(try await caches.value(for: "alive", now: 100) == "A")
        #expect(try await caches.value(for: "expired", now: 100) == nil)
        try await caches.clearExpired(now: 100)
        try await caches.deleteSourceVariables("source")
        #expect(try await caches.value(for: "loginHeader_source", now: 100) == nil)

        try await cookies.put(.init(url: "host", cookie: "a=1"))
        try await cookies.put(.init(url: "source|example.com|/", cookie: "b=2"))
        #expect(try await cookies.get("host")?.cookie == "a=1")
        #expect(try await cookies.getOkHTTP().count == 1)
        try await cookies.deleteOkHTTP()
        #expect(try await cookies.getOkHTTP().isEmpty)
    }

    @Test func searchBookStoreUsesSourceEnableGroupAndOrderForChangeSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let sourceRepository = SQLiteBookSourceRepository(database: database)
        let repository = SQLiteSearchBookRepository(database: database)
        var firstSource = BookSource(bookSourceUrl: "https://one", bookSourceName: "一号")
        firstSource.bookSourceGroup = "文字"
        firstSource.customOrder = 20
        var secondSource = BookSource(bookSourceUrl: "https://two", bookSourceName: "二号")
        secondSource.bookSourceGroup = "文字,精选"
        secondSource.customOrder = 10
        try await sourceRepository.save([firstSource, secondSource])
        var one = SearchBook(bookURL: "https://one/book", origin: firstSource.bookSourceUrl, originName: "一号", type: 0, name: "书", author: "作者")
        one.latestChapterTitle = "第一章"
        one.originOrder = 20
        var two = SearchBook(bookURL: "https://two/book", origin: secondSource.bookSourceUrl, originName: "二号", type: 0, name: "书", author: "作者")
        two.coverURL = "cover"
        two.originOrder = 10
        try await repository.put([one, two])

        #expect(try await repository.first(name: "书", author: "作者")?.bookURL == two.bookURL)
        let changed = try await repository.changeSources(name: "书", author: "作", sourceGroup: "文字", key: "二号")
        #expect(changed.map(\.bookURL) == [two.bookURL])
        #expect(changed.first?.originOrder == 10)
        #expect(try await repository.enabledWithCover(name: "书", author: "作者").map(\.bookURL) == [two.bookURL])

        secondSource.enabled = false
        try await sourceRepository.save([firstSource, secondSource])
        #expect(try await repository.enabledWithCover(name: "书", author: "作者").isEmpty)
        #expect(try await repository.get(bookURL: two.bookURL) != nil)
    }

    @Test func storesConfigurationEntitiesWithOrderingAndKeys() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let repository = SQLiteConfigurationRepository(database: database)

        let toc = [
            TxtTocRule(id: 2, name: "后", serialNumber: 2),
            TxtTocRule(id: 1, name: "前", serialNumber: 1)
        ]
        try await repository.saveTxtTocRules(toc)
        #expect(try await repository.loadTxtTocRules().map(\.id) == [1, 2])

        let engines = [HttpTTS(id: 2, name: "B"), HttpTTS(id: 1, name: "A")]
        try await repository.saveHttpTTS(engines)
        #expect(try await repository.loadHttpTTS().map(\.name) == ["A", "B"])

        let subscriptions = [
            RuleSub(id: 2, name: "后", url: "2"),
            RuleSub(id: 1, name: "前", url: "1")
        ]
        var orderedSubscriptions = subscriptions
        orderedSubscriptions[0].customOrder = 2
        orderedSubscriptions[1].customOrder = 1
        try await repository.saveRuleSubs(orderedSubscriptions)
        #expect(try await repository.loadRuleSubs().map(\.id) == [1, 2])

        let keys = [
            KeyboardAssist(type: 1, key: "b", value: "B", serialNo: 2),
            KeyboardAssist(type: 0, key: "a", value: "A", serialNo: 1)
        ]
        try await repository.saveKeyboardAssists(keys)
        #expect(try await repository.loadKeyboardAssists().map(\.key) == ["a", "b"])

        var serverB = Server(id: 2, name: "B")
        serverB.sortNumber = 2
        var serverA = Server(id: 1, name: "A")
        serverA.sortNumber = 1
        try await repository.saveServers([serverB, serverA])
        #expect(try await repository.loadServers().map(\.id) == [1, 2])
    }

    @Test func decodesRssModelsAndPreservesDefaults() throws {
        let source = try JSONDecoder().decode(
            RssSource.self,
            from: Data(#"{"sourceUrl":"https://rss","sourceName":"订阅","enabled":"false","articleStyle":"2","loginUi":{"type":"input"}}"#.utf8)
        )
        #expect(source.enabled == false)
        #expect(source.articleStyle == 2)
        #expect(source.loginUi?.contains("input") == true)
        #expect(source.enableJs == true)

        let article = try JSONDecoder().decode(
            RssArticle.self,
            from: Data(#"{"origin":"https://rss","sort":"all","title":"文章","link":"/1","order":"42","read":1}"#.utf8)
        )
        #expect(article.order == 42)
        #expect(article.read)
        #expect(article.record(at: 100).record == "/1")
        #expect(article.star(at: 200).starTime == 200)
    }

    @Test func rssSourceRepositorySupportsGroupsSearchAndOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let repository = SQLiteRssSourceRepository(database: database)
        var later = RssSource(sourceUrl: "https://b", sourceName: "科技日报")
        later.sourceGroup = "资讯,科技"; later.customOrder = 20
        var earlier = RssSource(sourceUrl: "https://a", sourceName: "新闻")
        earlier.sourceGroup = "资讯"; earlier.sourceComment = "每日"; earlier.customOrder = 10
        try await repository.save([later, earlier])

        #expect(try await repository.all().map(\.sourceUrl) == ["https://a", "https://b"])
        #expect(Set(try await repository.groups()) == Set(["资讯", "科技"]))
        #expect(try await repository.inGroup("科技").map(\.sourceUrl) == ["https://b"])
        #expect(try await repository.search("每日").map(\.sourceUrl) == ["https://a"])
        try await repository.setEnabled(false, sourceURL: "https://a")
        #expect(try await repository.disabled().map(\.sourceUrl) == ["https://a"])
    }

    @Test func rssArticlesUseCompositeKeyIgnoreAppendAndGlobalReadLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let articles = SQLiteRssArticleRepository(database: database)
        let records = SQLiteRssReadRecordRepository(database: database)
        var old = RssArticle(origin: "one", sort: "all", title: "旧标题", link: "/same")
        old.order = 1
        try await articles.append([old])
        var duplicate = old; duplicate.title = "不应覆盖"; duplicate.order = 99
        var secondSort = old; secondSort.sort = "other"; secondSort.title = "另一分类"
        try await articles.append([duplicate, secondSort])

        #expect(try await articles.articles(origin: "one", sort: "all").first?.title == "旧标题")
        #expect(try await articles.articles(origin: "one", sort: "other").count == 1)
        try await records.insertIgnoringExisting(old.record(at: 100))
        var sameLinkOtherOrigin = RssArticle(origin: "two", sort: "all", title: "同链接", link: "/same")
        sameLinkOtherOrigin.order = 2
        try await articles.append([sameLinkOtherOrigin])
        #expect(try await articles.articles(origin: "two", sort: "all").first?.read == true)
        try await articles.clearOld(origin: "one", sort: "all", before: 2)
        #expect(try await articles.articles(origin: "one", sort: "all").isEmpty)
        try await articles.updateOrigin(from: "one", to: "renamed")
        #expect(try await articles.article(origin: "renamed", link: "/same", sort: "other")?.origin == "renamed")
    }

    @Test func rssStarsReplaceCompositeKeyAndSortNewestFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        let stars = SQLiteRssStarRepository(database: database)
        var firstArticle = RssArticle(origin: "one", sort: "all", title: "甲", link: "/1")
        firstArticle.group = "技术"
        var secondArticle = RssArticle(origin: "one", sort: "all", title: "乙", link: "/2")
        secondArticle.group = "生活"
        try await stars.save(firstArticle.star(at: 100))
        try await stars.save(secondArticle.star(at: 200))
        var replacement = firstArticle.star(at: 300); replacement.title = "甲更新"
        try await stars.save(replacement)

        #expect(try await stars.all().map(\.title) == ["甲更新", "乙"])
        #expect(Set(try await stars.groups()) == Set(["技术", "生活"]))
        try await stars.updateOrigin(from: "one", to: "renamed")
        #expect(try await stars.star(origin: "renamed", link: "/1")?.origin == "renamed")
        try await stars.remove(origin: "renamed", link: "/1")
        #expect(try await stars.all().map(\.link) == ["/2"])
    }

    @Test func defaultRssParserExtractsItemFieldsAndPrioritizesImages() throws {
        let xml = #"""
        <rss xmlns:media="urn:media" xmlns:content="urn:content"><channel>
          <item><title> 第一篇 </title><link> /one </link>
            <description><![CDATA[<p>x</p><img src="description.jpg">]]></description>
            <content:encoded><![CDATA[<img src="content.jpg">正文]]></content:encoded>
            <pubDate> today </pubDate>
          </item>
          <item><title>第二篇</title><link>/two</link>
            <media:thumbnail url="thumb.jpg" />
            <enclosure type="image/jpeg" url="enclosure.jpg" />
            <time>later</time>
          </item>
        </channel></rss>
        """#
        let result = try RSSDefaultParser.parse(sortName: "全部", xml: xml, sourceURL: "https://rss")
        #expect(result.nextURL == nil)
        #expect(result.articles.count == 2)
        #expect(result.articles[0].title == "第一篇")
        #expect(result.articles[0].image == "description.jpg")
        #expect(result.articles[0].content?.contains("正文") == true)
        #expect(result.articles[0].origin == "https://rss")
        #expect(result.articles[0].sort == "全部")
        #expect(result.articles[1].image == "enclosure.jpg")
        #expect(result.articles[1].pubDate == "later")
    }

    @Test func rssRuleParserExtractsFieldsReversesAndSupportsPageSentinel() async throws {
        var source = RssSource(sourceUrl: "https://rss.example/root/", sourceName: "规则源")
        source.ruleArticles = "-@CSS:.item"
        source.ruleTitle = "@CSS:h2@text"
        source.rulePubDate = "@CSS:time@text"
        source.ruleDescription = "@CSS:p@text"
        source.ruleImage = "@CSS:img@src"
        source.ruleLink = "@CSS:a@href"
        source.ruleNextPage = "PAGE"
        source.type = 2
        let body = #"""
        <div class="item"><h2>甲</h2><time>1</time><p>A</p><img src="a.jpg"><a href="/a">go</a></div>
        <div class="item"><h2>乙</h2><time>2</time><p>B</p><img src="b.jpg"><a href="/b">go</a></div>
        """#
        let report = try await RSSRuleParser().parse(
            sortName: "分类", sortURL: "https://rss.example/list?page=1",
            redirectURL: "https://rss.example/list?page=1", body: body, source: source
        )
        #expect(report.result.articles.map(\.title) == ["乙", "甲"])
        #expect(report.result.articles.first?.link == "https://rss.example/b")
        #expect(report.result.articles.first?.image == "https://rss.example/b.jpg")
        #expect(report.result.articles.first?.type == 2)
        #expect(report.result.nextURL == "https://rss.example/list?page=1")
    }

    @Test func rssJSONListWithoutWildcardExtractsIndividualArticles() async throws {
        var source = RssSource(sourceUrl: "https://rss.example", sourceName: "JSON 订阅")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        let report = try await RSSRuleParser().parse(
            sortName: "全部", sortURL: "https://rss.example/feed", redirectURL: "https://rss.example/feed",
            body: #"{"items":[{"title":"第一篇","link":"/one"},{"title":"第二篇","link":"/two"}]}"#,
            source: source
        )
        #expect(report.result.articles.map(\.title) == ["第一篇", "第二篇"])
        #expect(report.result.articles.map(\.link) == ["https://rss.example/one", "https://rss.example/two"])
    }

    @Test func rssSourceImporterSupportsObjectArrayManifestAndUpdateSelection() throws {
        let importer = RSSSourceImporter()
        let object = try importer.decode(Data(#"{"sourceUrl":"https://one","sourceName":"一"}"#.utf8))
        #expect(object.sources.map(\.sourceUrl) == ["https://one"])
        let array = try importer.decode(Data(#"[{"sourceUrl":"https://two","sourceName":"二"}]"#.utf8))
        #expect(array.sources.map(\.sourceUrl) == ["https://two"])
        let manifest = try importer.decode(Data(#"{"sourceUrls":["https://list/one.json","https://list/two.json"]}"#.utf8))
        #expect(manifest.subscriptionURLs.count == 2)

        var old = RssSource(sourceUrl: "https://one", sourceName: "旧"); old.lastUpdateTime = 100
        var newer = RssSource(sourceUrl: "https://one", sourceName: "新"); newer.lastUpdateTime = 200
        #expect(importer.defaultSelection(incoming: [newer], existing: [old]) == [true])
        let merged = try importer.merge([newer], into: [old], addGroup: "导入")
        #expect(merged.first?.sourceName == "新")
        #expect(merged.first?.groups.contains("导入") == true)
        #expect(try importer.decode(importer.encode(merged)).sources.first?.sourceUrl == "https://one")
    }

    @Test func rssSortResolverParsesSeparatorsAndFallback() async {
        var source = RssSource(sourceUrl: "https://rss", sourceName: "源")
        source.sortUrl = "新闻::/news&&科技::/tech\n生活::/life"
        let sorts = await RSSSortResolver().resolve(source)
        #expect(sorts.map(\.name) == ["新闻", "科技", "生活"])
        #expect(sorts.map(\.url) == ["/news", "/tech", "/life"])
        source.sortUrl = "invalid"
        #expect(await RSSSortResolver().resolve(source) == [.init(name: "", url: "https://rss")])
    }

    @Test func rssReadingPolicyHandlesDescriptionRuleAndMediaBranches() {
        let policy = RSSReadingPolicy()
        var source = RssSource(sourceUrl: "https://rss.example", sourceName: "源")
        var article = RssArticle(origin: source.sourceUrl, sort: "", title: "文章", link: "/post/1")
        article.description = "<p>摘要正文</p>"
        #expect(policy.mode(article: article, source: source) == .html(content: "<p>摘要正文</p>", baseURL: "https://rss.example/post/1"))
        article.description = nil
        #expect(policy.mode(article: article, source: source) == .web(url: "https://rss.example/post/1"))
        source.ruleContent = "@CSS:article@html"
        #expect(policy.mode(article: article, source: source, resolvedContent: "<article>正文</article>") == .html(content: "<article>正文</article>", baseURL: "https://rss.example/post/1"))
        article.type = 1
        #expect(policy.mode(article: article, source: source, resolvedContent: "../cover.jpg") == .image(url: "https://rss.example/cover.jpg"))
        article.type = 2
        #expect(policy.mode(article: article, source: source, resolvedContent: "video.mp4") == .video(url: "https://rss.example/post/video.mp4"))
    }

    @Test func rssHTMLAndResourcePoliciesApplyRulesInOrder() {
        let processor = RSSHTMLProcessor()
        #expect(processor.contentHTML("<head></head><body>x</body>", style: "body{color:red}").contains("<style>body{color:red}</style></head>"))
        #expect(processor.contentHTML("<p>x</p>", style: nil).hasPrefix("<style>\(RSSHTMLProcessor.appearanceStyle)</style><style>\(RSSHTMLProcessor.defaultStyle)</style>"))
        var source = RssSource(sourceUrl: "https://rss", sourceName: "源")
        source.startJs = "window.ready=true"; source.startStyle = "p{font-size:20px}"
        let start = processor.startHTML("<body><p>x</p></body>", source: source)
        #expect(start.contains("<script>window.ready=true</script></body>"))
        #expect(start.contains("<style>p{font-size:20px}</style>"))

        let blacklistWins = RSSResourcePolicy(blacklist: "https://ads,.*\\.track\\.js", whitelist: "https://ads/ok")
        #expect(!blacklistWins.allows("https://ads/ok"))
        #expect(!blacklistWins.allows("https://cdn.track.js"))
        #expect(blacklistWins.allows("https://cdn.example/a.js"))
        let whitelist = RSSResourcePolicy(blacklist: nil, whitelist: "https://safe,https://cdn\\.example/.*")
        #expect(whitelist.allows("https://safe/image"))
        #expect(!whitelist.allows("https://other/image"))
        #expect(blacklistWins.contentBlockerJSON()?.contains("\"type\":\"block\"") == true)
        #expect(whitelist.contentBlockerJSON()?.contains("ignore-previous-rules") == true)
    }

    @Test func rssStartPageUsesDedicatedStartJSAndStyle() throws {
        var source = RssSource(sourceUrl: "https://rss.example", sourceName: "源")
        source.startHtml = "<body><p>入口</p></body>"
        source.startJs = "window.started=true"
        source.startStyle = "p{color:green}"
        #expect(try RSSStartPageResolver().resolve(source) == .startHTML(content: "<body><p>入口</p></body>", baseURL: "https://rss.example"))
        source.startHtml = "@js:'<body>脚本入口</body>'"
        #expect(try RSSStartPageResolver().resolve(source) == .startHTML(content: "<body>脚本入口</body>", baseURL: "https://rss.example"))
        source.startHtml = nil
        #expect(try RSSStartPageResolver().resolve(source) == nil)
    }
}
