import SwiftUI

struct WebDAVBackupView: View {
    @ObservedObject private var coordinator = WebDAVBackupCoordinator.shared
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var rules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var rss: RSSLibraryModel
    @EnvironmentObject private var subscriptions: RuleSubscriptionModel
    @State private var deletingBackup: WebDAVRemoteBackup?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            connectionSection
            automationSection
            actionSection
            if let preview = coordinator.previewBackup {
                restorePreviewSection(preview)
            }
            historySection
            if coordinator.isWorking {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(coordinator.workingLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let status = coordinator.statusMessage {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            status,
                            systemImage: coordinator.isStatusError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .foregroundStyle(coordinator.isStatusError ? Color.red : Color.green)
                        if let detail = coordinator.statusDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("WebDAV 云备份")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(coordinator.isWorking)
        .onDisappear { coordinator.persistConfiguration() }
        .alert("删除云端备份？", isPresented: Binding(
            get: { deletingBackup != nil },
            set: { if !$0 { deletingBackup = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deletingBackup {
                    deletingBackup = nil
                    Task { await coordinator.deleteRemoteBackup(target) }
                }
            }
            Button("取消", role: .cancel) { deletingBackup = nil }
        } message: {
            Text("将从 WebDAV 服务器永久删除 \(deletingBackup?.fileName ?? "")。")
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("服务器地址（如 https://dav.jianguoyun.com/dav/）", text: $coordinator.settings.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            TextField("远端目录（如 LegadoBackups）", text: $coordinator.settings.remoteDirectory)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            TextField("账号", text: $coordinator.settings.username)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            SecureField("密码或应用专用密码", text: $coordinator.password)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("测试连接并刷新列表") {
                Task { await coordinator.testConnection() }
            }
            .disabled(!coordinator.credentials.isConfigured)
        } header: {
            Text("WebDAV 服务器")
        } footer: {
            Text("支持坚果云、Nextcloud、Alist、群晖等标准 WebDAV 服务。密码保存在本机钥匙串；无钥匙串权限时保存在本机受保护的文件中。")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle("开启自动备份", isOn: $coordinator.settings.autoBackupEnabled)
                .onChange(of: coordinator.settings.autoBackupEnabled) { _ in coordinator.persistConfiguration() }
            Picker("自动备份间隔", selection: $coordinator.settings.autoBackupIntervalHours) {
                Text("每 6 小时").tag(6)
                Text("每 12 小时").tag(12)
                Text("每 24 小时").tag(24)
                Text("每 72 小时").tag(72)
            }
            .disabled(!coordinator.settings.autoBackupEnabled)
            .onChange(of: coordinator.settings.autoBackupIntervalHours) { _ in coordinator.persistConfiguration() }
            Toggle("备份包含本地 TXT 和 EPUB", isOn: $coordinator.settings.includeLocalBooks)
                .onChange(of: coordinator.settings.includeLocalBooks) { _ in coordinator.persistConfiguration() }
            Stepper(
                "最多保留历史版本：\(coordinator.settings.maxRetainedBackups) 份",
                value: $coordinator.settings.maxRetainedBackups,
                in: 1...30
            )
            .onChange(of: coordinator.settings.maxRetainedBackups) { _ in coordinator.persistConfiguration() }
            if let lastAt = coordinator.settings.lastBackupAt {
                ReadingLabeledContent("上次成功备份", value: Self.dateFormatter.string(from: lastAt))
            }
        } header: {
            Text("自动备份策略")
        } footer: {
            Text("应用启动时会按间隔自动检查并静默上传 .legadobackup 归档，超出保留上限的最旧历史版本会自动清理。")
        }
    }

    private var actionSection: some View {
        Section("立即操作") {
            Button("立即备份到 WebDAV", systemImage: "icloud.and.arrow.up") {
                Task { await coordinator.backupNow(flushLibraries: waitForWrites) }
            }
            .disabled(!coordinator.credentials.isConfigured)
            Button("刷新云端历史版本", systemImage: "arrow.clockwise") {
                Task { await coordinator.refreshHistory() }
            }
            .disabled(!coordinator.credentials.isConfigured)
        }
    }

    private func restorePreviewSection(_ preview: PreparedLibraryBackup) -> some View {
        let library = preview.manifest.snapshot
        let localAttachments = preview.manifest.attachments.filter { $0.path.hasPrefix("local/") }
        let totalBytes = localAttachments.reduce(Int64(0)) { $0 + $1.bytes }
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                if let name = coordinator.previewFileName {
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("书籍 \(library.books.count) 本 · 书源 \(library.sources.count) 个 · 净化规则 \(library.replaceRules.count) 条")
                    .font(.subheadline.weight(.medium))
                Text("书签 \(library.bookmarks.count) 条 · 阅读记录 \(library.records.count) 条 · RSS 源 \(library.rssSources.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !localAttachments.isEmpty {
                    Text("本地书附件 \(localAttachments.count) 个（\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if preview.manifest.createdAt.timeIntervalSince1970 > 0 {
                    Text("备份时间：\(Self.dateFormatter.string(from: preview.manifest.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            Button("确认合并到当前书库", systemImage: "arrow.down.doc") {
                Task {
                    await coordinator.commitRestore(
                        flushLibraries: waitForWrites,
                        reloadLibraries: reloadAllLibraries
                    )
                }
            }
            Button("取消恢复") {
                coordinator.previewBackup = nil
                coordinator.previewFileName = nil
            }
        } header: {
            Text("恢复预览")
        } footer: {
            Text("合并恢复会保留每本书较新的阅读进度，已有的书源、净化规则与书签不会被覆盖丢失。")
        }
    }

    private var historySection: some View {
        Section {
            if coordinator.backups.isEmpty {
                Text("点击「刷新云端历史版本」查看或恢复历史备份。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.backups) { backup in
                    Button {
                        Task { await coordinator.downloadAndPreview(backup) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.fileName)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    if let date = backup.lastModified {
                                        Text(Self.dateFormatter.string(from: date))
                                    }
                                    if backup.sizeBytes > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("预览恢复")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ReadingTheme.accent)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            deletingBackup = backup
                        }
                    }
                }
            }
        } header: {
            Text("云端历史版本（\(coordinator.backups.count)）")
        }
    }

    private func waitForWrites() async {
        await books.waitForLibraryWrites()
        await sources.waitForLibraryWrites()
        await rules.waitForLibraryWrites()
        await activity.waitForLibraryWrites()
        await rss.waitForLibraryWrites()
        await subscriptions.waitForLibraryWrites()
    }

    private func reloadAllLibraries() async {
        async let loadBooks: Void = books.load()
        async let loadSources: Void = sources.load(force: true)
        async let loadRules: Void = rules.load()
        async let loadActivity: Void = activity.load()
        async let loadRSS: Void = rss.load()
        async let loadSubs: Void = subscriptions.load()
        _ = await (loadBooks, loadSources, loadRules, loadActivity, loadRSS, loadSubs)
    }
}
