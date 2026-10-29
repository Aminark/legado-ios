import SwiftUI

struct RuleSubscriptionView: View {
    @EnvironmentObject private var bookSources: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var model: RuleSubscriptionModel
    @State private var editing: RuleSub?

    private var visibleValues: [RuleSub] { model.values.filter { $0.type != 1 } }

    var body: some View {
        List {
            if visibleValues.isEmpty { ReadingUnavailableView("没有规则订阅", systemImage: "link.badge.plus") }
            ForEach(visibleValues) { value in
                Button { open(value) } label: {
                    HStack(spacing: 12) {
                        Text(typeName(value.type)).font(.caption.bold()).foregroundStyle(ReadingTheme.accent).frame(width: 48)
                        VStack(alignment: .leading, spacing: 4) { Text(value.name.isEmpty ? value.url : value.name).foregroundStyle(.primary); Text(value.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if value.autoUpdate { Image(systemName: value.silentUpdate ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle").foregroundStyle(.secondary) }
                        if model.pendingIDs.contains(value.id) { Text("有更新").font(.caption2).foregroundStyle(.orange) }
                    }
                }.swipeActions(edge: .leading) { Button("编辑", systemImage: "pencil") { editing = value }.tint(.blue) }
            }.onDelete { offsets in
                let ids = Set(offsets.compactMap { visibleValues.indices.contains($0) ? visibleValues[$0].id : nil })
                let sourceOffsets = IndexSet(model.values.indices.filter { ids.contains(model.values[$0].id) })
                Task { await model.remove(at: sourceOffsets) }
            }
        }
        .navigationTitle("规则订阅")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { editing = RuleSub() } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
        .task { await model.load() }
        .sheet(item: $editing) { value in RuleSubscriptionEditView(value: value) { item in await model.save(item) } }
        .alert("规则订阅", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("好") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }

    private func open(_ value: RuleSub) {
        model.clearPending(value.id)
        Task {
            switch value.type {
            case 2: await replaceRules.importRemoteURL(value.url)
            default: await bookSources.importRemoteURL(value.url)
            }
        }
    }
    private func typeName(_ type: Int) -> String { type == 2 ? "净化" : "书源" }
}

private struct RuleSubscriptionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: RuleSub
    @State private var saving = false
    let save: (RuleSub) async -> Bool
    init(value: RuleSub, save: @escaping (RuleSub) async -> Bool) { _value = State(initialValue: value); self.save = save }
    var body: some View {
        ReadingNavigationStack {
            Form {
                Picker("类型", selection: $value.type) { Text("书源").tag(0); Text("净化规则").tag(2) }
                TextField("名称", text: $value.name)
                ReadingTextField("订阅URL", text: $value.url, axis: .vertical).textInputAutocapitalization(.never).disableAutocorrection(true)
                Toggle("自动更新", isOn: $value.autoUpdate)
                if value.autoUpdate {
                    Stepper("更新间隔：\(value.updateInterval) 小时", value: $value.updateInterval, in: 1...720)
                    Toggle("静默更新", isOn: $value.silentUpdate)
                }
            }.navigationTitle("规则订阅").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { saving = true; Task { if await save(value) { dismiss() }; saving = false } }.disabled(saving || value.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
