# 迁移任务清单

> 2026-11-07提交前清理：下文原始日志/xcresult已删除，路径保留为历史验证标识；状态依据清理前的实际结果，永久测试及fixture未删除。详见MIGRATION_PROGRESS顶部说明。

状态约定：待追踪 → 已定位 → 修复中 → 已修改/待验证 → 已验证（写明范围）。设备/真实服务验证单列；已验证不代表模块完整。

Android 路径以固定提交 `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c` 下 `app/src/main/java/io/legado/app/` 为根；Swift Core 文件位于 `Sources/LegadoCore/`，页面模型位于 `App/Features/`。本文件 ID 为持久标识，沿用初始化编号；代理内部编号以此表为准。

## 追加：搜索、阅读、书源具体 Bug（2026-11-07）

| ID | 优先级 | 线索 / Android 源码 | Swift 源码 | 问题与修复方案 | 状态 / 验证 |
| --- | --- | --- | --- | --- | --- |
| IMPORT-001 | P1 | Issue #267；ui/association/OnLineImportActivity.kt、AndroidManifest.xml | Import/RuleImportInput.swift、SourceLibraryModel.swift、LegadoApp.swift、Info.plist | importonline/auto/yuedu 书源一键导入在下载前被拒绝；补兼容别名、保留类型边界与预检，不误导入其他规则 | 已验证：别名/类型/混合/嵌套边界纳入521项全量通过；importonline→HTTP→预检→保存真实UI通过。yuedu解析及scheme静态校验通过，外部App唤起未专项实测 |
| SEARCH-008 | P1 | 独立发现；BookSource.kt respondTime 注释、CheckSourceService.kt 实测值、SearchModel.kt 30秒 | Search/BookSearchService.swift | 历史响应耗时误作超时，200ms记录把实际请求压为5秒；恢复单源30秒/多源8秒已有默认及用户覆盖 | 已验证：请求timeout断言由5秒失败转为30/8秒通过；521项全量通过。非零用户覆盖分支保留并核对调用链，本次未另改真实设置测试 |
| SEARCH-009 | P1 | 独立发现；model/webBook/SearchModel.kt mergeItems | Search/BookSearchService.swift | 合并键删除所有标点，把同作者 C++ 与 C# 不同书误并；保留标题内部有意义符号和已有作者装饰清理 | 已验证：不同符号书名/作者、纯符号、原装饰合并与全量521项通过 |
| SEARCH-010 | P1 | 独立发现；SearchModel.kt onSearchFinish / iOS UI 生命周期 | App/RootTabView.swift SearchView | 尾行先在搜索中显示，完成后不再触发onAppear，后页无法加载；记录已出现结果，在首轮及分页完成时重新检查末行 | 已验证：模拟器红测仅page1；修复后用新关键词实际请求page1→2→3，第二页→详情→目录→正文完整UI通过；并发/暂停/hasMore仍由模型保护 |
| CONTENT-004 | P1 | PR #355 为检查线索（仅Web补丁）；model/webBook/BookContent.kt、help/book/ContentProcessor.kt | Book/ContentSanitizer.swift 中 ChapterHTMLFormatter | 合法图片属性含 `>` 时标签提取提前截断，图片标记丢失；正确识别引号内字符 | 已验证：完整正文链、单双引号/大写/多行/懒加载/空src边界及521项通过；不声称补完网络文本内嵌图片渲染 |
| CONTENT-005 | P1 | 同上；help/book/ContentHelp.kt、ContentProcessor.kt | Book/ContentSanitizer.swift、Book/ChapterResegmenter.swift | 开启重新分段破坏图片属性空格/引号；仅对正文重排，原图片标记作为边界保留 | 已验证：开关两态、缓存/当前/邻章/连续窗、多图顺序、稳定性、显式净化规则回归及521项通过；不声称复现Issue #474的净化规则根因 |
| CONTENT-006 | P1 | 本次读者链补漏；ui/book/read/page/entities/TextChapter.kt 等图文排版链待继续追踪 | Reader/ReaderTextView.swift、Reader/ReaderScrollView.swift | 网络文本阅读当前以NSAttributedString(string:)展示，未发现内嵌img解码/布局链；图片标记完整不等于图片可显示。需独立处理资源请求头、缓存、尺寸、分页/连续布局与失败状态 | 已定位实现限制，未迁移/待验证；按用户收尾要求停止扩展，EPUB Readium显示链不在此限制中 |

