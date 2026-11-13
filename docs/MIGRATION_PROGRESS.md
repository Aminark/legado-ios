# 迁移进度与验证证据

> 提交前清理（2026-11-07）：按用户要求删除本次临时日志、xcresult、截图/附件、PR元数据快照、Kotlin对照执行临时目录及可再生编译产物/Python缓存，释放约2.14 GiB。下文原始日志路径为历史验证记录，现已清理；测试结论、失败经过及可重跑的测试/fixture仍保留。清理前后对267个已有及待提交项目文件做SHA-256核对，内容一致；随后仅补充本清理说明。Android只读副本、依赖源码缓存和此前的发布/设计/补丁资料保留。此次仅清理文件，未重新运行测试。

## 最新追加：搜索、阅读、书源 Bug 修复（2026-11-07，已按用户要求收尾）

用户反馈前两轮对使用体验的价值不明显，将当前范围收窄到搜索、阅读、书源，并明确从 PR 寻找问题。已枚举参考仓库全部 211 条 PR 的元数据，审查相关改动及讨论，按证据区分 PR 线索、Issue 反馈和 iOS 独立发现。未恢复全项目功能扩展。

本次先添加真实失败回归，再改生产代码：

- `pr-bugs-red.log`：7 个测试方法、6 个套件失败，覆盖一键导入下载前拒绝、respondTime 错当超时、C++/C# 不同书合并、合法图片属性截断、重分段改坏图片属性；保留失败日志，不算通过。
- `pr-bugs-red-ui.log/xcresult`：iOS 18.3 独立模拟器实跑，一键导入后预检未出现，测试失败；后续将继续验证分页和阅读。
- `pr-bugs-swift.log`：修复后完整 `swift test --disable-sandbox` **521 项、57 套件通过**。覆盖新增 13 项及既有模型/核心回归；没有把这一数量当作第三方书源覆盖率。
- `pr-search-pagination-probe.log/xcresult`：一键导入修复后，实际 UI 能导入并显示第一页，但第二页未出现；fixture 日志只有 page=1。随后修改 SearchView，记录已出现的结果，在首轮/分页完成时重新检查末行，保留模型暂停/并发/hasMore 保护。
- `pr-search-flow-verified.log/xcresult` **实际失败**：重复运行时，未变更书源默认未选中，测试点击了禁用导入按钮并留在预检。依据导出 UI 层级（`pr-search-flow-attachments`）修正测试为显式全选、确认按钮可用并等待预检关闭；未修改生产导入选择行为来绕过失败。后续结果见最终验证记录。
- `pr-search-flow-final.log/xcresult` **实际失败**：已加载第二页（HTTP 日志 page=1→2→3），点击时封面占位与标题两个同名 StaticText 导致测试定位歧义。改为明确首个匹配，并使用每次新关键词避免旧缓存掩盖分页；不把这次部分成功算作完整链路通过。
- 新增 `scripts/fixtures/search-flow-server.py` 与 `LegadoSearchFlowUITests` 仅用于合成 HTTP 端到端回归，不是第三方书源实测，也不是生产 Mock。
- 图片修复仅保证正文标记/地址在格式化和重分段中完整；当前网络文本阅读器未实现内嵌图片解码，不将本次说成“所有图片已可显示”。用户明确配置的净化规则仍可修改图片地址，保留相应回归。

最终验证：

| 检查 | 本次实际结果 | 证据（`.build/migration-audit/`） |
| --- | --- | --- |
| SwiftPM完整测试 | 521项、57套件通过 | `pr-bugs-swift.log` |
| Xcode/iOS阅读器回归 | 构建成功，29项通过 | `pr-bugs-reader.log/xcresult` |
| iOS完整业务链 | 1项通过：HTTP一键导入→预检/保存→新关键词→第1/2页→详情→目录→网络正文；第3页空结果正常结束 | `pr-search-flow-green.log/xcresult`、`pr-search-fixture.log`、`pr-search-flow-green-attachments` |
| 静态/仓库检查 | `git diff --check`、Info.plist/project.pbxproj校验通过；fixture Python语法及HTTP响应通过；Android工作区无修改 | 本次终端输出 |
| 独立补漏复核 | 交叉检查导入兼容/类型边界、搜索超时/合并符号、分页的暂停/并发/离开保护，未发现明确新增回归 | TODO对应验证边界 |

