import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HttpTTSLibraryModel: ObservableObject {
    @Published private(set) var engines: [HttpTTS] = []
    @Published var errorMessage: String?

    private func repository() throws -> SQLiteConfigurationRepository {
        SQLiteConfigurationRepository(database: try LegadoDatabase.shared())
    }

    func load() async {
        do {
            engines = try await Self.loadStoredEngines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func loadStoredEngines() async throws -> [HttpTTS] {
        let database = try LegadoDatabase.shared()
        let file = Bundle.main.url(forResource: "retiredHttpTTS", withExtension: "json")
        let retired = try file.map { try JSONDecoder().decode([HttpTTS].self, from: Data(contentsOf: $0)) } ?? []
        let unconfigured = retired.filter { engine in
            BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo").isEmpty
        }
        return try await database.loadHttpTTS(retiring: unconfigured)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ value: HttpTTS) async {
        guard !value.isRetiredNextEngine else {
            errorMessage = "Next 引擎已停用。"
            return
        }
        var value = value
        value.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        var values = engines.filter { $0.id != value.id }
        values.append(value)
        await persist(values)
    }

    func delete(at offsets: IndexSet) async {
        var values = engines
        values.remove(atOffsets: offsets)
        await persist(values)
    }

    func importData(_ data: Data) async {
        do {
            let decoder = JSONDecoder()
            let imported: [HttpTTS]
            if let array = try? decoder.decode([HttpTTS].self, from: data) {
                imported = array
            } else {
                imported = [try decoder.decode(HttpTTS.self, from: data)]
            }
            let available = imported.filter { !$0.isRetiredNextEngine }
            if !imported.isEmpty, available.isEmpty {
                errorMessage = "Next 引擎已停用。"
                return
            }
            var byID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
            for value in available { byID[value.id] = value }
            await persist(Array(byID.values))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(engines)
    }

    private func persist(_ values: [HttpTTS]) async {
        do {
            let values = sorted(values)
            try await repository().saveHttpTTS(values)
            engines = values
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sorted(_ values: [HttpTTS]) -> [HttpTTS] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct HttpTTSManagementView: View {
    @StateObject private var model = HttpTTSLibraryModel()
    @StateObject private var edgePreview = ReaderSpeechController()
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("edgeTtsVoice") private var edgeSpeechVoice = EdgeSpeechVoice.xiaoxiao
    @State private var editing: HttpTTS?
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var exportDocument = HttpTTSJSONDocument(data: Data("[]".utf8))
    @State private var offlineInstallation = OfflineSpeechSynthesizer.InstallationState.checking

    var body: some View {
        List {
            Section {
                EdgeSpeechVoicePicker(selection: $edgeSpeechVoice)
                Button(edgePreview.isSpeaking ? "停止 Edge 试听" : "试听 Edge 语音",
                       systemImage: edgePreview.isSpeaking ? "stop.fill" : "play.fill") {
                    edgePreview.toggleSynthesized(.edge(edgeSpeechVoice), text: "你好，你正在试听微软 Edge 的中文朗读语音。")
                }
                if appTTSEngine == EdgeSpeechSynthesizer.engineTag {
                    Label("已设为全局朗读引擎", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("设为全局朗读引擎") { appTTSEngine = EdgeSpeechSynthesizer.engineTag }
                }
                if let error = edgePreview.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text(EdgeSpeechSynthesizer.engineName)
            } footer: {
                Text("需要联网，所朗读的文字会发送给微软进行语音合成。")
            }
            Section {
                OfflineSpeechModelControls(installation: offlineInstallation, includesPreview: true)
            } header: {
                Text(OfflineSpeechSynthesizer.engineName)
            } footer: {
                Text("下载一次即可离线朗读，书籍正文留在设备上。")
            }
            Section("自定义 HTTP TTS 引擎") {
                ForEach(model.engines) { engine in
                    Button {
                        editing = engine
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.name).foregroundStyle(.primary)
                            Text(engine.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in Task { await model.delete(at: offsets) } }
                if model.engines.isEmpty {
                    Text("没有自定义 HTTP TTS 引擎，可新建或导入 JSON。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("在线朗读引擎")
        .onChange(of: edgeSpeechVoice) { _ in edgePreview.stop() }
        .onDisappear { edgePreview.stop() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("新建", systemImage: "plus") { editing = HttpTTS() }
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("导入", systemImage: "square.and.arrow.down") { importsFile = true }
                    Button("导出", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = .init(data: try model.exportData())
                            exportsFile = true
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                    Button("清除朗读缓存", systemImage: "trash") {
                        Task {
                            await HttpTTSAudioCache.shared.clear()
                        }
                    }
                }
            }
        }
        .task { await model.load() }
        .task {
            for await state in await OfflineSpeechSynthesizer.shared.installationUpdates() {
                offlineInstallation = state
            }
        }
        .sheet(item: $editing) { engine in
            ReadingNavigationStack {
                HttpTTSEditorView(engine: engine) { value in
                    Task { await model.save(value) }
                }
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.json, .data]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                Task { await model.importData(data) }
            } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $exportsFile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "httpTTS"
        ) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("在线朗读引擎", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EdgeSpeechVoicePicker: View {
    @Binding var selection: EdgeSpeechVoice

    var body: some View {
        Picker("Edge 音色", selection: $selection) {
            ForEach(EdgeSpeechVoice.allCases) { voice in
                Text(voice.name).tag(voice)
            }
        }
    }
}

struct OfflineSpeechModelControls: View {
    let installation: OfflineSpeechSynthesizer.InstallationState
    var includesPreview = false
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @StateObject private var preview = ReaderSpeechController()

    var body: some View {
        Group {
            switch installation {
            case .checking:
                ProgressView("正在检查离线语音…")
            case .installed:
                if includesPreview {
                    Button(preview.isSpeaking ? "停止试听" : "试听离线中文语音", systemImage: preview.isSpeaking ? "stop.fill" : "play.fill") {
                        preview.toggleSynthesized(.offline, text: "你好，语音已经下载完成。现在可以离线朗读这本书。")
                    }
                    if appTTSEngine == OfflineSpeechSynthesizer.engineTag {
                        Label("已设为全局朗读引擎", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("设为全局朗读引擎") { appTTSEngine = OfflineSpeechSynthesizer.engineTag }
                    }
                    if let error = preview.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            case .downloading(let bytes):
                let total = OfflineSpeechSynthesizer.downloadByteCount
                let percentage = bytes * 100 / total
                ProgressView(value: Double(bytes), total: Double(total)) {
                    Text("正在下载 MeloTTS")
                } currentValueLabel: {
                    Text("\(percentage)% · \(bytes / 1_000_000) / \(total / 1_000_000) MB")
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
            case .verifying:
                ProgressView("正在校验并安装 MeloTTS…")
            case .unavailable, .failed:
                Button("下载 MeloTTS（约 75 MB）", systemImage: "arrow.down.circle") {
                    Task { try? await OfflineSpeechSynthesizer.shared.install() }
                }
                if case .failed(let error) = installation {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .onDisappear { preview.stop() }
    }
}

private struct HttpTTSEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine: HttpTTS
    let onSave: (HttpTTS) -> Void
    @StateObject private var speech = ReaderSpeechController()
    @State private var testText = "这是一段在线朗读引擎测试文本。"
    @State private var loginInfo: String
    @State private var showsLoginForm = false

    init(engine: HttpTTS, onSave: @escaping (HttpTTS) -> Void) {
        _engine = State(initialValue: engine)
        self.onSave = onSave
        _loginInfo = State(initialValue: BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo"))
    }

    var body: some View {
        Form {
            Section("基本") {
                TextField("名称", text: $engine.name)
                TextEditor(text: $engine.url).frame(minHeight: 110)
                TextField("Content-Type 正则", text: optional(\.contentType))
                TextField("并发率", text: optional(\.concurrentRate))
                Toggle("启用 Cookie", isOn: optionalBool(\.enabledCookieJar))
            }
            Section("请求与脚本") {
                fieldLabel("Header")
                TextEditor(text: optional(\.header)).frame(minHeight: 80)
                fieldLabel("JS 库")
                TextEditor(text: optional(\.jsLib)).frame(minHeight: 100)
                fieldLabel("登录地址/脚本")
                TextEditor(text: optional(\.loginUrl)).frame(minHeight: 80)
                fieldLabel("登录 UI")
                TextEditor(text: optional(\.loginUi)).frame(minHeight: 80)
                fieldLabel("登录信息 JSON")
                TextEditor(text: $loginInfo).frame(minHeight: 80)
                if engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Button("打开登录表单", systemImage: "person.badge.key") { showsLoginForm = true }
                }
                fieldLabel("登录检查 JS")
                TextEditor(text: optional(\.loginCheckJs)).frame(minHeight: 100)
            }
            Section("测试") {
                TextField("测试文本", text: $testText)
                Button(speech.isSpeaking ? "停止测试" : "播放测试", systemImage: speech.isSpeaking ? "stop.fill" : "play.fill") {
                    speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: true)
                    speech.toggleHTTP(engine: engine, text: testText)
                }
                if let error = speech.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(engine.name.isEmpty ? "新建在线朗读引擎" : engine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: loginInfo)
                    onSave(engine)
                    dismiss()
                }
                    .disabled(engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showsLoginForm) {
            ReadingNavigationStack {
                SourceCredentialsForm(source: engine.bookSourceAdapter) { value in loginInfo = value }
            }
        }
        .onDisappear { speech.stop() }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.subheadline.weight(.medium))
    }

    private func optional(_ keyPath: WritableKeyPath<HttpTTS, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: keyPath] ?? "" }, set: { engine[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func optionalBool(_ keyPath: WritableKeyPath<HttpTTS, Bool?>) -> Binding<Bool> {
        Binding(get: { engine[keyPath: keyPath] == true }, set: { engine[keyPath: keyPath] = $0 })
    }
}

private struct HttpTTSJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
