import SwiftUI
import UniformTypeIdentifiers

struct BackupSyncView: View {
    @EnvironmentObject private var model: BackupSyncModel
    @State private var includesLocalBooks = true
    @State private var includesCachedChapters = false
    @State private var importsBackup = false
    @State private var confirmsCloud = false
    @State private var confirmsWebDAV = false
    @State private var disconnectsWebDAV = false
    @State private var disconnectsGoogle = false
    @State private var customIntervalProvider: BackupCloudProvider?

    var body: some View {
        Form {
            fileBackupSection
            webDAVSection
            googleSection
            iCloudSection
        }
        .navigationTitle("备份与同步")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshAccount()
            #if DEBUG
            await model.prepareDemoPreviewIfRequested()
            #endif
        }
        .fileImporter(isPresented: $importsBackup, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url): Task { await model.prepare(url) }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { model.message = error.localizedDescription }
            }
        }
        .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { model.cleanupExport() } })) {
            if let url = model.exportURL { BackupExportPicker(url: url) { model.cleanupExport() } }
        }
        .sheet(item: $model.prepared, onDismiss: { model.finishRestorePreview() }) { prepared in
            restorePreview(prepared)
        }
        .sheet(item: $customIntervalProvider) { provider in
            CustomBackupIntervalView(provider: provider, minutes: model.automaticBackupInterval(for: provider))
        }
        .alert("备份与同步", isPresented: Binding(get: { model.message != nil && model.prepared == nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var fileBackupSection: some View {
        Section {
                Toggle("包含本地 TXT / EPUB 书籍", isOn: $includesLocalBooks)
                Toggle("包含已缓存正文", isOn: $includesCachedChapters)
                Button {
                    Task { await model.export(localBooks: includesLocalBooks, cachedChapters: includesCachedChapters) }
                } label: {
                    BackupActionLabel("导出备份", systemImage: "square.and.arrow.up", isLoading: model.operation == .export)
                }.accessibilityIdentifier("backup.export")
                Button { importsBackup = true } label: {
                    BackupActionLabel("从备份恢复", systemImage: "square.and.arrow.down", isLoading: model.operation == .prepare)
                }.accessibilityIdentifier("backup.import")
            } header: { Text("文件备份") } footer: {
                Text("包含书架、进度、阅读统计、历史记录、书签、订阅、书源和设置。自定义字体和背景图片请另行保存。")
            }
            .disabled(model.isWorking)
    }

    private var webDAVSection: some View {
        Section {
            NavigationLink {
                WebDAVBackupSettingsView()
            } label: { Label(model.webDAVConnected ? "管理 WebDAV 连接" : "连接 WebDAV", systemImage: "externaldrive.badge.icloud") }
                .accessibilityIdentifier("backup.webdav.configure")
            if model.webDAVConnected {
                Text(model.webDAVUsername).foregroundStyle(.secondary).accessibilityIdentifier("backup.webdav.account")
                automaticBackupControls(.webDAV)
                Toggle("WebDAV 自动同步", isOn: Binding(get: { model.webDAVEnabled }, set: { value in
                    if value { confirmsWebDAV = true } else { Task { await model.setWebDAVEnabled(false) } }
                })).accessibilityIdentifier("backup.webdav.toggle")
                .alert("启用 WebDAV 同步", isPresented: $confirmsWebDAV) {
                    Button("启用并合并") { Task { await model.setWebDAVEnabled(true) } }
                    Button("取消", role: .cancel) { }
                } message: { Text("将书架、进度、书签、书源和设置合并到当前 WebDAV。首次同项采用云端配置，阅读进度保留较新的记录。不包含本地书及正文文件；将停用其他自动同步方式。") }
                Button { Task { await model.synchronizeWebDAV() } } label: {
                    BackupActionLabel("立即同步", systemImage: "arrow.triangle.2.circlepath", isLoading: model.operation == .webDAVSync)
                }.accessibilityIdentifier("backup.webdav.sync")
                Button { Task { await model.uploadBackup(to: .webDAV) } } label: {
                    BackupActionLabel("备份到 WebDAV", systemImage: "arrow.up.doc", isLoading: model.operation == .upload(.webDAV))
                }.accessibilityIdentifier("backup.webdav.upload")
                NavigationLink("查看云端备份") { RemoteBackupListView(provider: .webDAV) }
                    .accessibilityIdentifier("backup.webdav.list")
                if let date = model.webDAVLastSync { LabeledContentCompat("最近成功同步", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button("解除 WebDAV 连接", role: .destructive) { disconnectsWebDAV = true }
                    .alert("解除 WebDAV 连接？", isPresented: $disconnectsWebDAV) {
                        Button("解除连接", role: .destructive) { model.disconnectWebDAV() }
                        Button("取消", role: .cancel) { }
                    } message: { Text("停止自动同步并移除本机保存的凭据，保留本机和云端数据。") }
            }
        } header: { Text("WebDAV") } footer: {
            Text("兼容坚果云等 WebDAV 服务。自动同步用于合并进度；自动备份保存可恢复的历史副本。云端不包含本地 TXT / EPUB 和正文缓存，完整迁移请导出文件备份。")
        }
        .disabled(model.isWorking)
    }

    private var googleSection: some View {
        Section {
            if model.googleRestoring { ProgressView("正在恢复 Google 登录…") }
            if let notice = model.googleNotice { Text(notice).foregroundStyle(.secondary) }
            if let email = model.googleEmail {
                Label(email, systemImage: "person.crop.circle").accessibilityIdentifier("backup.google.account")
                automaticBackupControls(.googleDrive)
                Button { Task { await model.uploadBackup(to: .googleDrive) } } label: {
                    BackupActionLabel("备份到 Google Drive", systemImage: "arrow.up.doc", isLoading: model.operation == .upload(.googleDrive))
                }.accessibilityIdentifier("backup.google.upload")
                NavigationLink("查看云端备份") { RemoteBackupListView(provider: .googleDrive) }
                    .accessibilityIdentifier("backup.google.list")
                Button("解除 Google 绑定", role: .destructive) { disconnectsGoogle = true }
                    .alert("解除 Google 绑定？", isPresented: $disconnectsGoogle) {
                        Button("解除绑定", role: .destructive) { model.disconnectGoogle() }
                        Button("取消", role: .cancel) { }
                    } message: { Text("移除本机登录状态，保留本机数据和 Google Drive 中的备份。") }
            } else {
                Button { Task { await model.bindGoogle() } } label: {
                    BackupActionLabel("绑定 Google 账号", systemImage: "person.crop.circle.badge.plus", isLoading: model.operation == .googleBinding)
                }.accessibilityIdentifier("backup.google.bind")
                    .disabled(!model.googleConfigured)
                if !model.googleConfigured { Text("Google 绑定将在应用登录配置完成后可用。").foregroundStyle(.secondary) }
            }
        } header: { Text("Google Drive") } footer: {
            Text("通过 Google 官方登录授权，仅访问本应用的专用备份空间。每次备份单独保存，可选择旧备份预览并合并恢复；不包含本地 TXT / EPUB 和正文缓存。")
        }
        .disabled(model.isWorking || model.googleRestoring)
    }

    @ViewBuilder
    private func automaticBackupControls(_ provider: BackupCloudProvider) -> some View {
        Toggle(isOn: Binding(
            get: { model.automaticBackupProviders.contains(provider) },
            set: { value in Task { await model.setAutomaticBackup(value, for: provider) } }
        )) {
            BackupActionLabel("自动备份", isLoading: model.operation == .automaticBackup(provider))
        }.accessibilityIdentifier("backup.\(provider.rawValue).automatic")
        let minutes = model.automaticBackupInterval(for: provider)
        let presets = [5, 15, 30, 60, 120, 360, 1440]
        Picker("备份间隔", selection: Binding(
            get: { model.automaticBackupInterval(for: provider) },
            set: { value in
                if value == -1 { customIntervalProvider = provider }
                else { Task { await model.setAutomaticBackupInterval(value, for: provider) } }
            }
        )) {
            ForEach(presets, id: \.self) { value in Text(backupIntervalLabel(value)).tag(value) }
            if !presets.contains(minutes) { Text(backupIntervalLabel(minutes)).tag(minutes) }
            Text("自定义…").tag(-1)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("backup.\(provider.rawValue).interval")
        .accessibilityValue(backupIntervalLabel(minutes))
        if let date = model.automaticBackupDates[provider] {
            LabeledContentCompat("最近自动备份", value: date.formatted(date: .abbreviated, time: .shortened))
                .accessibilityIdentifier("backup.\(provider.rawValue).lastAutomatic")
        }
        if let error = model.automaticBackupErrors[provider] {
            Text("自动备份未完成：\(error)").foregroundStyle(.secondary)
                .accessibilityIdentifier("backup.\(provider.rawValue).automaticError")
        }
    }

    private var iCloudSection: some View {
        Section {
            if model.iCloudConfigured {
                Label(model.accountStatus, systemImage: "icloud")
                    .accessibilityIdentifier("backup.accountStatus")
                Toggle("iCloud 自动同步", isOn: Binding(get: { model.enabled }, set: { value in
                    if value { confirmsCloud = true } else { model.disable() }
                }))
                .accessibilityIdentifier("backup.cloudToggle")
                .alert("启用 iCloud 同步", isPresented: $confirmsCloud) {
                    Button("启用并合并") { Task { await model.setEnabled(true) } }
                    Button("取消", role: .cancel) { }
                } message: { Text("将所选应用数据合并到当前系统 iCloud 账号的私有空间，不包含正文与本地书文件。") }
                Button { Task { await model.synchronize() } } label: {
                    BackupActionLabel("立即同步", systemImage: "arrow.triangle.2.circlepath", isLoading: model.operation == .iCloudSync)
                }
                    .disabled(!model.enabled || model.isWorking)
                    .accessibilityIdentifier("backup.sync")
                if let date = model.lastSync { LabeledContentCompat("最近成功同步", value: date.formatted(date: .abbreviated, time: .shortened)) }
            } else { Label("此版本暂未启用 iCloud", systemImage: "icloud.slash").foregroundStyle(.secondary) }
            } header: { Text("iCloud") } footer: {
                Text(model.iCloudConfigured
                     ? "使用系统已登录的 iCloud 账号。开启后在启动、回到前台和离开应用时尝试同步书架、阅读进度、书签、书源与设置。首次合并时同项采用云端配置，阅读进度保留较新的记录。本地书及正文缓存请用完整文件备份迁移。关闭同步会保留两端数据。"
                     : "可使用 WebDAV 同步、Google Drive 备份或文件备份。")
            }
        .disabled(model.isWorking)
    }

    private func restorePreview(_ prepared: PreparedLibraryBackup) -> some View {
        let snapshot = prepared.manifest.snapshot
        let minutes = snapshot.records.reduce(Int64(0)) { $0 + max($1.readTime, 0) } / 60_000
        return ReadingNavigationStack {
                Form {
                    Section("备份内容") {
                        Text(prepared.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContentCompat("书架", value: "\(prepared.manifest.snapshot.books.count) 本")
                        LabeledContentCompat("书源", value: "\(prepared.manifest.snapshot.sources.count) 个")
                        LabeledContentCompat("书签", value: "\(prepared.manifest.snapshot.bookmarks.count) 个")
                        LabeledContentCompat("阅读记录", value: "\(snapshot.records.count) 条")
                            .accessibilityIdentifier("backup.preview.readRecords")
                        LabeledContentCompat("累计阅读", value: "\(minutes) 分钟")
                            .accessibilityIdentifier("backup.preview.readTime")
                        LabeledContentCompat("搜索历史", value: "\(snapshot.searchKeywords.count) 条")
                            .accessibilityIdentifier("backup.preview.searchHistory")
                        LabeledContentCompat("订阅阅读记录", value: "\(snapshot.rssReadRecords.count) 条")
                            .accessibilityIdentifier("backup.preview.rssHistory")
                        LabeledContentCompat("本地书文件", value: "\(prepared.manifest.attachments.filter { $0.path.hasPrefix("local/") }.count) 个")
                        LabeledContentCompat("正文缓存", value: "\(prepared.manifest.attachments.filter { $0.path.hasPrefix("chapters/") }.count) 章")
                    }
                    Section {
                        Button { Task { await model.restore() } } label: {
                            BackupActionLabel("合并恢复", isLoading: model.operation == .restore)
                        }.accessibilityIdentifier("backup.restoreConfirm")
                    } footer: { Text("保留现有书架和较新阅读进度。阅读统计合并后不会重复累计或减少；同名作者的不同网址保留本机版本。") }
                }
                .navigationTitle("恢复预览")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancelRestore() }.disabled(model.isWorking) } }
                .disabled(model.isWorking)
                .alert("恢复未完成", isPresented: Binding(get: { model.message != nil && model.prepared != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("好") { model.message = nil }
                } message: { Text(model.message ?? "") }
            }
            .interactiveDismissDisabled(model.isWorking)
    }
}

private struct BackupActionLabel: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool

    init(_ title: String, systemImage: String? = nil, isLoading: Bool) {
        self.title = title; self.systemImage = systemImage; self.isLoading = isLoading
    }

    var body: some View {
        HStack {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
            Spacer(minLength: 12)
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在处理")
                    .accessibilityIdentifier("backup.rowProgress")
            }
        }
    }
}

private func backupIntervalLabel(_ minutes: Int) -> String {
    if minutes.isMultiple(of: 1440) { return "\(minutes / 1440) 天" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
    return "\(minutes) 分钟"
}

private struct CustomBackupIntervalView: View {
    @EnvironmentObject private var model: BackupSyncModel
    @Environment(\.dismiss) private var dismiss
    let provider: BackupCloudProvider
    @State private var minutesText: String
    @State private var invalidMinutes = false
    @State private var isSaving = false

    init(provider: BackupCloudProvider, minutes: Int) {
        self.provider = provider
        _minutesText = State(initialValue: String(minutes))
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    HStack {
                        Text("间隔（分钟）")
                        TextField("1～10080", text: $minutesText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("backup.interval.customMinutes")
                    }
                    if invalidMinutes { Text("请输入 1～10080 分钟").foregroundStyle(.red) }
                }
            }
            .navigationTitle("自定义间隔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let minutes = Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
                              AutomaticLibraryBackup.intervalMinutesRange.contains(minutes) else { invalidMinutes = true; return }
                        isSaving = true
                        Task {
                            if await model.setAutomaticBackupInterval(minutes, for: provider) { dismiss() }
                            isSaving = false
                        }
                    }.accessibilityIdentifier("backup.interval.save")
                }
            }
            .disabled(isSaving || model.isWorking)
        }
    }
}

