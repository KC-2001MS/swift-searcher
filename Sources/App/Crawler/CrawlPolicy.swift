import Foundation

/// どの URL を巡回してよいかの判定
struct CrawlScope: Sendable {
    let settings: CrawlerSettings
    /// シードのホスト（scope が seed-hosts のときに使う）
    var seedHosts: Set<String>

    func allows(_ url: URL, depth: Int) -> Bool {
        guard depth <= settings.maxDepth else { return false }
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard !URLNormalizer.isLikelyNonHTML(url) else { return false }
        // 長すぎる URL は、カレンダーのように無限に URL を生成するページ（クローラートラップ）であることが多い
        guard url.absoluteString.utf8.count <= 2048 else { return false }
        if settings.blockedHosts.contains(where: { URLNormalizer.host(host, isWithin: $0) }) { return false }
        if Self.looksLikeTrap(url) { return false }

        switch settings.scope {
        case .web:
            return true
        case .seedHosts:
            return seedHosts.contains(host)
        case .allowlist:
            return settings.allowedHosts.contains { URLNormalizer.host(host, isWithin: $0) }
        }
    }

    /// クローラートラップ（無限に URL が作られる構造）らしい URL か。
    ///
    /// 例: `/a/b/a/b/a/b/...` のように同じパスが繰り返される、パスが極端に深い、クエリパラメータが多すぎる
    static func looksLikeTrap(_ url: URL) -> Bool {
        let segments = url.path.split(separator: "/")
        if segments.count > 20 { return true }
        var counts: [Substring: Int] = [:]
        for segment in segments {
            counts[segment, default: 0] += 1
            if counts[segment]! > 3 { return true }
        }
        if let query = url.query, query.split(separator: "&").count > 10 { return true }
        return false
    }
}

/// 再訪問の間隔を決める（適応的な再訪問）。
///
/// すべてのページを同じ頻度で取得し直すと、ほとんど更新されないページに無駄なアクセスが増え、
/// 頻繁に更新されるページの変化は見逃してしまう。そこで、取得し直すたびに
///
/// - 内容が変わっていた → 間隔を半分にする（もっと頻繁に見に来る）
/// - 変わっていなかった → 間隔を 1.5 倍にする（あまり見に来ない）
///
/// として、ページごとの更新頻度に合わせた間隔に近づけていく。
enum RevisitPolicy {
    static func nextInterval(previous: Double?, changed: Bool, settings: CrawlerSettings) -> Double {
        let minimum = settings.revisitMin.timeInterval
        let maximum = settings.revisitMax.timeInterval
        guard let previous, previous > 0 else {
            return min(max(settings.revisitInitial.timeInterval, minimum), maximum)
        }
        let next = changed ? previous / 2 : previous * 1.5
        return min(max(next, minimum), maximum)
    }

    /// 全ページが同じ時刻に再訪問されないよう、±10% のゆらぎを加える
    static func jittered(_ interval: Double) -> Double {
        interval * Double.random(in: 0.9...1.1)
    }
}
