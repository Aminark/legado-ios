import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class RuleSubscriptionModel: ObservableObject {
    @Published private(set) var values: [RuleSub] = []
    @Published var errorMessage: String?
    @Published private(set) var pendingIDs = Set<Int64>()
    private let repository: SQLiteConfigurationRepository?
    private let transport: any HTTPTransport
    private var isCheckingUpdates = false
    private var saveTask: Task<Bool, Never>?
    private var saveGeneration = 0
    private var persistedValues: [RuleSub] = []

    init(repository: SQLiteConfigurationRepository? = nil, transport: any HTTPTransport = URLSessionHTTPTransport.shared) {
        self.repository = repository ?? (try? LegadoDatabase(url: LegadoDatabase.defaultURL())).map { SQLiteConfigurationRepository(database: $0) }
        self.transport = transport
    }
    func load() async {
        guard let repository else { errorMessage = "无法打开规则订阅数据库"; return }
        let generation = saveGeneration
        do {
            let loaded = try await repository.loadRuleSubs().sorted { $0.customOrder < $1.customOrder }
            guard generation == saveGeneration, saveTask == nil else { return }
            values = loaded
            persistedValues = loaded
        }
        catch { errorMessage = error.localizedDescription }
    }
    func save(_ value: RuleSub) async -> Bool {
        guard !value.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "URL不能为空"; return false }
        guard !values.contains(where: { $0.id != value.id && $0.url == value.url }) else { errorMessage = "URL已存在"; return false }
        var updated = values
        if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
        else { var item = value; item.customOrder = (updated.map(\.customOrder).max() ?? -1) + 1; updated.append(item) }
        return await persist(updated)
    }
    func remove(at offsets: IndexSet) async { _ = await persist(values.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)) }
    func move(from offsets: IndexSet, to destination: Int) async {
        var updated = values; updated.move(fromOffsets: offsets, toOffset: destination)
        for index in updated.indices { updated[index].customOrder = index + 1 }
        _ = await persist(updated)
    }
    func checkAutomaticUpdates(bookSources: SourceLibraryModel, rssSources: RSSLibraryModel, replaceRules: ReplaceRuleLibraryModel) async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let ids = values.map(\.id)
        // Network and persistence waits allow the user to edit or delete rows.
        // Resolve each ID again instead of retaining indexes across suspension.
        for id in ids {
            guard !Task.isCancelled else { return }
            guard let index = values.firstIndex(where: { $0.id == id }),
                  values[index].autoUpdate, values[index].type != 1,
                  values[index].update <= now else { continue }
            let elapsedHours = (now - max(values[index].update, 0)) / 3_600_000
            guard Int64(max(values[index].updateInterval, 0)) <= elapsedHours else { continue }
            var subscription = values[index]
            subscription.update = now
            var timestamped = values; timestamped[index] = subscription
            guard await persist(timestamped) else { continue }
            do {
                let data = try await fetch(subscription.url)
                try Task.checkCancellation()
                guard values.contains(subscription) else { continue }
                if subscription.silentUpdate {
                    switch subscription.type {
                    case 1: try await rssSources.applySilentSubscription(data)
                    case 2: try await replaceRules.applySilentSubscription(data)
                    default: try await bookSources.applySilentSubscription(data)
                    }
                } else if try hasUpdates(data, type: subscription.type, bookSources: bookSources, rssSources: rssSources, replaceRules: replaceRules) {
                    pendingIDs.insert(subscription.id)
                }
            } catch is CancellationError {
                return
            } catch { errorMessage = "\(subscription.name.isEmpty ? subscription.url : subscription.name)：\(error.localizedDescription)" }
        }
    }
    func clearPending(_ id: Int64) { pendingIDs.remove(id) }

    private func fetch(_ value: String) async throws -> Data {
        let withoutUA = value.hasSuffix("#requestWithoutUA")
        let raw = withoutUA ? String(value.dropLast("#requestWithoutUA".count)) : value
        guard let url = URL(string: raw) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if withoutUA { request.setValue("", forHTTPHeaderField: "User-Agent") }
        let response = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return response.data
    }

    private func hasUpdates(_ data: Data, type: Int, bookSources: SourceLibraryModel, rssSources: RSSLibraryModel, replaceRules: ReplaceRuleLibraryModel) throws -> Bool {
        switch type {
        case 1:
            let incoming = try RSSSourceImporter().decode(data).sources
            guard incoming.first?.sourceUrl.isEmpty == false else { throw RSSSourceImportError.invalidSource }
            return incoming.contains { value in rssSources.sources.first(where: { $0.sourceUrl == value.sourceUrl }).map { $0.lastUpdateTime < value.lastUpdateTime } ?? true }
        case 2:
            let incoming = try ReplaceRuleImporter().decode(data)
            return incoming.contains { value in
                guard let old = replaceRules.rules.first(where: { $0.id == value.id }) else { return true }
                return old.pattern != value.pattern || old.replacement != value.replacement
            }
        default:
            let incoming = try BookSourceImporter().decode(data)
            guard incoming.first?.bookSourceUrl.isEmpty == false else { throw BookSourceImportError.emptyDocument }
            return incoming.contains { value in bookSources.sources.first(where: { $0.bookSourceUrl == value.bookSourceUrl }).map { $0.lastUpdateTime < value.lastUpdateTime } ?? true }
        }
    }
    private func persist(_ updated: [RuleSub]) async -> Bool {
        guard let repository else { errorMessage = "无法打开规则订阅数据库"; return false }
        values = updated.sorted { $0.customOrder < $1.customOrder }
        saveGeneration &+= 1
        let generation = saveGeneration
        let previous = saveTask
        let save = Task { @MainActor [weak self, repository] in
            _ = await previous?.value
            do {
                try await repository.saveRuleSubs(updated)
                self?.persistedValues = updated
                return true
            } catch {
                if let self {
                    if saveGeneration == generation { values = persistedValues.sorted { $0.customOrder < $1.customOrder } }
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        saveTask = save
        let succeeded = await save.value
        if saveGeneration == generation { saveTask = nil }
        pendingIDs.formIntersection(Set(values.map(\.id)))
        return succeeded
    }
}
