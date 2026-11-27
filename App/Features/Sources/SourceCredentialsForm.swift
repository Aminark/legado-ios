import SwiftUI

private struct SourceCredentialField: Decodable, Identifiable {
    var name = ""
    var type = "text"
    var action: String?
    var chars: [String?]?
    var `default`: String?
    var viewName: String?
    var id: String { "\(name)-\(type)" }

    private enum CodingKeys: String, CodingKey { case name, type, action, chars, `default`, viewName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        action = try values.decodeIfPresent(String.self, forKey: .action)
        chars = try values.decodeIfPresent([String?].self, forKey: .chars)
        `default` = try values.decodeIfPresent(String.self, forKey: .default)
        viewName = try values.decodeIfPresent(String.self, forKey: .viewName)
    }
}

struct SourceCredentialsForm: View {
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    @StateObject private var interaction = SourceInteractionSession()
    let onSave: (String) -> Void
    @State private var isLoading = true
    @State private var rows: [SourceCredentialField] = []
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var pendingFieldAction: Task<Void, Never>?

    var body: some View {
        Form {
            if isLoading {
                ProgressView("正在生成登录表单…")
            }
            ForEach(rows) { row in
                switch row.type {
                case "password":
                    SecureField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                case "select":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "toggle":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "button":
                    Button(label(for: row)) { runAction(row.action) }
                default:
                    TextField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRunning ? "执行中…" : "登录") { saveAndLogin() }.disabled(isRunning || isLoading)
            }
        }
        .task { await loadRows() }
        .sourceInteraction(interaction, source: source)
        .onDisappear { pendingFieldAction?.cancel() }
    }

    private func loadRows() async {
        defer { isLoading = false }
        do {
            values = decodeLoginInfo()
            let json = try await renderedLoginUI()
            let layout = try LegadoURLBuilder.decodeLenientJSON(json)
            rows = try JSONDecoder().decode([SourceCredentialField].self, from: JSONEncoder().encode(layout))
            for row in rows where row.type != "button" && values[row.name] == nil {
                values[row.name] = row.default ?? options(for: row).first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderedLoginUI() async throws -> String {
        guard var raw = source.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "[]"
        }
        let script: String?
        if raw.hasPrefix("@js:") {
            script = String(raw.dropFirst(4))
        } else if raw.hasPrefix("<js>"), raw.hasSuffix("</js>") {
            script = String(raw.dropFirst(4).dropLast(5))
        } else {
            script = nil
        }
        if let script {
            let result = try await interaction.evaluator.evaluateAsync(
                script: script,
                result: .object(values.mapValues(JSONValue.string)),
                executionContext: .init(source: source)
            )
            raw = result.value.stringValue
        }
        return raw
    }

    private func decodeLoginInfo() -> [String: String] {
        let raw = BookSourceRuntimeStore.shared.get(sourceID: source.id, key: "loginInfo")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func binding(for row: SourceCredentialField) -> Binding<String> {
        Binding(get: { values[row.name] ?? row.default ?? "" }, set: { values[row.name] = $0 })
    }

    private func options(for row: SourceCredentialField) -> [String] {
        let options = row.chars?.compactMap { $0 } ?? []
        return options.isEmpty ? [row.default ?? ""] : options
    }

    private func label(for row: SourceCredentialField) -> String {
        guard let value = row.viewName, value.count >= 2,
              value.first == "'", value.last == "'" else { return row.name }
        return String(value.dropFirst().dropLast())
    }

    private func runAction(_ action: String?) {
        guard let action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        let source = source
        let values = values
        Task { @MainActor in
            defer { isRunning = false }
            do {
                try store(values)
                _ = try await interaction.evaluator.evaluateAsync(
                    script: "\(source.loginScript ?? "")\n\(action)",
                    result: .object(values.mapValues(JSONValue.string)),
                    executionContext: .init(source: source)
                )
                if source.loginUi?.isEmpty == false { await loadRows() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleFieldAction(_ action: String?) {
        guard action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        pendingFieldAction?.cancel()
        pendingFieldAction = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                runAction(action)
            } catch { }
        }
    }

    @discardableResult private func store(_ values: [String: String]) throws -> String {
        let raw = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginInfo", value: raw)
        return raw
    }

    private func saveAndLogin() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        do {
            try store(values)
            let source = source
            let values = values
            Task { @MainActor in
                do {
                    if let login = source.loginScript?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
                        _ = try await interaction.evaluator.evaluateAsync(
                            script: "\(login)\nif (typeof login === 'function') login.apply(this);",
                            result: .object(values.mapValues(JSONValue.string)),
                            executionContext: .init(source: source)
                        )
                    }
                    if source.loginScript == nil, let url = source.loginUrl, !url.isEmpty {
                        let reply = try await interaction.evaluator.evaluateAsync(
                            script: "java.startBrowserAwait(result, source.getTag()).statusCode()",
                            result: .string(url), executionContext: .init(source: source)
                        )
                        guard let status = Int(reply.value.stringValue), (200..<400).contains(status) else {
                            errorMessage = "网页登录未完成，可以重试。"
                            isRunning = false
                            return
                        }
                    }
                    onSave(BookSourceRuntimeStore.shared.get(sourceID: source.id, key: "loginInfo"))
                    isRunning = false
                    if !interaction.isPresenting { dismiss() }
                } catch {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }
}
