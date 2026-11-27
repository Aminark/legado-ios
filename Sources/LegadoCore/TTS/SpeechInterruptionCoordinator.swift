import Foundation

/// Deterministic state machine that tracks playback intent across iOS audio
/// interruptions (turn-by-turn navigation, phone calls, Siri) and route
/// changes (unplugging headphones / disconnecting Bluetooth).
///
/// Design invariants:
/// - Navigation/call interruption pauses active playback and marks intent to resume.
/// - Manual pause, stop, or audio route disconnection cancels any pending resume
///   intent so audio never unexpectedly resumes over the speaker.
/// - Transient interruptions (such as short turn-by-turn prompts) resume when
///   iOS signals `.shouldResume`, or when `resumeWithoutSystemHint` is enabled
///   and interruption ends cleanly without user intervention.
public struct SpeechInterruptionCoordinator: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case playing
        case pausedByUser
        case pausedByInterruption
        case pausedByRouteDisconnect
    }

    public enum Action: Sendable, Equatable {
        case none
        case pause
        case resume
    }

    public private(set) var phase: Phase = .idle
    public private(set) var pendingAutoResume = false

    public init() {}

    public mutating func didStartPlaying() {
        phase = .playing
        pendingAutoResume = false
    }

    public mutating func didPauseByUser() {
        pendingAutoResume = false
        if phase != .idle {
            phase = .pausedByUser
        }
    }

    public mutating func didResumeByUser() {
        pendingAutoResume = false
        phase = .playing
    }

    public mutating func didStop() {
        phase = .idle
        pendingAutoResume = false
    }

    public mutating func handleInterruptionBegan(ignoresAudioFocus: Bool, pausesForPhoneCalls: Bool) -> Action {
        if ignoresAudioFocus && !pausesForPhoneCalls {
            return .none
        }
        guard phase == .playing else {
            return .none
        }
        phase = .pausedByInterruption
        pendingAutoResume = true
        return .pause
    }

    public mutating func handleInterruptionEnded(
        shouldResume: Bool,
        ignoresAudioFocus: Bool,
        pausesForPhoneCalls: Bool,
        resumeTransientWithoutHint: Bool = false
    ) -> Action {
        if ignoresAudioFocus && !pausesForPhoneCalls {
            return .none
        }
        guard phase == .pausedByInterruption else {
            pendingAutoResume = false
            return .none
        }
        let allowResume = pendingAutoResume && (shouldResume || resumeTransientWithoutHint)
        pendingAutoResume = false
        if allowResume {
            phase = .playing
            return .resume
        }
        phase = .pausedByUser
        return .none
    }

    public mutating func handleRouteDisconnected() -> Action {
        pendingAutoResume = false
        guard phase == .playing || phase == .pausedByInterruption else {
            return .none
        }
        let wasPlaying = phase == .playing
        phase = .pausedByRouteDisconnect
        return wasPlaying ? .pause : .none
    }
}
