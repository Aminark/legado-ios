#if SWIFT_PACKAGE
import LegadoCore
#endif
import Foundation

@MainActor
final class ReplaceRuleLibraryModel: ObservableObject {
    @Published private(set) var rules: [ReplaceRule] = []
    @Published var notice: Notice?

    struct Notice: Identifiable {
        enum Kind { case success, error }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    private let repository: any ReplaceRuleRepository
    private let importer = ReplaceRuleImporter()
    private var saveTask: Task<Result<Void, Error>, Never>?
    private var saveGeneration = 0
    private var persistedRules: [ReplaceRule] = []

    init(repository: any ReplaceRuleRepository) { self.repository = repository }

    static func live() -> ReplaceRuleLibraryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        return ReplaceRuleLibraryModel(repository: FileReplaceRuleRepository(fileURL: base.appendingPathComponent("replace-rules.json")))
    }

    static func demo() -> ReplaceRuleLibraryModel {
        ReplaceRuleLibraryModel(repository: InMemoryReplaceRuleRepository())
    }

    func load() async {
        do { rules = try await repository.load(); persistedRules = rules }
        catch { notice = .init(kind: .error, title: "净化规则读取失败", detail: error.localizedDescription) }
    }

    func importFiles(_ urls: [URL]) async {
        do {
            var updated = rules
            var count = 0
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let incoming = try importer.decode(Data(contentsOf: url, options: .mappedIfSafe))
                updated = importer.merge(incoming, into: updated)
                count += incoming.count
            }
            try await saveRules(updated)
            notice = .init(kind: .success, title: "净化规则已导入", detail: "本次读取 \(count) 条，当前共 \(rules.count) 条。")
        } catch {
            notice = .init(kind: .error, title: "净化规则导入失败", detail: error.localizedDescription)
        }
    }

    func importRemoteURL(_ value: String) async { await importText(value) }

    func importText(_ value: String) async {
        do {
            let input = try RuleImportInput.parse(value, kind: "replaceRule")
            let data: Data
            switch input {
            case .json(let value): data = Data(value.utf8)
            case .remote:
                let (body, response) = try await URLSessionHTTPTransport.shared.download(for: input.request()!)
                if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) { throw URLError(.badServerResponse) }
                data = body
            }
            let incoming = try importer.decode(data)
            let updated = importer.merge(incoming, into: rules)
            try await saveRules(updated)
            notice = .init(kind: .success, title: "净化规则已导入", detail: "本次读取 \(incoming.count) 条，当前共 \(rules.count) 条。")
        } catch { notice = .init(kind: .error, title: "净化规则导入失败", detail: error.localizedDescription) }
    }

    func newRule(copying original: ReplaceRule? = nil) -> ReplaceRule {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let maximumID = rules.map(\.id).max() ?? 0
        let id = max(now, maximumID < Int64.max ? maximumID + 1 : now)
        var rule = original ?? ReplaceRule(id: id, name: "", pattern: "")
        rule.id = id
        if original != nil { rule.name += " 副本" }
        rule.sortOrder = (rules.map(\.sortOrder).filter { $0 != Int.min && $0 < Int.max }.max() ?? -1) + 1
        return rule
    }

    func save(_ rule: ReplaceRule) async -> Bool {
        do { try ReplaceRuleValidator.validate(rule) }
        catch { notice = .init(kind: .error, title: "规则无效", detail: error.localizedDescription); return false }
        return await persist(importer.merge([rule], into: rules))
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        var updated = rules
        updated.move(fromOffsets: offsets, toOffset: destination)
        for index in updated.indices { updated[index].sortOrder = index }
        await persist(updated)
    }

    func remove(id: Int64) async { await persist(rules.filter { $0.id != id }) }

    func applySilentSubscription(_ data: Data) async throws {
        let incoming = try importer.decode(data)
        let changed = incoming.filter { value in
            guard let old = rules.first(where: { $0.id == value.id }) else { return true }
            return old.pattern != value.pattern || old.replacement != value.replacement
        }
        guard !changed.isEmpty else { return }
        let updated = importer.merge(changed, into: rules)
        try await saveRules(updated)
    }

    func setEnabled(_ enabled: Bool, for id: Int64) async {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var updated = rules
        updated[index].isEnabled = enabled
        await persist(updated)
    }

    func remove(at offsets: IndexSet) async {
        var updated = rules
        updated.remove(atOffsets: offsets)
        await persist(updated)
    }

    @discardableResult
    private func persist(_ updated: [ReplaceRule]) async -> Bool {
        do {
            try await saveRules(updated)
            return true
        } catch {
            notice = .init(kind: .error, title: "净化规则保存失败", detail: error.localizedDescription)
            return false
        }
    }

    private func saveRules(_ updated: [ReplaceRule]) async throws {
        rules = updated
        saveGeneration &+= 1
        let generation = saveGeneration
        let previousSave = saveTask
        let task = Task { @MainActor [weak self, repository] () -> Result<Void, Error> in
            _ = await previousSave?.value
            do {
                try await repository.save(updated)
                self?.persistedRules = updated
                return .success(())
            } catch {
                if let self, saveGeneration == generation { rules = persistedRules }
                return .failure(error)
            }
        }
        saveTask = task
        let result = await task.value
        if saveGeneration == generation { saveTask = nil }
        try result.get()
    }
}