用户再次明确要求收尾，因此停止新增问题与功能实现。合成 HTTP 服务18764已关闭，独立测试模拟器`6519A372-C1D7-462F-BDCF-B976D44FD31B`已关闭，保留测试数据和证据。未提交Git commit、未推送、未修改Android或数据库结构。

恢复时先检查 IMPORT-001、SEARCH-008～010、CONTENT-004～006 的最新状态。本次完成的是明确的6项Bug修复；第三方实际书源、yuedu外部App唤起、网络文本内嵌图像渲染仍不能标记全部验证，后续仅在用户继续授权范围内处理。前两轮剩余项仍保留，不宣称全项目迁移完成。

## 前两轮结论（2026-11-07，Asia/Shanghai；已按用户要求收尾）

已连续推进两轮：第一轮修复网络文本阅读、搜索/发现、书架和换源存储、RSS；第二轮继续更新前脚本、WebView、文章规则桥、TXT导入/重建及段落重排，并进行独立补漏。**全项目迁移审计未完成**；已确认未实现项保留在 MIGRATION_TODO.md，不得将本轮通过测试解释为 Android 功能完整度已经达到。

Android 只读基线：Luoyacheng/legado-E `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c`。iOS 父仓库起始提交 `ef206d324cc1aa2bab8ca1be0dfbc9ebdafc7ef9`。未修改 Android、未引入第三方依赖、未修改数据库 schemaVersion，未操作真实用户数据库做清理或破坏性迁移。

## 第一轮修改与模块验证

每项的 Android/Swift 源码、问题、方案和验证状态见 TODO 同 ID。以下是本轮实际交付和证据，不是未来计划：

| 任务 | 修改结果 | 验证范围 |
| --- | --- | --- |
| NET-001～006 | 标题脚本、目录顺序/真假值/章节上下文、canReName 和详情字段上下文、副文完整正文链路、搜索/发现详情回退和 POST 选项保留 | NetworkBookServiceTests、JavaScriptRuleEvaluatorTests、SourceCompatibilityTests、SearchDetailFallbackTests、ChapterContentCacheTests、LocalFileServiceTests；网络→缓存→TXT 导出只出现一份副文 |
| SHELF-001～007 | 追更过滤、真实保存结果、最近同名章/冲突缓存键、六种分组排序/设置/拖动入口、分组更新/取消、有效分组位、load/save 并发保护 | BookUpdateCoordinatorTests、BookLibraryRegressionTests、BookDetailRegressionTests；UI 验证新分组排序设置和顺序编辑入口 |
| SEARCH-001～005 | 动态/登录请求头、元数据/变量/page 上下文、来源数排序、JS URL 翻页、发现失败同页重试与请求版本保护 | BookSearchServiceTests、BookExploreServiceTests、SearchRegressionTests、ExploreRegressionTests；延迟响应受控测试覆盖 A→B→A 和旧分页任务 |
| RSS-001～003 | 文章请求变量、nextPage 共享变量、正则捕获组不展开成独立文章 | RSSRegressionTests、RSSLibraryRegressionTests；本地 HTTP fixture 的导入更新/搜索/翻页/正文刷新/收藏 UI 流程 |
| SWITCH-001～003 | 验证阶段只读；同/不同 URL 目录与书架协调保存；自动/手动成功才切界面；提交中禁止取消；未入架预览不自动入架；章节数字/纯标题/近邻匹配；提前继承 reverseToc | BookSourceSwitchServiceTests、BookLibraryRegressionTests、LegadoDatabaseTests、BookDetailRegressionTests；SQLite 中途写入失败回滚，文件补偿失败显示诊断，并发保存不携带失败快照 |

### 独立补漏中继续修复的关联问题

