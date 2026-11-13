# Android → iOS 迁移审计

> 提交前清理说明（2026-11-07）：本次生成的原始测试日志、xcresult、附件、PR快照及临时Kotlin执行目录已按用户要求删除。下文相关路径仅供追溯曾执行的验证；测试结论见MIGRATION_PROGRESS，永久回归测试及Fixtures保留。Android只读副本仍在原路径。

## 基线与恢复方式

- 本轮日期：2026-11-07（Asia/Shanghai）。状态：**前两轮及本次搜索/阅读/书源 Bug 修复均已按用户要求收尾；全项目审计仍未完成**。
- Android：<https://github.com/Luoyacheng/legado-E>，`main`，固定提交 `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c`。
- 只读副本：`.build/migration-audit/android-reference`；若被清理，应重新获取上述提交，不能默认为最新 main 与本轮相同。旁边 Flutter 项目的参考源码未作为本轮基线。
- iOS：当前 `legado-ios` 工作区，位于父级 CodeStore Git 仓库。本轮开始时 iOS 目录无已有修改；父仓库其他项目的修改不属于本任务。
- 未找到适用于当前 iOS/Android 目录的 AGENTS.md。Android 原始源码不得修改。
- 恢复时先读本文件、MIGRATION_TODO.md、MIGRATION_PROGRESS.md，再检查当前 diff 和关键测试；禁止把“文件存在”“模型字段存在”“编译成功”当成完整迁移。

## 2026-11-07 追加：按 PR 线索排查搜索、阅读、书源 Bug

用户收窄目标为以上三类 Bug，并要求从 PR 寻找线索。通过 GitHub API 分三页枚举 `Luoyacheng/legado-E` 全部 211 条 PR 元数据（含关闭项，非全部代码审查），快照保存在 `.build/migration-audit/pr-bug-candidates-20261107.json`。实际检查相关 PR 的 diff/讨论，再沿当前 iOS 调用链核对；不将 PR 标题或 Android 用户反馈直接认定为 iOS Bug。

