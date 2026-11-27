import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum ReadingCompatibility {
    static var usesLegacyUI: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiLegacyCompatibility")
        #else
        false
        #endif
    }
}

struct ReadingNavigationStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            NavigationStack { content }
        } else {
            NavigationView { content }.navigationViewStyle(.stack)
        }
    }
}

struct ReadingLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            LabeledContent(title) { content }
        } else {
            HStack {
                Text(title)
                Spacer()
                content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}

extension ReadingLabeledContent where Content == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value) }
    }
}

struct ReadingTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis) {
        self.title = title
        _text = text
        self.axis = axis
    }

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            TextField(title, text: $text, axis: axis)
        } else if axis == .vertical {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 80).accessibilityLabel(title)
            }
        } else {
            TextField(title, text: $text)
        }
    }
}

struct ReadingShareLink<Label: View>: View {
    private let items: [Any]
    private let label: Label

    init(item: String, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    init(item: URL, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    var body: some View {
        Button { presentShareSheet() } label: { label }
    }

    private func presentShareSheet() {
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIActivityViewController) else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}

extension ReadingShareLink where Label == SwiftUI.Label<Text, Image> {
    init(item: URL) {
        self.init(item: item) { SwiftUI.Label("分享", systemImage: "square.and.arrow.up") }
    }
}

struct ReadingPhotoPicker<Label: View>: View {
    let onData: (Data) -> Void
    let onError: (Error) -> Void
    @ViewBuilder var label: Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label }
            .readingPhotoPicker(isPresented: $isPresented, onData: onData, onError: onError)
    }
}

private struct ReadingPhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onData: (Data) -> Void
    let onError: (Error) -> Void
    @State private var pendingResult: Result<Data, Error>?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            let result = pendingResult
            pendingResult = nil
            switch result {
            case .success(let data): onData(data)
            case .failure(let error): onError(error)
            case nil: break
            }
        }) {
            ReadingPhotoPickerController { result in
                // Apply changes after the picker finishes dismissing, so a
                // Form update cannot remove its presenter mid-transition.
                pendingResult = result
                isPresented = false
            }
        }
    }
}

struct ReadingPhotoPickerController: UIViewControllerRepresentable {
    let onResult: @MainActor (Result<Data, Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: @MainActor (Result<Data, Error>?) -> Void

        init(onResult: @escaping @MainActor (Result<Data, Error>?) -> Void) {
            self.onResult = onResult
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { onResult(nil); return }
            loadImage(from: provider)
        }

        func loadImage(from provider: NSItemProvider) {
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
            provider.loadDataRepresentation(forTypeIdentifier: identifier, completionHandler: didLoadImageData)
        }

        // Photos calls back on NSItemProvider-callback-queue. A method reference
        // preserves explicit nonisolation in optimized device builds, whereas a
        // closure here can infer MainActor and assert before reaching the Task.
        nonisolated private func didLoadImageData(_ data: Data?, _ error: (any Error)?) {
            let result: Result<Data, Error>
            if let data { result = .success(data) }
            else { result = .failure(error ?? CocoaError(.fileReadCorruptFile)) }
            Task { @MainActor [weak self] in
                self?.onResult(result)
            }
        }
    }
}

private struct ReadingLocalBookFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onFiles: ([LocalBookImportFile]) -> Void
    let onError: (Error) -> Void
    @State private var pickedFiles: [LocalBookImportFile] = []
    @State private var pickerHasDismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            pickerHasDismissed = true
            deliverFilesWhenReady()
        }) {
            let epub = UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
            ReadingImportPicker(contentTypes: [.plainText, epub], allowsMultipleSelection: true) { urls in
                pickedFiles = urls.map { LocalBookImportFile(url: $0) }
                isPresented = false
                deliverFilesWhenReady()
            } onCancel: {
                pickedFiles = []
                isPresented = false
            }
            .onAppear {
                pickedFiles = []
                pickerHasDismissed = false
            }
        }
    }

    private func deliverFilesWhenReady() {
        // Providers may return their copies before or after dismissing Files.
        guard pickerHasDismissed, !pickedFiles.isEmpty else { return }
        let files = pickedFiles
        pickedFiles = []
        guard files.allSatisfy({ LocalBookService.supports($0.url) && !$0.url.hasDirectoryPath }) else {
            onError(LocalBookError.unsupportedFormat)
            return
        }
        onFiles(files)
    }
}