红测证据：`.build/migration-audit/pr-bugs-red.log`（7个测试方法、6套件，预期失败）；`.build/migration-audit/pr-bugs-red-ui.log/xcresult`（一键导入预检未出现）；`pr-search-pagination-probe.log/xcresult`（第二页未出现）。绿测：`pr-bugs-swift.log` 521项/57套件，`pr-bugs-reader.log/xcresult` iOS29项，`pr-search-flow-green.log/xcresult` 1项完整UI链路。所有失败轮次保留，详见进度文档。

## 原两轮已修改

| ID | 优先级 | Android 源码 | Swift 源码 | 问题与已实施方案 | 状态 / 验证 |
| --- | --- | --- | --- | --- | --- |
| NET-001 | P1 | model/webBook/BookChapterList.kt:147 | Book/NetworkBookService.swift、RuleEngine/JavaScriptRuleEvaluator.swift | formatJs 原有编辑入口无执行；按去重后的目录顺序共享 gInt 执行，单项异常/无值/超限保留原名并诊断 | 已验证：目录脚本、状态共享、异常/无值/长度上限；执行中取消仍见 NET-009 |
| NET-002 | P1 | model/webBook/BookChapterList.kt:127、utils/StringExtensions.kt:76 | Book/NetworkBookService.swift | 修正 reverseToc、重复 URL 的保留顺序、isVolume/isVip/isPay 非空真假语义 | 已验证：目录反转/去重/真假值参数化回归 |
| NET-003 | P1 | model/webBook/BookInfo.kt:65 | Book/NetworkBookService.swift | canReName 未生效且字段上下文滞后；保留非空搜索书名作者，显式允许才改名，逐字段同步 book | 已验证：保持/改名/补空/详情字段上下文回归 |
| NET-004 | P1 | model/webBook/BookChapterList.kt:229 | Book/NetworkBookService.swift | 目录项未注入 chapter，变量与字段执行顺序不同；补全 name→url→updateTime→卷→VIP→付费链 | 已验证：章节字段依赖和变量顺序回归 |
| NET-005 | P1 | model/webBook/BookContent.kt:137 | Book/NetworkBookService.swift、Book/ChapterContentCache.swift | 文本副文从未进入阅读；拼入全文后统一替换，再取首分页标题；兼容旧分离缓存、避免导出重复 | 已验证：网络→缓存→TXT 一体回归、旧缓存兼容；媒体副文不在完成范围 |
| NET-006 | P1 | model/webBook/BookList.kt:67、171 | Book/NetworkBookService.swift、Search/BookSearchService.swift、Explore/BookExploreService.swift、Networking/LegadoURLBuilder.swift | 搜索详情 URL/空列表无详情回退；复用现有响应，保留已展开 POST 选项/变量，不重复执行 URL JS | 已验证：7 项详情回退回归、POST 重放、错误保留、重定向；响应缓存仍见 NET-010 |
| SHELF-001 | P1 | ui/main/MainViewModel.kt:130、data/entities/Book.kt:169 | Books/BookLibraryModel.swift、Settings/OtherSettingsView.swift | onlyUpdateRead 应为无未读章节才更新，替换曾阅读时间判断并修正文案 | 已验证：零章/单章/追平/未读边界回归 |
| SHELF-002 | P1 | ui/main/MainViewModel.kt:173 | Book/BookUpdateCoordinator.swift、Books/BookLibraryModel.swift、Books/BookDetailViewModel.swift | 保存失败错误报告成功；恢复旧目录/元数据、不累计成功数；详情及更新先在内存校验，确认当前书源后统一存储，避免未入架外键失败与旧请求覆盖新目录 | 已验证：目录/书架失败不误报、未入架 SQLite 预览、同 URL 换源后旧更新响应不写入 |
| SHELF-003 | P1 | model/webBook/BookChapterList.kt:157、305、help/book/BookHelp.kt | Book/BookUpdateCoordinator.swift、Books/BookDetailViewModel.swift | 重复章名跳首项、缓存重复键崩溃；选择最近同名章、字典冲突保留后值，详情恢复也采用最近索引 | 已验证：更新和详情恢复的同名章、重复缓存键回归 |
| SHELF-004 | P2 | ui/main/bookshelf/style1/books/BooksFragment.kt:221、data/entities/BookGroup.kt:56、ui/book/manage/BookAdapter.kt:179 | Books/BookLibraryModel.swift、App/RootTabView.swift、OtherSettingsView.swift | 六种分组排序/默认继承原有字段不执行；补全模型、持久化、分组配置和拖动自定义顺序入口 | 已验证：模型六模式/持久化/失败恢复；iOS 18.3 新设置/顺序编辑入口操作；真实拖动待专项验证 |
| SHELF-005 | P2 | ui/main/MainViewModel.kt:119、ui/main/bookshelf/style1/books/BooksFragment.kt:114 | Books/BookLibraryModel.swift、App/RootTabView.swift | 更新忽略当前组、取消继续请求；按组筛选、遵守禁更/本地/追更设置，取消停止队列 | 已验证：分组过滤、取消停止队列回归 |
| SHELF-006 | P2 | data/dao/BookDao.kt:58 | Books/BookLibraryModel.swift | 无效历史分组位使未分组书永久隐藏；按当前有效分组掩码求交 | 已验证：无效分组位回归 |
| SHELF-007 | P2 | ui/main/bookshelf/BookshelfViewModel.kt（响应式数据更新） | Books/BookLibraryModel.swift | 导入/生命周期 load 的旧结果可覆盖进行中的保存；为加载加入代际和保存等待保护 | 已验证：延迟/重叠加载、并发进度/分组保存回归 |
| SEARCH-001 | P1 | model/analyzeRule/AnalyzeUrl.kt:133 | Explore/BookExploreService.swift | 发现遗漏 JS/登录请求头；复用公共解析器和后台规则执行器 | 已验证：动态/登录请求头回归 |
| SEARCH-002 | P1 | model/webBook/BookList.kt:211 | Search/BookSearchService.swift、Explore/BookExploreService.swift | 字段顺序和 book/page/变量上下文不全；按原版顺序解析、详情链接最后处理 | 已验证：搜索/发现字段依赖及变量隔离回归 |
| SEARCH-003 | P2 | model/webBook/SearchModel.kt:188 | Search/BookSearchService.swift | 同相关度结果缺少来源数排序；来源数降序并保留平局稳定性 | 已验证：来源数排序和稳定性回归 |
| SEARCH-004 | P1 | model/webBook/SearchModel.kt:69 | Search/SearchViewModel.swift | 无模板标记的 @js:/<js> URL 被误认为不能翻页；增加动态规则识别 | 已验证：两种 JS URL 第 2 页回归 |
| SEARCH-005 | P1 | ui/book/explore/ExploreShowViewModel.kt:101 | Explore/ExploreSourceViewModel.swift、Explore/ExploreView.swift | 发现失败跳页且不能重试，A→B→A 过期请求覆盖；版本保护、失败保留页号和列表、显式重试 | 已验证：同页重试、A→B→A、旧分页任务 3 个并发回归；故障服务真实 UI 待专项验证 |
| RSS-001 | P1 | model/rss/Rss.kt:98 | RSS/RSSService.swift | 正文丢失文章请求 JS 生成变量；合并 response.requestVariables 与原文变量 | 已验证：文章请求变量回归；RSS UI 全流程结果见进度文档 |
| RSS-002 | P1 | model/rss/RssParserByRule.kt:64 | RSS/RSSRuleParser.swift | nextPage 写变量未传文章；采用更新后的共享变量并逐文章隔离 | 已验证：分页共享/文章隔离回归；RSS UI 全流程结果见进度文档 |
| RSS-003 | P1 | model/rss/RssParserByRule.kt getElements→getItem | RSS/RSSRuleParser.swift | 正则捕获组被当成独立文章展开；保留整组、倒序按文章进行 | 已验证：多捕获组及倒序回归；真实第三方 RSS 源待验证 |
| SWITCH-001 | P1 | ui/book/info/BookInfoViewModel.kt changeTo、ui/book/changesource/ChangeBookSourceViewModel.kt | Book/BookSourceSwitchService.swift、Books/BookLibraryModel.swift、Persistence/{BookRepository,LegadoDatabase}.swift、SourceSwitchView、BookDetailView、ReaderView | 换源验证提前写目录，同 URL 可破坏旧目录，书架失败仍切 UI；改纯验证，SQLite 书籍+目录单事务，文件仓库失败恢复，成功才切 UI；提交时禁取消、未入架预览不自动入架 | 已验证：同/不同 URL 成功失败、SQLite 事务回滚、文件补偿失败诊断、并发保存、自动提交 gating、迟到详情；取消入口 UI 通过；真实书源换源待验证 |
| SWITCH-002 | P1 | help/book/BookHelp.kt:500、data/entities/Book.kt:398 | Book/BookSourceSwitchService.swift | 纯比例回退跳错章、数字写法和重复章名失配；增加近邻纯标题/章节数匹配，无匹配保留索引，保留 iOS 精确标题能力和安全字符偏移 | 已验证：中文/全角/阿拉伯数字、重复章名、空目录和极端索引回归 |
| SWITCH-003 | P1 | data/entities/Book.kt migrateTo、model/webBook/BookChapterList.kt | Book/BookSourceSwitchService.swift | 换源加载目录前未携带 reverseToc；先传当前 readConfig 再生成目录和匹配进度 | 已验证：候选目录继承 readConfig 回归 |


