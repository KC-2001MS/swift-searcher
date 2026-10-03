import Foundation

/// フロンティアに入れる URL 1件
struct FrontierEntry: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// 通常のページ
        case page
        /// サイトマップ（中の URL をフロンティアに追加する）
        case sitemap
    }

    var url: String
    /// シードからのリンクの深さ
    var depth: Int
    /// 一時的なエラーで再試行した回数
    var retries: Int = 0
    var kind: Kind = .page

    /// 優先度（小さいほど先に取り出す）。
    ///
    /// 浅いページ（トップページに近いページ）ほど重要なことが多いので先に取り出す。
    /// 再試行のときは少し後回しにする。
    var priority: Double {
        // サイトマップは多くの URL を一度に教えてくれるので最優先にする
        if kind == .sitemap { return -1 }
        return Double(depth) + Double(retries) * 2
    }
}

/// フロンティアから取り出した URL と、そのホストの貸し出し（リース）
struct FrontierLease: Sendable, Equatable {
    var origin: String
    var entry: FrontierEntry
}

/// フロンティアの状態
struct FrontierStats: Codable, Sendable, Equatable {
    /// URL が待っているホストの数
    var hosts: Int
    /// 今すぐ取り出せるホストの数
    var readyHosts: Int
    /// 待っている URL の総数（概算）
    var queuedURLs: Int
}

/// フロンティア（未訪問 URL の待ち行列）。
///
/// 大規模なクローラーでは、フロンティアは「ホストごとの待ち行列」と
/// 「次にアクセスしてよい時刻順のホストの一覧」の2段構成にする（Mercator 方式）。
///
/// ```text
///   ready（ホスト → 次にアクセスしてよい時刻）       ホストごとの待ち行列（優先度順）
///   ┌───────────────────────────┐            ┌──────────────────────────┐
///   │ https://a.example  10:00:01 │ ─────────▶ │ / (0)  /about (1)  ...    │
///   │ https://b.example  10:00:03 │ ─────────▶ │ /blog (1)  /blog/x (2) ... │
///   └───────────────────────────┘            └──────────────────────────┘
/// ```
///
/// - ワーカーは「時刻が来ているホスト」を1つ借りて、その待ち行列から優先度の高い URL を1件取り出す
/// - 借りている間は他のワーカーはそのホストにアクセスしない（同じサーバーへの同時アクセスを防ぐ）
/// - 取得が終わったら、Crawl-delay 後の時刻を付けてホストを返す
/// - ワーカーが落ちても、リースの期限が切れれば自動で他のワーカーが使えるようになる
protocol Frontier: Sendable {
    /// URL を追加する。すでに追加したことのある URL は（force でなければ）無視する。
    /// 追加できたら true を返す
    @discardableResult
    func enqueue(_ entry: FrontierEntry, origin: String, force: Bool) async throws -> Bool

    /// 今すぐアクセスしてよいホストを1つ借り、その URL を1件取り出す。無ければ nil
    func claim(now: Date, lease: Duration) async throws -> FrontierLease?

    /// ホストを返す。次にアクセスしてよい時刻を `nextAllowedAt` にする
    func release(origin: String, nextAllowedAt: Date) async throws

    func stats(now: Date) async throws -> FrontierStats
}

extension Frontier {
    @discardableResult
    func enqueue(_ entry: FrontierEntry, origin: String) async throws -> Bool {
        try await enqueue(entry, origin: origin, force: false)
    }
}

/// メモリ上のフロンティア（テストと、Redis を使わない開発用）
actor InMemoryFrontier: Frontier {
    private var seen = Set<String>()
    private var queues: [String: [FrontierEntry]] = [:]
    /// ホスト → 次にアクセスしてよい時刻
    private var ready: [String: Date] = [:]
    let maxQueuePerHost: Int

    init(maxQueuePerHost: Int = .max) {
        self.maxQueuePerHost = maxQueuePerHost
    }

    func enqueue(_ entry: FrontierEntry, origin: String, force: Bool) -> Bool {
        var queue = queues[origin, default: []]
        // 待ち行列が一杯のときは「追加済み」にしない（後で空いたら追加できるように）
        guard queue.count < maxQueuePerHost else { return false }
        if !force {
            guard seen.insert(entry.url).inserted else { return false }
        }
        if queue.contains(where: { $0.url == entry.url }) { return false }
        queue.append(entry)
        queues[origin] = queue
        if ready[origin] == nil { ready[origin] = .distantPast }
        return true
    }

    func claim(now: Date, lease: Duration) -> FrontierLease? {
        // 時刻が来ているホストのうち、最も早く待っているものを選ぶ
        guard let origin = ready.filter({ $0.value <= now }).min(by: { $0.value < $1.value })?.key else {
            return nil
        }
        guard var queue = queues[origin], !queue.isEmpty else {
            ready[origin] = nil
            queues[origin] = nil
            return nil
        }
        // 優先度が最も高い（値が小さい）もの。同じなら先に入れたもの
        let index = queue.indices.min { queue[$0].priority < queue[$1].priority }!
        let entry = queue.remove(at: index)
        queues[origin] = queue
        ready[origin] = now.addingTimeInterval(lease.timeInterval)
        return FrontierLease(origin: origin, entry: entry)
    }

    func release(origin: String, nextAllowedAt: Date) {
        if let queue = queues[origin], !queue.isEmpty {
            ready[origin] = nextAllowedAt
        } else {
            ready[origin] = nil
            queues[origin] = nil
        }
    }

    func stats(now: Date) -> FrontierStats {
        FrontierStats(
            hosts: ready.count,
            readyHosts: ready.values.filter { $0 <= now }.count,
            queuedURLs: queues.values.reduce(0) { $0 + $1.count }
        )
    }
}
