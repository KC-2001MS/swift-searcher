import Foundation

/// ランキングに使う特徴量。
///
/// 大規模な検索エンジンは、検索語との関連度だけでなく、ページの重要度・新しさ・
/// 実際にクリックされたかどうかなど、数百の要素（特徴量）を組み合わせて順位を決める。
/// ここではその考え方を小さく再現している。
struct RankingFeatures: Codable, Sendable, Equatable {
    /// BM25F（検索語との関連度）。log(1 + x) で大きな値を抑える
    var bm25: Double = 0
    /// 検索語のうち、ページに含まれていた割合（0〜1）
    var coverage: Double = 0
    /// 検索語のうち、タイトルに含まれていた割合（0〜1）
    var titleCoverage: Double = 0
    /// 検索語のうち、被リンクのアンカーテキストに含まれていた割合（0〜1）
    var anchorCoverage: Double = 0
    /// 検索文字列がそのままタイトルに含まれていたか（0 / 1）
    var phraseInTitle: Double = 0
    /// 検索文字列がそのまま本文などに含まれていたか（0 / 1）
    var phraseInBody: Double = 0
    /// PageRank（全体の最大値で割って 0〜1 にしたもの）
    var pageRank: Double = 0
    /// HostRank（全体の最大値で割って 0〜1 にしたもの）
    var hostRank: Double = 0
    /// 新しさ。最後に内容が変わってからの日数で減衰する（0〜1）
    var freshness: Double = 0
    /// URL の浅さ（トップページに近いほど 1 に近い）
    var shallowness: Double = 0
    /// クリック率（表示回数が少ないうちは事前の値 0.1 に近くなるよう平滑化している）
    var clickThroughRate: Double = 0
    /// 検索語とページの言語が合っているか（0〜1）
    var languageMatch: Double = 0

    static let names = [
        "bm25", "coverage", "titleCoverage", "anchorCoverage", "phraseInTitle", "phraseInBody",
        "pageRank", "hostRank", "freshness", "shallowness", "clickThroughRate", "languageMatch",
    ]

    var vector: [Double] {
        [bm25, coverage, titleCoverage, anchorCoverage, phraseInTitle, phraseInBody,
         pageRank, hostRank, freshness, shallowness, clickThroughRate, languageMatch]
    }
}

/// 線形のランキングモデル。
///
/// ```text
/// score = Σ（重み × 特徴量）
/// ```
///
/// 重みは最初は手で決めた値（`default`）を使い、検索ログが溜まったら
/// `App train-ranker` でクリックの記録から学習し直す（Learning to Rank）。
struct RankingModel: Codable, Sendable, Equatable {
    var version: Int
    var featureNames: [String]
    var weights: [Double]

    static let `default` = RankingModel(
        version: 0,
        featureNames: RankingFeatures.names,
        weights: [
            1.0,   // bm25
            1.5,   // coverage
            0.4,   // titleCoverage
            0.3,   // anchorCoverage
            0.3,   // phraseInTitle
            0.15,  // phraseInBody
            0.4,   // pageRank
            0.2,   // hostRank
            0.1,   // freshness
            0.1,   // shallowness
            0.5,   // clickThroughRate
            0.1,   // languageMatch
        ]
    )

    /// 特徴量の並びが今のコードと一致しているか（古いモデルを読み込んで誤った重みを使わないように）
    var isCompatible: Bool {
        featureNames == RankingFeatures.names && weights.count == featureNames.count
    }

    func score(_ features: RankingFeatures) -> Double {
        zip(weights, features.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