## 已定位的后续迁移项（状态以各行验证范围为准）

| ID | 优先级 | Android 源码 | Swift 源码 | 问题 / 下一步方案 | 状态 / 验证 |
| --- | --- | --- | --- | --- | --- |
| NET-007 | P1 | model/webBook/WebBook.kt:270 | Domain/BookSourceRules.swift、Book/BookUpdateCoordinator.swift | preUpdateJs 原有字段/入口无执行；接入详情补全、同步refreshTocUrl/reGetBook、字段/变量回写与地址变更协调保存 | 已验证：65 项更新/缓存/书架/详情定向回归；新增完整脚本桥、同步刷新/精确重搜、身份变更原子提交及失败保持旧状态；已纳入第二轮完整508项及iOS29项回归 |
| NET-008 | P1 | model/webBook/WebBook.kt:415 | Book/NetworkBookService.swift、Networking/HTTPClient.swift | webJs 返回值/空值重试、sourceRegex 观察、POST HTML、异常取消接入；UA用于整个WK实例 | 已验证：完整508项、iOS29项（含4项真实WK及UA）通过；资源观察有明确平台边界 |
| NET-009 | P1 | 仓库根 modules/rhino/src/main/java/com/script/rhino/{RhinoScriptEngine.kt:327,340,RhinoContext.kt} | RuleEngine/JavaScriptRuleEvaluator.swift、RuleExecutionWorker | Android 每万条指令观察取消；iOS 已补规则分支/native调用/提交边界取消，但不能保证复杂JS或单次正则执行中取消/硬超时；需统一引擎级可中断方案 | 已定位平台适配差距；不声称超时已解决 |
| NET-010 | P2 | model/webBook/WebBook.kt:198、296、395 | NetworkBookService.swift、SearchBook.swift | 缺 infoHtml/tocHtml 缓存复用，打开详情仍重复请求；设计响应生命周期/失效策略后迁移 | 已定位，未实现/未验证 |
| NET-011 | P1 | model/webBook/BookContent.kt:136 | NetworkBookService.swift、Reader/* | 音视频副文 URL 下载及歌词/弹幕处理缺失，当前只保留原值；须结合完整媒体模块迁移 | 已定位，未实现/未验证 |
| NET-012 | P2 | model/webBook/BookContent.kt:183 | NetworkBookService.swift、ReaderViewModel.swift、BookChapterRepository.swift | 正文 title 仅临时显示，未回写章节仓库/标题图；需明确标题来源和缓存更新事务 | 已定位，未实现/未验证 |
| NET-013 | P1 | ui/book/read/ReadBookActivity.kt:1289、model/SourceCallBack.kt | Reader/*、RuleEngine/JavaScriptRuleEvaluator.swift | payAction/callBackJs 缺少完整入口/业务桥接；先追踪认证、操作结果和生命周期 | 已定位，未实现/未验证 |
| SHELF-008 | P1 | data/entities/Book.kt、data/dao/BookDao.kt | Domain/LibraryModels.swift、BookLibraryModel.swift | Android type 是位标志，iOS 存 sourceType；音视频/更新失败/临时书系统分组未等价，禁止直接套掩码 | 已定位，需兼容旧存储方案，未执行破坏性迁移 |
| SHELF-009 | P2 | ui/main/MainViewModel.kt、data/entities/Book.kt simulatedTotalChapterNum | BookUpdateCoordinator.swift、BookLibraryModel.swift | 模拟阅读、更新失败状态/回调等仍缺失；与 NET-007/013 协同检查 | 已定位，未实现/未验证 |
| SEARCH-006 | P1 | ui/main/explore/ExploreAdapter.kt（动态分类控件及 infoMap） | Domain/ExploreKind.swift、Explore/ExploreSourceViewModel.swift | text/button/select 等动态发现控件被过滤，只支持 URL；需要实际状态/变量/请求交互迁移 | 已定位，未实现/未验证 |
| SEARCH-007 | P2 | help/book/BookHelp.kt formatBookName/formatBookAuthor、model/webBook/BookList.kt | BookSearchService.swift、BookExploreService.swift、NetworkBookService.swift | 书名/作者/字数格式化尚未逐项对齐；不能只用名称清理猜测等价 | 待完整追踪/未验证 |
| RSS-004 | P1 | model/analyzeRule/AnalyzeRule.kt evalJS | RuleEngine/RuleEngine.swift、JavaScriptRuleEvaluator.swift、RSSService.swift | 补真实rssArticle字段/变量对象，贯通请求与正文规则；持久化绑定原条目身份避免串改 | 已验证：101 项定向与 1 项异常回归；真实文章/变量对象、请求→正文→持久化贯通，原条目主键固定；已纳入第二轮完整508项及iOS29项回归 |
| AUDIT-REMAINING | P1 | 见 MIGRATION_AUDIT.md 对应表 | 见 MIGRATION_AUDIT.md 对应表 | 本地格式、媒体、书源登录、订阅、备份/远程服务、全文规则引擎、设置等还需真实调用链审计 | 未完成，不属于本轮“已验证”范围 |

## 第二轮追加条目

| ID | 优先级 | Android 源码 | Swift 源码 | 问题与方案 | 状态 / 验证 |
| --- | --- | --- | --- | --- | --- |
| CONTENT-001 | P2 | help/book/ContentProcessor.kt:111 | Book/ContentSanitizer.swift | 重复标题仅整行匹配；补前缀删除，保留同行正文；空标题不能吞标点段 | 已验证：完整508项/iOS29项通过；内容/阅读器/替换回归覆盖 |
| CONTENT-002 | P1 | help/book/ContentHelp.kt reSegment、ContentProcessor.kt:138 | Book/ChapterResegmenter.swift、Book/ContentSanitizer.swift、Reader/ReaderViewModel.swift | 迁移断行合并、引号修正、词典、对话和长段切分，消费每书 reSegment 并接阅读设置；固定随机种子防分页漂移 | 已验证：原始Kotlin实跑128样本与Swift一致，完整508项及iOS29项通过；新开关在分页/连续阅读UI通过（实际开关控件点击） |
| LOCAL-001 | P1 | model/localBook/TextFile.kt getTocRules、ui/book/import | LocalBook/LocalBookService.swift、Books/BookLibraryModel.swift | 导入实时读取管理页启用规则；现有 legacy_imports 标记一次性默认初始化，明确全停用/删空不复活默认 | 已验证：本地导入/规则持久化定向 53 项通过；完整508项及iOS29项通过 |
| LOCAL-002 | P1 | model/localBook/TextFile.kt 标题脚本 | LocalBook/LocalBookService.swift | 空标题跳过匹配并保留正文，隐藏前言保留全文 intro，规则只按首次分隔符拆脚本 | 已验证：同批 53 项含正文回读/隐藏前言/空标题；完整508项及iOS29项通过 |
| LOCAL-003 | P2 | model/localBook/TextFile.kt prevLength | LocalBook/LocalBookService.swift | prevLength 使用上一有效章的长度，跳过标题时 index/seekPos 不误推进 | 已验证：同批 53 项含脚本上下文；完整508项及iOS29项通过 |
| LOCAL-004 | P1 | model/localBook/TextFile.kt 编码与有效性 | LocalBook/LocalBookService.swift | 修复编码探测/跨块多字节边界，空/BOM-only 文件拒绝，目录/正文执行 maxFileSize 校验 | 已验证：同批 53 项含 UTF-8/UTF-16LE/BE/GB18030/Big5、180万字节回读及emoji边界；完整508项及iOS29项通过 |

| CONTENT-003 | P1 | ui/book/read/ReadBookActivity.kt、data/entities/Book.kt 的单书配置 | Books/BookLibraryModel.swift、Reader/ReaderView.swift | 阅读设置整本旧快照覆盖最新元数据并自动入架预览；改为只更新当前 URL+origin 对应记录的单个配置字段 | 已验证：完整508项/iOS29项；覆盖四入口模型保存/预览/失败分支，物理音频和故障弹窗未专项UI测试 |
| RSS-005 | P1 | model/analyzeRule/RuleDataInterface.kt、help/RuleBigDataHelp.kt、data/entities/BaseRssArticle.kt | RSS/RSSVariableStore.swift、RuleEngine/JavaScriptRuleEvaluator.swift、RSSService.swift | 大变量独立持久化及 10000 UTF-16 阈值迁移；每文章批次原子保存，区分脚本提交与文章数据库事务 | 已验证：nil规范为JS null、10000阈值、IO失败与事务边界，完整508项/iOS29项通过；无schema迁移 |
| LOCAL-005 | P1 | ui/book/toc/TocActivity.kt:173、TocViewModel.kt:38、model/ReadBook.kt:976 | LocalBook/LocalBookService.swift、Books/BookLibraryModel.swift、Books/LocalBookDetailView.swift | 已入架 TXT 缺少选择规则/重新分章；保留文件及书籍身份，重建目录并按正文位置恢复进度，失败回滚 | 已验证：空规则、UTF16 BOM、卷标/正文、失败/取消与位置映射，完整508项/iOS29项通过；新增TXT导入/重建与EPUB完整UI流程通过 |

| NET-014 | P1 | model/analyzeRule/AnalyzeUrl.kt:445、869 | Networking/HTTPClient.swift、RuleEngine/JavaScriptRuleEvaluator.swift | URL仅提供webJs时错误启用WebView；统一HTTP/dataURI/stream/嵌套AJAX仅依据显式webView，保留bodyJs | 已验证：HTTP/dataURI/stream/嵌套AJAX回归，完整508项/iOS29项通过 |
| RSS-006 | P1 | model/analyzeRule/AnalyzeRule.kt:290–360 | RuleEngine/JavaScriptRuleEvaluator.swift | 嵌套规则原先捕获旧context且丢弃修改；复用同步核心，补四种提取入口、最新状态、逐项替换、取消与异常传播 | 已验证：大栈有限线程池、异常重入保护、逐项替换/取消/嵌套回写，定向101项及完整508项/iOS29项通过；只读元素接口有限 |

| RULE-001 | P2 | model/analyzeRule/AnalyzeRule.kt getElement/getElements、Jsoup 元素调用 | RuleEngine/JavaScriptRuleEvaluator.swift 元素包装 | 已补读取接口，完整可变DOM/全部Jsoup方法尚未迁移；逐方法追踪实际书源用法后扩展，不能用现有包装宣称完整Jsoup等价 | 已定位/未实现部分/未验证 |
| LOCAL-006 | P1 | model/localBook/LocalBook.kt getChapterList/importArchiveFile | LocalBook/LocalBookService.swift | Android PDF/MOBI/UMD/压缩包格式没有对应完整iOS入口和解析链，当前仅TXT/EPUB；需独立设计及样本验证，不属于iOS系统不可能实现的限制 | 已定位/待专项迁移 |
