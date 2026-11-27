@preconcurrency import AVFAudio
import MediaPlayer
import SwiftUI

@MainActor
final class ReaderPageInput: ObservableObject {
    var turn: ((Int) -> Void)?
}

struct ReaderVolumeInput: UIViewRepresentable {
    let input: ReaderPageInput

    func makeUIView(context: Context) -> VolumeInputView {
        let view = VolumeInputView(frame: .zero)
        view.input = input
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: VolumeInputView, context: Context) { view.input = input }
    static func dismantleUIView(_ view: VolumeInputView, coordinator: Void) { view.stop() }

    final class VolumeInputView: MPVolumeView {
        weak var input: ReaderPageInput?
        private var observation: NSKeyValueObservation?
        private var original: Float?
        private var reference: Float = 0.5
        private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
        private var slider: UISlider? { subviews.compactMap { $0 as? UISlider }.first }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { stop(); return }
            guard observation == nil, slider != nil else { return }
            let audio = AVAudioSession.sharedInstance()
            let previous = (audio.category, audio.mode, audio.categoryOptions)
            do {
                try audio.setCategory(.ambient)
                try audio.setActive(true)
            } catch {
                try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
                return
            }
            previousAudio = previous
            original = audio.outputVolume
            // Leave one hardware step at either end so both buttons produce an event.
            reference = min(max(audio.outputVolume, 1.0 / 16), 15.0 / 16)
            observation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let level = change.newValue else { return }
                Task { @MainActor in self?.changed(level) }
            }
            if original != reference { setLevel(reference) }
        }

        private func changed(_ level: Float) {
            guard original != nil, abs(level - reference) > 0.005 else { return }
            setLevel(reference)
            input?.turn?(level < reference ? 1 : -1)
        }

        private func setLevel(_ level: Float) {
            slider?.setValue(level, animated: false)
            slider?.sendActions(for: .valueChanged)
            slider?.sendActions(for: .touchUpInside)
        }

        func stop() {
            observation?.invalidate()
            observation = nil
            guard let level = original else { return }
            original = nil
            let audio = AVAudioSession.sharedInstance()
            if abs(audio.outputVolume - level) > 0.005 { setLevel(level) }
            if audio.category == .ambient, let previousAudio {
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                try? audio.setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
            }
            previousAudio = nil
        }
    }
}
