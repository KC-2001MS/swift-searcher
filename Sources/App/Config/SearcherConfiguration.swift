import Foundation
import Vapor

/// このプロセスが担当する役割。
///
/// 大規模な検索エンジンは「巡回する」「インデックスを持つ」「検索を受け付ける」といった役割ごとに
/// 別々のサーバー群で動かす。このプロジェクトでも同じ実行ファイルを `APP_ROLE` で切り替えて、
/// 役割ごとに必要な台数だけ起動できるようにしている。
///
/// ```text
///  api        検索 API（ブローカー）。各シャードに問い合わせて結果をまとめ、最終的な順位を決める
///  shard      インデックスシャード。担当するページだけの転置インデックスをメモリに持つ
///  worker     クロールワーカー。分散フロンティアから URL を取り出して取得・解析・保存する
///  scheduler  再訪問スケジューラー。再取得の時期が来たページやシードをフロンティアに入れる
///  all        開発用。上のすべてを1つのプロセスで動かす
/// ```
enum AppRole: String, Sendable, CaseIterable {
    case api
    case shard
    case worker
    case scheduler
    case all

    var runsAPI: Bool { self == .api || self == .all }
    var runsShard: Bool { self == .shard || self == .all }
    var runsWorker: Bool { self == .worker || self == .all }
    var runsScheduler: Bool { self == .scheduler || self == .all }
}

/// クローラーの設定
struct CrawlerSettings: Sendable {
    /// 巡回範囲
    enum Scope: String, Sendable {
        /// シードと同じホストだけ
        case seedHosts = "seed-hosts"
        /// `allowedHosts` に列挙したホスト（とそのサブドメイン）だけ
        case allowlist
        /// Web 全体（外部リンクもたどる）
        case web
    }

    var scope: Scope
    /// scope が allowlist のときに巡回してよいホスト（サブドメインを含む）
    var allowedHosts: Set<String>
    /// 巡回しないホスト（サブドメインを含む）
    var blockedHosts: Set<String>
    /// シードからたどる最大の深さ
    var maxDepth: Int
    /// 1つのホストから取得する最大ページ数（1つの巨大サイトに巡回を独占されないようにする）
    var maxPagesPerHost: Int
    /// 1つのホストのフロンティアに溜めておける最大 URL 数
    var maxQueuePerHost: Int
    /// 同じホストへのリクエスト間隔の最小値（robots.txt の Crawl-delay の方が長ければそちらを使う）
    var minHostDelay: Duration
    /// Crawl-delay の上限（極端に長い値で巡回が止まらないようにする）
    var maxHostDelay: Duration
    /// 1つのワーカープロセスで同時に処理する URL 数
    var workerConcurrency: Int
    /// フロンティアから取り出したホストを他のワーカーに渡さない時間（ワーカーが落ちても自動で解放される）
    var hostLease: Duration
    var userAgent: String
    /// robots.txt のグループ照合に使うトークン（User-Agent の製品名部分）
    var robotsToken: String
    /// robots.txt をキャッシュする時間
    var robotsTTL: Duration
    /// 1ページあたりの最大サイズ（バイト）
    var maxBodyBytes: Int
    /// 一時的なエラーで再試行する最大回数
    var maxRetries: Int
    /// 再訪問の間隔の初期値・最小値・最大値
    var revisitInitial: Duration
    var revisitMin: Duration
    var revisitMax: Duration
    /// URL 重複除去用のブルームフィルターのビット数（Redis の文字列は最大 2^32 ビット）
    var bloomBits: Int
    /// ブルームフィルターのハッシュ関数の数
    var bloomHashes: Int
    /// SimHash のハミング距離がこれ以下なら「ほぼ同じ内容」とみなす
    var nearDuplicateDistance: Int