struct ReadingImportPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: @MainActor ([URL]) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ReadingImportPicker

        init(parent: ReadingImportPicker) { self.parent = parent }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
    }
}

final class SecurityScopedImportURL: @unchecked Sendable {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    var isDirectory: Bool {
        if url.hasDirectoryPath { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func readData() throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            readResult = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw CocoaError(.fileReadUnknown) }
        return try readResult.get()
    }
}

/// Presents `UIDocumentPickerViewController` directly via UIKit from the active
/// topmost view controller, avoiding SwiftUI nested-sheet and detent conflicts.
@MainActor
enum ReadingDocumentPickerPresenter {
    private static var activeSession: Session?

    static func present(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onPick: @escaping @MainActor ([SecurityScopedImportURL]) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        if let existing = activeSession, existing.isActive { return }
        activeSession = nil

        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else {
            onCancel()
            return
        }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        guard !(presenter is UIDocumentPickerViewController) else { return }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true

        let session = Session(picker: picker, onPick: onPick, onCancel: onCancel)
        picker.delegate = session
        picker.presentationController?.delegate = session
        activeSession = session

        let presentNow: @MainActor () -> Void = {
            presenter.present(picker, animated: true) {
                Task { @MainActor in
                    if picker.presentingViewController == nil {
                        clear(session)
                        onCancel()
                    }
                }
            }
        }
        if let dismissing = presenter.presentedViewController, dismissing.isBeingDismissed {
            if let coordinator = dismissing.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in
                    Task { @MainActor in presentNow() }
                }
            } else {
                DispatchQueue.main.async { presentNow() }
            }
        } else {
            presentNow()
        }
    }

    private static func clear(_ session: Session) {
        if activeSession === session { activeSession = nil }
    }

    @MainActor
    private final class Session: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        private weak var picker: UIDocumentPickerViewController?
        private let onPick: @MainActor ([SecurityScopedImportURL]) -> Void
        private let onCancel: @MainActor () -> Void
        private var finished = false

        var isActive: Bool {
            !finished && picker?.presentingViewController != nil
        }

        init(
            picker: UIDocumentPickerViewController,
            onPick: @escaping @MainActor ([SecurityScopedImportURL]) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.picker = picker
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller: controller, files: urls.map(SecurityScopedImportURL.init))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller: controller, files: nil)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(controller: nil, files: nil)
        }

        private func finish(controller: UIDocumentPickerViewController?, files: [SecurityScopedImportURL]?) {
            guard !finished else { return }
            finished = true
            let deliver: @MainActor () -> Void = { [onPick, onCancel] in
                ReadingDocumentPickerPresenter.clear(self)
                if let files, !files.isEmpty {
                    onPick(files)
                } else {
                    onCancel()
                }
            }
            guard let controller else {
                deliver()
                return
            }
            if controller.isBeingDismissed {
                if let coordinator = controller.transitionCoordinator {
                    coordinator.animate(alongsideTransition: nil) { _ in
                        Task { @MainActor in deliver() }
                    }
                } else {
                    DispatchQueue.main.async { deliver() }
                }
            } else if controller.presentingViewController != nil {
                controller.dismiss(animated: true) {
                    Task { @MainActor in deliver() }
                }
            } else {
                deliver()
            }
        }
    }
}

enum ReadingSheetDetent { case medium, large }

