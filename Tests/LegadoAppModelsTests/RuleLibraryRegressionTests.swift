import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

private actor FailingSourceRepository: BookSourceRepository {
    func load() -> [BookSource] { [] }
    func save(_ sources: [BookSource]) throws { throw CocoaError(.fileWriteNoPermission) }
}
private actor FailingReplaceRepository: ReplaceRuleRepository {
    func load() -> [ReplaceRule] { [] }
    func save(_ sources: [ReplaceRule]) throws { throw CocoaError(.fileWriteNoPermission) }
}

private actor ImportFixtureTransport: HTTPTransport {
    let documents: [String: String]
    private(set) var requests: [URLRequest] = []
    init(documents: [String: String]) { self.documents = documents }
    func data(for request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard let url = request.url, let document = documents[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return .init(data: Data(document.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

@MainActor
struct RuleLibraryRegressionTests {
    @Test func overlappingSourceTogglesKeepBothChanges() async {
        let sources = ["a", "b"].map { BookSource(bookSourceUrl: "https://\($0).test", bookSourceName: $0) }
        let repository = SuspendedSourceRepository(sources: sources)
        let model = SourceLibraryModel(repository: repository)
        await model.load()
        let first = Task { await model.setEnabled(false, for: sources[0].id) }
        await repository.waitForSave()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await model.setExploreEnabled(false, for: sources[1].id)
        }
        while !secondStarted { await Task.yield() }
        await repository.finishSave()
        await first.value
        await second.value

        #expect(model.sources[0].enabled == false)
        #expect(model.sources[1].enabledExplore == false)
        #expect(await repository.load() == model.sources)
    }

    @Test func overlappingPurificationTogglesKeepBothChanges() async {
        let rules = (1...2).map { ReplaceRule(id: Int64($0), name: "规则\($0)", pattern: "广告") }
        let repository = SuspendedReplaceRepository(rules: rules)
        let model = ReplaceRuleLibraryModel(repository: repository)
        await model.load()
        let first = Task { await model.setEnabled(false, for: rules[0].id) }
        await repository.waitForSave()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await model.setEnabled(false, for: rules[1].id)
        }
        while !secondStarted { await Task.yield() }
        await repository.finishSave()
        await first.value
        await second.value

        #expect(model.rules.allSatisfy { !$0.isEnabled })
        #expect(await repository.load() == model.rules)
    }

    @Test func pickedJSONFilesAreReadTogetherAndReviewedBeforeImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = [
            ("书源.json", #"{"bookSourceUrl":"https://picked-json.test","bookSourceName":"JSON 书源"}"#),
            ("大写扩展名.JSON", #"[{"bookSourceUrl":"https://picked-uppercase.test","bookSourceName":"大写扩展名"}]"#),
            ("书源.txt", #"{"bookSourceUrl":"https://picked-text.test","bookSourceName":"文本扩展名"}"#)
        ]
        let files = try inputs.map { name, content in
            let url = directory.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            return SourceImportFile(url: url)
        }
        let model = SourceLibraryModel.demo(sources: [])

        await model.previewPickedFiles(files)

        #expect(model.notice == nil)
        #expect(!model.isWorking)
        #expect(model.pendingImport?.validCount == 3)
        #expect(model.sources.isEmpty)
        let selectedIDs = Set(try #require(model.pendingImport).items.map(\.id))
        await model.commitPendingImport(selectedIDs: selectedIDs, keepOriginalName: false, keepOriginalGroup: false,
                                        keepOriginalEnabled: false, customGroup: nil, addCustomGroup: true)
        #expect(model.sources.count == 3)
        #expect(model.pendingImport == nil)
    }

    @Test func missingOrDirectoryImportReportsFailureWithoutChangingSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = BookSource(bookSourceUrl: "https://existing-source.test", bookSourceName: "原有书源")
        for url in [directory, directory.appendingPathComponent("missing.json")] {
            let model = SourceLibraryModel.demo(sources: [original])
            await model.load()
            await model.previewFiles([url])
            #expect(model.notice?.kind == .error)
            #expect(model.pendingImport == nil)
            #expect(model.sources == [original])
            #expect(!model.isWorking)
        }
    }

    @Test func largeImportKeepsTheMainActorResponsive() async throws {
        let comment = String(repeating: "规则说明", count: 1_024)
        let entries = (0..<1_000).map { index in
            ["bookSourceUrl": "https://large-\(index).test", "bookSourceName": "书源\(index)", "bookSourceComment": comment]
        }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
        let model = SourceLibraryModel.demo(sources: [])
        var servicedUIWork = false
        let heartbeat = Task { @MainActor in servicedUIWork = true }
        defer { heartbeat.cancel() }

        await model.previewText(input)

        #expect(servicedUIWork, "Parsing a large catalog must yield the main actor to UI work")
        #expect(model.pendingImport?.validCount == entries.count)
        #expect(model.sources.isEmpty)
        #expect(!model.isWorking)
    }

    @Test func failedSourceSaveAndImportKeepDraftAndReview() async throws {
        let model = SourceLibraryModel(repository: FailingSourceRepository())
        let source = BookSource(bookSourceUrl: "https://test", bookSourceName: "测试")
        #expect(await model.saveSource(source) == false)
        #expect(model.sources.isEmpty)
        await model.previewText(String(decoding: try JSONEncoder().encode(source), as: UTF8.self))
        #expect(model.pendingImport?.validCount == 1)
        await model.commitPendingImport(selectedIDs: [source.id], keepOriginalName: false, keepOriginalGroup: false, keepOriginalEnabled: false, customGroup: nil, addCustomGroup: true)
        #expect(model.pendingImport != nil)
        #expect(model.sources.isEmpty)
    }

    @Test func replacingSourcePreservesOrderAndBothEnabledFlags() async throws {
        var old = BookSource(bookSourceUrl: "https://test", bookSourceName: "旧名称")
        old.customOrder = 42; old.enabled = false; old.enabledExplore = false
        old.bookSourceGroup = "本地分组"
        var new = BookSource(bookSourceUrl: old.id, bookSourceName: "新名称")
        new.lastUpdateTime = 10
        let model = SourceLibraryModel(repository: InMemoryBookSourceRepository(sources: [old]))
        await model.load()
        await model.previewText(String(decoding: try JSONEncoder().encode(new), as: UTF8.self))
        await model.commitPendingImport(selectedIDs: [old.id], keepOriginalName: true, keepOriginalGroup: true, keepOriginalEnabled: true, customGroup: nil, addCustomGroup: true)
        let saved = try #require(model.sources.first)
        #expect(saved.customOrder == 42)
        #expect(!saved.enabled && !saved.enabledExplore)
        #expect(saved.bookSourceName == "旧名称")
        #expect(saved.bookSourceGroup == "本地分组")
    }

    @Test func importReviewDeduplicatesIDsAndKeepsValidEntries() async {
        let model = SourceLibraryModel.demo(sources: [])
        await model.previewText(#"[{"bookSourceUrl":"https://test","bookSourceName":"旧"},{"bookSourceUrl":"https://test","bookSourceName":"新"},{"bookSourceName":"缺地址"},{"bookSourceUrl":"https://bad","bookSourceName":"坏类型","ruleContent":99}]"#)
        #expect(model.pendingImport?.validCount == 1)
        #expect(model.pendingImport?.invalidCount == 2)
        #expect(model.pendingImport?.items.first?.source.bookSourceName == "新")
    }

    @Test func changingSourceURLCannotSilentlyDeleteAnotherSource() async {
        let first = BookSource(bookSourceUrl: "https://first", bookSourceName: "一")
        let second = BookSource(bookSourceUrl: "https://second", bookSourceName: "二")
        let model = SourceLibraryModel(repository: InMemoryBookSourceRepository(sources: [first, second]))
        await model.load()
        var edited = first
        edited.bookSourceUrl = second.id
        #expect(await model.saveSource(edited, replacing: first.id) == false)
        #expect(model.sources == [first, second])
    }

    @Test func remoteManifestFeedsPreviewAndHonorsWithoutUserAgent() async throws {
        let transport = ImportFixtureTransport(documents: [
            "https://import.test/manifest": #"{"sourceUrls":["https://import.test/a#requestWithoutUA","https://import.test/b"]}"#,
            "https://import.test/a": #"{"bookSourceUrl":"https://a.test","bookSourceName":"A"}"#,
            "https://import.test/b": #"[{"bookSourceUrl":"https://b.test","bookSourceName":"B"},{"bookSourceName":"损坏"}]"#
        ])
        let model = SourceLibraryModel(repository: InMemoryBookSourceRepository(), importTransport: transport)
        await model.previewRemoteURL("https://import.test/manifest")
        #expect(model.pendingImport?.validCount == 2)
        #expect(model.pendingImport?.invalidCount == 1)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[1].value(forHTTPHeaderField: "User-Agent") == "null")
        #expect(model.sources.isEmpty)
    }

    @Test func cyclicImportManifestReportsErrorWithoutMutation() async {
        let transport = ImportFixtureTransport(documents: ["https://import.test/cycle": #"{"sourceUrls":["https://import.test/cycle"]}"#])
        let model = SourceLibraryModel(repository: InMemoryBookSourceRepository(), importTransport: transport)
        await model.previewRemoteURL("https://import.test/cycle")
        #expect(model.pendingImport == nil)
        #expect(model.sources.isEmpty)
        #expect(model.notice?.detail.contains("循环") == true)
        #expect(await transport.requests.count == 1)
    }

    @Test func directSubscriptionImportUsesSameManifestResolution() async {
        let transport = ImportFixtureTransport(documents: [
            "https://import.test/list": #"{"sourceUrls":["https://import.test/one"]}"#,
            "https://import.test/one": #"{"bookSourceUrl":"https://one.test","bookSourceName":"订阅"}"#
        ])
        let model = SourceLibraryModel(repository: InMemoryBookSourceRepository(), importTransport: transport)
        await model.importRemoteURL("https://import.test/list")
        #expect(model.sources.first?.bookSourceName == "订阅")
        #expect(model.pendingImport == nil)
    }

    @Test func purificationSaveValidatesAndFailureLeavesLibraryUntouched() async {
        let model = ReplaceRuleLibraryModel(repository: FailingReplaceRepository())
        var rule = model.newRule()
        #expect(await model.save(rule) == false)
        #expect(model.rules.isEmpty)
        rule.pattern = "广告"
        #expect(await model.save(rule) == false)
        #expect(model.rules.isEmpty)
    }

    @Test func purificationCopyGetsDistinctIDAndMovePersistsExecutionOrder() async {
        let repository = InMemoryReplaceRuleRepository()
        let model = ReplaceRuleLibraryModel(repository: repository)
        var rule = model.newRule(); rule.name = "清理"; rule.pattern = "广告"
        #expect(await model.save(rule))
        let copy = model.newRule(copying: rule)
        #expect(copy.id != rule.id)
        #expect(copy.name == "清理 副本")
        #expect(await model.save(copy))
        await model.move(from: [1], to: 0)
        #expect(model.rules.map(\.id) == [copy.id, rule.id])
        #expect(model.rules.map(\.sortOrder) == [0, 1])
        #expect(await repository.load() == model.rules)
    }
}

private actor SuspendedSourceRepository: BookSourceRepository {
    private var sources: [BookSource]
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    init(sources: [BookSource]) { self.sources = sources }
    func load() -> [BookSource] { sources }
    func save(_ sources: [BookSource]) async {
        if !started {
            started = true
            await withCheckedContinuation { pending = $0 }
        }
        self.sources = sources
    }
    func waitForSave() async { while !started { await Task.yield() } }
    func finishSave() { pending?.resume(); pending = nil }
}

private actor SuspendedReplaceRepository: ReplaceRuleRepository {
    private var rules: [ReplaceRule]
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    init(rules: [ReplaceRule]) { self.rules = rules }
    func load() -> [ReplaceRule] { rules }
    func save(_ rules: [ReplaceRule]) async {
        if !started {
            started = true
            await withCheckedContinuation { pending = $0 }
        }
        self.rules = rules
    }
    func waitForSave() async { while !started { await Task.yield() } }
    func finishSave() { pending?.resume(); pending = nil }
}
