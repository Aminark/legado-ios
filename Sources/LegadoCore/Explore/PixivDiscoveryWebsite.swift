import Foundation

/// Web destinations for the PixivSource rules that reconstruct serialized JavaScript
/// functions and open a browser for authentication. Pixiv manages the account session.
public struct PixivDiscoveryWebsite: Sendable {
    private let novels: Bool

    public init?(source: BookSource) {
        guard let address = URL(string: source.bookSourceUrl), Self.isPixiv(address),
              ["", "/", "/novel", "/manga"].contains(address.path),
              source.bookSourceComment?.contains("github.com/DowneyRem/PixivSource") == true,
              let rules = source.ruleExplore?.bookList,
              rules.contains("isFunctionString("), rules.contains("eval(") else { return nil }
        novels = address.path != "/manga"
    }

    public var publicRanking: URL {
        URL(string: novels ? "https://www.pixiv.net/novel/ranking.php?mode=daily"
                           : "https://www.pixiv.net/ranking.php?mode=daily")!
    }

    public func login(returningTo page: URL? = nil) -> URL {
        let destination = page.flatMap { Self.isPixiv($0) ? $0 : nil } ?? publicRanking
        var account = URLComponents(string: "https://accounts.pixiv.net/login")!
        account.queryItems = [URLQueryItem(name: "return_to", value: destination.absoluteString)]
        return account.url!
    }

    public func destination(for kind: ExploreKind) -> URL? {
        guard let template = kind.navigableURL else { return nil }
        // An account-relative bookmark page lets Pixiv resolve the signed-in
        // user. No account ID or session credential is passed into the rule VM.
        let raw = template.replacingOccurrences(of: #"{{cache.get("pixivUid")}}"#, with: "self")
            .replacingOccurrences(of: "{{page}}", with: "1")
            .replacingOccurrences(of: #"\{\{\(page-1\)\*\d+\}\}"#, with: "0", options: .regularExpression)
        guard let parts = URLComponents(string: raw), let address = parts.url,
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        if parts.host == "pixivsource.pages.dev" || (parts.host == "github.com" && parts.path.hasPrefix("/DowneyRem/PixivSource/")) {
            return address
        }
        if parts.host == "cdn.jsdelivr.net", parts.path == "/gh/DowneyRem/PixivSource@main/pixiv.json" {
            return URL(string: "https://github.com/DowneyRem/PixivSource")
        }
        guard Self.isPixiv(address) else { return nil }
        let query = parts.queryItems ?? []
        let mode = query.first { $0.name == "mode" }?.value
        let adult = mode == "r18" || query.contains(URLQueryItem(name: "r18", value: "true"))
        var page = URLComponents()
        page.scheme = "https"
        page.host = "www.pixiv.net"
        switch parts.path {
        case "/ajax/ranking/novel", "/ranking.php":
            page.path = parts.path == "/ranking.php" ? "/ranking.php" : "/novel/ranking.php"
            page.queryItems = query.filter { ["mode", "p", "content", "date"].contains($0.name) }
        case "/ajax/follow_latest/novel", "/ajax/follow_latest/illust":
            let path = novels ? "/novel/bookmark_new" : "/bookmark_new_illust"
            page.path = path + (adult ? "_r18.php" : ".php")
        case "/ajax/top/novel", "/ajax/top/illust", "/ajax/street/for_you":
            page.path = novels ? (adult ? "/novel/cate_r18.php" : "/novel") : "/"
        case "/ajax/novel/discovery", "/ajax/illust/discovery":
            page.path = novels ? "/novel/discovery" : "/discovery"
            page.queryItems = query.filter { $0.name == "mode" }
        case "/ajax/novel/new", "/ajax/illust/new":
            let path = novels ? "/novel/new" : "/new_illust"
            page.path = path + (adult ? "_r18.php" : ".php")
        case "/ajax/watch_list/novel", "/ajax/watch_list/manga":
            page.path = novels ? "/following/watchlist/novels" : "/following/watchlist/manga"
        case "/ajax/user/self/novels/bookmarks", "/ajax/user/self/illusts/bookmarks":
            page.path = novels ? "/novel/bookmark.php" : "/bookmark.php"
            page.queryItems = query.filter { $0.name == "rest" || $0.name == "tag" }
        case "/ajax/user_event/portal/novels", "/ajax/user_event/portal/artworks":
            page.path = novels ? "/novel/event/" : "/user_event.php"
        case "/ajax/commission/page/request/complete/novels", "/ajax/commission/page/request/complete/manga":
            page.path = novels ? "/request/complete/novels" : "/request/complete/manga"
        case "/ajax/novel/editors_picks":
            page.path = "/novel/editors_picks"
        case "", "/", "/novel/marker_all.php":
            return address
        default:
            let segments = parts.path.split(separator: "/")
            if segments.starts(with: ["ajax", "genre", "novel"]), segments.count == 4 {
                page.path = "/genre/novel/" + segments[3]
                page.queryItems = query.filter { $0.name == "mode" }
            } else if segments.starts(with: ["ajax", "search", "novels"]), segments.count == 4 {
                page.path = "/tags/" + segments[3] + "/novels"
                page.queryItems = query.filter { ["mode", "order", "s_mode"].contains($0.name) }
            } else if segments.starts(with: ["ajax", "user"]), segments.count == 5,
                      UInt64(segments[2]) != nil {
                if segments.suffix(2) == ["profile", "all"] {
                    page.path = "/users/\(segments[2])/novels"
                } else if segments.suffix(2) == ["novels", "bookmarks"] {
                    page.path = "/users/\(segments[2])/bookmarks/novels"
                    page.queryItems = query.filter { $0.name == "rest" || $0.name == "tag" }
                } else { return nil }
            } else { return nil }
        }
        return page.url
    }

    private static func isPixiv(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.pixiv.net"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}