extension View {
    func readingLocalBookFileImporter(
        isPresented: Binding<Bool>,
        onFiles: @escaping ([LocalBookImportFile]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> some View {
        modifier(ReadingLocalBookFileImporterModifier(isPresented: isPresented, onFiles: onFiles, onError: onError))
    }

    func readingPhotoPicker(
        isPresented: Binding<Bool>,
        onData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) -> some View {
        modifier(ReadingPhotoPickerModifier(isPresented: isPresented, onData: onData, onError: onError))
    }

    @ViewBuilder
    func readingNumericTransition() -> some View {
        if #available(iOS 16.0, *) { contentTransition(.numericText()) }
        else { self }
    }

    @ViewBuilder
    func readingNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>, @ViewBuilder destination: () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(NavigationLink(isActive: isPresented, destination: destination) { EmptyView() }.hidden())
        }
    }

    @ViewBuilder
    func readingScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            scrollContentBackground(.hidden)
        } else {
            background(ReadingUIKitConfiguration { controller in
                func clearTables(in view: UIView) {
                    if let table = view as? UITableView { table.backgroundColor = .clear }
                    for child in view.subviews { clearTables(in: child) }
                }
                if let parent = controller.parent { clearTables(in: parent.view) }
            })
        }
    }

    @ViewBuilder
    func readingScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            scrollDismissesKeyboard(.immediately)
        } else {
            simultaneousGesture(DragGesture().onChanged { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
        }
    }

    @ViewBuilder
    func readingNavigationBarBackground() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbarBackground(ReadingTheme.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            background(ReadingUIKitConfiguration { controller in
                let appearance = UINavigationBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(ReadingTheme.canvas)
                controller.navigationController?.navigationBar.standardAppearance = appearance
                controller.navigationController?.navigationBar.scrollEdgeAppearance = appearance
            })
        }
    }

    @ViewBuilder
    func readingTabBarBackground() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbarBackground(ReadingTheme.canvas, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
        } else {
            background(ReadingUIKitConfiguration { controller in
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(ReadingTheme.canvas)
                controller.tabBarController?.tabBar.standardAppearance = appearance
                controller.tabBarController?.tabBar.scrollEdgeAppearance = appearance
            })
        }
    }

    @ViewBuilder
    func readingTabBarHidden() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbar(.hidden, for: .tabBar)
        } else {
            background(ReadingHiddenTabBar())
        }
    }

    @ViewBuilder
    func readingHomeIndicatorHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }

    @ViewBuilder
    func readingPresentationDetents(_ detents: [ReadingSheetDetent]) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            presentationDetents(Set(detents.map { $0 == .medium ? PresentationDetent.medium : .large }))
        } else {
            background(ReadingUIKitConfiguration { controller in
                var current: UIViewController? = controller
                while let candidate = current {
                    if let sheet = candidate.presentationController as? UISheetPresentationController {
                        sheet.detents = detents.map { $0 == .medium ? .medium() : .large() }
                        break
                    }
                    current = candidate.parent
                }
            })
        }
    }

    @ViewBuilder
    func readingPresentationDragIndicator() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            presentationDragIndicator(.visible)
        } else {
            background(ReadingUIKitConfiguration { controller in
                var current: UIViewController? = controller
                while let candidate = current {
                    if let sheet = candidate.presentationController as? UISheetPresentationController {
                        if !sheet.prefersGrabberVisible { sheet.prefersGrabberVisible = true }
                        break
                    }
                    current = candidate.parent
                }
            })
        }
    }
}

private struct ReadingUIKitConfiguration: UIViewControllerRepresentable {
    let configure: (UIViewController) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(configure: configure) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.configure = configure }

    final class Controller: UIViewController {
        var configure: (UIViewController) -> Void

        init(configure: @escaping (UIViewController) -> Void) {
            self.configure = configure
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); configure(self) }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); configure(self) }
    }
}

private struct ReadingHiddenTabBar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var hiddenBar: UITabBar?
        private var previouslyHidden = false

        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let bar = tabBarController?.tabBar else { return }
            hiddenBar = bar
            previouslyHidden = bar.isHidden
            bar.isHidden = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hiddenBar?.isHidden = previouslyHidden
        }
    }
}
