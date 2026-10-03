import Foundation

/// URL の正規化を行う。
///
/// 同じページを指す URL は表記ゆれがあっても1つにまとめないと、
/// 同じページを何度も取得したり、検索結果に重複して表示されたりしてしまう。
/// 例えば次の URL はすべて同じページとして扱う。
///
/// - `HTTPS://IROIRO.DEV/`
/// - `https://iroiro.dev:443/`
/// - `https://iroiro.dev/#section`
/// - `https://iroiro.dev/a/../`
/// - `https://iroiro.dev/?utm_source=x`
enum URLNormalizer {
    /// 解析用の除外パラメータ（ページ内容に影響しないトラッキング用クエリ）
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src",
    ]

    /// HTML ではないと判断できる拡張子。取得する前に除外して無駄な通信を減らす
    private static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "avif",
        "pdf", "zip", "gz", "tar", "dmg", "pkg", "ipa", "exe",
        "mp3", "mp4", "mov", "m4a", "wav", "webm",
        "css", "js", "json", "xml", "rss", "atom", "txt",
        "woff", "woff2", "ttf", "otf",
    ]

    /// 相対 URL を `base` を基準に解決し、正規化した URL を返す。
    /// http / https 以外（mailto: や javascript: など）は nil を返す。
    static func normalize(_ string: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        return normalize(resolved)
    }

    /// 絶対 URL を正規化する
    static func normalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        components.scheme = scheme
        components.host = host
        // 認証情報付きの URL は扱わない
        components.user = nil
        components.password = nil
        // フラグメント（#以降）はサーバーに送られないので削除
        components.fragment = nil
        // デフォルトポートは省略
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        // パスの "." / ".." を解決し、空のパスは "/" にする
        components.percentEncodedPath = removeDotSegments(components.percentEncodedPath)
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        // トラッキング用のクエリを削除し、残りを名前順に並べ替える
        if let items = components.queryItems {
            let filtered = items
                .filter { item in
                    let name = item.name.lowercased()
                    return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
                }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.url
    }

    /// URL のオリジン（スキーム + ホスト + ポート）。robots.txt とホストごとの管理の単位になる
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    /// `host` が `domain` そのものか、そのサブドメインか（例: `blog.example.com` は `example.com` に含まれる）
    static func host(_ host: String, isWithin domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// 拡張子から HTML ではないと判断できる URL かどうか
    static func isLikelyNonHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && skippedExtensions.contains(ext)
    }

    /// RFC 3986 5.2.4 の remove_dot_segments
    static func removeDotSegments(_ path: String) -> String {
        guard path.contains(".") else { return path }
        var output: [Substring] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            switch segment {
            case ".":
                if index == segments.count - 1 { output.append("") }
            case "..":
                if output.count > 1 { output.removeLast() }
                if index == segments.count - 1 { output.append("") }
            default:
                output.append(segment)
            }
        }
        let joined = output.joined(separator: "/")
        if path.hasPrefix("/") && !joined.hasPrefix("/") {
            return "/" + joined
        }
        return joined
    }
}
