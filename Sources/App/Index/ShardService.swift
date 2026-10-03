import Fluent
import Foundation
import Vapor

/// インデックスシャードのサービス。
///
/// 全ページをバケット（0〜1023）に分け、`bucket % shardCount == shardID` のページだけを担当する。
/// 担当するページの転置インデックスをメモリに持ち、一定間隔で変更されたページを取り込む。
///
/// - 取り込み（refresh）: `updated_at` が前回より新しいページだけを読み、新しいセグメントにする
/// - まとめ直し（merge）: セグメントが増えすぎたら、データベースから全部読み直して1つにする
///   （このときアンカーテキストや PageRank の変化もまとめて反映される）
///
/// 同じシャードを複数台（レプリカ）で動かせば、1台が止まっても検索を続けられ、負荷も分散できる。
actor ShardService {
    let shardID: Int
    let shardCount: Int
    let database: any Database
    let settings: IndexSettings
    let logger: Logger

    private(set) var index = ShardIndex()
    /// どこまでのページを取り込んだか（ページの `updated_at` の最大値）
    private(set) var watermark: Date?
    private(set) var builtAt: Date?
    private(set) var lastRefreshAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    init(shardID: Int, shardCount: Int, database: any Database, settings: IndexSettings, logger: Logger) {
        self.shardID = shardID
        self.shardCount = shardCount
        self.database = database
        self.settings = settings
        self.logger = logger
    }

    /// このシャードが担当するバケット
    var buckets: [Int] {
        (0..<ShardRouting.bucketCount).filter { ShardRouting.shard(forBucket: $0, shardCount: shardCount) == shardID }
    }

    // MARK: - 構築

    /// データベースから担当するページを全部読み、インデックスを作り直す
    func rebuild() async throws {
        let loader = IndexLoader(database: database, buckets: buckets)
        let (sources, maxUpdatedAt) = try await loader.loadAll()
        // 新しいインデックスを作り終えてから差し替えるので、作っている間も古いインデックスで検索できる
        index = ShardIndex(sources: sources)
        watermark = maxUpdatedAt
        builtAt = Date()
        logger.info("シャード\(shardID): \(index.documentCount) 件の文書でインデックスを作りました（語: \(index.termCount)）")
    }

    /// 前回から変更されたページを取り込む
    func refresh() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let since = watermark else {
            try await rebuild()
            return
        }
        let loader = IndexLoader(database: database, buckets: buckets)
        // 同じ時刻に更新されたページを取りこぼさないよう、少しさかのぼって読む（重複は上書きされるだけ）
        let changes = try await loader.loadChanges(since: since.addingTimeInterval(-2))
        lastRefreshAt = Date()
        guard !changes.upserts.isEmpty || !changes.removals.isEmpty else { return }

        index.apply(upserts: changes.upserts, removals: changes.removals)
        if let maxUpdatedAt = changes.maxUpdatedAt { watermark = max(since, maxUpdatedAt) }
        logger.debug("シャード\(shardID): 追加・更新 \(changes.upserts.count) 件、削除 \(changes.removals.count) 件")

        if index.segmentCount > settings.maxSegments {
            try await rebuild()
        }
    }

    /// 一定間隔で refresh を繰り返す
    func startRefreshing() {
        guard refreshTask == nil else { return }
        let interval = settings.refreshInterval
        refreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try await self.refresh()
                } catch is CancellationError {
                    return
                } catch {
                    self.logger.error("シャード\(self.shardID): インデックスの更新に失敗しました: \(error)")
                }
            }
        }
    }

    func shutdown() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - 検索

    func stats(terms: [String]) -> CorpusStats {
        index.stats(for: terms)
    }

    func search(_ request: ShardSearchRequest) -> ShardSearchResponse {
        let (total, candidates) = index.search(request.query, corpus: request.corpus, limit: request.limit)
        return ShardSearchResponse(shardID: shardID, total: total, candidates: candidates)
    }

    func snippets(_ request: SnippetRequest) -> SnippetResponse {
        var snippets: [String: String] = [:]
        for id in request.pageIDs {
            snippets[id.uuidString] = index.snippet(pageID: id, terms: request.terms)
        }
        return SnippetResponse(snippets: snippets)
    }

    var status: ShardStatus {
        ShardStatus(
            shardID: shardID,
            shardCount: shardCount,
            documents: index.documentCount,
            segments: index.segmentCount,
            terms: index.termCount,
            builtAt: builtAt,
            lastRefreshAt: lastRefreshAt,
            watermark: watermark
        )
    }
}