    static let `default` = CrawlerSettings(
        scope: .seedHosts,
        allowedHosts: [],
        blockedHosts: [],
        maxDepth: 16,
        maxPagesPerHost: 50_000,
        maxQueuePerHost: 100_000,
        minHostDelay: .milliseconds(1000),
        maxHostDelay: .seconds(30),
        workerConcurrency: 32,
        hostLease: .seconds(60),
        userAgent: "SwiftSearcher/1.0 (+https://github.com/KC-2001MS/swift-searcher)",
        robotsToken: "SwiftSearcher",
        robotsTTL: .seconds(24 * 60 * 60),
        maxBodyBytes: 4 * 1024 * 1024,
        maxRetries: 3,
        revisitInitial: .seconds(7 * 24 * 60 * 60),
        revisitMin: .seconds(24 * 60 * 60),
        revisitMax: .seconds(90 * 24 * 60 * 60),
        bloomBits: 1 << 30,
        bloomHashes: 7,
        nearDuplicateDistance: 3
    )
}

/// インデックスシャードの設定
struct IndexSettings: Sendable {
    /// シャードの数
    var shardCount: Int
    /// このプロセスが担当するシャード番号（role が shard のとき）
    var shardID: Int
    /// 変更されたページを取り込む間隔
    var refreshInterval: Duration
    /// セグメントがこの数を超えたら1つにまとめ直す（マージ）
    var maxSegments: Int
    /// 1シャードが返す候補の最大数
    var candidatesPerShard: Int

    static let `default` = IndexSettings(
        shardCount: 2,
        shardID: 0,
        refreshInterval: .seconds(60),
        maxSegments: 8,
        candidatesPerShard: 200
    )
}

/// 検索 API（ブローカー）の設定
struct SearchSettings: Sendable {
    /// シャードごとのレプリカの URL。nil ならシャードを同じプロセス内で動かす
    var shardEndpoints: [[String]]?
    /// シャードへの問い合わせのタイムアウト
    var shardTimeout: Duration
    /// 同じホストのページを検索結果の1ページに何件まで出すか（ホストの偏りを防ぐ）
    var maxResultsPerHost: Int
    /// 検索結果のキャッシュ時間。0 でキャッシュしない
    var cacheTTL: Duration
    /// ランキングモデルを読み込み直す間隔
    var modelReloadInterval: Duration
    /// 検索ログ（表示・クリック）を記録するか
    var logQueries: Bool

    static let `default` = SearchSettings(
        shardEndpoints: nil,
        shardTimeout: .milliseconds(800),
        maxResultsPerHost: 2,
        cacheTTL: .seconds(300),
        modelReloadInterval: .seconds(600),
        logQueries: true
    )
}

/// アプリ全体の設定。すべて環境変数から上書きできる
struct SearcherConfiguration: Sendable {
    var role: AppRole
    /// 最初に巡回する URL
    var seeds: [URL]
    var crawler: CrawlerSettings
    var index: IndexSettings
    var search: SearchSettings
    /// 管理用エンドポイント・内部エンドポイントのトークン。nil ならそれらを無効にする
    var adminToken: String?

    static let `default` = SearcherConfiguration(
        role: .all,
        seeds: [URL(string: "https://iroiro.dev/")!],
        crawler: .default,
        index: .default,
        search: .default,
        adminToken: nil
    )

