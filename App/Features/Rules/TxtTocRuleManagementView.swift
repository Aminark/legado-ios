import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TxtTocRuleManagementModel: ObservableObject {
    @Published private(set) var rules: [TxtTocRule] = []
    @Published var message: String?
    private let repository: SQLiteConfigurationRepository?

    init() {
        repository = (try? LegadoDatabase(url: LegadoDatabase.defaultURL())).map {
            SQLiteConfigurationRepository(database: $0)
        }
    }

    func load() async {
        guard let repository else { message = "无法打开目录规则数据库"; return }
        do {
            rules = try await repository.loadTxtTocRules(initialDefaults: TxtTocRuleDefaults.load()).sorted { $0.serialNumber < $1.serialNumber }
        }
        catch { message = error.localizedDescription }
    }

    func importDefaults(report: Bool = true) async {
        let defaults = TxtTocRuleDefaults.load()
        guard !defaults.isEmpty else { message = "应用内置目录规则缺失"; return }
        var updated = rules.filter { $0.id >= 0 }
        updated.append(contentsOf: defaults)
        if await persist(updated), report { message = "已恢复内置目录规则" }
    }

    func save(_ rule: TxtTocRule) async -> Bool {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.id == -100 else {
            message = "名称和正则不能为空"
            return false
        }
        guard rule.rule.isEmpty || (try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines)) != nil else {
            message = "目录正则语法错误"
            return false
        }
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index] = rule }
        else { var value = rule; value.serialNumber = (updated.map(\.serialNumber).max() ?? 0) + 1; updated.append(value) }
        return await persist(updated)
    }

    func toggle(_ rule: TxtTocRule) async {
        var value = rule; value.enable.toggle(); _ = await save(value)
    }

    func remove(at offsets: IndexSet) async {
        _ = await persist(rules.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        var updated = rules
        updated.move(fromOffsets: offsets, toOffset: destination)
        for index in updated.indices { updated[index].serialNumber = index + 1 }
        _ = await persist(updated)
    }

    func importData(_ data: Data) async {
        do {
            let decoded: [TxtTocRule]
            if let values = try? JSONDecoder().decode([TxtTocRule].self, from: data) { decoded = values }
            else { decoded = [try JSONDecoder().decode(TxtTocRule.self, from: data)] }
            var merged = rules
            for value in decoded {
                if let index = merged.firstIndex(where: { $0.id == value.id }) { merged[index] = value }
                else { merged.append(value) }
            }
            for index in merged.indices { merged[index].serialNumber = index + 1 }
            if await persist(merged) { message = "已导入 \(decoded.count) 条目录规则" }
        } catch { message = error.localizedDescription }
    }

    private func persist(_ values: [TxtTocRule]) async -> Bool {
        guard let repository else { message = "无法打开目录规则数据库"; return false }
        do {
            try await repository.saveTxtTocRules(values)
            rules = try await repository.loadTxtTocRules().sorted { $0.serialNumber < $1.serialNumber }
            return true
        } catch { message = error.localizedDescription; return false }
    }
}

struct TxtTocRuleManagementView: View {
    @StateObject private var model = TxtTocRuleManagementModel()
    @State private var editing: TxtTocRule?
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        List {
            if model.rules.isEmpty {
                ReadingUnavailableView("没有TXT目录规则", systemImage: "list.bullet.rectangle")
            }
            ForEach(model.rules) { rule in
                Button { editing = rule } label: {
                    HStack(spacing: 12) {
                        Image(systemName: rule.enable ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(rule.enable ? ReadingTheme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).foregroundStyle(.primary)
                            Text(rule.rule).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(rule.enable ? "停用" : "启用") { Task { await model.toggle(rule) } }
                        .tint(rule.enable ? .orange : .green)
                }
            }
            .onDelete { offsets in Task { await model.remove(at: offsets) } }
            .onMove { offsets, destination in Task { await model.move(from: offsets, to: destination) } }
        }
        .navigationTitle("TXT目录规则")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建", systemImage: "plus") { editing = TxtTocRule() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("导入JSON", systemImage: "square.and.arrow.down") { importing = true }
                    Button("导出JSON", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(model.rules.isEmpty)
                    Button("恢复内置规则", systemImage: "arrow.counterclockwise") {
                        Task { await model.importDefaults() }
                    }
                    EditButton()
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { value in
            TxtTocRuleEditView(value: value) { await model.save($0) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { Task { await model.importData(data) } }
        }
        .fileExporter(
            isPresented: $exporting,
            document: TxtTocRuleDocument(rules: model.rules),
            contentType: .json,
            defaultFilename: "txtTocRules.json"
        ) { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
        .alert("TXT目录规则", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
    }
}

private struct TxtTocRuleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: TxtTocRule
    @State private var sample = ""
    @State private var saving = false
    let save: (TxtTocRule) async -> Bool

    init(value: TxtTocRule, save: @escaping (TxtTocRule) async -> Bool) {
        _value = State(initialValue: value)
        _sample = State(initialValue: value.example ?? "")
        self.save = save
    }

    private var testResult: String {
        guard let expression = try? NSRegularExpression(pattern: value.rule, options: .anchorsMatchLines) else { return "正则语法错误" }
        let range = NSRange(sample.startIndex..., in: sample)
        let values = expression.matches(in: sample, range: range).prefix(20).compactMap { match -> String? in
            guard let range = Range(match.range, in: sample) else { return nil }
            return String(sample[range])
        }
        return values.isEmpty ? "没有匹配" : "匹配 \(values.count) 条：\n" + values.joined(separator: "\n")
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                TextField("名称", text: $value.name)
                ReadingTextField("目录正则", text: $value.rule, axis: .vertical)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
                ReadingTextField("标题处理JavaScript（可选）", text: Binding(
                    get: { value.replacement }, set: { value.replacement = $0 }
                ), axis: .vertical).font(.body.monospaced())
                Toggle("启用", isOn: $value.enable)
                Section("测试文本") {
                    TextEditor(text: $sample).frame(minHeight: 130)
                    Text(testResult).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .navigationTitle("TXT目录规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        value.example = sample.isEmpty ? nil : sample
                        saving = true
                        Task { if await save(value) { dismiss() }; saving = false }
                    }.disabled(saving)
                }
            }
        }
    }
}

private struct TxtTocRuleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let rules: [TxtTocRule]
    init(rules: [TxtTocRule]) { self.rules = rules }
    init(configuration: ReadConfiguration) throws { rules = [] }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(rules))
    }
}
