import SwiftUI
import UIKit

struct SyntaxCodeEditor: UIViewRepresentable {
    enum Language { case json, rule, javascript, regex }

    // Syntax colors are text, so they need more contrast than system icon tints.
    private enum Palette {
        static let keyword = adaptive(0x7A2BA6, dark: 0xD5A5F5)
        static let number = adaptive(0x895900, dark: 0xE6B66A)
        static let operation = adaptive(0xAD285F, dark: 0xF49AB8)
        static let punctuation = adaptive(0x14666E, dark: 0x83CED8)
        static let string = adaptive(0x2D6B39, dark: 0x8CCF96)
        static let key = adaptive(0x1E5EB2, dark: 0x93BFFF)
        static let comment = adaptive(0x64646B, dark: 0xA4A4AE)

        private static func adaptive(_ light: UInt32, dark: UInt32) -> UIColor {
            UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                               green: CGFloat((hex >> 8) & 0xff) / 255,
                               blue: CGFloat(hex & 0xff) / 255, alpha: 1)
            }
        }
    }
    @Binding var text: String
    var language: Language = .rule

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.tintColor = UIColor(ReadingTheme.accent)
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 20, right: 12)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "syntaxCodeEditor"
        if #available(iOS 16.0, *) { view.isFindInteractionEnabled = true }
        let bar = UIToolbar()
        bar.tintColor = UIColor(ReadingTheme.accent)
        bar.sizeToFit()
        let editingItems: [UIBarButtonItem] = [
            UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction(title: "", subtitle: nil) { [weak view, coordinator = context.coordinator] _ in
                guard let view else { return }
                if #available(iOS 16.0, *) { view.findInteraction?.presentFindNavigator(showingReplace: true) }
                else { coordinator.presentFindAndReplace(in: view) }
            }),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction(title: "", subtitle: nil) { [weak view] _ in view?.undoManager?.undo() }),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction(title: "", subtitle: nil) { [weak view] _ in view?.undoManager?.redo() }),
        ]
        let symbolItems: [UIBarButtonItem] = ["@", "$", "{}", "[]", "##", "\n", "\t"].map { symbol in
            UIBarButtonItem(title: symbol == "\n" ? "↵" : symbol == "\t" ? "⇥" : symbol,
                primaryAction: UIAction(title: "", subtitle: nil) { [weak view] _ in view?.insertText(symbol) })
        }
        let completionItems: [UIBarButtonItem] = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "完成", primaryAction: UIAction(title: "", subtitle: nil) { [weak view] _ in view?.resignFirstResponder() })]
        bar.items = editingItems + symbolItems + completionItems
        bar.items?.last?.accessibilityIdentifier = "syntaxCodeEditor.done"
        if #available(iOS 26.0, *) {
            view.inputAccessoryView = CodeInputAccessory(items: bar.items ?? [])
        } else {
            view.inputAccessoryView = bar
        }
        view.text = text
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        // SwiftUI can render an older binding snapshot while the next native
        // keystroke is already in the text view. Wait for acknowledgement of
        // the latest local edit instead of replacing it with that snapshot.
        if let pending = context.coordinator.pendingLocalText {
            guard text == pending else { return }
            context.coordinator.pendingLocalText = nil
        }
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, view.text.utf16.count), length: 0)
        }
        context.coordinator.highlight(view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyntaxCodeEditor
        private var highlightedText: String?
        private var highlightedStyle: UIUserInterfaceStyle?
        private var highlightedLanguage: Language?
        var pendingLocalText: String?
        init(_ parent: SyntaxCodeEditor) { self.parent = parent }

        func presentFindAndReplace(in view: UITextView) {
            guard var presenter = view.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            let alert = UIAlertController(title: "查找与替换", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "查找内容" }
            alert.addTextField { $0.placeholder = "替换为（可留空）" }
            alert.addAction(UIAlertAction(title: "查找下一个", style: .default) { [weak view, weak alert] _ in
                guard let view, let query = alert?.textFields?.first?.text, !query.isEmpty else { return }
                let text = (view.text ?? "") as NSString
                let start = min(NSMaxRange(view.selectedRange), text.length)
                var range = text.range(of: query, range: NSRange(location: start, length: text.length - start))
                if range.location == NSNotFound { range = text.range(of: query) }
                guard range.location != NSNotFound else { return }
                view.becomeFirstResponder()
                view.selectedRange = range
                view.scrollRangeToVisible(range)
            })
            alert.addAction(UIAlertAction(title: "全部替换", style: .default) { [weak view, weak alert] _ in
                guard let view, let fields = alert?.textFields,
                      let query = fields.first?.text, !query.isEmpty else { return }
                let original = view.text ?? ""
                let replacement = original.replacingOccurrences(of: query, with: fields.last?.text ?? "")
                guard replacement != original else { return }
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: 0, length: original.utf16.count)
                view.insertText(replacement)
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            presenter.present(alert, animated: true)
        }

        func textViewDidChange(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            pendingLocalText = view.text
            parent.text = view.text
            highlight(view)
        }

        func textViewDidEndEditing(_ view: UITextView) {
            pendingLocalText = nil
            parent.text = view.text
            highlight(view)
        }

        func highlight(_ view: UITextView) {
            guard view.markedTextRange == nil,
                  highlightedText != view.text || highlightedStyle != view.traitCollection.userInterfaceStyle || highlightedLanguage != parent.language else { return }
            highlightedText = view.text
            highlightedStyle = view.traitCollection.userInterfaceStyle
            highlightedLanguage = parent.language
            let storage = view.textStorage
            let selection = view.selectedRange
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.label], range: all)
            if storage.length <= 500_000 {
                let tokens: [(String, UIColor)] = [
                    (#"\b(?:true|false|null|undefined|return|var|let|const|if|else|function|new|for|while|try|catch|throw|await|async)\b"#, Palette.keyword),
                    (#"\b\d+(?:\.\d+)?\b"#, Palette.number),
                    (#"@(?:css|xpath|json|js|put|get):?|\$\.|&&|\|\||%%|##|\{\{|\}\}"#, Palette.operation),
                    (#"[{}\[\]()]"#, Palette.punctuation),
                    (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, Palette.string),
                    (#""(?:\\.|[^"\\])*"(?=\s*:)"#, Palette.key),
                ]
                for (pattern, color) in tokens {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    regex.enumerateMatches(in: view.text, range: all) { result, _, _ in
                        if let result { storage.addAttribute(.foregroundColor, value: color, range: result.range) }
                    }
                }
                if parent.language == .regex {
                    for pattern in [#"[.*+?^$|]"#, #"\\[dDsSwWbB0-9]|\{[0-9,]+\}"#] {
                        let regex = try? NSRegularExpression(pattern: pattern)
                        regex?.enumerateMatches(in: view.text, range: all) { result, _, _ in
                            if let result { storage.addAttribute(.foregroundColor, value: Palette.operation, range: result.range) }
                        }
                    }
                }
                if parent.language == .javascript {
                    let pattern = #"(?m)^\s*//.*$|/\*[\s\S]*?\*/"#
                    let regex = try? NSRegularExpression(pattern: pattern)
                    regex?.enumerateMatches(in: view.text, range: all) { result, _, _ in
                        if let result { storage.addAttribute(.foregroundColor, value: Palette.comment, range: result.range) }
                    }
                }
            }
            storage.endEditing()
            view.selectedRange = selection
            view.typingAttributes = [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.label]
        }
    }
}

// Keep Done visible while allowing the editing shortcuts to scroll on narrow keyboards.
private final class CodeInputAccessory: UIInputView {
    init(items: [UIBarButtonItem]) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemGroupedBackground
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let actions = items.filter { $0.primaryAction != nil }
        var done: UIButton?
        for (index, item) in actions.enumerated() {
            let button = UIButton(type: .system)
            if let action = item.primaryAction { button.addAction(action, for: .touchUpInside) }
            button.setImage(item.image, for: .normal)
            button.setTitle(item.title, for: .normal)
            button.tintColor = UIColor(ReadingTheme.accent)
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.accessibilityIdentifier = item.accessibilityIdentifier
            button.accessibilityLabel = item.accessibilityLabel
            button.translatesAutoresizingMaskIntoConstraints = false
            if index == actions.count - 1 {
                button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
                done = button
                addSubview(button)
            } else {
                if index < 3 { button.accessibilityLabel = ["查找与替换", "撤销", "重做"][index] }
                stack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            }
        }
        addSubview(scroll)
        scroll.addSubview(stack)
        guard let done else { return }
        NSLayoutConstraint.activate([
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            done.widthAnchor.constraint(equalToConstant: 60),
            done.topAnchor.constraint(equalTo: topAnchor),
            done.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }
}

struct RuleCodeFieldView: View {
    let title: String
    let path: String
    @Binding var text: String
    var language: SyntaxCodeEditor.Language = .rule
    var help: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            if let help {
                Text(help).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
            }
            SyntaxCodeEditor(text: $text, language: language)
            HStack {
                Text("\(text.components(separatedBy: "\n").count) 行 · \(text.utf16.count) 字符")
                Spacer()
                if language == .rule { Text("CSS · XPath · JSONPath · JS") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
