@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderView: View {
    private var usesEPUBLayout = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: ReaderViewModel
    private var book: Book { model.book }
    @State private var sourceSwitchBook: Book?
    @StateObject private var speech = ReaderSpeechController()
    @State private var showsTableOfContents = false
    @State private var showsBookmarks = false
    @State private var illustrationChapter: BookChapter?
    @State private var showsAutoReadControls = false
    @State private var showsStyleControls = false
    @State private var isAutoReading = false
    @State private var showsReaderMenu = false
    @State private var followsSystemBrightness = true
    @State private var readerBrightness = Double(UIScreen.main.brightness)
    @State private var batteryLevel = UIDevice.current.batteryLevel
    @State private var batteryState = UIDevice.current.batteryState
    @State private var brightnessBeforeReading = Double(UIScreen.main.brightness)
    @State private var tocSearch = ""
    @State private var tocDescending = false
    @State private var showsContentSearch = false
    @State private var showsReplaceRules = false
    @State private var showsReaderSettings = false
    @State private var showsMoreAppearance = false
    @State private var showsCacheManagement = false
    @State private var showsClickActionSettings = false
    @State private var showsContentEditor = false
    @State private var editedContent = ""
    @State private var contentEditError: String?
    @State private var backgroundImage: UIImage?
    @State private var backgroundError: String?
    @State private var showsBackgroundPicker = false
    @State private var showsFontImporter = false
    @State private var fontError: String?
    @State private var readerJumpPosition: Int?
    @State private var contentSearchQuery = ""
    @State private var readerPosition = 0
    @State private var readerPageRanges: [NSRange] = []
    @State private var speechPageIndex = 0
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var readerRenderRevision = 0
    @State private var isWaitingForNextChapter = false
    @State private var isWaitingForPreviousChapter = false
    @State private var httpTTSEngines: [HttpTTS] = []
    @State private var resumesSpeechAfterChapterLoad = false
    @State private var speechTimerTask: Task<Void, Never>?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var progressSaveGeneration = 0
    @State private var speechStartGeneration = 0
    @State private var speechTimerRemaining = 0
    @State private var isSavingBookmark = false
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 21
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.0
    @AppStorage("lineSpacingExtra") private var lineSpacing = 8.0
    @AppStorage("readerQidianLayoutVersion") private var defaultLayoutVersion = 0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 10.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 6.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 32.0
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 10.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 20.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 20.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 20.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 20.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = false
    @AppStorage("tipHeaderLeft") private var tipHeaderLeft = 1
    @AppStorage("tipHeaderMiddle") private var tipHeaderMiddle = 0
    @AppStorage("tipHeaderRight") private var tipHeaderRight = 0
    @AppStorage("tipFooterLeft") private var tipFooterLeft = 6
    @AppStorage("tipFooterMiddle") private var tipFooterMiddle = 0
    @AppStorage("tipFooterRight") private var tipFooterRight = 8
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("autoReadSpeed") private var autoReadSpeed = 10
    @AppStorage("ttsFollowSys") private var ttsFollowSystem = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("systemTtsVoice") private var systemTTSVoice = ""
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("streamReadAloudAudio") private var streamReadAloudAudio = true
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @AppStorage("readerFullJustify") private var fullJustify = true
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = true
    @AppStorage("readerShowBrightness") private var showBrightness = true
    @AppStorage("readerBrightness") private var storedReaderBrightness = 0.0
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @State private var pageAnimation: Int
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("clickActionTopLeft") private var clickActionTL = 0
    @AppStorage("clickActionTopCenter") private var clickActionTC = 0
    @AppStorage("clickActionTopRight") private var clickActionTR = 0
    @AppStorage("clickActionMiddleLeft") private var clickActionML = 0
    @AppStorage("clickActionMiddleRight") private var clickActionMR = 0
    @AppStorage("clickActionBottomLeft") private var clickActionBL = 0
    @AppStorage("clickActionBottomCenter") private var clickActionBC = 0
    @AppStorage("clickActionBottomRight") private var clickActionBR = 0


    init(book: Book, chapters: [BookChapter], initialIndex: Int, source: BookSource) {
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            source: source
        ))
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int, usesEPUBLayout: Bool = true) {
        self.usesEPUBLayout = usesEPUBLayout
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex
        ))
    }

    init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        var readerChapters = chapters
        var readerInitialIndex = initialIndex
        var readerContent = content
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiScrollRegression") {
            readerChapters = (0..<80).map {
                BookChapter(url: "demo://scroll/\($0)", title: "第\($0 + 1)章 · 连续阅读", bookUrl: book.bookUrl, index: $0)
            }
            readerInitialIndex = 20
            if arguments.contains("-uiShortChapters") { readerContent = "短章正文，继续向下可以自然读到下一章。" }
        }
        #endif
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        #if DEBUG
        if arguments.contains("-uiPagedBoundaryRegression") {
            var testBook = book
            let source = BookSource(bookSourceUrl: "https://paged-regression.invalid", bookSourceName: "分页测试")
            testBook.origin = source.id
            let cache = ChapterContentCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("paged-ui-\(UUID().uuidString)"))
            _model = StateObject(wrappedValue: ReaderViewModel(book: testBook, chapters: readerChapters,
                initialIndex: readerInitialIndex, source: source,
                service: ReaderPagedBoundaryTestLoader(failFirst: arguments.contains("-uiPagedBoundaryFailure")),
                cache: cache, prefetchLimit: 0))
            return
        }
        if arguments.contains("-uiCacheRegression") {
            readerChapters = (0..<1200).map {
                BookChapter(url: "demo://cache/\($0)", title: "第\($0 + 1)章 · 缓存验证", bookUrl: book.bookUrl, index: $0)
            }
            var cacheBook = book
            cacheBook.name = "缓存滚动验证"
            let source = BookSource(bookSourceUrl: "https://cache-regression.invalid", bookSourceName: "缓存测试")
            cacheBook.origin = source.id
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-ui-\(UUID().uuidString)")
            _model = StateObject(wrappedValue: ReaderViewModel(book: cacheBook, chapters: readerChapters,
                initialIndex: 369, source: source, service: ReaderCacheTestLoader(), cache: .init(directory: directory)))
            return
        }
        if arguments.contains("-uiReaderFailure") {
            _model = StateObject(wrappedValue: ReaderViewModel(
                book: book, chapters: readerChapters, initialIndex: readerInitialIndex,
                source: BookSource(bookSourceUrl: "https://reader-failure.invalid", bookSourceName: "正文失败测试源"),
                service: ReaderFailureTestLoader()
            ))
            return
        }
        #endif
        _model = StateObject(wrappedValue: ReaderViewModel(
            demoBook: book,
            chapters: readerChapters,
            initialIndex: readerInitialIndex,
            content: readerContent
        ))
    }


    var body: some View {
        if usesEPUBLayout, book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
            EPUBReaderView(book: book, chapters: model.chapters, initialIndex: model.currentIndex)
        } else {
            textReaderBody
        }
    }

    private var textReaderBody: some View {
        readerCanvas
        .preferredColorScheme(resolvedStyle.id == "night" ? .dark : .light)
        .readingTabBarHidden()
        .navigationBarBackButtonHidden(true)
        .background {
            ReaderInteractivePopEnabler()
                .frame(width: 0, height: 0)
        }
        .statusBarHidden(hideStatusBar)
        .readingHomeIndicatorHidden(hideHomeIndicator)
        .overlay(alignment: .top) {
            if showsReaderMenu {
                readerTopChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if !showsReaderMenu, pageAnimation != 3 {
                if model.showsPagedChapterLoading {
                    HStack(spacing: 8) { ProgressView(); Text("正在准备章节…").font(.caption) }
                        .padding(10).background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 40).accessibilityIdentifier("reader.chapterPreparing")
                } else if let error = model.pagedChapterError {
                    Text("章节未加载：\(error)。请再次滑动重试。")
                        .font(.caption).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20).padding(.bottom, 40)
                        .accessibilityIdentifier("reader.chapterTurnError")
                }
            }
        }
        .animation(.easeOut(duration: 0.22), value: showsReaderMenu)
        .onAppear {
            updateDefaultTypography()
            activity.beginReading(book)
            speech.onNextChapter = { moveSpeechToChapter(direction: 1) }
            speech.onPreviousChapter = { moveSpeechToChapter(direction: -1) }
            speech.onRemoteStop = {
                speechTimerTask?.cancel()
                speechTimerRemaining = 0
                resumesSpeechAfterChapterLoad = false
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            batteryState = UIDevice.current.batteryState
            brightnessBeforeReading = Double(UIScreen.main.brightness)
            if storedReaderBrightness > 0.05 {
                followsSystemBrightness = false
                readerBrightness = storedReaderBrightness
                UIScreen.main.brightness = CGFloat(storedReaderBrightness)
            } else {
                readerBrightness = brightnessBeforeReading
            }
            backgroundImage = ReaderBackgroundStore.load()
            ReaderScreenOrientation.apply(screenOrientation)
            Task { await loadHTTPEngines() }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoBookmarks") {
                showsBookmarks = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderMenu") {
                showsReaderMenu = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderStyle") {
                DispatchQueue.main.async { showsStyleControls = true }
            }
        }
        .onDisappear {
            isAutoReading = false
            UIApplication.shared.isIdleTimerDisabled = false
            if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
            saveProgress(immediate: true)
            ReaderScreenOrientation.restoreApplicationDefault()
            activity.cancelReading(book)
            UIDevice.current.isBatteryMonitoringEnabled = false
            if !followsSystemBrightness {
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
            }
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            speech.onNextChapter = nil
            speech.onPreviousChapter = nil
            speech.onRemoteStop = nil
            model.cancelCaching()
            model.cancelPreloading()
        }
        .overlay(alignment: .bottom) {
            if showsReaderMenu {
                readerBottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsTableOfContents) { tableOfContents }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .sheet(item: $illustrationChapter) { chapter in
            EPUBIllustrationsView(book: book, chapter: chapter)
        }
        .sheet(isPresented: $showsAutoReadControls) { autoReadControls }
        .sheet(isPresented: $showsStyleControls) { styleControls }
        .sheet(isPresented: $showsContentSearch) { contentSearchSheet }
        .sheet(item: $sourceSwitchBook) { currentBook in
            ReadingNavigationStack {
                SourceSwitchView(book: currentBook, sources: sourceLibrary.sources) { report, source in
                    Task {
                        await progressSaveTask?.value
                        await activity.endReading(book)
                        await library.replace(oldBookURL: book.bookUrl, with: report.book)
                        model.applySourceSwitch(report, source: source)
                        readerPosition = report.book.durChapterPos
                        readerJumpPosition = nil
                        readerPageRanges = []
                        readerRenderRevision &+= 1
                        activity.beginReading(report.book)
                    }
                }
            }
        }
        .sheet(isPresented: $showsReplaceRules) {
            ReadingNavigationStack { ReplaceRuleManagementView() }
        }
        .sheet(isPresented: $showsReaderSettings, onDismiss: { showsMoreAppearance = false }) { readerSettings }
        .sheet(isPresented: $showsClickActionSettings) { clickActionSettings }
        .sheet(isPresented: $showsContentEditor) { contentEditor }
        .task(id: model.chapterLoadGeneration) {
            isWaitingForNextChapter = false
            isWaitingForPreviousChapter = false
            let needsInitialPosition = !model.hasLoadedCurrentChapter
            if let pending = progressSaveTask {
                let pendingGeneration = progressSaveGeneration
                await pending.value
                // A newer page callback may have scheduled another save while
                // this chapter task was waiting. Never erase that newer task's
                // handle, or a subsequent chapter transition could skip it.
                if progressSaveGeneration == pendingGeneration {
                    progressSaveTask = nil
                }
            }
            readerJumpPosition = nil
            if needsInitialPosition {
                readerPageRanges = []
                readerPosition = model.requestedPosition
            }
            await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], prefetchNextChapter: pageAnimation != 3)
            guard !Task.isCancelled else { return }
            if needsInitialPosition {
                readerPosition = pageAnimation == 3
                    ? continuousPosition(model.requestedPosition, content: model.content)
                    : min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
            }
            if let chapter = model.currentChapter {
                await library.updateProgress(for: book, chapter: chapter, position: readerPosition)
            }
            if resumesSpeechAfterChapterLoad, !model.content.isEmpty {
                resumesSpeechAfterChapterLoad = false
                startConfiguredSpeech()
            }
        }
        .task(id: "\(model.chapterLoadGeneration):\(pageAnimation == 3):\(model.hasLoadedCurrentChapter):\(model.scrollRevision)") {
            guard pageAnimation == 3 else { return }
            await model.prepareContinuousReading(rules: model.usesReplaceRules ? replaceRules.rules : [])
        }
        .onAppear { updateIdleTimer() }
        .onChange(of: keepScreenOn) { _ in
            updateIdleTimer()
        }
        .onChange(of: adjacentReadiness) { _ in
            if model.isContinuationWindowReady, isWaitingForNextChapter {
                isWaitingForNextChapter = false
                readerRenderRevision &+= 1
            }
            if model.isPreviousWindowReady, isWaitingForPreviousChapter {
                advanceToPreparedPreviousChapter()
            }
        }
        .onChange(of: isAutoReading) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.isSpeaking) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.completionCount) { _ in
            if readAloudByPage {
                continueSpeechToNextPage()
            } else {
                continueSpeechToNextChapter()
            }
        }
        .onChange(of: speech.currentSegmentIndex) { index in
            guard model.paragraphs.indices.contains(index), !readAloudByPage else { return }
            readerJumpPosition = nil
            DispatchQueue.main.async { readerJumpPosition = model.paragraphs[index].id }
        }
        .onChange(of: readAloudByPage) { _ in
            restartSpeechAfterReaderLayoutChange()
        }
        .onChange(of: readAloudWakeLock) { _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(readerBrightness)
                }
                activity.beginReading(book)
            } else {
                isAutoReading = false
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
                saveProgress(immediate: true)
                activity.cancelReading(book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryState = UIDevice.current.batteryState
        }
        .onChange(of: screenOrientation) { value in
            ReaderScreenOrientation.apply(value)
        }
        .onChange(of: themeMode) { _ in
            isAutoReading = false
            readerJumpPosition = nil
            currentPage = 1
            totalPages = 1
        }
        .onChange(of: pageAnimation) { value in
            isAutoReading = false
            saveProgress(immediate: true)
            readerJumpPosition = readerPosition
            currentPage = 1
            totalPages = 1
            UserDefaults.standard.set(value, forKey: "pageAnim")
            let updatedBook = model.useGlobalPageAnimation()
            Task { await library.addOrUpdate(updatedBook) }
        }
    }


    private var readerCanvas: some View {
        ZStack {
            readerContent
            readerMenuDismissOverlay
        }
        .background {
            ZStack {
                backgroundColor
                if let backgroundImage = activeBackgroundImage {
                    Image(uiImage: backgroundImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var readerContent: some View {
        if pageAnimation != 3,
           (model.isLoading && model.content.isEmpty) || (model.content.isEmpty && !model.hasLoadedCurrentChapter) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在打开本章")
                    .font(.subheadline.weight(.medium))
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { showsReaderMenu.toggle() }
            .transition(.opacity)
        } else if pageAnimation != 3, model.content.isEmpty && model.hasLoadedCurrentChapter {
            VStack(spacing: 18) {
                Image(systemName: "text.page.slash").font(.largeTitle)
                Text(model.currentChapterError == nil ? "正文为空" : "本章加载失败").font(.title3.weight(.semibold))
                Text(model.currentChapterError ?? "本章暂无正文。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                readerRecoveryActions
                Button("打开阅读菜单") { showsReaderMenu = true }
                    .accessibilityIdentifier("reader.failureMenu")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
        } else {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if headerVisible { readerTipBar(isHeader: true) }
                    readerSurface.clipped()
                    if footerVisible { readerTipBar(isHeader: false) }
                }
                // Reuse the upper part of the home-indicator safe area while
                // keeping at least 14 points clear at the bottom of the screen.
                .padding(.bottom, -min(20, max(geometry.safeAreaInsets.bottom - 14, 0)))
                .frame(maxWidth: readingColumnMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottom) {
                if let error = model.currentChapterError, !showsReaderMenu {
                    VStack(spacing: 10) {
                        Text(model.content.isEmpty ? "本章加载失败" : "本章加载不完整").font(.subheadline.weight(.semibold))
                        Text(error).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        readerRecoveryActions
                        Button("打开阅读菜单") { showsReaderMenu = true }
                            .accessibilityIdentifier("reader.failureMenu")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(foregroundColor)
                    .background(backgroundColor)
                }
            }
        }
    }

    private var readerRecoveryActions: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    if pageAnimation == 3, model.scrollChapters.contains(where: { $0.id == model.currentIndex }) {
                        await model.retryContinuousChapter(index: model.currentIndex, rules: model.usesReplaceRules ? replaceRules.rules : [])
                    } else {
                        await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], forceRefresh: true)
                    }
                }
            } label: {
                Label(model.scrollRetries.contains(model.currentIndex) ? "重试中…" : "重试本章", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            .accessibilityIdentifier("reader.retryChapter")
            if model.canEditContent {
                Button(action: openSourceSwitch) {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("reader.failureChangeSource")
            }
        }
        .readingSecondaryButtonStyle()
    }

    private func openSourceSwitch() {
        stopSpeechIfNeeded()
        isAutoReading = false
        saveProgress(immediate: true)
        showsReaderMenu = false
        sourceSwitchBook = model.bookForSourceSwitch(position: readerPosition)
    }

    @ViewBuilder private var readerSurface: some View {
        if pageAnimation == 3 {
            ReaderScrollView(
                configuration: readerTextConfiguration,
                chapters: model.scrollChapters,
                resetID: model.scrollRevision,
                activeIndex: model.currentIndex,
                loadingAhead: model.isLoadingScrollAhead,
                loadingBehind: model.isLoadingScrollBehind,
                onNeedChapters: { direction in
                    Task { await model.extendContinuousReading(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) }
                },
                onPositionChanged: { index, position in
                    if index != model.currentIndex {
                        saveProgress(immediate: true)
                        model.updateContinuousPosition(chapter: index)
                        readerJumpPosition = nil
                    }
                    let resolved = min(max(position, 0), model.content.utf16.count)
                    if readerPosition != resolved { readerPosition = resolved }
                },
                onRetainChapters: { model.retainContinuousChapters($0) }
            )
        } else {
            readerTextConfiguration
        }
    }

    private var readerTextConfiguration: ReaderTextView {
        ReaderTextView(
            text: readerDisplayText,
            title: model.title,
            previousTitle: pageAnimation == 3 ? model.previousTitle : nil,
            previousText: pageAnimation == 3 ? model.previousContent : "",
            isPreviousReady: pageAnimation == 3 && model.isPreviousWindowReady,
            continuationTitle: pageAnimation == 3 ? model.continuationTitle : nil,
            continuationText: pageAnimation == 3 ? model.continuationContent : "",
            isContinuationReady: pageAnimation == 3 && model.isContinuationWindowReady,
            isVolume: model.currentChapter?.isVolume == true,
            fontSize: fontSize,
            fontPath: fontPath,
            letterSpacing: letterSpacing,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            paddingTop: paddingTop,
            paddingBottom: paddingBottom,
            headerInset: 0,
            footerInset: 0,
            fontWeight: fontWeight,
            titleMode: titleMode,
            titleSize: titleSize,
            titleTopSpacing: titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing,
            underlineMode: underlineMode,
            isSelectable: false,
            fullJustify: fullJustify,
            pageAnimation: pageAnimation,
            isEInkMode: themeMode == "3",
            clickActions: clickActions,
            backgroundColor: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
            foregroundColor: resolvedStyle.foreground,
            requestedPosition: pageAnimation == 3 ? readerPosition : model.requestedPosition,
            jumpPosition: readerJumpPosition,
            renderRevision: readerRenderRevision,
            readerPosition: $readerPosition,
            pageRanges: $readerPageRanges,
            currentPage: $currentPage,
            totalPages: $totalPages,
            isAutoReading: isAutoReading,
            isAutoReadPaused: pausesAutoReading,
            isLoadingNextChapter: isWaitingForNextChapter,
            secondsPerScreen: Double(autoReadSpeed),
            onReachedEnd: { boundaryPosition in
                if pageAnimation == 3 {
                    requestNextChapter()
                    return
                }
                if model.canGoNext {
                    showsReaderMenu = false
                    readerPosition = boundaryPosition
                    saveProgress(immediate: true)
                    readerJumpPosition = nil
                    turnPagedChapter(1)
                } else {
                    isAutoReading = false
                }
            },
            onReachedStart: { boundaryPosition in
                if pageAnimation == 3 {
                    requestPreviousChapter()
                    return
                }
                guard model.canGoPrevious else { return }
                showsReaderMenu = false
                readerPosition = boundaryPosition
                saveProgress(immediate: true)
                readerJumpPosition = nil
                turnPagedChapter(-1)
            },
            onEnteredPrevious: { position in
                guard pageAnimation == 3, model.canGoPrevious, model.hasPreviousWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.previousContent)
                readerJumpPosition = nil
                model.promotePrevious(position: readerPosition)
            },
            onEnteredContinuation: { position in
                guard pageAnimation == 3, model.canGoNext, model.hasContinuationWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.continuationContent)
                readerJumpPosition = nil
                model.promoteContinuation(position: readerPosition)
            },
            onDeferredRender: { readerRenderRevision &+= 1 },
            onCancelNextLoading: { isWaitingForNextChapter = false },
            onPageChanged: pageDidChange,
            onTapAction: handleTapAction,
            chapterTransition: model.chapterTransition,
            onWillTurnPage: { model.cancelPagedChapterTurn() },
            canGoPreviousChapter: model.canGoPrevious,
            canGoNextChapter: model.canGoNext,
            onPrepareChapter: { direction in
                await model.preparePagedChapter(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : [])
            },
            onCommitChapter: { prepared in
                saveProgress(immediate: true)
                readerJumpPosition = nil
                guard model.commitPagedChapter(prepared) else { return false }
                readerPosition = model.requestedPosition
                return true
            },
            onCancelChapterPreparation: { model.cancelPagedChapterTurn() },
            pageBackgroundColor: resolvedStyle.background,
            pageBackgroundImage: activeBackgroundImage
        )
    }

    @ViewBuilder private var readerMenuDismissOverlay: some View {
        if showsReaderMenu {
            Color.black
                .opacity(resolvedStyle.id == "night" ? 0.08 : 0.03)
                .ignoresSafeArea()
                .contentShape(ReaderMenuDismissShape())
                .onTapGesture { showsReaderMenu = false }
                .accessibilityHidden(true)
        }
    }

    private var readingColumnMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
    }

    private var adjacentReadiness: Int {
        (model.isPreviousWindowReady ? 1 : 0) | (model.isContinuationWindowReady ? 2 : 0)
    }

    private var readerDisplayText: String {
        if !model.content.isEmpty { return model.content }
        if pageAnimation == 3 {
            return String(repeating: "\n", count: 80)
        }
        if model.isLoading || !model.hasLoadedCurrentChapter {
            return "正文正在后台加载…\n\n你可以继续向下滚动，下一章已经提前生成。"
        }
        let reason = model.diagnostics.first?.message ?? "当前书源没有返回正文。"
        return "本章加载失败\n\n\(reason)\n\n本章位置会保留，请继续向下进入下一章。"
    }

    private func continuousPosition(_ position: Int, content: String) -> Int {
        let length = content.isEmpty ? 80 : content.utf16.count
        return min(max(position, 0), max(length - 1, 0))
    }

    private var activeBackgroundImage: UIImage? {
        themeMode != "3" && useBackgroundImage ? backgroundImage : nil
    }

    private var backgroundColor: Color {
        Color(uiColor: resolvedStyle.background)
    }

    private var foregroundColor: Color {
        Color(uiColor: resolvedStyle.foreground)
    }

    private var resolvedStyle: ReaderStylePreset {
        themeMode == "3" ? .eInk : ReaderStylePreset.resolve(theme)
    }

    private var headerVisible: Bool {
        switch headerMode {
        case 1: true
        case 2: false
        default: hideStatusBar
        }
    }

    private var footerVisible: Bool { footerMode == 0 }

    private var pausesAutoReading: Bool {
        isWaitingForNextChapter
            || isWaitingForPreviousChapter
            || model.pagedChapterDirection != nil
            || showsReaderMenu
            || showsTableOfContents
            || showsBookmarks
            || illustrationChapter != nil
            || showsAutoReadControls
            || showsStyleControls
            || showsContentSearch
            || showsReplaceRules
            || showsReaderSettings
            || showsCacheManagement
            || showsClickActionSettings
            || showsContentEditor
    }


    private func readerTipBar(isHeader: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            readerTipRow(
                isHeader ? [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight] : [tipFooterLeft, tipFooterMiddle, tipFooterRight],
                date: context.date,
                showDivider: isHeader ? showHeaderLine : showFooterLine,
                isHeader: isHeader
            )
            .padding(.top, isHeader ? headerPaddingTop : max(footerPaddingTop - 6, 0))
            .padding(.bottom, isHeader ? headerPaddingBottom : footerPaddingBottom + min(footerPaddingTop, 6))
            .offset(y: isHeader ? 0 : -6)
        }
        .allowsHitTesting(isHeader)
    }

    private func readerTipRow(_ values: [Int], date: Date, showDivider: Bool, isHeader: Bool) -> some View {
        let texts = values.map { readerTipText($0, date: date) }
        let nonempty = values.indices.filter { !texts[$0].isEmpty }
        let hasTitle = nonempty.contains { values[$0] == 1 || values[$0] == 7 }
        let active = hasTitle ? nonempty : Array(values.indices)
        return HStack(spacing: isHeader ? 2 : 8) {
            if isHeader {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 18)
                .accessibilityLabel("退出阅读")
                .accessibilityIdentifier("reader.headerBack")
            }
            ForEach(active, id: \.self) { index in
                let isTitle = values[index] == 1 || values[index] == 7
                readerTipContent(values[index], text: texts[index])
                    .frame(maxWidth: hasTitle && !isTitle ? nil : .infinity,
                           alignment: index == 0 ? .leading : (index == 1 ? .center : .trailing))
                    .layoutPriority(isTitle ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: isHeader ? 11 : 10))
        .foregroundStyle(foregroundColor.opacity(0.48))
        .lineLimit(1)
        .padding(.leading, isHeader ? headerPaddingLeft : footerPaddingLeft)
        .padding(.trailing, isHeader ? headerPaddingRight : footerPaddingRight)
        .overlay(alignment: .bottom) {
            if showDivider { Divider().overlay(foregroundColor.opacity(0.35)) }
        }
    }

    @ViewBuilder
    private func readerTipContent(_ value: Int, text: String) -> some View {
        if [3, 8, 9, 10].contains(value) {
            HStack(spacing: 4) {
                if value == 8 || value == 9 { Text(text) }
                readerBatteryIcon
            }
        } else {
            Text(text)
        }
    }

    private var readerBatteryIcon: some View {
        let fraction = min(max(Double(batteryLevel), 0), 1)
        let percentage = Int((fraction * 100).rounded())
        let charging = batteryState == .charging || batteryState == .full
        return HStack(spacing: 0.5) {
            ZStack {
                RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 0.8)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(foregroundColor.opacity(0.22))
                        .frame(width: geometry.size.width * fraction)
                }
                .padding(1.5)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6, weight: .bold))
                }
            }
            .frame(width: 18, height: 9)
            RoundedRectangle(cornerRadius: 0.75).frame(width: 1.5, height: 4)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(batteryLevel >= 0 ? "电量 \(percentage)%" : "电量未知")
        .accessibilityValue(batteryState == .full ? "已充满" : (charging ? "充电中" : "未充电"))
    }

    private func readerTipText(_ value: Int, date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let chapterCount = max(model.chapters.filter { !$0.isVolume }.count, 1)
        let readableIndex = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        let chapterFraction = chapterPageFraction
        let progress = min(max((Double(max(readableIndex - 1, 0)) + chapterFraction) / Double(chapterCount), 0), 1)
        let progressText = String(format: "%.1f%%", progress * 100)
        switch value {
        case 1: return model.title
        case 2: return time
        case 3: return "电量"
        case 4: return "\(currentPage)/\(totalPages)"
        case 5: return progressText
        case 6: return "\(currentPage)/\(totalPages)  \(progressText)"
        case 7: return book.name
        case 8: return time
        case 9: return time
        case 10: return "电量"
        case 11: return "\(readableIndex)/\(chapterCount)"
        default: return ""
        }
    }

    private var readerChromeTint: Color {
        .primary
    }

    private var readerChromeBackground: some View {
        Rectangle().fill(.regularMaterial)
    }

    private var chapterProgress: Double {
        let chapter = max(model.chapters.filter { !$0.isVolume }.count, 1)
        let readable = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        let pagePart = chapterPageFraction
        return min(max((Double(max(readable - 1, 0)) + pagePart) / Double(chapter), 0), 1)
    }

    private var chapterPageFraction: Double {
        guard totalPages > 1 else { return 1 }
        return min(max(Double(max(currentPage - 1, 0)) / Double(totalPages - 1), 0), 1)
    }


    private var readerTopChrome: some View {
        HStack(spacing: 4) {
            readerChromeIconButton("chevron.backward", label: "返回") { dismiss() }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.title).lineLimit(1)
                    if model.isCaching {
                        Text("缓存 \(model.cacheCompleted)/\(model.cacheTotal)")
                            .accessibilityLabel("正在缓存章节")
                    } else if model.loadedFromCache {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel("已缓存")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            readerChromeIconButton(bookmarkSaved ? "bookmark.fill" : "bookmark", label: "书签") {
                addBookmark()
            }
            .accessibilityValue(bookmarkSaved ? "已添加" : "添加当前位置")
            .disabled(isSavingBookmark)
            readerMoreMenu
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var readerMoreMenu: some View {
        Menu {
            Button("搜索正文", systemImage: "magnifyingglass") {
                showsReaderMenu = false
                showsContentSearch = true
            }
            if book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
                Button("本章插图", systemImage: "photo.on.rectangle") {
                    showsReaderMenu = false
                    illustrationChapter = model.currentChapter
                }
            }
            Button("书签列表", systemImage: "bookmark") {
                showsReaderMenu = false
                showsBookmarks = true
            }
            Button(isAutoReading ? "停止自动阅读" : "自动阅读", systemImage: isAutoReading ? "stop" : "play") {
                if isAutoReading {
                    isAutoReading = false
                } else {
                    showsReaderMenu = false
                    showsAutoReadControls = true
                }
            }
            Divider()
            Button(resolvedStyle.id == "night" ? "切换为日间" : "切换为夜间", systemImage: resolvedStyle.id == "night" ? "sun.max" : "moon") {
                toggleNightTheme()
            }
            .disabled(themeMode == "3")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
    }

    private var readerBottomChrome: some View {
        VStack(spacing: 12) {
            readerChapterControls
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
            LazyVGrid(columns: readerToolbarColumns, spacing: 12) {
                readerChromeAction("list.bullet", "目录") {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                if model.canEditContent {
                    readerChromeAction("arrow.triangle.2.circlepath", "换源", action: openSourceSwitch)
                    .accessibilityIdentifier("reader.changeSource")
                    .accessibilityValue(book.originName)
                }
                readerChromeAction(speech.isSpeaking ? "stop" : "headphones", speech.isSpeaking ? "停止" : "朗读", isActive: speech.isSpeaking) { toggleSpeech() }
                readerChromeAction(
                    resolvedStyle.id == "night" ? "sun.max" : "moon",
                    resolvedStyle.id == "night" ? "日间" : "夜间",
                    action: toggleNightTheme
                )
                .disabled(themeMode == "3")
                .accessibilityIdentifier("reader.toggleDayNight")
                readerChromeAction("gearshape", "设置") {
                    showsReaderMenu = false
                    showsReaderSettings = true
                }
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var readerToolbarColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? (model.canEditContent ? 3 : 2) : (model.canEditContent ? 5 : 4)
        return Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    private var readerChapterControls: some View {
        HStack(spacing: 16) {
            readerChromeIconButton("chevron.left", label: "上一章") { moveChapter(-1) }
                .disabled(!model.canGoPrevious)
                .opacity(model.canGoPrevious ? 1 : 0.25)
            VStack(spacing: 8) {
                HStack {
                    let chapterCount = model.chapters.filter { !$0.isVolume }.count
                    let chapterNumber = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
                    if #available(iOS 16.0, *) {
                        ViewThatFits(in: .horizontal) {
                            Text("第 \(chapterNumber) 章 / 共 \(chapterCount) 章").fixedSize()
                            Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                        }
                    } else {
                        Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                    }
                    Spacer(minLength: 8)
                    Text(chapterProgress, format: .percent.precision(.fractionLength(0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                ProgressView(value: chapterProgress)
                    .tint(readerChromeTint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("阅读进度")
            .accessibilityValue(chapterProgress.formatted(.percent.precision(.fractionLength(0))))
            readerChromeIconButton("chevron.right", label: "下一章") { moveChapter(1) }
                .disabled(!model.canGoNext)
                .opacity(model.canGoNext ? 1 : 0.25)
        }
    }

    private func readerChromeIconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerChromeAction(_ icon: String, _ title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: min(toolbarIconSize, 28), weight: .regular))
                    .frame(height: 28)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var readerBrightnessBinding: Binding<Double> {
        Binding(
            get: { readerBrightness },
            set: { value in
                followsSystemBrightness = false
                readerBrightness = value
                storedReaderBrightness = value
                UIScreen.main.brightness = CGFloat(value)
            }
        )
    }

    private var followsSystemBrightnessBinding: Binding<Bool> {
        Binding(
            get: { followsSystemBrightness },
            set: { follows in
                followsSystemBrightness = follows
                storedReaderBrightness = follows ? 0 : readerBrightness
                if follows {
                    readerBrightness = brightnessBeforeReading
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
            }
        )
    }

    private func toggleNightTheme() {
        if resolvedStyle.id == "night" {
            theme = previousDayTheme == "night" ? "wechat" : previousDayTheme
        } else {
            previousDayTheme = resolvedStyle.id
            theme = "night"
        }
    }

    private func moveChapter(_ direction: Int) {
        stopSpeechIfNeeded()
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func turnPagedChapter(_ direction: Int) {
        if let pending = model.pagedChapterDirection {
            guard pending != direction else { return }
            model.cancelPagedChapterTurn()
        }
        Task {
            if await model.turnPagedChapter(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) {
                readerPosition = model.requestedPosition
            } else if model.pagedChapterError != nil {
                isAutoReading = false
            }
        }
    }

    private func requestNextChapter() {
        if pageAnimation == 3 {
            guard model.canGoNext else { isAutoReading = false; return }
            Task { await model.extendContinuousReading(direction: 1, rules: model.usesReplaceRules ? replaceRules.rules : []) }
            return
        }
        guard model.canGoNext, model.hasContinuationWindow else {
            isAutoReading = false
            return
        }
        if model.isContinuationWindowReady {
            isWaitingForNextChapter = false
            readerRenderRevision &+= 1
        } else {
            isWaitingForNextChapter = true
        }
    }

    private func requestPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow else { return }
        if model.isPreviousWindowReady {
            advanceToPreparedPreviousChapter()
        } else {
            isWaitingForPreviousChapter = true
        }
    }

    private func advanceToPreparedPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow, model.isPreviousWindowReady else { return }
        isWaitingForPreviousChapter = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        let position = max(model.previousContent.utf16.count - 1, 0)
        readerPosition = position
        model.promotePrevious(position: position)
    }

    private func startAutoReading() {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        isAutoReading = true
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn || isAutoReading
            || (readAloudWakeLock && speech.isSpeaking)
    }

    private func pageDidChange() {
        saveProgress()
        guard enableReadRecord else { return }
        Task { await activity.checkpoint(book) }
    }


    private var autoReadControls: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    HStack {
                        Text("自动翻页速度")
                        Spacer()
                        Text("\(autoReadSpeed)s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(autoReadSpeed) },
                            set: { autoReadSpeed = max(1, min(Int($0.rounded()), 120)) }
                        ),
                        in: 1...120,
                        step: 1
                    )
                } footer: {
                    Text("数值表示自动阅读一屏所用的秒数，范围 1–120 秒。")
                }
                Section {
                    Button("目录", systemImage: "list.bullet") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsTableOfContents = true }
                    }
                    Button("开始自动阅读", systemImage: "play.fill") {
                        showsAutoReadControls = false
                        startAutoReading()
                    }
                    Button("主菜单", systemImage: "menubar.rectangle") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsReaderMenu = true }
                    }
                    Button("停止自动阅读", systemImage: "stop.fill", role: .destructive) {
                        isAutoReading = false
                        showsAutoReadControls = false
                    }
                    Button("设置", systemImage: "gearshape") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsStyleControls = true }
                    }
                }
            }
            .navigationTitle("自动阅读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续阅读") { showsAutoReadControls = false }
                }
            }
        }
        .readingPresentationDetents([.medium])
    }


    private var styleControls: some View {
        ReadingNavigationStack {
            appearanceOptions
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsStyleControls = false }
                    }
                }
        }
        .readingPresentationDetents([.medium])
        .readingPresentationDragIndicator()
    }

    private var appearanceOptions: some View {
        Form {
            Section("快速排版") {
                Button("默认排版", systemImage: "text.alignleft", action: applyDefaultLayout)
                    .accessibilityIdentifier("reader.defaultLayout")
                HStack(spacing: 12) {
                    Button {
                        fontSize = max(5, fontSize - 1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 38, height: 32)
                    }
                    .readingSecondaryButtonStyle()

                    VStack(spacing: 2) {
                        Text("字号")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(fontSize))")
                            .font(.headline.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        fontSize = min(50, fontSize + 1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 38, height: 32)
                    }
                    .readingSecondaryButtonStyle()
                }

                HStack(spacing: 8) {
                    Text("行距")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    readerChoiceChip("紧凑", selected: lineSpacing <= 7) { lineSpacing = 6 }
                    readerChoiceChip("标准", selected: lineSpacing > 7 && lineSpacing < 18) { lineSpacing = 8 }
                    readerChoiceChip("宽松", selected: lineSpacing >= 18) { lineSpacing = 22 }
                }
                Toggle("两端对齐", isOn: $fullJustify)
            }

            Section("阅读背景") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ReaderStylePreset.legadoDefaults) { preset in
                            let isSelected = resolvedStyle.id == preset.id && activeBackgroundImage == nil
                            Button {
                                useBackgroundImage = false
                                theme = preset.id
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(uiColor: preset.background))
                                        .frame(width: 54, height: 72)
                                        .overlay {
                                            Text("文字")
                                                .font(.caption)
                                                .foregroundStyle(Color(uiColor: preset.foreground))
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(
                                                    Color(uiColor: preset.foreground).opacity(isSelected ? 0.4 : 0.12),
                                                    lineWidth: isSelected ? 1.25 : 0.75
                                                )
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Color(uiColor: preset.foreground))
                                                    .padding(6)
                                            }
                                        }
                                    Text(preset.name)
                                        .font(.caption2)
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }
                Button("选择背景图片", systemImage: "photo") {
                    backgroundError = nil
                    showsBackgroundPicker = true
                }
                if backgroundImage != nil {
                    HStack(spacing: 0) {
                        Text("使用背景图片")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { useBackgroundImage.toggle() }
                            .accessibilityHidden(true)
                        Toggle("使用背景图片", isOn: $useBackgroundImage)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Button("删除背景图片", systemImage: "trash", role: .destructive) {
                        ReaderBackgroundStore.remove()
                        backgroundImage = nil
                        useBackgroundImage = false
                    }
                }
                if let backgroundError {
                    Text(backgroundError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("文字") {
                valueSlider("字号", value: $fontSize, range: 5...50, format: { "\(Int($0))" })
                valueSlider("字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01, format: { String(format: "%.2f", $0) })
                valueSlider("行间距", value: $lineSpacing, range: 0...50, format: { "\(Int($0))" })
                valueSlider("段距", value: $paragraphSpacing, range: 0...50, format: { String(format: "%.1f", $0) })
                Picker("字重", selection: $fontWeight) {
                    Text("正常").tag(0)
                    Text("粗体").tag(1)
                    Text("细体").tag(2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("段落缩进")
                    TextField("请输入缩进字符", text: $paragraphIndent)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("段落缩进字符")
                    Text("控制每段开头的缩进，默认两个全角空格；清空后不缩进。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(fontPath.isEmpty ? "选择字体文件" : "更换字体文件", systemImage: "textformat") {
                    showsFontImporter = true
                }
                if !fontPath.isEmpty {
                    HStack {
                        Text("当前字体")
                        Spacer()
                        Text(URL(fileURLWithPath: fontPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                    }
                    Button("恢复默认字体", role: .destructive) { fontPath = "" }
                }
                if let fontError {
                    Text(fontError).font(.footnote).foregroundStyle(.red)
                }
                Picker("下划线", selection: $underlineMode) {
                    Text("关闭").tag(0)
                    Text("实线").tag(1)
                    Text("虚线").tag(2)
                }
            }

            Section("章节标题") {
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                .pickerStyle(.segmented)
                valueSlider("标题字号增量", value: $titleSize, range: -10...30, format: { String(format: "%+.0f", $0) })
                valueSlider("标题上间距", value: $titleTopSpacing, range: 0...100, format: { "\(Int($0))" })
                valueSlider("标题下间距", value: $titleBottomSpacing, range: 0...100, format: { "\(Int($0))" })
            }

            Section("翻页动画") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Self.pageAnimationChoices, id: \.0) { choice in
                            Button {
                                pageAnimation = choice.value
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: choice.icon)
                                        .font(.headline)
                                    Text(choice.title)
                                        .font(.caption2)
                                }
                                .foregroundStyle(pageAnimation == choice.value ? ReadingTheme.onAccent : Color.primary)
                                .frame(width: 58, height: 54)
                                .background(
                                    pageAnimation == choice.value ? ReadingTheme.accentFill : Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(pageAnimation == choice.value ? ReadingTheme.selectionBorder : .clear, lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(pageAnimation == choice.value ? .isSelected : [])
                        }
                    }
                }
                Text(pageAnimation == 3
                     ? "滚动模式连续滚动，点击中间区域打开菜单。"
                     : "当前模式按整屏翻页；左右滑动翻页，点击中间区域打开菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("正文边距") {
                valueSlider("左边距", value: $paddingLeft, range: 0...100, format: { "\(Int($0))" })
                valueSlider("右边距", value: $paddingRight, range: 0...100, format: { "\(Int($0))" })
                valueSlider("上边距", value: $paddingTop, range: 0...100, format: { "\(Int($0))" })
                valueSlider("下边距", value: $paddingBottom, range: 0...100, format: { "\(Int($0))" })
            }

            Section("页眉页脚") {
                Picker("页眉显示", selection: $headerMode) {
                    Text("状态栏显示时隐藏").tag(0)
                    Text("显示").tag(1)
                    Text("隐藏").tag(2)
                }
                Picker("页脚显示", selection: $footerMode) {
                    Text("显示").tag(0)
                    Text("隐藏").tag(1)
                }
                tipPicker("页眉左", selection: $tipHeaderLeft)
                tipPicker("页眉中", selection: $tipHeaderMiddle)
                tipPicker("页眉右", selection: $tipHeaderRight)
                tipPicker("页脚左", selection: $tipFooterLeft)
                tipPicker("页脚中", selection: $tipFooterMiddle)
                tipPicker("页脚右", selection: $tipFooterRight)
                Toggle("页眉分隔线", isOn: $showHeaderLine)
                Toggle("页脚分隔线", isOn: $showFooterLine)
            }

            Section("页眉边距") {
                valueSlider("左边距", value: $headerPaddingLeft, range: 0...100, format: { "\(Int($0))" })
                valueSlider("右边距", value: $headerPaddingRight, range: 0...100, format: { "\(Int($0))" })
                valueSlider("上边距", value: $headerPaddingTop, range: 0...100, format: { "\(Int($0))" })
                valueSlider("下边距", value: $headerPaddingBottom, range: 0...100, format: { "\(Int($0))" })
            }

            Section("页脚边距") {
                valueSlider("左边距", value: $footerPaddingLeft, range: 0...100, format: { "\(Int($0))" })
                valueSlider("右边距", value: $footerPaddingRight, range: 0...100, format: { "\(Int($0))" })
                valueSlider("上边距", value: $footerPaddingTop, range: 0...100, format: { "\(Int($0))" })
                valueSlider("下边距", value: $footerPaddingBottom, range: 0...100, format: { "\(Int($0))" })
            }
        }
        .navigationTitle("阅读样式")
        .navigationBarTitleDisplayMode(.inline)
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
            backgroundError = nil
            do {
                backgroundImage = try ReaderBackgroundStore.save(data)
                useBackgroundImage = true
            } catch {
                backgroundError = error.localizedDescription
            }
        } onError: { error in
            backgroundError = error.localizedDescription
        }
        .fileImporter(
            isPresented: $showsFontImporter,
            allowedContentTypes: [.font, .data],
            allowsMultipleSelection: false
        ) { result in
            fontError = nil
            do {
                guard let source = try result.get().first else { return }
                fontPath = try ReaderFontStore.install(from: source)
            } catch {
                fontError = error.localizedDescription
            }
        }
    }

    private func updateDefaultTypography() {
        guard defaultLayoutVersion < 3 else { return }
        // Preserve the previous preset's 36-point line height when replacing
        // the scaled system fallback with full-size PingFang.
        if defaultLayoutVersion < 1, fontPath.isEmpty, fontSize == 20, fontWeight == 0,
           letterSpacing == 0, lineSpacing == 12, paragraphSpacing == 10 {
            lineSpacing = 8
        }
        if defaultLayoutVersion < 2, titleSize == 0 { titleSize = 6 }
        if titleBottomSpacing == 0 { titleBottomSpacing = 32 }
        defaultLayoutVersion = 3
    }

    private func applyDefaultLayout() {
        defaultLayoutVersion = 3
        fontSize = 20
        fontPath = ""
        fontWeight = 0
        titleSize = 6
        titleBottomSpacing = 32
        letterSpacing = 0
        lineSpacing = 8
        paragraphSpacing = 10
        paragraphIndent = "　　"
        paddingLeft = 16
        paddingRight = 16
        paddingTop = 6
        paddingBottom = 6
        fullJustify = true
        hideStatusBar = true
        headerMode = 1
        headerPaddingTop = 0
        headerPaddingBottom = 10
        headerPaddingLeft = 20
        headerPaddingRight = 20
        tipHeaderLeft = 1
        tipHeaderMiddle = 0
        tipHeaderRight = 0
        showHeaderLine = false
        footerMode = 0
        footerPaddingTop = 6
        footerPaddingBottom = 6
        footerPaddingLeft = 20
        footerPaddingRight = 20
        tipFooterLeft = 6
        tipFooterMiddle = 0
        tipFooterRight = 8
        showFooterLine = false
    }

    private static let pageAnimationChoices: [(value: Int, title: String, icon: String)] = [
        (0, "覆盖", "rectangle.on.rectangle"),
        (1, "滑动", "rectangle.portrait.and.arrow.right"),
        (2, "仿真", "book.pages"),
        (3, "滚动", "arrow.up.and.down"),
        (4, "无动画", "rectangle")
    ]

    private func readerChoiceChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? ReadingTheme.onAccent : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? ReadingTheme.accentFill : Color.secondary.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(selected ? ReadingTheme.selectionBorder : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private static let readerTipChoices: [(Int, String)] = [
        (0, "无"), (7, "书名"), (1, "标题"), (2, "时间"), (3, "电量"),
        (10, "电量%"), (4, "页数"), (5, "进度(%)"), (11, "进度(xx/yyy)"),
        (6, "页数及进度"), (8, "时间及电量"), (9, "时间及电量%")
    ]

    private func tipPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.readerTipChoices, id: \.0) { value, name in
                Text(name).tag(value)
            }
        }
    }


    private var clickActions: [Int] {
        // Keep persisted action IDs stable; removed sync/page-turn actions become a no-op or menu.
        [clickActionTL, clickActionTC, clickActionTR, clickActionML, 0, clickActionMR, clickActionBL, clickActionBC, clickActionBR]
            .map {
                if $0 == 12 { return -1 }
                if $0 == 1 || $0 == 2 { return 0 }
                return $0
            }
    }

    private static let tapActionChoices: [(Int, String)] = [
        (-1, "无动作"), (0, "菜单"),
        (3, "下一章"), (4, "上一章"), (5, "朗读上一段"), (6, "朗读下一段"),
        (7, "添加书签"), (8, "编辑正文"), (9, "替换(启用/禁用)"), (10, "目录"),
        (11, "搜索正文"), (13, "暂停/继续朗读")
    ]

    private var clickActionSettings: some View {
        ReadingNavigationStack {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            VStack(spacing: 8) {
                                Text(["左上", "上中", "右上", "左中", "中央", "右中", "左下", "下中", "右下"][index])
                                    .font(.caption).foregroundStyle(.secondary)
                                if index == 4 {
                                    Text("固定：菜单")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(ReadingTheme.accent)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Picker("动作", selection: clickActionBinding(at: index)) {
                                        ForEach(Self.tapActionChoices, id: \.0) { action in
                                            Text(action.1).tag(action.0)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(10)
            .navigationTitle("点击区域设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsClickActionSettings = false }
                }
            }
        }
    }

    private func clickActionBinding(at index: Int) -> Binding<Int> {
        let binding: Binding<Int> = switch index {
        case 0: $clickActionTL
        case 1: $clickActionTC
        case 2: $clickActionTR
        case 3: $clickActionML
        case 5: $clickActionMR
        case 6: $clickActionBL
        case 7: $clickActionBC
        default: $clickActionBR
        }
        return Binding(
            get: {
                switch binding.wrappedValue {
                case 12: -1
                case 1, 2: 0
                default: binding.wrappedValue
                }
            },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func handleTapAction(_ action: Int) {
        switch action {
        case 0: showsReaderMenu.toggle()
        case 3: if model.canGoNext { moveChapter(1) }
        case 4: if model.canGoPrevious { moveChapter(-1) }
        case 5: speech.previousSegment()
        case 6: speech.nextSegment()
        case 7: addBookmark()
        case 8:
            guard model.canEditContent else { return }
            showsReaderMenu = false
            editedContent = model.content
            contentEditError = nil
            showsContentEditor = true
        case 9:
            showsReaderMenu = false
            let updatedBook = model.toggleReplaceRules(position: readerPosition)
            Task {
                await library.addOrUpdate(updatedBook)
            }
        case 10:
            showsReaderMenu = false
            showsTableOfContents = true
        case 11:
            showsReaderMenu = false
            showsContentSearch = true
        case 13:
            isAutoReading = false
            configureSpeech()
            if let engine = selectedHTTPEngine {
                speech.pauseOrResumeHTTP(engine: engine, text: model.content, continuesAcrossChapters: true)
            } else {
                speech.pauseOrResume(text: model.content, continuesAcrossChapters: true)
            }
        default: break
        }
    }


    private var quickAppearanceControls: some View {
        VStack(spacing: 16) {
            if showBrightness {
                HStack(spacing: 10) {
                    Text("亮度").font(.subheadline)
                    Slider(value: readerBrightnessBinding, in: 0.05...1)
                        .accessibilityLabel("阅读亮度")
                    HStack(spacing: 6) {
                        Text("随系统").font(.caption).accessibilityHidden(true)
                        Toggle("跟随系统亮度", isOn: followsSystemBrightnessBinding)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("reader.followSystemBrightness")
                    }
                }
            }

            HStack(spacing: 10) {
                Text("字号").font(.subheadline)
                HStack(spacing: 0) {
                    Button { fontSize = max(5, fontSize - 1) } label: {
                        Image(systemName: "minus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("减小字号")
                    .disabled(fontSize <= 5)
                    Text("\(Int(fontSize))")
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 32)
                        .accessibilityLabel("当前字号")
                        .accessibilityValue("\(Int(fontSize))")
                        .accessibilityIdentifier("reader.quickFontSize")
                    Button { fontSize = min(50, fontSize + 1) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("增大字号")
                    .disabled(fontSize >= 50)
                }
                .background(Color.secondary.opacity(0.1), in: Capsule())
                Spacer(minLength: 0)
                Button("默认排版", action: applyDefaultLayout)
                    .font(.caption)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("reader.quickDefaultLayout")
            }

            HStack(spacing: 8) {
                ForEach(["preset1", "night", "wechat", "preset2"], id: \.self) { id in
                    let preset = ReaderStylePreset.resolve(id)
                    let selected = resolvedStyle.id == id && activeBackgroundImage == nil
                    Button {
                        useBackgroundImage = false
                        if id == "night", resolvedStyle.id != "night" {
                            previousDayTheme = resolvedStyle.id
                        }
                        theme = id
                    } label: {
                        Circle()
                            .fill(Color(uiColor: preset.background))
                            .frame(width: 36, height: 36)
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(selected ? 0.7 : 0.18), lineWidth: selected ? 2 : 0.75)
                            }
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color(uiColor: preset.foreground))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(themeMode == "3")
                }
                Button {
                    showsMoreAppearance = true
                } label: {
                    Text("更多外观")
                        .font(.caption)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .accessibilityIdentifier("reader.moreAppearance")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var readerSettings: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    quickAppearanceControls
                }

                Section {
                    Toggle("两端对齐", isOn: $fullJustify)
                    Button("编辑本章正文", systemImage: "square.and.pencil") {
                        editedContent = model.content
                        contentEditError = nil
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsContentEditor = true }
                    }
                    .disabled(!model.canEditContent || model.content.isEmpty)
                    Button("重新获取本章", systemImage: "arrow.clockwise") {
                        showsReaderSettings = false
                        refreshCurrentChapter()
                    }
                    .disabled(model.isLoading || !model.canEditContent)
                } header: {
                    Text("正文")
                } footer: {
                    if !model.canEditContent {
                        Text("本地 TXT / EPUB 直接读取原文件。本章编辑与网络刷新仅对网络书籍开放。")
                    }
                }

                Section("屏幕") {
                    Picker("屏幕方向", selection: $screenOrientation) {
                        Text("跟随系统").tag("0")
                        Text("竖向").tag("1")
                        Text("横向").tag("2")
                        Text("跟随传感器").tag("3")
                        Text("反向竖屏").tag("4")
                        Text("反向横屏").tag("5")
                    }
                    Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                    if #available(iOS 16.0, *) {
                        Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
                    }
                    Toggle("隐藏状态栏", isOn: $hideStatusBar)
                    Toggle("显示亮度调节", isOn: $showBrightness)
                }

                Section("朗读") {
                    Picker("全局朗读引擎", selection: $appTTSEngine) {
                        Text("系统 TTS").tag("")
                        ForEach(httpTTSEngines) { engine in
                            Text(engine.name).tag(String(engine.id))
                        }
                    }
                    Picker("本书朗读引擎", selection: bookTTSEngineBinding) {
                        Text("跟随全局").tag("__global__")
                        Text("系统 TTS").tag("")
                        ForEach(httpTTSEngines) { engine in
                            Text(engine.name).tag(String(engine.id))
                        }
                    }
                    Picker("系统声音", selection: $systemTTSVoice) {
                        Text("系统默认中文声音").tag("")
                        ForEach(systemTTSVoices, id: \.identifier) { voice in
                            Text("\(voice.name)（\(voice.language)）").tag(voice.identifier)
                        }
                    }
                    Toggle("跟随系统语速", isOn: $ttsFollowSystem)
                    Stepper("朗读语速：\(ttsSpeechRate)", value: $ttsSpeechRate, in: 0...45)
                        .disabled(ttsFollowSystem)
                    Toggle("按页朗读", isOn: $readAloudByPage)
                    Toggle("流式播放在线音频", isOn: $streamReadAloudAudio)
                    Toggle("朗读时保持亮屏", isOn: $readAloudWakeLock)
                    Toggle("忽略音频焦点", isOn: $ignoreAudioFocus)
                    Toggle("忽略焦点时仍在来电时暂停", isOn: $pauseReadAloudWhilePhoneCalls)
                        .disabled(!ignoreAudioFocus)
                    Toggle("媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
                    Stepper("默认定时：\(ttsTimer) 分钟", value: $ttsTimer, in: 0...180)
                    if speechTimerRemaining > 0 {
                        Text("本次朗读还剩 \(speechTimerRemaining) 分钟")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let error = speech.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("操作") {
                    Button("自动阅读设置", systemImage: "play.circle") {
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsAutoReadControls = true }
                    }
                    Button("点击区域设置", systemImage: "square.grid.3x3") {
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsClickActionSettings = true }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .readingNavigationDestination(isPresented: $showsMoreAppearance) { appearanceOptions }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsReaderSettings = false }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
    }


    private var contentEditor: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .padding(8)
                if let contentEditError {
                    Text(contentEditError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsContentEditor = false }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("重置") { refreshEditorFromSource() }
                    Button("保存") { saveEditedContent() }
                        .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func refreshCurrentChapter() {
        stopSpeechIfNeeded()
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            readerPosition = min(readerPosition, model.content.utf16.count)
        }
    }

    private func refreshEditorFromSource() {
        contentEditError = nil
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            editedContent = model.content
            if let error = model.diagnostics.first(where: { $0.severity == .error }) {
                contentEditError = error.message
            }
        }
    }

    private func saveEditedContent() {
        contentEditError = nil
        Task {
            do {
                try await model.saveEditedContent(editedContent)
                readerPosition = min(readerPosition, editedContent.utf16.count)
                showsContentEditor = false
            } catch {
                contentEditError = error.localizedDescription
            }
        }
    }


    private var tableOfContents: some View {
        ReadingNavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack {
                        Label("已缓存 \(tocCachedChapterCount)/\(tocReadableChapterCount) 章", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("reader.toc.cachedSummary")
                        Spacer()
                        Button("定位当前") {
                            if let chapter = model.currentChapter { proxy.scrollTo(chapter.id, anchor: .center) }
                        }
                        .accessibilityIdentifier("reader.toc.current")
                    }
                    .font(.caption)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    if model.cacheTotal > 0 { tocCacheProgress }
                    List {
                        Section {
                            ForEach(tocChapters) { entry in
                                let chapter = entry.chapter
                                if chapter.isVolume {
                                    Label(chapter.title, systemImage: "books.vertical.fill")
                                        .font(.headline)
                                        .foregroundStyle(ReadingTheme.accent)
                                        .padding(.vertical, 4)
                                        .listRowBackground(ReadingTheme.accent.opacity(0.07))
                                } else {
                                    let isCurrent = chapter.id == model.currentChapter?.id
                                    let isCached = model.isChapterCached(chapter)
                                    Button {
                                        stopSpeechIfNeeded()
                                        saveProgress(immediate: true)
                                        readerJumpPosition = nil
                                        model.select(index: entry.index)
                                        readerPosition = 0
                                        showsTableOfContents = false
                                    } label: {
                                        ReaderTOCChapterLabel(title: chapter.title, number: entry.number,
                                            isCurrent: isCurrent, isCached: isCached,
                                            progress: isCurrent ? chapterProgress : 0)
                                            .equatable()
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(isCurrent ? ReadingTheme.accent.opacity(0.08) : Color.clear)
                                    .id(chapter.id)
                                    .accessibilityIdentifier("reader.toc.chapter.\(chapter.url)")
                                    .accessibilityValue(isCached ? "已缓存" : "未缓存")
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(book.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text("\(tocReadableChapterCount) 章")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: chapterProgress).tint(ReadingTheme.accent)
                                Text("第 \(max(model.currentIndex + 1, 1)) 章 · \(Int(chapterProgress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .textCase(nil)
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .accessibilityIdentifier("reader.toc.list")
                }
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $tocSearch, prompt: "搜索章节")
                .task {
                    await model.refreshCachedChapters()
                    guard !Task.isCancelled, tocSearch.isEmpty, let chapter = model.currentChapter else { return }
                    proxy.scrollTo(chapter.id, anchor: .center)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsTableOfContents = false } }
                    ToolbarItem(placement: .topBarTrailing) { tocCacheMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(tocDescending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") { tocDescending.toggle() }
                    }
                }
                .sheet(isPresented: $showsCacheManagement, onDismiss: {
                    Task { await model.refreshCachedChapters() }
                }) { readerCacheManagement }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }

    private var tocCacheProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.isCaching ? "正在缓存" : (model.cacheCompleted < model.cacheTotal ? "缓存已停止" : "缓存任务结束"))
                Spacer()
                Text("\(model.cacheCompleted)/\(model.cacheTotal)").monospacedDigit()
                if model.isCaching {
                    Button("停止缓存", role: .destructive) { model.cancelCaching() }
                        .accessibilityIdentifier("reader.toc.cacheStop")
                }
            }
            .font(.subheadline)
            if model.isCaching {
                ProgressView(value: Double(model.cacheCompleted), total: Double(max(model.cacheTotal, 1)))
            }
            Text("成功 \(model.cacheSucceeded) 章 · 失败 \(model.cacheFailed) 章")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.cacheFailed > 0 ? Color.orange : Color.secondary)
                .accessibilityIdentifier("reader.toc.cacheResult")
            if let error = model.cacheError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var tocReadableChapterCount: Int {
        model.chapters.filter { !$0.isVolume }.count
    }

    private var tocCachedChapterCount: Int {
        model.chapters.filter { !$0.isVolume && model.isChapterCached($0) }.count
    }

    private var tocCacheMenu: some View {
        Menu {
            if model.canEditContent {
                Button("缓存接下来 10 章", systemImage: "arrow.down.circle") { model.cacheNextTen() }
                    .disabled(model.chapters.isEmpty || model.isCaching)
                Button("缓存剩余章节", systemImage: "square.and.arrow.down.on.square") { model.cacheRemaining() }
                    .disabled(model.chapters.isEmpty || model.isCaching)
                if model.isCaching {
                    Button("停止缓存", systemImage: "stop.circle", role: .destructive) { model.cancelCaching() }
                }
                Divider()
            }
            Button("缓存管理", systemImage: "internaldrive") { showsCacheManagement = true }
        } label: {
            Text("缓存")
        }
        .accessibilityIdentifier("reader.toc.cacheMenu")
    }

    private var contentSearchSheet: some View {
        ReadingNavigationStack {
            Group {
                if contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadingUnavailableView("搜索正文", systemImage: "magnifyingglass", description: Text("输入本章正文关键字"))
                } else if contentSearchResults.isEmpty {
                    ReadingUnavailableView.search(text: contentSearchQuery)
                } else {
                    List(contentSearchResults) { paragraph in
                        Button {
                            readerPosition = paragraph.id
                            readerJumpPosition = nil
                            DispatchQueue.main.async { readerJumpPosition = paragraph.id }
                            showsContentSearch = false
                        } label: {
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("正文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $contentSearchQuery, prompt: "搜索本章")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showsContentSearch = false }
                }
            }
        }
    }

    private var contentSearchResults: [ReaderParagraph] {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return model.paragraphs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var tocChapters: [ReaderTOCEntry] {
        let query = tocSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        var number = 0
        let entries = model.chapters.enumerated().compactMap { index, chapter -> ReaderTOCEntry? in
            if !chapter.isVolume { number += 1 }
            guard query.isEmpty || chapter.title.localizedCaseInsensitiveContains(query) else { return nil }
            return ReaderTOCEntry(chapter: chapter, index: index, number: number)
        }
        return tocDescending ? Array(entries.reversed()) : entries
    }


    private var readerCacheManagement: some View {
        ReadingNavigationStack {
            CacheManagementView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showsCacheManagement = false }
                    }
                }
        }
    }

    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            Group {
                let bookmarks = activity.bookmarks(for: book)
                if bookmarks.isEmpty {
                    ReadingUnavailableView(
                        "本书还没有书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击顶部书签按钮即可记录当前位置。")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.chapterName).font(.headline).foregroundStyle(.primary)
                                if !bookmark.bookText.isEmpty {
                                    Text(bookmark.bookText).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("位置 \(bookmark.chapterPosition)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } }
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsBookmarks = false } } }
        }
    }

    private var bookmarkSaved: Bool {
        let page = currentPage - 1
        let range = pageAnimation != 3 && readerPageRanges.indices.contains(page) ? readerPageRanges[page] : nil
        return !model.bookmarks(at: readerPosition, in: activity.bookmarks, pageRange: range).isEmpty
    }

    private func addBookmark() {
        guard !isSavingBookmark, !bookmarkSaved, let chapter = model.currentChapter else { return }
        let currentBook = book
        let position = readerPosition
        let content = model.content
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.addBookmark(
                book: currentBook,
                chapter: chapter,
                position: position,
                content: content
            )
        }
    }

    private func jump(to bookmark: Bookmark) {
        guard let index = bookmark.resolvedChapterIndex(in: model.chapters) else { return }
        stopSpeechIfNeeded()
        saveProgress(immediate: true)
        model.select(index: index, position: bookmark.chapterPosition)
        readerPosition = bookmark.chapterPosition
        readerJumpPosition = nil
        showsBookmarks = false
    }


    private func saveProgress(immediate: Bool = false) {
        guard let chapter = model.currentChapter else { return }
        let position = readerPosition
        let currentBook = book
        progressSaveGeneration &+= 1
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak library] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled, let library else { return }
            await library.updateProgress(for: currentBook, chapter: chapter, position: position)
        }
    }


    private func stopSpeechIfNeeded() {
        speechStartGeneration &+= 1
        if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
    }

    private func restartSpeechAfterReaderLayoutChange() {
        readerPageRanges = []
        guard speech.isSpeaking || speech.isPaused else { return }
        speechStartGeneration &+= 1
        speech.stop()
        configureSpeech()
        startConfiguredSpeech()
    }

    private func toggleSpeech() {
        isAutoReading = false
        configureSpeech()
        if speech.isSpeaking || speech.isPaused {
            speechStartGeneration &+= 1
            speech.stop()
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        scheduleSpeechTimer()
        startConfiguredSpeech()
    }

    private func startConfiguredSpeech() {
        if readAloudByPage {
            guard !readerPageRanges.isEmpty else {
                guard !model.content.isEmpty else { return }
                let generation = speechStartGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard generation == speechStartGeneration,
                          readAloudByPage,
                          !speech.isSpeaking,
                          !speech.isPaused else { return }
                    startConfiguredSpeech()
                }
                return
            }
            let pageIndex = readerPageRanges.firstIndex { readerPosition < NSMaxRange($0) }
                ?? max(readerPageRanges.count - 1, 0)
            speechPageIndex = pageIndex
            speakPage(at: pageIndex, from: readerPosition)
            return
        }
        let start = model.paragraphs.lastIndex(where: { $0.id <= readerPosition }) ?? 0
        let text = model.paragraphs.indices.contains(start)
            ? model.paragraphs[start...].map(\.text).joined(separator: "\n")
            : model.content
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: text,
                continuesAcrossChapters: true,
                segmentIndexOffset: start
            )
            prefetchNextChapterSpeech(engine: engine)
        } else {
            speech.speak(text, continuesAcrossChapters: true, segmentIndexOffset: start)
        }
    }

    private func speakPage(at index: Int, from position: Int? = nil) {
        guard readerPageRanges.indices.contains(index) else {
            continueSpeechToNextChapter()
            return
        }
        let range = readerPageRanges[index]
        let start = min(max(position ?? range.location, range.location), NSMaxRange(range))
        let pageRange = NSRange(location: start, length: max(NSMaxRange(range) - start, 0))
        guard pageRange.length > 0 else {
            continueSpeechToNextPage()
            return
        }
        let pageText = (model.content as NSString).substring(with: pageRange)
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: pageText,
                continuesAcrossChapters: true,
                segmentIndexOffset: 0
            )
        } else {
            speech.speak(pageText, continuesAcrossChapters: true, segmentIndexOffset: 0)
        }
    }

    private func continueSpeechToNextPage() {
        guard readAloudByPage, readerPageRanges.indices.contains(speechPageIndex) else {
            continueSpeechToNextChapter()
            return
        }
        readerPosition = NSMaxRange(readerPageRanges[speechPageIndex])
        guard readerPageRanges.indices.contains(speechPageIndex + 1) else {
            continueSpeechToNextChapter()
            return
        }
        speechPageIndex += 1
        let nextPosition = readerPageRanges[speechPageIndex].location
        readerPosition = nextPosition
        readerJumpPosition = nextPosition
        speakPage(at: speechPageIndex)
    }

    private func prefetchNextChapterSpeech(engine: HttpTTS) {
        Task {
            guard let content = await model.nextSpeechContent(
                rules: model.usesReplaceRules ? replaceRules.rules : []
            ), selectedHTTPEngine?.id == engine.id else { return }
            speech.prefetchHTTP(engine: engine, text: content, limit: 10)
        }
    }

    private func continueSpeechToNextChapter() {
        guard model.canGoNext else {
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        model.goNext()
        readerPosition = model.requestedPosition
    }

    private func moveSpeechToChapter(direction: Int) {
        let canMove = direction < 0 ? model.canGoPrevious : model.canGoNext
        guard canMove else { return }
        speech.stop()
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func scheduleSpeechTimer() {
        speechTimerTask?.cancel()
        speechTimerRemaining = ttsTimer
        guard speechTimerRemaining > 0 else { return }
        speechTimerTask = Task { @MainActor in
            do {
                while speechTimerRemaining > 0 {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    if !speech.isSpeaking && !speech.isPaused && !resumesSpeechAfterChapterLoad {
                        speechTimerRemaining = 0
                        break
                    }
                    if !speech.isPaused { speechTimerRemaining -= 1 }
                    if speechTimerRemaining == 0 {
                        speech.stop()
                        resumesSpeechAfterChapterLoad = false
                    }
                }
            } catch { }
        }
    }

    private func configureSpeech() {
        speech.configure(
            followsSystemRate: ttsFollowSystem,
            speechRate: ttsSpeechRate,
            readByPage: readAloudByPage,
            streamsHTTPAudio: streamReadAloudAudio,
            voiceIdentifier: systemTTSVoice,
            ignoresAudioFocus: ignoreAudioFocus,
            pausesForPhoneCalls: pauseReadAloudWhilePhoneCalls,
            mediaButtonPerNext: mediaButtonPerNext,
            bookName: model.book.name,
            chapterTitle: model.title,
            author: model.book.author
        )
    }

    private static func globalPageAnimation() -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pageAnim") == nil,
           let legacy = defaults.object(forKey: "readerPageAnimation") as? NSNumber {
            defaults.set(legacy.intValue, forKey: "pageAnim")
        }
        return defaults.integer(forKey: "pageAnim")
    }

    private var selectedHTTPEngine: HttpTTS? {
        let value = model.book.readConfig?.ttsEngine ?? appTTSEngine
        guard let id = Int64(value) else { return nil }
        return httpTTSEngines.first { $0.id == id }
    }

    private var systemTTSVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var bookTTSEngineBinding: Binding<String> {
        Binding(
            get: { model.book.readConfig?.ttsEngine ?? "__global__" },
            set: { value in
                let updated = model.setTTSEngine(value == "__global__" ? nil : value)
                Task { await library.addOrUpdate(updated) }
            }
        )
    }

    private func loadHTTPEngines() async {
        guard let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        if values.isEmpty,
           let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) {
            values = defaults
            try? await repository.saveHttpTTS(values)
        }
        httpTTSEngines = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !appTTSEngine.isEmpty, selectedHTTPEngine == nil { appTTSEngine = "" }
    }
}

