import Fluent
import Foundation
import Vapor

/// ランキング済みの検索結果1件
struct RankedItem: Codable, Sendable, Equatable {
    var pageID: UUID
    var shardID: Int
    var url: String
    var host: String
    var title: String
    var description: String
    var language: String?
    var changedAt: Date
    var matchedTerms: [String]
    var features: RankingFeatures
    var score: Double
}

/// ブローカーが返す検索結果
struct BrokerResult: Sendable {
    var query: ParsedQuery
    /// 一致した文書の数（各シャードの件数の合計）
    var total: Int
    /// 応答しなかったシャードがあり、結果が一部欠けているか
    var partial: Bool
    var modelVersion: Int
    /// このページに表示する結果
    var items: [RankedItem]
    /// ページ ID → 抜粋
    var snippets: [UUID: String]
    var fromCache: Bool
}

/// キャッシュに保存する内容（抜粋はページごとに取り直すので含めない）
private struct CachedRanking: Codable {
    var total: Int
    var partial: Bool
    var items: [RankedItem]
}

/// 検索ブローカー。
///
/// 検索のリクエストを受け取り、全シャードに問い合わせて結果をまとめる（スキャッター・ギャザー）。
///
/// ```text
///                     ┌──▶ シャード0 ──┐
///  ① 統計値を集める    ├──▶ シャード1 ──┤   各シャードの文書頻度などを合計する
///                     └──▶ シャード2 ──┘
///                     ┌──▶ シャード0 ──┐
///  ② 候補を集める      ├──▶ シャード1 ──┤   合計した統計値で点数を計算させ、上位の候補を返させる
///                     └──▶ シャード2 ──┘
///  ③ 最終的な順位付け   ランキングモデルで点数を付け、同じホストが並びすぎないよう調整する
///  ④ 抜粋を取得        表示する結果のページを持っているシャードにだけ問い合わせる
/// ```
///
/// 応答しないシャードがあっても、残りのシャードの結果だけで返す（`partial: true`）。
/// 一部の結果が欠けても、検索がまったくできないよりは良いという考え方。
struct SearchBroker: Sendable {
    let shards: [any ShardClient]
    let settings: SearchSettings
    let candidatesPerShard: Int
    let models: RankingModelStore
    let cache: any QueryCache
    let synonyms: SynonymDictionary
    let logger: Logger

    func search(_ raw: String, page: Int, per: Int) async throws -> BrokerResult {
        let query = QueryParser.parse(raw, synonyms: synonyms)
        let model = await models.model
        guard !query.terms.isEmpty else {
            return BrokerResult(query: query, total: 0, partial: false, modelVersion: model.version, items: [], snippets: [:], fromCache: false)
        }

        // 検索結果全体（上位の候補）をキャッシュする。ページ送りしてもシャードに問い合わせ直さずに済む
        let cacheKey = "v\(model.version):" + query.cacheKey
        var ranking: CachedRanking
        var fromCache = false
        if let data = await cache.get(cacheKey), let cached = try? JSONDecoder().decode(CachedRanking.self, from: data) {
            ranking = cached
            fromCache = true
        } else {
            ranking = try await rank(query, model: model)
            if !ranking.partial, let data = try? JSONEncoder().encode(ranking) {
                await cache.set(cacheKey, value: data, ttl: settings.cacheTTL)
            }
        }

        let start = min((page - 1) * per, ranking.items.count)
        let end = min(start + per, ranking.items.count)
        let items = Array(ranking.items[start..<end])
        let snippets = await fetchSnippets(items, terms: query.terms)
        return BrokerResult(
            query: query,
            total: ranking.total,
            partial: ranking.partial,
            modelVersion: model.version,
            items: items,
            snippets: snippets,
            fromCache: fromCache
        )
    }

    // MARK: - 順位付け

