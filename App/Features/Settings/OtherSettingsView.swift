import SwiftUI
import WebKit

struct OtherSettingsView: View {
    @AppStorage("auto_refresh") private var autoRefresh = false
    @AppStorage("onlyUpdateRead") private var onlyUpdateRead = false
    @AppStorage("defaultHomePage") private var defaultHomePage = "bookshelf"
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var maintenance: Maintenance?
    @State private var isWorking = false
    @State private var message: String?

    private enum Maintenance: String, Identifiable {
        case webCache = "清理网页缓存"
        case database = "整理数据库"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("启动与书架") {
                Picker("启动页面", selection: $defaultHomePage) {
                    Text("书架").tag("bookshelf")
                    Text("发现").tag("explore")
                    Text("统计").tag("statistics")
                    Text("设置").tag("settings")
                }
                Toggle("启动时更新书架", isOn: $autoRefresh)
                Toggle("自动更新仅检查读过的书", isOn: $onlyUpdateRead).disabled(!autoRefresh)
            }
            Section("网络与存储") {
                NavigationLink {
                    NetworkSettingsView()
                } label: { Label("网络与缓存设置", systemImage: "network") }
                NavigationLink {
                    CacheManagementView()
                } label: { Label("章节缓存管理", systemImage: "internaldrive") }
                Button("清理网页缓存", systemImage: "globe") { maintenance = .webCache }
                Button("整理数据库", systemImage: "externaldrive.badge.checkmark") { maintenance = .database }
            }
            Section {
                Toggle("记录运行日志", isOn: Binding(get: { settings.recordLog }, set: { enabled in
                    var value = ApplicationSettingsStore.shared.settings
                    value.recordLog = enabled
                    do { try ApplicationSettingsStore.shared.save(value); settings = value }
                    catch { message = error.localizedDescription }
                }))
                NavigationLink {
                    DiagnosticLogView()
                } label: { Label("日志与诊断", systemImage: "doc.text.magnifyingglass") }
            } header: { Text("诊断") } footer: {
                Text("日志仅保存在本机，最多保留 500 条。网络日志不记录请求正文与 Header，URL 查询参数和常见凭据会隐藏。")
            }
        }
        .navigationTitle("其他设置")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView("正在处理…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onAppear { settings = ApplicationSettingsStore.shared.settings }
        .confirmationDialog(maintenance?.rawValue ?? "", isPresented: Binding(
            get: { maintenance != nil }, set: { if !$0 { maintenance = nil } }
        ), titleVisibility: .visible) {
            if let operation = maintenance {
                Button(operation.rawValue) { Task { await perform(operation) } }
            }
            Button("取消", role: .cancel) { maintenance = nil }
        } message: {
            Text(maintenance == .webCache ? "清理网页和图片的临时缓存，保留登录 Cookie、书架和阅读进度。" : "回收数据库中的空闲空间，保留全部书籍、规则和阅读记录。")
        }
        .alert("操作结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    @MainActor private func perform(_ operation: Maintenance) async {
        maintenance = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch operation {
            case .webCache:
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache], modifiedSince: .distantPast)
                URLCache.shared.removeAllCachedResponses()
            case .database:
                let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
                try await database.compact()
            }
            DiagnosticLog.shared.record(category: "存储", message: "\(operation.rawValue)完成")
            message = "\(operation.rawValue)完成"
        } catch {
            DiagnosticLog.shared.record(.error, category: "存储", message: error.localizedDescription)
            message = error.localizedDescription
        }
    }
}

struct NetworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                ReadingTextField("留空使用默认浏览器 UA", text: $settings.userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("User-Agent")
            } header: { Text("默认 User-Agent") } footer: {
                Text("书源或 RSS 单独设置的 UA 优先于此项。")
            }
            Section {
                TextField("例如 http://127.0.0.1:7890", text: $settings.proxy)
                    .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("全局代理")
            } header: { Text("全局代理") } footer: {
                Text("支持 HTTP、HTTPS 和 SOCKS5 地址，不含账号密码。书源代理优先于全局代理；使用代理时由代理解析域名。")
            }
            Section {
                TextEditor(text: $settings.hosts)
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 130)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("Hosts")
            } header: { Text("自定义 Hosts") } footer: {
                Text("每行填写 IP地址 域名，例如 192.168.1.2 books.example.com。支持 IPv4、IPv6 和 # 注释。适用于应用内 HTTP/HTTPS 请求；系统网页、登录网页和系统媒体播放器使用系统网络设置。")
            }
            Section("连接") {
                Picker("请求超时", selection: $settings.timeoutSeconds) {
                    Text("跟随书源").tag(0)
                    ForEach([5, 10, 15, 30, 60, 120, 180, 300], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Stepper("搜索并发数：\(settings.concurrentSources)", value: $settings.concurrentSources, in: 1...64)
                Toggle("兼容无效证书的书源", isOn: $settings.ignoreCertificateErrors)
                Text("证书兼容开启时允许自签名或过期证书；关闭后由系统验证 HTTPS 证书。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("章节缓存") {
                Picker("容量上限", selection: $settings.chapterCacheMB) {
                    ForEach([16, 32, 64, 128, 256, 512, 1024, 2048, 4096], id: \.self) {
                        Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0)
                    }
                }
                Stepper(settings.prefetchChapters == 0 ? "关闭章节预加载" : "预加载 \(settings.prefetchChapters) 章", value: $settings.prefetchChapters, in: 0...20)
                Text("默认提前缓存后续 10 章，翻章或滚动进入下一章时继续补齐；已缓存章节不重复下载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("超出上限时清理最久未读取的章节；容量调整在保存时生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复本页默认值") {
                    let recordLog = settings.recordLog
                    settings = .init()
                    settings.recordLog = recordLog
                }
            }
        }
        .navigationTitle("网络与缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(isSaving)
            }
        }
        .disabled(isSaving)
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            settings.recordLog = ApplicationSettingsStore.shared.settings.recordLog
            try ApplicationSettingsStore.shared.save(settings)
            try await ChapterContentCache.live().pruneIfNeeded()
            DiagnosticLog.shared.record(category: "设置", message: "网络与缓存设置已保存")
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
