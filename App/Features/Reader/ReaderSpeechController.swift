@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

private final class IncrementalAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.legado.tts.stream-loader")
    private let contentType: String?
    private let expectedLength: Int64
    private var data = Data()
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var finished = false
    private var failure: Error?
    private var consumeTask: Task<Void, Never>?

    init(stream: HttpTTSAudioStream) {
        contentType = stream.contentType
        expectedLength = stream.expectedContentLength ?? 0
        super.init()
        consumeTask = Task { [weak self] in
            do {
                for try await chunk in stream.chunks {
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        self?.data.append(chunk)
                        self?.processPendingRequests()
                    }
                }
                self?.queue.async { [weak self] in
                    self?.finished = true
                    self?.processPendingRequests()
                }
            } catch {
                self?.queue.async { [weak self] in
                    self?.failure = error
                    self?.finished = true
                    self?.processPendingRequests()
                }
            }
        }
    }

    deinit { consumeTask?.cancel() }

    func cancel() {
        consumeTask?.cancel()
        queue.async { [weak self] in
            guard let self, !finished else { return }
            failure = CancellationError()
            finished = true
            processPendingRequests()
        }
    }

    func install(on asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pending.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func processPendingRequests() {
        pending.removeAll { request in
            if let info = request.contentInformationRequest {
                info.contentType = contentType.flatMap { UTType(mimeType: $0)?.identifier }
                info.contentLength = expectedLength
                info.isByteRangeAccessSupported = false
            }
            if let failure {
                request.finishLoading(with: failure)
                return true
            }
            guard let dataRequest = request.dataRequest else {
                if finished { request.finishLoading(); return true }
                return false
            }
            let offset = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            if offset < data.count {
                let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                let end = min(data.count, requestedEnd)
                if end > offset { dataRequest.respond(with: data.subdata(in: offset..<end)) }
            }
            let deliveredEnd = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            if deliveredEnd >= requestedEnd || finished {
                request.finishLoading()
                return true
            }
            return false
        }
    }
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionCount = 0
    @Published private(set) var currentSegmentIndex = 0
    private var synthesizer: AVSpeechSynthesizer?
    private var audioSessionActive = false
    private let httpService = HttpTTSService()
    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamLoader: IncrementalAudioResourceLoader?
    private var streamCompletionToken: NSObjectProtocol?
    private var httpTask: Task<Void, Never>?
    private var httpPrefetchTasks: [Task<Void, Never>] = []
    private var httpSegments: [String] = []
    private var httpSegmentIndex = 0
    private var httpEngine: HttpTTS?
    private var systemSegments: [String] = []
    private var systemSegmentIndex = 0
    private var segmentIndexOffset = 0
    private var followsSystemRate = true
    private var speechRate = 5
    private var readByPage = false
    private var streamsHTTPAudio = true
    private var voiceIdentifier = ""
    private var continuesAcrossChapters = false
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var isChangingSystemSegment = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var bookName = ""
    private var chapterTitle = ""
    private var author = ""
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onRemoteStop: (() -> Void)?

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func toggle(text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speak(text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func toggleHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func stop() {
        guard audioSessionActive || !httpPrefetchTasks.isEmpty else { return }
        synthesizer?.stopSpeaking(at: .word)
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
        httpPrefetchTasks.forEach { $0.cancel() }
        httpPrefetchTasks.removeAll()
        httpSegments = []
        httpSegmentIndex = 0
        httpEngine = nil
        systemSegments = []
        systemSegmentIndex = 0
        segmentIndexOffset = 0
        continuesAcrossChapters = false
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    func configure(
        followsSystemRate: Bool,
        speechRate: Int,
        readByPage: Bool,
        streamsHTTPAudio: Bool = true,
        voiceIdentifier: String = "",
        ignoresAudioFocus: Bool = false,
        pausesForPhoneCalls: Bool = false,
        mediaButtonPerNext: Bool = false,
        bookName: String = "",
        chapterTitle: String = "",
        author: String = ""
    ) {
        self.followsSystemRate = followsSystemRate
        self.speechRate = min(max(speechRate, 0), 45)
        self.readByPage = readByPage
        self.streamsHTTPAudio = streamsHTTPAudio
        self.voiceIdentifier = voiceIdentifier
        self.ignoresAudioFocus = ignoresAudioFocus
        self.pausesForPhoneCalls = pausesForPhoneCalls
        self.mediaButtonPerNext = mediaButtonPerNext
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.author = author
    }

    func speak(_ text: String, continuesAcrossChapters: Bool = false, segmentIndexOffset: Int = 0) {
        stop()
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        if let synthesizer, synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        systemSegments = segments(for: text)
        guard !systemSegments.isEmpty else { return }
        systemSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        playCurrentSystemSegment()
    }

    func speakHTTP(
        engine: HttpTTS,
        text: String,
        continuesAcrossChapters: Bool = false,
        segmentIndexOffset: Int = 0
    ) {
        stop()
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        httpEngine = engine
        httpSegments = segments(for: text)
        guard !httpSegments.isEmpty else { return }
        httpSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        isSpeaking = true
        playCurrentHTTPSegment()
        prefetchHTTP(engine: engine, texts: Array(httpSegments.dropFirst()))
    }

    func prefetchHTTP(engine: HttpTTS, text: String, limit: Int = 10) {
        let values = Array(segments(for: text).prefix(max(limit, 0)))
        prefetchHTTP(engine: engine, texts: values)
    }

    func pauseOrResume(text: String, continuesAcrossChapters: Bool = false) {
        if isPaused {
            resumePlayback()
        } else if isSpeaking {
            pausePlayback()
        } else {
            speak(text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    func pauseOrResumeHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if audioPlayer != nil {
            pauseOrResume(text: text, continuesAcrossChapters: continuesAcrossChapters)
        } else if isSpeaking {
            httpTask?.cancel()
            isSpeaking = false
            isPaused = true
        } else if isPaused, httpEngine != nil {
            isPaused = false
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    private func segments(for text: String) -> [String] {
        let values = readByPage ? [text] : text.components(separatedBy: .newlines)
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func activateAudioSession() {
        if notificationTokens.isEmpty {
            observeAudioSession()
            installRemoteCommands()
        }
        audioSessionActive = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    private func pausePlayback() {
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if let streamPlayer {
            streamPlayer.pause()
        } else if let synthesizer, synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        } else if httpTask != nil {
            httpTask?.cancel()
            httpTask = nil
        } else {
            return
        }
        isPaused = true
        isSpeaking = false
        updateNowPlaying()
    }

    private func resumePlayback() {
        activateAudioSession()
        if let audioPlayer {
            isSpeaking = audioPlayer.play()
        } else if let streamPlayer {
            streamPlayer.play()
            isSpeaking = true
        } else if let synthesizer, synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if httpEngine != nil, httpSegments.indices.contains(httpSegmentIndex) {
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            return
        }
        isPaused = false
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleAudioInterruption(type: type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleAudioInterruption(type raw: UInt?, options rawOptions: UInt) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            resumesAfterInterruption = isSpeaking
            if isSpeaking { pausePlayback() }
        case .ended:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumesAfterInterruption, options.contains(.shouldResume) { resumePlayback() }
            resumesAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        if isSpeaking { pausePlayback() }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        addRemoteTarget(center.playCommand) { $0.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { $0.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { controller in
            controller.isPaused ? controller.resumePlayback() : controller.pausePlayback()
        }
        addRemoteTarget(center.stopCommand) { controller in
            controller.stop()
            controller.onRemoteStop?()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward(usesChapterPreference: true) }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward(usesChapterPreference: true) }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (ReaderSpeechController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    func nextSegment() {
        guard isSpeaking || isPaused else { return }
        skipForward(usesChapterPreference: false)
    }

    func previousSegment() {
        guard isSpeaking || isPaused else { return }
        skipBackward(usesChapterPreference: false)
    }

    private func playCurrentSystemSegment() {
        guard systemSegments.indices.contains(systemSegmentIndex) else {
            finishNaturally()
            return
        }
        let utterance = AVSpeechUtterance(string: systemSegments[systemSegmentIndex])
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let multiplier = followsSystemRate ? 1 : Float(speechRate + 5) / 10
        utterance.rate = min(
            max(AVSpeechUtteranceDefaultSpeechRate * multiplier, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = 1
        if synthesizer == nil {
            synthesizer = AVSpeechSynthesizer()
            synthesizer?.delegate = self
        }
        synthesizer?.speak(utterance)
        currentSegmentIndex = segmentIndexOffset + systemSegmentIndex
        isSpeaking = true
        isPaused = false
        updateNowPlaying()
    }

    private func skipForward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onNextChapter?()
        } else if httpEngine != nil, httpSegmentIndex + 1 < httpSegments.count {
            stopCurrentHTTPPlayback()
            httpSegmentIndex += 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex + 1 < systemSegments.count {
            changeSystemSegment(to: systemSegmentIndex + 1)
        } else {
            onNextChapter?()
        }
    }

    private func skipBackward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onPreviousChapter?()
        } else if httpEngine != nil, httpSegmentIndex > 0 {
            stopCurrentHTTPPlayback()
            httpSegmentIndex -= 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex > 0 {
            changeSystemSegment(to: systemSegmentIndex - 1)
        } else {
            onPreviousChapter?()
        }
    }

    private func stopCurrentHTTPPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
    }

    private func changeSystemSegment(to index: Int) {
        isChangingSystemSegment = true
        synthesizer?.stopSpeaking(at: .immediate)
        systemSegmentIndex = index
        playCurrentSystemSegment()
        DispatchQueue.main.async { [weak self] in self?.isChangingSystemSegment = false }
    }

    private func updateNowPlaying() {
        guard isSpeaking || isPaused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookName,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? 1 : 0
        ]
    }

    private func playCurrentHTTPSegment() {
        guard let engine = httpEngine, httpSegments.indices.contains(httpSegmentIndex) else {
            stop()
            return
        }
        let text = httpSegments[httpSegmentIndex]
        currentSegmentIndex = segmentIndexOffset + httpSegmentIndex
        let rate = speechRate + 5
        httpTask?.cancel()
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if streamsHTTPAudio {
                    let stream = try await httpService.audioStream(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    if stream.isIncremental, stream.expectedContentLength ?? 0 > 0 {
                        playIncrementalHTTPStream(stream)
                    } else {
                        var data = Data()
                        for try await chunk in stream.chunks { data.append(chunk) }
                        try Task.checkCancellation()
                        try playBufferedHTTPAudio(data)
                    }
                } else {
                    let audio = try await httpService.audio(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    try playBufferedHTTPAudio(audio.data)
                }
                isPaused = false
                updateNowPlaying()
                if !isSpeaking { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    private func playBufferedHTTPAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        isSpeaking = player.play()
    }

    private func playIncrementalHTTPStream(_ stream: HttpTTSAudioStream) {
        let url = URL(string: "legado-tts-stream://audio/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        let loader = IncrementalAudioResourceLoader(stream: stream)
        loader.install(on: asset)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        streamLoader = loader
        streamPlayer = player
        streamCompletionToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.incrementalPlayerDidFinish() }
        }
        player.play()
        isSpeaking = true
    }

    private func incrementalPlayerDidFinish() {
        stopCurrentHTTPPlayback()
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count { playCurrentHTTPSegment() }
        else { finishNaturally() }
    }

    private func prefetchHTTP(engine: HttpTTS, texts: [String]) {
        guard !texts.isEmpty else { return }
        let rate = speechRate + 5
        let task = Task { [weak self] in
            guard let self else { return }
            for text in texts {
                guard !Task.isCancelled else { return }
                _ = try? await self.httpService.audio(engine: engine, text: text, speechRate: rate)
            }
        }
        httpPrefetchTasks.append(task)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        guard flag else {
            errorMessage = "HTTP TTS 音频播放失败"
            stop()
            return
        }
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count {
            playCurrentHTTPSegment()
        } else {
            finishNaturally()
        }
    }

    private func finishNaturally() {
        let shouldContinue = continuesAcrossChapters
        stop()
        if shouldContinue { completionCount += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        systemSegmentIndex += 1
        if systemSegmentIndex < systemSegments.count { playCurrentSystemSegment() }
        else { finishNaturally() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
    }
}