    static func fromEnvironment(_ environment: Environment) -> SearcherConfiguration {
        var config = SearcherConfiguration.default

        if let value = Environment.get("APP_ROLE"), let role = AppRole(rawValue: value.lowercased()) {
            config.role = role
        }
        if let value = Environment.get("SEARCHER_SEEDS") {
            let seeds = value.split(separator: ",").compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            if !seeds.isEmpty { config.seeds = seeds }
        }
        if let value = Environment.get("SEARCHER_ADMIN_TOKEN"), !value.isEmpty {
            config.adminToken = value
        }

        // MARK: クローラー
        var crawler = config.crawler
        if let value = Environment.get("CRAWLER_SCOPE"), let scope = CrawlerSettings.Scope(rawValue: value.lowercased()) {
            crawler.scope = scope
        }
        crawler.allowedHosts = hostSet("CRAWLER_ALLOWED_HOSTS") ?? crawler.allowedHosts
        crawler.blockedHosts = hostSet("CRAWLER_BLOCKED_HOSTS") ?? crawler.blockedHosts
        crawler.maxDepth = int("CRAWLER_MAX_DEPTH", min: 0) ?? crawler.maxDepth
        crawler.maxPagesPerHost = int("CRAWLER_MAX_PAGES_PER_HOST", min: 1) ?? crawler.maxPagesPerHost
        crawler.maxQueuePerHost = int("CRAWLER_MAX_QUEUE_PER_HOST", min: 1) ?? crawler.maxQueuePerHost
        if let ms = int("CRAWLER_MIN_HOST_DELAY_MS", min: 0) { crawler.minHostDelay = .milliseconds(ms) }
        crawler.workerConcurrency = int("CRAWLER_WORKER_CONCURRENCY", min: 1) ?? crawler.workerConcurrency
        if let value = Environment.get("CRAWLER_USER_AGENT"), !value.isEmpty {
            crawler.userAgent = value
            crawler.robotsToken = String(value.prefix { $0 != "/" && $0 != " " })
        }
        if let days = Environment.get("CRAWLER_REVISIT_MAX_DAYS").flatMap(Double.init), days > 0 {
            crawler.revisitMax = .seconds(days * 24 * 60 * 60)
        }
        if let bits = int("CRAWLER_BLOOM_BITS", min: 1024) {
            crawler.bloomBits = min(bits, 1 << 32)
        }
        config.crawler = crawler

        // MARK: インデックス
        var index = config.index
        index.shardCount = int("INDEX_SHARD_COUNT", min: 1) ?? index.shardCount
        index.shardID = int("INDEX_SHARD_ID", min: 0) ?? index.shardID
        if let seconds = int("INDEX_REFRESH_SECONDS", min: 1) { index.refreshInterval = .seconds(seconds) }
        index.maxSegments = int("INDEX_MAX_SEGMENTS", min: 1) ?? index.maxSegments
        index.candidatesPerShard = int("INDEX_CANDIDATES_PER_SHARD", min: 10) ?? index.candidatesPerShard
        config.index = index

        // MARK: 検索 API
        var search = config.search
        // 例: "http://shard0-a:8080,http://shard0-b:8080;http://shard1-a:8080"
        //     （; でシャードを、, で同じシャードのレプリカを区切る）
        if let value = Environment.get("SEARCH_SHARDS"), !value.isEmpty {
            let shards = value.split(separator: ";").map { shard in
                shard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            search.shardEndpoints = shards
            config.index.shardCount = shards.count
        }
        if let ms = int("SEARCH_SHARD_TIMEOUT_MS", min: 1) { search.shardTimeout = .milliseconds(ms) }
        search.maxResultsPerHost = int("SEARCH_MAX_RESULTS_PER_HOST", min: 1) ?? search.maxResultsPerHost
        if let seconds = int("SEARCH_CACHE_SECONDS", min: 0) { search.cacheTTL = .seconds(seconds) }
        if let value = Environment.get("SEARCH_LOG_QUERIES") {
            search.logQueries = ["1", "true", "yes"].contains(value.lowercased())
        }
        config.search = search

        if environment == .testing {
            config.search.cacheTTL = .zero
        }
        return config
    }

    private static func int(_ key: String, min: Int) -> Int? {
        guard let value = Environment.get(key).flatMap(Int.init), value >= min else { return nil }
        return value
    }

    private static func hostSet(_ key: String) -> Set<String>? {
        guard let value = Environment.get(key) else { return nil }
        let hosts = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(hosts)
    }
}

extension Application {
    private struct SearcherConfigurationKey: StorageKey {
        typealias Value = SearcherConfiguration
    }

    /// アプリ全体で共有する設定
    var searcherConfiguration: SearcherConfiguration {
        get { storage[SearcherConfigurationKey.self] ?? .default }
        set { storage[SearcherConfigurationKey.self] = newValue }
    }
}

extension Duration {
    /// ミリ秒（Redis のスコアなどに使う）
    var milliseconds: Int64 {
        let c = components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
