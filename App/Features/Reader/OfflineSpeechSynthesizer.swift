import CryptoKit
import Foundation
import SherpaOnnxC

actor OfflineSpeechSynthesizer {
    static let shared = OfflineSpeechSynthesizer()
    static let engineTag = "builtin:melo"
    static let engineName = "离线中文语音（MeloTTS）"

    enum InstallationState: Equatable, Sendable {
        case checking, unavailable, downloading(Int64), verifying, installed, failed(String)

        var isInstalled: Bool { self == .installed }
    }

    private static let source = URL(string: "https://huggingface.co/csukuangfj/vits-melo-tts-zh_en/resolve/a0d5c6a264c0ef92d70d8661d8cc502d79627cd6/")!
    private static let downloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    private static let modelFile = "model.int8.onnx"
    private static let rules = ["date.fst", "phone.fst", "number.fst", "new_heteronym.fst"]
    private static let files: [(path: String, bytes: Int64, checksum: String)] = [
        (modelFile, 53_517_430, "f085f5079e05f039b800aeb542f5253c26a303211b0c6465d0d9387977855a63"),
        ("LICENSE", 1_053, "88a50e5a02bbc2a5c2f084dc19da751aa97b1690f5fda76cd8005c8634d1ca70"),
        ("tokens.txt", 655, "d18664a7e12bd7ea1022ddaf951e534e136815016c5a809d6b64156bffb4369d"),
        ("lexicon.txt", 6_837_671, "7236884b02435ac5d10cf69b4be40a61b45aa676b5300f0e412f185748fee528"),
        ("date.fst", 59_154, "eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718"),
        ("phone.fst", 88_630, "1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7"),
        ("number.fst", 64_482, "743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd"),
        ("new_heteronym.fst", 21_974, "ca14b2127e27baa571664e4bb791e143e7425f56a6bc29db08d74f97e6aa4e29"),
        ("dict/hmm_model.utf8", 519_739, "f17790586ac86dd048c8adffed052c4bd2b28ed0682972c1275e59040c0589a7"),
        ("dict/idf.utf8", 5_998_717, "dbd1e03d72b2263cc8d84a4304ed77677eed9e7deaf43a1a5133bbba9733b535"),
        ("dict/jieba.dict.utf8", 5_071_204, "3043b77068e09c9904f27cad82f12b6ebe9dbdb5aeff3b25e45ab7f9c1122b55"),
        ("dict/stop_words.utf8", 8_974, "b788b8a939d2e2fe079abd579ea98f12f9fb84370bfd0dddd81bb9381f7ab42c"),
        ("dict/user.dict.utf8", 49, "495bbf49270408a1234690e1e6a97328f30a482a7a72aa769e8a12e8714b0c62"),
        ("dict/pos_dict/char_state_tab.utf8", 327_139, "28b7be1dd7369766a51445af4d42e9a2ba4bf374c13be5bc1ca7721e27271dbb"),
        ("dict/pos_dict/prob_emit.utf8", 1_687_686, "c33c4cb7edf3b3a5947df7209b6e9f267eae1f21335d9e2bd2521ea07105457a"),
        ("dict/pos_dict/prob_start.utf8", 4_347, "13623ea0e9300bdb597cb2da28770b7b385d6c0098d66e516083fb01b6bd5d96"),
        ("dict/pos_dict/prob_trans.utf8", 124_159, "f22363e2307408293d180c6f9f6b5cb75879d52f722f7764fa2d3d0ae2400236")
    ]
    static let downloadByteCount = files.reduce(Int64(0)) { $0 + $1.bytes }

    private let directory: URL
    private var installation: Task<Void, Error>?
    private var installationState: InstallationState = .unavailable
    private var installationObservers: [UUID: AsyncStream<InstallationState>.Continuation] = [:]
    private var synthesizer: Model?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeloTTS-a0d5c6a", isDirectory: true)
    }

    var isInstalled: Bool {
        Self.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.path)
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
        }
    }

    func currentInstallationState() -> InstallationState {
        if installation == nil {
            if isInstalled {
                updateInstallationState(.installed)
            } else if installationState.isInstalled {
                updateInstallationState(.unavailable)
            }
        }
        return installationState
    }

    func installationUpdates() -> AsyncStream<InstallationState> {
        let state = currentInstallationState()
        let id = UUID()
        let (stream, continuation) = AsyncStream<InstallationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        installationObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeInstallationObserver(id) }
        }
        return stream
    }

    private func removeInstallationObserver(_ id: UUID) {
        installationObservers[id] = nil
    }

    private func updateInstallationState(_ state: InstallationState) {
        guard state != installationState else { return }
        installationState = state
        installationObservers.values.forEach { $0.yield(state) }
    }

    private func recordDownloadedBytes(_ count: Int64) {
        guard case .downloading(let completed) = installationState else { return }
        let updated = completed + count
        updateInstallationState(updated < Self.downloadByteCount ? .downloading(updated) : .verifying)
    }

    func install() async throws {
        if let installation { return try await installation.value }
        guard !isInstalled else {
            updateInstallationState(.installed)
            return
        }
        synthesizer = nil
        updateInstallationState(.downloading(0))
        let installation = Task {
            try await Self.downloadModel(to: directory) { count in
                await self.recordDownloadedBytes(count)
            }
        }
        self.installation = installation
        defer { self.installation = nil }
        do {
            try await installation.value
            updateInstallationState(.installed)
        } catch {
            updateInstallationState(.failed(error.localizedDescription))
            throw error
        }
    }

    private static func downloadModel(to directory: URL, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let manager = FileManager.default
        var stage = directory.deletingLastPathComponent().appendingPathComponent(".melo-\(UUID().uuidString)")
        try manager.createDirectory(at: stage.appendingPathComponent("dict/pos_dict"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try stage.setResourceValues(attributes)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                let destination = stage.appendingPathComponent(file.path)
                group.addTask {
                    let url = source.appendingPathComponent(file.path)
                    let usesRanges = file.bytes >= 6_000_000
                    if usesRanges {
                        try await downloadInRanges(url, size: Int(file.bytes), to: destination, progress: progress)
                    } else {
                        let (temporary, response) = try await download(URLRequest(url: url))
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        guard response.statusCode == 200 else { throw Failure.download(file.path) }
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }
                    let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                    guard data.count == Int(file.bytes) else { throw Failure.download(file.path) }
                    if !usesRanges { await progress(file.bytes) }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == file.checksum else { throw Failure.checksum(file.path) }
                }
            }
            for try await _ in group {}
        }

        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: stage, to: directory)
    }

    private static func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        for attempt in 0...5 {
            do {
                let (file, response) = try await downloads.download(for: request)
                if let http = response as? HTTPURLResponse, !(500...599).contains(http.statusCode) {
                    return (file, http)
                }
                try? FileManager.default.removeItem(at: file)
                throw URLError(.badServerResponse)
            } catch let error as URLError where error.code != .cancelled && attempt < 5 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 300_000_000)
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private static func downloadInRanges(
        _ url: URL, size: Int, to destination: URL, progress: @Sendable (Int64) async -> Void
    ) async throws {
        let chunkSize = 2 * 1024 * 1024
        let offsets = Array(stride(from: 0, to: size, by: chunkSize))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        for batch in stride(from: 0, to: offsets.count, by: 4) {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for start in offsets[batch..<min(batch + 4, offsets.count)] {
                    group.addTask {
                        let end = min(start + chunkSize, size) - 1
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                        let (file, response) = try await download(request)
                        defer { try? FileManager.default.removeItem(at: file) }
                        guard response.statusCode == 206,
                              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(size)" else {
                            throw Failure.download(url.lastPathComponent)
                        }
                        let data = try Data(contentsOf: file)
                        guard data.count == end - start + 1 else { throw Failure.download(url.lastPathComponent) }
                        return (start, data)
                    }
                }
                for try await (start, data) in group {
                    try output.seek(toOffset: UInt64(start))
                    try output.write(contentsOf: data)
                    await progress(Int64(data.count))
                }
            }
        }
    }

    func audio(text: String, rate: Int, followsSystemRate: Bool) throws -> Data {
        try Task.checkCancellation()
        guard isInstalled else {
            if installationState.isInstalled { updateInstallationState(.unavailable) }
            throw Failure.needsDownload
        }
        let engine = try synthesisEngine()
        let speed: Float = followsSystemRate ? 1 : min(max(Float(rate + 5) / 10, 0.5), 2.5)
        var pcm = Data()
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            let limit = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
            let end = limit == text.endIndex ? limit : text[start..<limit].lastIndex(where: { "。！？；.!?\n".contains($0) })
                .map { text.index(after: $0) } ?? limit
            pcm.append(engine.pcm(text: String(text[start..<end]), speed: speed))
            start = end
        }
        guard !pcm.isEmpty else { throw Failure.emptyAudio }
        return Self.wave(pcm, sampleRate: engine.sampleRate)
    }

    private func synthesisEngine() throws -> Model {
        if let synthesizer { return synthesizer }
        let engine = try Model(directory: directory, modelFile: Self.modelFile, rules: Self.rules)
        synthesizer = engine
        return engine
    }

    private final class Model {
        let handle: OpaquePointer
        let sampleRate: UInt32

        init(directory: URL, modelFile: String, rules: [String]) throws {
            var strings: [UnsafeMutablePointer<CChar>] = []
            defer { strings.forEach { free($0) } }
            func cString(_ string: String) -> UnsafePointer<CChar>? {
                guard let pointer = strdup(string) else { return nil }
                strings.append(pointer)
                return UnsafePointer(pointer)
            }
            func path(_ relativePath: String) -> String {
                directory.appendingPathComponent(relativePath).path
            }
            var config = SherpaOnnxOfflineTtsConfig()
            config.model.vits.model = cString(path(modelFile))
            config.model.vits.lexicon = cString(path("lexicon.txt"))
            config.model.vits.tokens = cString(path("tokens.txt"))
            config.model.vits.dict_dir = cString(path("dict"))
            config.model.vits.noise_scale = 0.667
            config.model.vits.noise_scale_w = 0.8
            config.model.vits.length_scale = 1
            config.model.num_threads = 2
            config.model.provider = cString("cpu")
            config.rule_fsts = cString(rules.map(path).joined(separator: ","))
            config.max_num_sentences = 1
            config.silence_scale = 0.2
            guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw Failure.initialization }
            let rate = SherpaOnnxOfflineTtsSampleRate(handle)
            guard rate > 0 else {
                SherpaOnnxDestroyOfflineTts(handle)
                throw Failure.initialization
            }
            self.handle = handle
            self.sampleRate = UInt32(rate)
        }

        deinit { SherpaOnnxDestroyOfflineTts(handle) }

        func pcm(text: String, speed: Float) -> Data {
            var config = SherpaOnnxGenerationConfig()
            config.speed = speed
            config.silence_scale = 0.2
            guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(handle, text, &config, nil, nil) else { return Data() }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let buffer = UnsafeBufferPointer(start: audio.pointee.samples, count: Int(audio.pointee.n))
            let samples = buffer.map { sample in
                Int16(min(max(sample.isFinite ? sample : 0, -1), 1) * Float(Int16.max)).littleEndian
            }
            return samples.withUnsafeBytes { Data($0) }
        }
    }

    private static func wave(_ pcm: Data, sampleRate: UInt32) -> Data {
        var wave = Data()
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) }
        }
        wave.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // Linear PCM
        append(UInt16(1)) // Mono
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        wave.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count))
        wave.append(pcm)
        return wave
    }

    private enum Failure: LocalizedError {
        case needsDownload, initialization, emptyAudio
        case download(String), checksum(String)

        var errorDescription: String? {
            switch self {
            case .needsDownload: "请先在朗读设置中下载离线中文语音。"
            case .initialization: "离线中文语音初始化失败。"
            case .emptyAudio: "离线中文语音未生成音频。"
            case .download(let file): "下载离线语音失败（\(file)），请稍后重试。"
            case .checksum(let file): "离线语音文件校验失败（\(file)），请重新下载。"
            }
        }
    }
}
