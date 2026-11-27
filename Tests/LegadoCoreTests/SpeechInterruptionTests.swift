import Foundation
import Testing
@testable import LegadoCore

struct SpeechInterruptionTests {
    @Test func interruptionCoordinatorPreservesPlaybackIntentAndCancelsOnUserOrRouteEvents() {
        var coordinator = SpeechInterruptionCoordinator()
        coordinator.didStartPlaying()

        // Turn-by-turn navigation begins: should pause and arm auto-resume.
        #expect(coordinator.handleInterruptionBegan(ignoresAudioFocus: false, pausesForPhoneCalls: false) == .pause)
        #expect(coordinator.phase == .pausedByInterruption)
        #expect(coordinator.pendingAutoResume == true)

        // Navigation ends with shouldResume: resumes automatically.
        #expect(coordinator.handleInterruptionEnded(
            shouldResume: true,
            ignoresAudioFocus: false,
            pausesForPhoneCalls: false
        ) == .resume)
        #expect(coordinator.phase == .playing)

        // If headphones disconnect during interruption, do NOT auto-resume over speaker.
        #expect(coordinator.handleInterruptionBegan(ignoresAudioFocus: false, pausesForPhoneCalls: false) == .pause)
        #expect(coordinator.handleRouteDisconnected() == .none)
        #expect(coordinator.phase == .pausedByRouteDisconnect)
        #expect(coordinator.handleInterruptionEnded(
            shouldResume: true,
            ignoresAudioFocus: false,
            pausesForPhoneCalls: false
        ) == .none)

        // If user already paused manually before an interruption, ending interruption must stay paused.
        coordinator.didResumeByUser()
        coordinator.didPauseByUser()
        #expect(coordinator.handleInterruptionBegan(ignoresAudioFocus: false, pausesForPhoneCalls: false) == .none)
        #expect(coordinator.handleInterruptionEnded(
            shouldResume: true,
            ignoresAudioFocus: false,
            pausesForPhoneCalls: false
        ) == .none)
        #expect(coordinator.phase == .pausedByUser)
    }

    @Test func resolvesRelocatedLocalBookAfterContainerUUIDChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-relocate-\(UUID().uuidString)", isDirectory: true)
        let localDir = root.appendingPathComponent("LocalBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let actual = localDir.appendingPathComponent("demo-novel.epub")
        try Data("stub".utf8).write(to: actual)

        let staleOldContainerURL = "file:///var/mobile/Containers/Data/Application/OLD-UUID-1234/Library/Application%20Support/Legado/LocalBooks/demo-novel.epub"
        let resolved = LocalBookService.resolveLocalFileURL(for: staleOldContainerURL, supportDirectory: root)
        #expect(resolved?.standardizedFileURL == actual.standardizedFileURL)
    }
}
