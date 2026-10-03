import Foundation

/// robots.txt の解析と判定（RFC 9309 準拠の簡易実装）。
///
/// robots.txt はサイト運営者が「クローラーにアクセスしてほしくない場所」を伝えるためのファイル。
/// 礼儀正しいクローラーは、ページを取得する前に必ずこれを確認する。
///
/// ```text
/// User-agent: *
/// Disallow: /private/
/// Allow: /private/public.html
/// Crawl-delay: 2
/// Sitemap: https://example.com/sitemap.xml
/// ```
struct RobotsTxt: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        var allow: Bool
        var pattern: String
    }

    /// 自分（User-Agent）に適用されるルール
    var rules: [Rule]
    /// 自分に適用される Crawl-delay（秒）。RFC 9309 には無い拡張だが広く使われている
    var crawlDelay: Double?
    /// robots.txt に記載されたサイトマップの URL
    var sitemaps: [String]

    /// すべて許可する robots.txt（robots.txt が存在しない場合など）
    static let allowAll = RobotsTxt(rules: [], crawlDelay: nil, sitemaps: [])
    /// すべて禁止する robots.txt（サーバーエラーで robots.txt が読めない場合など）
    static let disallowAll = RobotsTxt(rules: [Rule(allow: false, pattern: "/")], crawlDelay: nil, sitemaps: [])

    /// robots.txt の本文を解析し、`userAgent` に適用されるルールを取り出す
    init(parsing text: String, userAgent: String) {
        struct Group {
            var agents: [String] = []
            var rules: [Rule] = []
            var crawlDelay: Double?
        }

        var groups: [Group] = []
        var current: Group?
        var lastLineWasAgent = false
        var sitemaps: [String] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // コメントを除去
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                // User-agent 行が連続している間は同じグループ
                if !lastLineWasAgent {
                    if let group = current { groups.append(group) }
                    current = Group()
                }
                current?.agents.append(value.lowercased())
                lastLineWasAgent = true
            case "allow", "disallow":
                lastLineWasAgent = false
                // 空の Disallow は「すべて許可」を意味するのでルールとしては無視してよい
                guard !value.isEmpty else { continue }
                current?.rules.append(Rule(allow: key == "allow", pattern: value))
            case "crawl-delay":
                lastLineWasAgent = false
                current?.crawlDelay = Double(value)
            case "sitemap":
                // Sitemap はグループに属さない
                if !value.isEmpty { sitemaps.append(value) }
            default:
                lastLineWasAgent = false
            }
        }
        if let group = current { groups.append(group) }

        // 自分の名前に一致するグループを優先し、無ければ "*" のグループを使う。
        // 同じ名前のグループが複数あればルールを結合する。
        let token = userAgent.lowercased()
        var matched = groups.filter { $0.agents.contains(token) }
        if matched.isEmpty {
            matched = groups.filter { $0.agents.contains("*") }
        }
        self.rules = matched.flatMap(\.rules)
        self.crawlDelay = matched.compactMap(\.crawlDelay).max()
        self.sitemaps = sitemaps
    }

    init(rules: [Rule], crawlDelay: Double?, sitemaps: [String]) {
        self.rules = rules
        self.crawlDelay = crawlDelay
        self.sitemaps = sitemaps
    }

    /// URL へのアクセスが許可されているか
    func isAllowed(_ url: URL) -> Bool {
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let query = url.query(percentEncoded: true) {
            path += "?" + query
        }
        return isAllowed(path: path)
    }

    /// パス（クエリ含む）へのアクセスが許可されているか。
    /// 最も長く一致したルールが優先され、同じ長さなら Allow が優先される。
    ///
    /// 例: `Disallow: /private/` と `Allow: /private/public.html` があるとき、
    /// `/private/public.html` には両方が一致するが、より長い Allow が優先されて許可になる。
    func isAllowed(path: String) -> Bool {
        // robots.txt 自体はいつでも取得してよい
        if path == "/robots.txt" { return true }
        var best: Rule?
        for rule in rules where Self.matches(pattern: rule.pattern, path: path) {
            guard let current = best else {
                best = rule
                continue
            }
            if rule.pattern.count > current.pattern.count
                || (rule.pattern.count == current.pattern.count && rule.allow && !current.allow) {
                best = rule
            }
        }
        // どのルールにも一致しなければ許可
        return best?.allow ?? true
    }

    /// `*`（任意の文字列）と `$`（末尾）に対応したパターン照合
    static func matches(pattern: String, path: String) -> Bool {
        var pattern = Array(pattern)
        let path = Array(path)
        var anchored = false
        if pattern.last == "$" {
            anchored = true
            pattern.removeLast()
        }

        // 動的計画法: reachable[j] = パターンの先頭 i 文字がパスの先頭 j 文字に一致するか。
        // パターンを1文字ずつ読み進めながら、パスのどこまで一致し得るかを更新していく。
        // `*` は「0文字以上の任意の文字列」なので、それまでに一致できた位置以降すべてに進める
        var reachable = [Bool](repeating: false, count: path.count + 1)
        reachable[0] = true
        for p in pattern {
            var next = [Bool](repeating: false, count: path.count + 1)
            if p == "*" {
                var seen = false
                for j in 0...path.count {
                    seen = seen || reachable[j]
                    next[j] = seen
                }
            } else {
                for j in 0..<path.count where reachable[j] && path[j] == p {
                    next[j + 1] = true
                }
            }
            reachable = next
        }
        // アンカー無しなら前方一致でよい
        return anchored ? reachable[path.count] : reachable.contains(true)
    }
}
