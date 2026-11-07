import SwiftUI
import UIKit

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

// Shared by text reading, EPUB and every settings panel that adjusts a scalar.
struct ReadingSliderPreview {
    let id: String
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String
    var displayValue: Double

    init(id: String, title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double?, format: @escaping (Double) -> String) {
        self.id = id
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        displayValue = value.wrappedValue
    }
}

struct ReadingSearchExitButton: View {
    @Environment(\.dismissSearch) private var dismissSearch
    let action: () -> Void

    var body: some View {
        Button("定位当前章节", systemImage: "location") {
            dismissSearch()
            action()
        }
    }
}

struct ReadingSliderRow: View {
    let preview: ReadingSliderPreview
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onValueChanged: (Double) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            Text(preview.title)
                .font(.subheadline)
                .frame(minWidth: 42, alignment: .leading)
            ReadingSliderControl(preview: preview, onEditingChanged: onEditingChanged, onValueChanged: onValueChanged)
                .frame(maxWidth: .infinity, minHeight: 44)
            Text(preview.format(preview.displayValue))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }
}

private struct ReadingSliderControl: UIViewRepresentable {
    let preview: ReadingSliderPreview
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.change(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(preview.range.lowerBound)
        slider.maximumValue = Float(preview.range.upperBound)
        if !slider.isTracking { slider.value = Float(preview.displayValue) }
        slider.accessibilityIdentifier = preview.id
        slider.accessibilityLabel = preview.id
        slider.accessibilityValue = preview.format(preview.displayValue)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ReadingSliderControl
        private var editing = false

        init(parent: ReadingSliderControl) { self.parent = parent }

        @objc func begin(_ slider: UISlider) {
            guard !editing else { return }
            editing = true
            parent.onEditingChanged(true)
        }

        @objc func change(_ slider: UISlider) {
            let preview = parent.preview
            var value = Double(slider.value)
            if let step = preview.step, step > 0 {
                value = preview.range.lowerBound + ((value - preview.range.lowerBound) / step).rounded() * step
            }
            value = min(max(value, preview.range.lowerBound), preview.range.upperBound)
            preview.value.wrappedValue = value
            slider.value = Float(value)
            slider.accessibilityValue = preview.format(value)
            parent.onValueChanged(value)
        }

        @objc func end(_ slider: UISlider) {
            change(slider)
            guard editing else { return }
            editing = false
            parent.onEditingChanged(false)
        }
    }
}

struct ReadingPreviewSlider: View {
    let title: String
    let id: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    @Binding var activeSlider: ReadingSliderPreview?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let preview = ReadingSliderPreview(id: id, title: title, value: value, range: range, step: step, format: format)
        ReadingSliderRow(preview: preview, onEditingChanged: { editing in
            if editing {
                activeSlider = preview
            } else if activeSlider?.id == id {
                activeSlider = nil
            }
            onEditingChanged(editing)
        }, onValueChanged: { newValue in
            guard var active = activeSlider, active.id == id else { return }
            active.displayValue = newValue
            activeSlider = active
        })
        .anchorPreference(key: ReadingSliderAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

struct ReadingSliderPreviewLayer: ViewModifier {
    let preview: ReadingSliderPreview?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ReadingSliderAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let preview, let anchor = anchors[preview.id] {
                    let rect = geometry[anchor]
                    ReadingSliderRow(preview: preview)
                        .background {
                            RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)).padding(-10)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

struct ReadingPreviewPanel<Content: View>: View {
    @Binding var activeSlider: ReadingSliderPreview?
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = max(geometry.size.height * 0.55, 280)
            ZStack(alignment: .bottom) {
                Color.black.opacity(activeSlider == nil ? 0.18 : 0)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)
                    Color.clear.frame(height: panelHeight).allowsHitTesting(false)
                }
                content()
                    .frame(height: panelHeight)
                    .clipShape(ReadingPanelOutline())
                    .background(alignment: .top) {
                        ReadingPanelOutline()
                            .fill(Color(uiColor: .systemGroupedBackground))
                            .padding(.bottom, -geometry.safeAreaInsets.bottom)
                    }
                    // UIKit stops hit testing below 0.01, which can cancel the
                    // slider before it delivers its end-of-drag callback.
                    .opacity(activeSlider == nil ? 1 : 0.02)
            }
            .modifier(ReadingSliderPreviewLayer(preview: activeSlider))
        }
    }
}

private struct ReadingPanelOutline: Shape {
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: 20, height: 20)).cgPath)
    }
}

private struct ReadingSliderAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