private struct WebDAVBackupSettingsView: View {
    @EnvironmentObject private var model: BackupSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("https://dav.jianguoyun.com/dav/", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("backup.webdav.address")
                TextField("账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("backup.webdav.username")
                SecureField("应用专用密码", text: $password).textContentType(.password).accessibilityIdentifier("backup.webdav.password")
                Button {
                    Task {
                        if await model.connectWebDAV(address: address, username: username, password: password) { password = ""; dismiss() }
                        else { error = model.message; model.message = nil }
                    }
                } label: {
                    BackupActionLabel("测试并保存连接", isLoading: model.operation == .webDAVConnection)
                }.disabled(address.isEmpty || username.isEmpty || password.isEmpty || model.isWorking)
                    .accessibilityIdentifier("backup.webdav.save")
            } footer: { Text("使用 HTTPS 地址和云服务生成的应用专用密码。凭据保存在此设备的系统钥匙串中，不会放入备份文件。应用会在服务器中使用 Legado 文件夹。") }
        }
        .navigationTitle("WebDAV 连接")
        .onAppear { address = model.webDAVAddress; username = model.webDAVUsername }
        .onDisappear { password = "" }
        .alert("连接未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

private struct RemoteBackupListView: View {
    @EnvironmentObject private var model: BackupSyncModel
    let provider: BackupCloudProvider
    var body: some View {
        List {
            if model.remoteListLoaded && model.remoteBackups.isEmpty { Text("还没有云端备份，请先返回并创建一次备份。").foregroundStyle(.secondary) }
            ForEach(model.remoteBackups) { backup in
                Button {
                    Task { await model.previewRemoteBackup(backup, from: provider) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(backup.date?.formatted(date: .abbreviated, time: .shortened) ?? backup.name)
                            Text(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if model.operation == .remotePreview(provider, backup.id) {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在读取备份")
                                .accessibilityIdentifier("backup.remote.loading.\(backup.id)")
                        }
                    }
                }.accessibilityIdentifier("backup.remote.item.\(backup.id)")
            }
        }
        .navigationTitle(provider.title + " 备份")
        .toolbar {
            Button { Task { await model.loadRemoteBackups(from: provider) } } label: {
                if model.operation == .remoteList(provider) { ProgressView().accessibilityLabel("正在读取备份") }
                else { Label("刷新", systemImage: "arrow.clockwise") }
            }.disabled(model.isWorking)
        }
        .task { await model.loadRemoteBackups(from: provider) }
        .disabled(model.isWorking)
        .alert("备份与同步", isPresented: Binding(get: { model.message != nil && model.prepared == nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct LabeledContentCompat: View {
    let title: String; let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) } }
}

private struct BackupExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(_ completion: @escaping () -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion() }
    }
}
