import UIKit

// Standalone simulator-only file provider; never bundled with Legado.
@main
@MainActor
final class FixtureAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private func writeFixture(_ data: Data, to url: URL) throws {
        // Keep fixture file identities stable. Atomic replacement can leave
        // iOS 26's simulator Files provider with unresolvable document IDs.
        guard (try? Data(contentsOf: url)) != data else { return }
        try data.write(to: url)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtures = [
            ("JSON-Source.json", "https://file-import.test/json", "文件导入 JSON 测试"),
            ("JSON-Uppercase.JSON", "https://file-import.test/uppercase", "文件导入大写扩展名测试"),
            ("JSON-Text.txt", "https://file-import.test/text", "文件导入文本扩展名测试")
        ]
        for (name, url, title) in fixtures {
            let source = [["bookSourceUrl": url, "bookSourceName": title]]
            if let data = try? JSONSerialization.data(withJSONObject: source) {
                try? writeFixture(data, to: documents.appendingPathComponent(name))
            }
        }
        for name in ["TXT-Book.txt", "TXT-Uppercase.TXT"] {
            try? writeFixture(Data("第一章 开始\n这是用于验证本地 TXT 导入的小说正文。\n第二章 后续\n正文继续。".utf8),
                              to: documents.appendingPathComponent(name))
        }
        if let epub = Bundle.main.url(forResource: "EPUB-Book", withExtension: "epub"),
           let data = try? Data(contentsOf: epub) {
            try? writeFixture(data, to: documents.appendingPathComponent("EPUB-Book.epub"))
        }
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "书源导入测试文件已准备好"
        label.frame = CGRect(x: 20, y: 100, width: 350, height: 80)
        controller.view.addSubview(label)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        return true
    }
}