/// データベースからインデックスの材料を読み込む
struct IndexLoader: Sendable {
    let database: any Database
    let buckets: [Int]
    var batchSize = 2_000

    struct Changes: Sendable {
        var upserts: [IndexSource]
        var removals: [UUID]
        var maxUpdatedAt: Date?
    }

    /// 担当するページを全部読む（ID 順に少しずつ読み、メモリを使いすぎないようにする）
    func loadAll() async throws -> (sources: [IndexSource], maxUpdatedAt: Date?) {
        var sources: [IndexSource] = []
        var lastID: UUID?
        var maxUpdatedAt: Date?
        var hostRanks = HostRankCache(database: database)
        while true {
            var query = Page.query(on: database)
                .filter(\.$shardBucket ~~ buckets)
                .filter(\.$status == .ok)
                .sort(\.$id)
                .limit(batchSize)
            if let lastID { query = query.filter(\.$id > lastID) }
            let pages = try await query.all()
            guard let last = pages.last else { break }
            lastID = last.id
            sources += try await makeSources(pages, hostRanks: &hostRanks)
            for page in pages {
                if let updatedAt = page.updatedAt { maxUpdatedAt = max(maxUpdatedAt ?? updatedAt, updatedAt) }
            }
        }
        return (sources, maxUpdatedAt)
    }

    /// `since` より後に更新されたページを読む
    func loadChanges(since: Date) async throws -> Changes {
        let pages = try await Page.query(on: database)
            .filter(\.$shardBucket ~~ buckets)
            .filter(\.$updatedAt > since)
            .all()
        var hostRanks = HostRankCache(database: database)
        let live = pages.filter { $0.status == .ok }
        let removed = pages.filter { $0.status != .ok }.compactMap(\.id)
        let maxUpdatedAt = pages.compactMap(\.updatedAt).max()
        return Changes(upserts: try await makeSources(live, hostRanks: &hostRanks), removals: removed, maxUpdatedAt: maxUpdatedAt)
    }

    private func makeSources(_ pages: [Page], hostRanks: inout HostRankCache) async throws -> [IndexSource] {
        // このページを指すリンクのアンカーテキストを集める
        var anchors: [String: [String]] = [:]
        let urls = pages.map(\.url)
        for chunk in stride(from: 0, to: urls.count, by: 500).map({ Array(urls[$0..<min($0 + 500, urls.count)]) }) {
            let links = try await Link.query(on: database).filter(\.$targetURL ~~ chunk).all()
            for link in links where link.sourceHost != link.targetHost || link.sourceURL != link.targetURL {
                guard !link.anchorText.isEmpty else { continue }
                var list = anchors[link.targetURL, default: []]
                // 人気のページは被リンクが膨大になるので、アンカーテキストは100件まで
                if list.count < 100 { list.append(link.anchorText) }
                anchors[link.targetURL] = list
            }
        }

        var sources: [IndexSource] = []
        for page in pages {
            guard let id = page.id else { continue }
            let hostRank = try await hostRanks.rank(for: page.host)
            sources.append(IndexSource(
                pageID: id,
                url: page.url,
                host: page.host,
                title: page.title,
                description: page.description,
                headings: page.headings,
                content: page.content,
                anchorText: anchors[page.url, default: []].joined(separator: "\n"),
                language: page.language,
                pageRank: page.pageRank,
                hostRank: hostRank,
                clicks: page.clicks,
                impressions: page.impressions,
                changedAt: page.changedAt
            ))
        }
        return sources
    }
}

/// ホスト名 → HostRank（同じホストを何度も問い合わせないようにする）
struct HostRankCache: Sendable {
    let database: any Database
    private var ranks: [String: Double] = [:]

    init(database: any Database) {
        self.database = database
    }

    mutating func rank(for host: String) async throws -> Double {
        if let rank = ranks[host] { return rank }
        // 同じホスト名で http と https の両方があれば大きい方を使う
        let rank = try await Host.query(on: database).filter(\.$host == host).all().map(\.hostRank).max() ?? 0
        ranks[host] = rank
        return rank
    }
}

extension Application {
    private struct ShardServicesKey: StorageKey {
        typealias Value = [ShardService]
    }

    /// このプロセスで動かしているシャード（role が shard なら1つ、all なら全シャード）
    var shardServices: [ShardService] {
        get { storage[ShardServicesKey.self] ?? [] }
        set { storage[ShardServicesKey.self] = newValue }
    }
}