1. 书架目录保存失败改为失败状态后，SQLite 章节外键使未入架详情也无法展示：详情读取先只在内存解析，已入架书再由页面统一提交书籍+目录；未入架书保持预览状态。
2. 候选目录先写入会破坏同 URL 旧源：移除 BookSourceSwitchService 的写库职责和 repository 参数。SQLite 通过一次事务提交两类数据；文件仓库保留快照并补偿，补偿失败单独显示，未声称文件跨文件写入具有 SQLite 等级的崩溃原子性。
3. 修复手动换源后，自动换源入口仍可能在落盘失败时切 UI：增加 commit gating；验证到保存之间和保存期间的取消行为分别处理。
4. 书架旧源刷新请求迟到会覆盖同 URL 新源目录：先内存获取，再等待提交、核对当前 URL+origin，最后协调写入。新增门控并发回归。
5. 旧详情响应会覆盖手动换源、详情恢复会重选首个重复章名：加入加载代际检查和最近同名章匹配。
6. 重新逐个核对 formatJs/preUpdateJs/webJs/sourceRegex/canReName/subContent 等“有字段或编辑入口”的实际消费位置；未实现部分进入 NET-007～013 等待办，不标记完成。

## 第一轮已执行验证

环境：Xcode 26.1 (17B55)，iOS SDK 26.1；专用模拟器 `Legado Migration Audit 18`，iPhone 16 Pro / iOS 18.3，ID `6519A372-C1D7-462F-BDCF-B976D44FD31B`。未重置已有模拟器。

| 检查 | 真实结果 | 本地证据 |
| --- | --- | --- |
| 修改前 `swift test --disable-sandbox` | 373 tests / 49 suites 通过 | `.build/migration-audit/baseline-swift-test.log` |
| 首批书架定向 | 27 tests / 2 suites 通过 | `.build/migration-audit/shelf-tests.log` |
| 第一轮集成 | 409 tests / 50 suites 通过 | `.build/migration-audit/round1-swift-test.log` |
| 第一轮最终 `swift test --disable-sandbox` | **428 tests / 51 suites 全部通过** | `.build/migration-audit/final-swift-test.log` |
| Xcode generic iOS Simulator build | BUILD SUCCEEDED | `.build/migration-audit/simulator-build.log` |
| Xcode LegadoReaderTests | **第一轮最终代码复测 25 tests、0 failures** | `.build/migration-audit/reader-final.log`、`reader-final.xcresult` |
| Xcode ReaderUITests 选定 3 项 | **3 tests、0 failures**；分组设置/顺序编辑入口，分页与滚动模式失败/部分正文重试及换源取消入口 | `.build/migration-audit/core-ui.log`、`core-ui.xcresult` |
| Xcode LegadoRSSFlowUITests | **1 test、0 failures**；本地真实 HTTP 服务驱动 UI，非第三方在线源 | `.build/migration-audit/rss-ui.log`、`rss-ui.xcresult` |
| `python3 -m unittest discover -s scripts/tests -v` | **8 tests 通过** | `.build/migration-audit/script-tests.log` |
| `plutil -lint`、Swift 尾随空格扫描、`git diff --check -- .` | 通过 | 实际命令输出；Android 副本 `git status --short` 为空 |

中途真实失败及处理：目录 chapter.title 可选值编译错误已修；一个新增测试函数声明缺空格已修；Swift Testing 的 #require 中直接调用字典 removeValue 会产生不可变宏参数，改局部变量；中文数词解析把“百”的 wholeNumberValue 当普通数字，修正单位优先。均在后续通过测试后才更新状态，没有将失败或未执行的测试记作通过。