    private func rank(_ query: ParsedQuery, model: RankingModel) async throws -> CachedRanking {
        var partial = false

        // ① 全シャードの統計値を集めて合計する
        let statsTerms = query.terms + query.synonyms.values.flatMap { $0 }
        var corpus = CorpusStats()
        await withTaskGroup(of: CorpusStats?.self) { group in
            for shard in shards {
                group.addTask {
                    try? await shard.stats(ShardStatsRequest(terms: statsTerms))
                }
            }
            for await stats in group {
                if let stats { corpus.merge(stats) } else { partial = true }
            }
        }

        // ② 合計した統計値を渡して、各シャードに候補を出させる
        var total = 0
        var failures = 0
        var items: [RankedItem] = []
        let request = ShardSearchRequest(query: query, corpus: corpus, limit: candidatesPerShard)
        await withTaskGroup(of: ShardSearchResponse?.self) { group in
            for shard in shards {
                group.addTask {
                    do {
                        return try await shard.search(request)
                    } catch {
                        self.logger.warning("シャード\(shard.shardID)が応答しませんでした: \(error)")
                        return nil
                    }
                }
            }
            for await response in group {
                guard let response else {
                    partial = true
                    failures += 1
                    continue
                }
                total += response.total
                // ③ ランキングモデルで最終的な点数を付ける
                items += response.candidates.map { candidate in
                    RankedItem(
                        pageID: candidate.pageID,
                        shardID: response.shardID,
                        url: candidate.url,
                        host: candidate.host,
                        title: candidate.title,
                        description: candidate.description,
                        language: candidate.language,
                        changedAt: candidate.changedAt,
                        matchedTerms: candidate.matchedTerms,
                        features: candidate.features,
                        score: model.score(candidate.features)
                    )
                }
            }
        }
        if !shards.isEmpty && failures == shards.count {
            // すべてのシャードが応答しなかった
            throw Abort(.serviceUnavailable, reason: "検索インデックスに接続できませんでした")
        }

        items.sort { $0.score != $1.score ? $0.score > $1.score : $0.url < $1.url }
        return CachedRanking(total: total, partial: partial, items: Self.diversify(items, maxPerHost: settings.maxResultsPerHost))
    }

    /// 同じホストの結果が上位に並びすぎないようにする（ホストクラウディング）。
    ///
    /// 上位から見ていき、同じホストが `maxPerHost` 件を超えたら、その結果は後ろに回す。
    /// 1つの大きなサイトが検索結果を独占せず、いろいろなサイトの結果を見られるようにするため。
    static func diversify(_ items: [RankedItem], maxPerHost: Int) -> [RankedItem] {
        var counts: [String: Int] = [:]
        var head: [RankedItem] = []
        var tail: [RankedItem] = []
        for item in items {
            counts[item.host, default: 0] += 1
            if counts[item.host]! <= maxPerHost {
                head.append(item)
            } else {
                tail.append(item)
            }
        }
        return head + tail
    }

    // MARK: - 抜粋

    /// 表示する結果の抜粋を、その文書を持っているシャードにだけ問い合わせる
    private func fetchSnippets(_ items: [RankedItem], terms: [String]) async -> [UUID: String] {
        let byShard = Dictionary(grouping: items, by: \.shardID)
        var snippets: [UUID: String] = [:]
        await withTaskGroup(of: SnippetResponse?.self) { group in
            for (shardID, shardItems) in byShard {
                guard let shard = shards.first(where: { $0.shardID == shardID }) else { continue }
                let request = SnippetRequest(pageIDs: shardItems.map(\.pageID), terms: terms)
                group.addTask { try? await shard.snippets(request) }
            }
            for await response in group {
                for (id, snippet) in response?.snippets ?? [:] {
                    if let uuid = UUID(uuidString: id) { snippets[uuid] = snippet }
                }
            }
        }
        return snippets
    }
}

/// 使用中のランキングモデル。学習したモデルがデータベースに保存されたら読み込み直す
actor RankingModelStore {
    private(set) var model: RankingModel = .default
    private var reloadTask: Task<Void, Never>?

    init(model: RankingModel = .default) {
        self.model = model
    }

    /// データベースから最新のモデルを読み込む。今のコードと特徴量が合わないモデルは使わない
    func reload(on database: any Database, logger: Logger) async {
        do {
            guard let record = try await RankingModelRecord.query(on: database).sort(\.$version, .descending).first() else { return }
            guard record.model.isCompatible else {
                logger.warning("ランキングモデル v\(record.version) は特徴量が合わないため使いません")
                return
            }
            if record.model != model {
                model = record.model
                logger.info("ランキングモデル v\(record.version) を読み込みました")
            }
        } catch {
            logger.warning("ランキングモデルの読み込みに失敗しました: \(error)")
        }
    }

    func startReloading(on database: any Database, interval: Duration, logger: Logger) {
        guard reloadTask == nil else { return }
        reloadTask = Task {
            while !Task.isCancelled {
                await self.reload(on: database, logger: logger)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func shutdown() {
        reloadTask?.cancel()
        reloadTask = nil
    }
}

extension Application {
    private struct SearchBrokerKey: StorageKey {
        typealias Value = SearchBroker
    }

    var searchBroker: SearchBroker {
        get {
            guard let broker = storage[SearchBrokerKey.self] else {
                fatalError("SearchBroker が設定されていません。configure(_:) で設定してください。")
            }
            return broker
        }
        set { storage[SearchBrokerKey.self] = newValue }
    }
}