#if DEBUG
private actor ReaderPagedBoundaryTestLoader: ChapterContentLoading {
    private var failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        if chapter.index != 20 {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if failFirst {
                failFirst = false
                return .init(diagnostics: [.init(severity: .error, code: "content.request", message: "模拟章节加载失败", rule: chapter.url)])
            }
        }
        return .init(title: chapter.title, content: "第\(chapter.index + 1)章的合成测试正文。")
    }
}

private struct ReaderFailureTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: ProcessInfo.processInfo.arguments.contains("-uiReaderPartialFailure") ? "本章只加载了第一页正文。" : "",
              diagnostics: [.init(severity: .error, code: "content.request", message: "测试书源正文请求失败", rule: chapter.url)])
    }
}
#endif

private struct ReaderTOCEntry: Identifiable {
    let chapter: BookChapter
    let index: Int
    let number: Int
    var id: String { chapter.id }
}

private struct ReaderTOCChapterLabel: View, Equatable {
    let title: String
    let number: Int
    let isCurrent: Bool
    let isCached: Bool
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isCurrent ? ReadingTheme.accent : (isCached ? Color.primary : Color.secondary))
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(isCurrent || isCached ? Color.primary : Color.secondary).lineLimit(2)
                if isCurrent {
                    HStack(spacing: 6) {
                        Text("正在阅读")
                        ProgressView(value: progress).tint(ReadingTheme.accent)
                    }
                    .font(.caption2).foregroundStyle(ReadingTheme.accent)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(ReadingTheme.accent)
                .opacity(isCurrent || isCached ? 1 : 0)
                .frame(width: 18)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}