### 复现命令

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests -v
plutil -lint Legado.xcodeproj/project.pbxproj
git diff --check -- .
```

Xcode 测试通用参数：`-project Legado.xcodeproj -destination 'platform=iOS Simulator,id=6519A372-C1D7-462F-BDCF-B976D44FD31B' -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test`。

- 阅读器：`-scheme LegadoReaderTests`。
- 新入口及失败流程：`-scheme LegadoReaderUITests`，分别 `-only-testing:LegadoReaderUITests/RuleEditorUITests/testBookshelfGroupSortingSettingsAndOrderEditorAreReachable`、`-only-testing:LegadoReaderUITests/ReaderScrollGestureTests/testFailedChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes`、`-only-testing:LegadoReaderUITests/ReaderScrollGestureTests/testPartialChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes`。
- RSS：先启动 `python3 scripts/fixtures/rss-flow-server.py`，再 `-scheme LegadoRSSFlowUITests`；方案已配置 localhost:18763 fixture URL。
- `.build`/DerivedData 为可清理的本地证据，三份 docs、源码和测试才是跨会话持久记录。

## 未验证与下一步

- 没有执行 iOS 15 真机、Release/iPhoneOS 签名发布、真实第三方书源全面回归；没有声称 UI 测试覆盖所有新增错误分支。顺序编辑实际拖动和发现故障服务 UI 可专项补充。
- JavaScript 执行中取消/硬超时仍未解决；媒体副文/漫画/音视频/后台系统行为未等价，不得当作文字阅读链已通过的附带结论。
- 恢复时先读三份记录和末尾最新检查点，检查diff并重跑未完成的集成；第二轮通过后优先继续 SEARCH-006 动态发现控件及 SEARCH-007 元数据格式化。NET-009 引擎取消与媒体/存储类型差异需专项设计，不能做空实现。
- 对照 AUDIT 功能表继续本地格式、书源登录/订阅、备份/WebDAV/远程书库、全规则引擎、媒体、词典和系统配置的真实调用链。尚未核对的模块保持“待审计”，完成后再跑一轮入口补漏。

## 第一轮核对与恢复点

- 第一轮检查点：Swift 428 项、Xcode 阅读器 25 项、选定 UI 4 项、脚本 8 项均通过；最后的 Xcode 测试重新构建了最新 App。
- 本次新增专用模拟器已保留测试数据并关机；临时 RSS fixture 服务已停止，未清理其他模拟器或用户数据。
- 独立补漏完成的是**本轮已改模块及其关联入口**，不是全项目全部功能。尚未实现任务保持明确待办。
- 第一轮变更留在工作区，未提交或发布。Android 基线和恢复要求见 MIGRATION_AUDIT.md。

## 第二轮实施与历史验证（同次执行继续）

第一轮检查点后继续按优先级处理 NET-007/008（更新前脚本、正文 WebView）、RSS-004（rssArticle 对象桥）、本地 TXT 导入/分章和内容净化。**上述第一轮测试数量不自动适用于后续修改**，新增修改待重新验证。

- CONTENT-001：对照 Android ContentProcessor.kt:111 起重复标题前缀正则，iOS 只匹配整行，标题与正文同一行时未去除；已补前缀处理、原/替换后标题、标题正则转义与空标题保护，定向验证 `ContentSanitizerTests|ReaderRegressionTests|ReplaceRuleExecutionTests` 已执行，34 tests / 3 suites 全部通过，日志 `.build/migration-audit/content-targeted.log`。
- CONTENT-002：ContentHelp.reSegment 实际为断行黏合、引号/对话/随机长段处理，Swift 的 resegment 仅 trim 空白。已确认尚未等价；需要单独迁移算法/设置调用，不能把 trim 说成完成重排。

- LOCAL-001～004（定位/修复中）：本地 TXT 导入未读取规则管理页持久化规则；空标题脚本错误切章；prevLength 上下文错误；GB18030/无 BOM UTF-16 判别与空文件错误处理。由 LocalBookService/BookLibraryModel 导入调用链继续修复，未纳入第一轮测试通过结论。

### 第二轮模块定向证据（尚不替代最终集成）

- NET-007：`preupdate-targeted.log`，65 tests / 5 suites 通过。更新前脚本可修改书籍字段/变量，`java.refreshTocUrl/reGetBook` 同步桥支持取消；书籍 URL 变化经原子提交与冲突检查，仅安全匹配章节复制缓存，旧缓存保留。
- RSS-004：`rss-article-bridge-tests.log`，101 tests / 7 suites 通过；`rss-article-error-test.log` 单项异常回归通过。真实文章对象/变量贯穿规则、请求、正文和文章/收藏保存；脚本变更 link/origin 的工作上下文不改变原缓存条目身份。RSS-005 大变量独立存储继续实施，不能把尚未完成的跨文件/数据库事务说成全部回滚。
- LOCAL-001～004：`local-tests-final.log`，53 tests / 3 suites 通过。实时持久化规则、停用/删空语义、空标题/前言/prevLength、编码和多字节边界修复。Foundation 与 Android ICU 的所有编码识别不承诺相同；实际覆盖 UTF-8、UTF-16LE/BE、GB18030、Big5。
- CONTENT-002：使用环境已有 Kotlin 编译器/JDK，直接编译未修改的 Android `ContentHelp.kt`，120 个输入各运行原版 5 次均稳定，Swift 对照 120/120 一致。固定 fixture 已保存 `Tests/LegadoCoreTests/Fixtures/resegment-android.json`；临时 JVM/Swift 对照证据在 `.build/migration-audit/resegment-oracle/`。长段随机位置改为内容固定种子，是保证稳定分页的明确 iOS 适配。新增设置/缓存/朗读回归尚待运行。
- 中途一次 CONTENT 定向构建因其他代理正在修改 RuleEngine.swift 被编译器中止，未执行测试，不计通过。后续已统一要求模块代码冻结后集中执行，日志 `resegment-targeted.log` 保留该失败证据。
- 独立补漏 CONTENT-003：阅读设置写整本旧快照可覆盖最新元数据、自动加入预览书；改成单字段配置更新，新增现有书/预览/旧源/保存失败回归，待验证。

### 第二轮第一次集成与修复反馈

- `round2-swift-test.log`：492 tests / 56 suites，**8 issues，失败**。6项断言/错误来自LOCAL-005无标题分章的空正则校验，2项来自RSS-005缺失大变量返回undefined而非Android的null。其余新增内容重排/配置、NET-007/008测试通过；不能把整个测试运行说成通过。
- `round2-reader.log` / `round2-reader.xcresult`：**29 tests、0 failures**，包含4项真实后台WKWebView验证（脚本返回/空值重试、资源URL、POST HTML/未匹配超时、取消）。后续又增加UA断言及Reader设置/朗读补漏，仍须复验最新代码。
- `round2-script-tests.log`：8 tests通过。
- 修复中反馈：TXT不对空标题规则构造正则；泛型UTF16按实际BOM规范字节序，取消传播到扫描任务并在块/循环检查；RSS nil返回显式转JS null。
- CONTENT-003：仅持久化单字段；失败保留当前会话选择并明确提示“本次设置仅在当前阅读中生效”，不声称已经保存。净化/重排改变正文时停止旧朗读，HTTP下一章预取增加章节/内容/朗读代际检查，拒绝迟到的旧正文。实际声音输出与故障持久化弹窗尚未由UI专门验证。
- NET-014：独立复核发现仅webJs也错误启用WK；已改统一webView条件，新增HTTP/dataURI/stream/嵌套AJAX回归待验。
- RSS-006：嵌套getString捕获初始变量/文章且丢弃回写，正在修复同一共享上下文的完整链路。

以上是中途状态；恢复请以本文末尾最新检查点为准。

第二轮第二次构建：`round2-reader-final.log` / `round2-reader-final.xcresult` 再次29 tests、0 failures，包含UA实际断言和最新Reader设置代码。`round2-final-swift-test.log`因新增NET-014测试缺executionContext参数编译失败，未运行测试；已分配修复。独立检查同时补RSS-006两个边界：字符串列表`##`替换应逐元素进行；单worker同步化后必须显式传递取消标记，在分支/native请求/大变量提交边界观察取消（仍不声称可中断JSC指令）。修正后再跑完整测试。