- [PR #355](https://github.com/Luoyacheng/legado-E/pull/355)：已合并，只改 `modules/web/src/components/ChapterContent.vue` 图片提取正则。启发检查 iOS `ChapterHTMLFormatter` 与 `ContentSanitizer` 的图片标记完整性；当前 iOS 问题由独立回归验证，不是照搬该补丁。
- [PR #451](https://github.com/Luoyacheng/legado-E/pull/451)：Android `Book.addDelTag` 位运算和 Ruby 相邻文本处理；当前 iOS 无对应错误赋值，EPUB 遍历已跳过 rt/rp，并有“字形”回归。未认定为 iOS 待修 Bug。
- [PR #488](https://github.com/Luoyacheng/legado-E/pull/488)：尚未合并，作者设备验证未勾选；Android SVG 位图缩放与 iOS Readium 主渲染不同，不套用。
- [Issue #474](https://github.com/Luoyacheng/legado-E/issues/474)：作者澄清图片 URL `~` 被改为 `-` 来自净化规则，不声称 iOS 存在相同自动替换。
- [Issue #481](https://github.com/Luoyacheng/legado-E/issues/481)：缺复现链接/日志，不能推断导入数量限制；继续查阅导入反馈，在 [Issue #267](https://github.com/Luoyacheng/legado-E/issues/267) 找到真实 `importonline` 一键链接格式，与 Android `ui/association/OnLineImportActivity.kt`、`AndroidManifest.xml` 对照。
- 搜索：未找到可直接采用的搜索修复 PR；由本地检查定位 `respondTime` 超时混用、标题符号合并和尾行可见时分页触发缺口。分别对照 Android `SearchModel.kt`、`BookSource.kt`、`CheckSourceService.kt`，按独立发现记录。

本次不展开新模块，不升级依赖，不修改 Android、数据库结构或真实用户数据。状态和实际验证以 TODO/PROGRESS 的追加记录为准。

## 原两轮目录与依赖核对

Android `settings.gradle` 实际包含 `app`、`modules:book`、`modules:rhino`；另有 `modules/web` 的网页管理端源码及 app 内打包网页资源。`app/src/main/java/io/legado/app` 按 ui、model、data、help、service、web、lib、utils 分层。已枚举完整文件树，ui 内包括 main（书架/发现/RSS/我的）、book（搜索/详情/阅读/换源/漫画/音频/导入/分组等）、rss、replace、config、dict、file、login 等；service 包括缓存、导出、下载、音视频、HTTP/系统朗读和 Web 服务。

Android `app/build.gradle` 使用 Room、Kotlin 协程、OkHttp/Cronet、Jsoup/JsonPath/XPath、Rhino、Media3、视频播放器、WebView、libarchive、ZXing、中文转换、加密与编辑器等。依赖存在只说明原版技术边界，不能据此推断 iOS 等价能力。

iOS `Package.swift`：LegadoCore（Domain、Networking、RuleEngine、Book、Search、Explore、RSS、LocalBook、Persistence、Import、Debugging、TTS）与 LegadoAppModels；SwiftSoup 2.13.5、Kanna 6.1.0、ZIPFoundation 0.9.20，系统 JavaScriptCore/CryptoKit/SQLite。`App` 是 SwiftUI 入口和功能界面，Xcode 工程另含阅读器/界面测试。实际入口为 RootTabView 的书架、发现、统计、我的，RSS 位于功能入口中；正文阅读、EPUB、朗读采用独立实现。

## 功能对应与检查深度

下表“待审计”表示只核对结构/入口，未证实功能覆盖；“链路审计中”也不等于整个模块完成。

| 范围 | Android 源码（相对于 app/src/main/java/io/legado/app） | iOS 源码 | 当前深度 |
| --- | --- | --- | --- |
| 搜索/发现 | ui/book/search、ui/main/explore、model/webBook/{SearchModel,BookList,WebBook} | Search/BookSearchService、Explore/BookExploreService、SearchViewModel、ExploreView | 本轮链路审计/修复已验证部分分支；剩余见 SEARCH-* |
| 详情/目录/正文 | model/webBook/{BookInfo,BookChapterList,BookContent}、data/entities/rule | Book/NetworkBookService、JavaScriptRuleEvaluator、BookDetailViewModel、ReaderViewModel | 本轮文本链路已验证；剩余见 NET-* |
| 书架/分组/更新 | ui/main/MainViewModel、ui/main/bookshelf、ui/book/group、data/dao/{BookDao,BookGroupDao} | BookUpdateCoordinator、BookLibraryModel、RootTabView | 本轮书架链路已验证；剩余见 SHELF-* |
| 换源/阅读位置 | ui/book/changesource、help/book/BookHelp、data/entities/Book.migrateTo | BookSourceSwitchService、SourceSwitchView、ReaderViewModel、BookDetailViewModel | 本轮换源链路已验证；真实书源仍待专项验证 |
| 净化/内容排版 | help/book/{ContentProcessor,ContentHelp}、data/dao/ReplaceRuleDao | ContentSanitizer、ReplaceRuleTester、ReaderViewModel | ContentProcessor/ContentHelp 全算法与阅读/朗读链已追踪，第二轮实施验证中 |
| 规则引擎/网络 | model/analyzeRule、help/source、help/http、help/rhino | RuleEngine/*、Networking/* | 仅沿本轮功能调用检查；未全面审计 |
| 书源/登录/订阅 | ui/book/source、ui/login、model/RuleUpdate | Sources/*、Rules/RuleSubscriptionModel、Import/* | 待审计 |
| 本地书/文件/导出 | model/localBook、ui/book/import、service/ExportBookService | LocalBook/*、FileManagementView、LocalBookDetailView、EPUBReaderView | TXT 导入/规则/编码链第二轮修复；重新分章在实施，其他格式仍待审计 |
| RSS | model/rss、ui/rss、ui/main/rss | RSS/*、Features/RSS/* | 列表/正文/文章变量桥已追踪；大变量存储第二轮实施，其他入口待审计 |
| 阅读器/漫画/媒体/朗读 | model/{ReadBook,ReadManga,AudioPlay,VideoPlay,ReadAloud}、ui/book/read、ui/book/manga、service/* | Reader/*、TTS/* | 待审计；不能用文字阅读器覆盖证明漫画/音视频完成 |
| 阅读记录/书签/统计 | data/dao、ui/book/read、ui/book/bookmark | Activity/*、ReadingActivityRepository、ReaderViewModel | 待审计 |
| 备份/WebDAV/远程书库/Web服务 | help/AppWebDav、help/storage、model/remote、web、ui/book/import/remote | ConfigurationRepositories、LegadoDatabase、Settings/入口 | 待追踪；未判定完成 |
| 设置/词典/主题/系统能力 | ui/config、ui/dict、help/config、AndroidManifest.xml | OtherSettingsView、ReaderAppearance、Compatibility、Info.plist | 待审计，平台限制须单列 |

## 独立补漏规则

每轮代码完成后重读原版入口→业务模型→持久化调用，检查修复是否覆盖错误/取消/边界分支；核对 TODO 的未处理事项以及只有字段/编辑入口却未消费的配置。原版缺陷不应机械复制，保留差异时须写明原因和验证。全项目未完成前不得写“全部完成”。

## 本轮实际追踪范围（独立补漏后）

- 网络：BookList 的搜索详情回退、BookInfo 改名开关及字段赋值、BookChapterList 多页/反转/去重/标志/formatJs、BookContent 分页/副文/替换/标题；Swift 对照 NetworkBookService、BookSearchService、BookExploreService、LegadoURLBuilder、JavaScriptRuleEvaluator、ChapterContentCoordinator、LocalFileService、ReaderViewModel。实际沿正文→缓存→阅读/TTS输入→TXT导出核对副文；未把媒体副文标记已迁移。
- 书架：MainViewModel.updateToc、BooksFragment 的组内操作、BookGroup/BookDao 查询；Swift 对照 BookUpdateCoordinator、BookLibraryModel、RootTabView、OtherSettingsView、SQLite/File repositories。独立补漏检查持久化失败、重复章名、无效分组位、取消、load/save 交错和预览书籍外键约束。
- 换源：ChangeBookSourceViewModel、BookInfoViewModel.changeTo、Book.migrateTo、BookHelp.getDurChapter；Swift 追踪 SourceSwitchView→prepareSwitch→BookLibraryModel 提交→Reader/Detail 状态，包含自动换源、同 URL、未入架预览、保存失败和取消。精确标题选择最近出现项；按章节数字/纯标题匹配并回退旧索引，避免按目录总长度变化跳过未读章节。
- 搜索/发现：SearchModel.mergeItems、BookList 字段解析、AnalyzeUrl 请求头、ExploreShowViewModel 成功翻页时机；Swift 搜索分页、合并排序、发现 headers/page/book 变量、页面请求代际。抽离 ExploreSourceViewModel 便于实际受控异步回归，原 UI 架构不变。
- RSS：Rss.getContent、RssParserByRule.getElements/getItem/nextPage 共享 ruleData；Swift RSSService、RSSRuleParser、RSSLibraryModel、RSSWebReaderView 相关调用。修复文章请求变量、分页变量传播和捕获数组，不代表整个 RSS 规则桥完成。
- 持久化：检查 LegadoDatabase 的 books→chapters 外键及现有 transaction；新增换源单事务，无 schemaVersion 变动、没有运行用户数据库清理或破坏性迁移。

### 保留的合理 iOS 差异与平台限制

- 换源对重复标题取最近位置，保留跨目录精确标题匹配；数字/纯标题无法确认时保留旧索引并重置字符偏移，避免复制原版未知章节号误匹配的边界缺陷。
- JavaScriptCore 静态规则拒绝和长度限制不能替代执行中取消/硬超时。Android Rhino 的指令观察器已定位；NET-009 未解决，禁止将普通脚本回归通过表述为无限脚本安全验证。
- 文本副文完整进入正文；媒体副文下载/歌词/弹幕仍属 NET-011。DRM/后台执行/系统按钮等其他平台边界尚需模块审计，未伪造等价能力。
- 新旧 URL 相同且存在请求选项时保留可重放 POST；普通 GET 和观察到最终 URL 不同的重定向使用最终 URL。HTTPResponse 尚无重定向状态链，307/308 保留方法的精确策略仍待补充证据。
- 测试 fixtures 仅用于可重复验证，不向产品内置书源或替代真实业务逻辑。未运行跨站真实书源全面验证。

## 第二轮追加的真实源码范围

- 更新前链：WebBook.kt 的详情补全、preUpdateJs 专用 refreshTocUrl/reGetBook，AnalyzeRule 书籍脚本字段；Swift BookUpdateCoordinator→NetworkBookService→JS/native请求→BookLibraryModel.commitPreparedUpdate→详情/书架阅读入口及ChapterContentCache。
- TXT：TextFile.kt 的 getTocRules、标题脚本、前言、prevLength、分块读取，EncodingDetect.kt，TocActivity/TocViewModel；Swift LocalBookService、SQLite TXT规则存储、管理页、BookLibraryModel导入与LocalBookDetailView重新分章。Android其余本地格式尚未因此通过。
- RSS：AnalyzeRule.kt:794–841、RuleDataInterface、RssArticle/BaseRssArticle、Rss.kt、RssParserByRule.kt、ReadRssViewModel；Swift真文章对象、字段/变量修改与身份、重定向URL、嵌套请求、独立大变量。嵌套ajax的RSS上下文保留为iOS现有桥完整性改进，Android原代码未向该嵌套接口传rssArticle。
- 内容：ContentProcessor.kt 重复标题→重排→替换顺序，完整ContentHelp.kt；Swift ContentSanitizer、新ChapterResegmenter、ReaderViewModel全部正文/邻章/连续阅读/下一章朗读路径及ReaderView设置。实际运行原Kotlin作120样本差分，长段随机采用稳定种子，未称随机切分位置逐次相同。

第二轮独立补漏补充：TXT标题脚本返回空串时仍保留java.putVolume生成的卷标，后续index/prevTitle以实际目录为准；iOS保持卷标身份，不机械复制原版可能把卷标转普通章的边界。Reader设置只更改单字段并在失败时提示当前会话未持久化；净化/重排停止旧朗读，旧HTTP预读结果按代际丢弃。规则桥复核扩展到getString/getStringList/getElement/getElements、Boolean unescape重载、列表替换、嵌套变量回写和取消。元素对象仅支持已实现的真实HTML片段与常用读取接口，不等价于全部Jsoup API。

## 收尾依据与恢复边界

用户在本次执行末尾明确要求收尾，停止扩展新模块。最终验证结果以MIGRATION_PROGRESS末尾收尾检查点为准，未处理项以MIGRATION_TODO为准。功能与Android源码的对应关系、iOS合理适配和平台/实现限制分别保留；不能把新增页面、字段或全部自动化测试通过，解释为原版全部功能已经完成迁移。
