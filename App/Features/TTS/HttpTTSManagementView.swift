import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HttpTTSLibraryModel: ObservableObject {
    @Published private(set) var engines: [HttpTTS] = []
    @Published var errorMessage: String?

    private func repository() throws -> SQLiteConfigurationRepository {
        SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
    }

    func load() async {
        do {
            var values = try await repository().loadHttpTTS()
            if values.isEmpty { values = try bundledDefaults() }
            engines = sorted(values)
            if !values.isEmpty { try await repository().saveHttpTTS(engines) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ value: HttpTTS) async {
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
            var byID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
            for value in imported { byID[value.id] = value }
            await persist(Array(byID.values))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreDefaults() async {
        do {
            let defaults = try bundledDefaults()
            var byID = Dictionary(uniqueKeysWithValues: engines.filter { $0.id >= 0 }.map { ($0.id, $0) })
            for value in defaults { byID[value.id] = value }
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

    private func bundledDefaults() throws -> [HttpTTS] {
        guard let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([HttpTTS].self, from: Data(contentsOf: url))
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
    @State private var editing: HttpTTS?
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var exportDocument = HttpTTSJSONDocument(data: Data("[]".utf8))

    var body: some View {
        List {
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
        }
        .overlay {
            if model.engines.isEmpty {
                ReadingUnavailableView("没有在线朗读引擎", systemImage: "waveform", description: Text("可恢复内置引擎或导入 HTTP TTS JSON。"))
            }
        }
        .navigationTitle("在线朗读引擎")
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
                    Button("恢复内置引擎", systemImage: "arrow.counterclockwise") {
                        Task { await model.restoreDefaults() }
                    }
                    Button("清除朗读缓存", systemImage: "trash") {
                        Task { await HttpTTSAudioCache.shared.clear() }
                    }
                }
            }
        }
        .task { await model.load() }
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