第二轮第三次Swift集成：`round2-integrated-swift.log`编译通过，测试进程以SIGBUS退出，**未通过**。真实crash报告定位：033556的故障线程在SwiftSoup.HtmlTreeBuilderState触发栈保护；033614/033623在JavaScript异常处理器调用toString时递归重入。摘要保存在`.build/migration-audit/swiftpm-testing-helper-*-summary.json`。正在修复同步核心所需的工作线程栈及异常格式化重入；需定向并发/递归验证和完整复测，不能绕过该失败声明完成。

## 第二轮最新已验证检查点

- `rss006-targeted-tests.log`：101 tests / 8 suites通过，包括原24路6层递归负载、超深限制、异常对象toString再抛错、取消和搜索性能。固定大栈有限线程池处理规则递归；预更新等异步native桥的调度分开，避免互相等待。
- `round2-verified-swift.log`：**508 tests / 57 suites全部通过**，覆盖全部第二轮最新补修；替代前面失败运行的当前状态。在线真实书源测试仍按环境配置跳过，不计作通过。
- `round2-verified-reader.log` / `round2-verified-reader.xcresult`：**最新App重新构建，29 tests、0 failures**，包含真实WK及UA。
- 段落差分扩至128：额外8种Unicode空白揭示Java默认\s与ICU\s差异，已保留Java ASCII语义，128/128与未修改Android源码一致；fixture已更新。1000个标点/emoji生成边界样本此前无崩溃，长段稳定随机单独回归。
- 模拟器新增UI正在运行：书架分组、TXT+EPUB导入与TXT重建、分页/连续阅读重排开关、失败/部分正文重试换源。RSS真实本地HTTP流程随后执行。尚未把这些UI标为已通过。

