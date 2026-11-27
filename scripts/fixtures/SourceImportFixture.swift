import UIKit
import CryptoKit

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

    private func writeBackup(to directory: URL) throws {
        var snapshot: [String: Any] = [:]
        for key in ["sources", "groups", "bookmarks", "records", "rssSources", "rssStars",
                    "txtRules", "tts", "subscriptions", "keyboardAssists", "replaceRules"] {
            snapshot[key] = []
        }
        snapshot["books"] = [["bookUrl": "https://backup.example.test/book", "origin": "fixture", "name": "书库备份测试"]]
        snapshot["chapters"] = [:] as [String: Any]
        snapshot["preferences"] = [:] as [String: Any]
        let manifest: [String: Any] = ["version": 1, "createdAt": 0, "snapshot": snapshot, "attachments": []]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        var data = Data("LGBK0001".utf8)
        var length = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: SHA256.hash(data: json))
        data.append(json)
        try writeFixture(data, to: directory.appendingPathComponent("Reader-Library.legadobackup"))
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? writeBackup(to: documents)
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
        let paragraphs = String(repeating: "潮水退去，灯塔下面露出了通向岸边的小路。\n", count: 60)
        let chapters = ["第一章 雨夜", "第二章 灯塔", "第三章 天明"].map { $0 + "\n" + paragraphs }
        try? writeFixture(Data(chapters.joined(separator: "\n").utf8), to: documents.appendingPathComponent("TXT-Paging.txt"))
        for name in ["EPUB-Book.epub", "Reader-Test.ttf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               let data = try? Data(contentsOf: url) {
                try? writeFixture(data, to: documents.appendingPathComponent(name))
            }
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
