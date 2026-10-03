import Fluent
import Foundation
import SQLKit
import Vapor

/// クリックの記録からランキングモデルを学習する（Learning to Rank）。
///
/// ## 学習データの作り方（ペアワイズ）
///
/// 検索結果でクリックされた結果は、その上にあるのに飛ばされた結果より
/// 「ユーザーにとって良い」と考えられる（Skip Above という考え方）。
///
/// ```text
///  1位  A  ← 飛ばされた
///  2位  B  ← 飛ばされた
///  3位  C  ← クリックされた    →  (C > A), (C > B) という2つのペアができる
///  4位  D                     →  すぐ下の (C > D) もペアにする
/// ```
///
/// ## 学習（ロジスティック回帰）
///
/// ペア (良い, 悪い) ごとに、モデルの点数の差 `w・(x良い − x悪い)` が大きくなるように重み w を少しずつ動かす。
/// 学習データが少ないうちに極端な重みにならないよう、元の重みから離れすぎないようにする（正則化）。
///
/// クリックには「上位ほどクリックされやすい」という偏り（ポジションバイアス）があるが、
/// Skip Above は「上にあるのに飛ばされた」ものだけと比べるので、この偏りの影響を受けにくい。
struct RankerTrainer: Sendable {
    struct Pair: Sendable {
        /// x良い − x悪い
        var difference: [Double]
    }

    struct Result: Sendable {
        var pairs: Int
        var model: RankingModel?
        /// 学習前と学習後で、ペアの順序を正しく当てられた割合
        var accuracyBefore: Double
        var accuracyAfter: Double
    }

    let database: any Database
    let logger: Logger
    /// 何日前までのログを使うか
    var days = 30
    /// これより少ないペアでは学習しない
    var minimumPairs = 1_000
    var epochs = 20
    var learningRate = 0.05
    /// 元の重みから離れすぎないようにする強さ
    var regularization = 0.01

    func run(save: Bool = true) async throws -> Result {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let pairs = try await loadPairs(since: since)
        let base = try await currentModel()
        let before = Self.accuracy(base, pairs)
        // クリック率の集計は、学習できるだけのデータが無くても行う
        try await updateClickCounts(since: since)
        guard pairs.count >= minimumPairs else {
            logger.info("学習用のペアが足りません（\(pairs.count) / \(minimumPairs)）")
            return Result(pairs: pairs.count, model: nil, accuracyBefore: before, accuracyAfter: before)
        }

        var model = Self.train(pairs: pairs, initial: base, epochs: epochs, learningRate: learningRate, regularization: regularization)
        let after = Self.accuracy(model, pairs)
        logger.info("学習しました: ペア \(pairs.count) 件、正解率 \(before) → \(after)")

        if save {
            let latest = try await RankingModelRecord.query(on: database).sort(\.$version, .descending).first()?.version ?? 0
            model.version = latest + 1
            try await RankingModelRecord(version: model.version, model: model, trainedPairs: pairs.count).create(on: database)
        }
        return Result(pairs: pairs.count, model: model, accuracyBefore: before, accuracyAfter: after)
    }

    private func currentModel() async throws -> RankingModel {
        let latest = try await RankingModelRecord.query(on: database).sort(\.$version, .descending).first()
        if let model = latest?.model, model.isCompatible { return model }
        return .default
    }

    /// クリックの記録から学習用のペアを作る
    private func loadPairs(since: Date) async throws -> [Pair] {
        let clicks = try await SearchClick.query(on: database).filter(\.$createdAt >= since).all()
        let clickedByImpression = Dictionary(grouping: clicks, by: \.impressionID).mapValues { Set($0.map(\.position)) }
        var pairs: [Pair] = []
        let ids = Array(clickedByImpression.keys)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let impressions = try await SearchImpression.query(on: database).filter(\.$id ~~ chunk).all()
            for impression in impressions {
                guard let id = impression.id, let clicked = clickedByImpression[id] else { continue }
                pairs += Self.makePairs(results: impression.payload.results, clicked: clicked)
            }
        }
        return pairs
    }

    /// Skip Above（と、クリックのすぐ下の結果）でペアを作る
    static func makePairs(results: [ImpressionResult], clicked: Set<Int>) -> [Pair] {
        let byPosition = Dictionary(results.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
        var pairs: [Pair] = []
        for position in clicked.sorted() {
            guard let good = byPosition[position] else { continue }
            var worse = (results.map(\.position).filter { $0 < position && !clicked.contains($0) })
            if !clicked.contains(position + 1), byPosition[position + 1] != nil {
                worse.append(position + 1)
            }
            for other in worse {
                guard let bad = byPosition[other], bad.features.count == good.features.count else { continue }
                pairs.append(Pair(difference: zip(good.features, bad.features).map { $0 - $1 }))
            }
        }
        return pairs
    }

    /// 確率的勾配降下法で、ペアワイズのロジスティック損失 log(1 + exp(−w・d)) を小さくする
    static func train(pairs: [Pair], initial: RankingModel, epochs: Int, learningRate: Double, regularization: Double) -> RankingModel {
        var weights = initial.weights
        let anchor = initial.weights
        var order = Array(pairs.indices)
        var generator = SystemRandomNumberGenerator()
        for epoch in 0..<epochs {
            order.shuffle(using: &generator)
            // 学習が進むにつれて動かす量を小さくする
            let rate = learningRate / (1 + Double(epoch) * 0.1)
            for index in order {
                let d = pairs[index].difference
                let margin = zip(weights, d).reduce(0) { $0 + $1.0 * $1.1 }
                // 損失の勾配: −d × σ(−margin)
                let sigma = 1 / (1 + exp(margin))
                for i in weights.indices {
                    weights[i] += rate * (sigma * d[i] - regularization * (weights[i] - anchor[i]))
                }
            }
        }
        return RankingModel(version: initial.version, featureNames: initial.featureNames, weights: weights)
    }

    /// ペアの順序（クリックされた方が上）を正しく当てられた割合
    static func accuracy(_ model: RankingModel, _ pairs: [Pair]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let correct = pairs.filter { zip(model.weights, $0.difference).reduce(0) { $0 + $1.0 * $1.1 } > 0 }.count
        return Double(correct) / Double(pairs.count)
    }

    /// ページごとの表示回数・クリック数を集計し直す（クリック率の特徴量に使う）
    private func updateClickCounts(since: Date) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        var impressions: [String: Int] = [:]
        var lastID: UUID?
        while true {
            var query = SearchImpression.query(on: database).filter(\.$createdAt >= since).sort(\.$id).limit(5_000)
            if let lastID { query = query.filter(\.$id > lastID) }
            let batch = try await query.all()
            guard let last = batch.last else { break }
            lastID = last.id
            for impression in batch {
                for result in impression.payload.results { impressions[result.url, default: 0] += 1 }
            }
        }
        let clicks = try await SearchClick.query(on: database).filter(\.$createdAt >= since).all()
        var clickCounts: [String: Int] = [:]
        for click in clicks { clickCounts[click.url, default: 0] += 1 }

        for (url, shown) in impressions {
            let clicked = clickCounts[url] ?? 0
            try await sql.raw("""
                UPDATE pages SET impressions = \(bind: shown), clicks = \(bind: clicked)
                WHERE url_hash = \(bind: StableHash.url(url)) AND url = \(bind: url)
                """).run()
        }
    }
}