第二轮UI第一批：`round2-core-ui.log` / `round2-core-ui.xcresult`运行5项，4项通过、1项失败。已通过书架分组入口、TXT/EPUB系统文件选择与实际导入/重建/EPUB目录及插图、两种阅读模式失败/部分正文重试换源。重排开关第一次点击后值未变化；正在检查Form行的可访问元素与实际控件位置并单独复测，未改生产功能断言或跳过测试。

第二轮重排UI补测：`round2-resegment-ui.log` / `round2-resegment-ui.xcresult` **1 test、0 failures**，分别在分页和连续阅读模式切换、关闭设置、重新打开确认状态、恢复原值。XCTest层级显示Switch是362pt宽的整行；原中心点击落在空白，改为可见开关区域并等待实际状态变化，保留原功能断言。此项只修改测试点击定位，生产代码未改；其余4项UI无需重复执行。

## 收尾检查点（用户明确要求停止扩展范围）

用户要求“准备收尾”，因此本次停止增加新模块，已完成验证与记录；**不代表全项目迁移完成**。迁移功能有固定Android源码依据；并发保护、协调存储、稳定随机分段等为明确记录的iOS适配，并非声称原版每个细节均相同。

| 最新验证 | 结果 | 证据 |
| --- | --- | --- |
| Swift全量 | **508 tests / 57 suites通过** | `round2-verified-swift.log` |
| iOS模拟器构建与阅读器 | **29 tests、0 failures** | `round2-verified-reader.log`、`round2-verified-reader.xcresult` |
| 书架/文件/重试UI | **4项通过** | `round2-core-ui.log`、`round2-core-ui.xcresult`（同次另1项重排点击定位失败，已单独补测） |
| 重排开关UI | **1项通过，覆盖分页与连续阅读** | `round2-resegment-ui.log`、`round2-resegment-ui.xcresult` |
| RSS完整UI流程 | **1项通过**，本地HTTP真实请求→导入更新→搜索分页→正文刷新→收藏与重开 | `round2-rss-ui.log`、`round2-rss-ui.xcresult` |
| Kotlin→Swift段落差分 | **128/128一致**；长段随机为稳定种子适配 | 固定fixture与`resegment-oracle/comparison-final.txt` |
| Python脚本测试 | **8项通过** | `round2-script-tests.log` |
| 工程/差分静态检查 | `plutil -lint`、`git diff --check -- .`通过；Android只读副本无修改 | 收尾实际命令输出 |

- 三份审计文档、生产代码与测试均保存在工作区，未提交或发布；未修改Android，未新增生产依赖，数据库schemaVersion仍为7。未执行真实用户数据删除或破坏性迁移。
- 临时RSS fixture服务已停止；本次专用模拟器已关机，保留测试数据与导入fixture。其他模拟器未操作。
- 已验证的是表中范围；未运行真实第三方书源全面回归、iOS15真机、签名发布。阅读设置保存失败弹窗和物理音频输出未专项UI验证。大变量sidecar与SQLite不是联合事务；WebView资源观察不是全流量拦截；只读元素桥不是全部Jsoup API；JS/正则硬中断仍未实现。
- 恢复时先看TODO未实现条目：SEARCH-006/007、NET-009～013、SHELF-008/009、RULE-001、LOCAL-006及AUDIT-REMAINING。优先动态发现控件，再按P1缺口推进媒体/书源交互/其他本地格式和未审模块；不要重复宣称已通过的局部测试等于全项目完成。
