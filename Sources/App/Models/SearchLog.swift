import Fluent
import Foundation

/// 検索結果1件ぶんの記録（どの URL を何位に、どんな特徴量で表示したか）
struct ImpressionResult: Codable, Sendable, Equatable {
    var url: String
    var position: Int
    var features: [Double]
}

/// 検索結果の表示内容（jsonb に保存するため、配列を構造体で包んでいる）
struct ImpressionPayload: Codable, Sendable, Equatable {
    var results: [ImpressionResult]
}

/// 検索結果を表示した記録（インプレッション）。
///
/// どの検索語に対して、どの URL を何位に表示したかを残しておき、
/// クリックの記録と合わせてランキングモデルの学習に使う。
final class SearchImpression: Model, @unchecked Sendable {
    static let schema = "search_impressions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "query")
    var query: String

    /// 正規化した検索語（集計とサジェストに使う）
    @Field(key: "normalized_query")
    var normalizedQuery: String

    /// 何ページ目を表示したか
    @Field(key: "page")
    var page: Int

    @Field(key: "payload")
    var payload: ImpressionPayload

    @Field(key: "model_version")
    var modelVersion: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(query: String, normalizedQuery: String, page: Int, payload: ImpressionPayload, modelVersion: Int) {
        self.query = query
        self.normalizedQuery = normalizedQuery
        self.page = page
        self.payload = payload
        self.modelVersion = modelVersion
    }
}

/// 検索結果がクリックされた記録
final class SearchClick: Model, @unchecked Sendable {
    static let schema = "search_clicks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "impression_id")
    var impressionID: UUID

    @Field(key: "position")
    var position: Int

    @Field(key: "url")
    var url: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(impressionID: UUID, position: Int, url: String) {
        self.impressionID = impressionID
        self.position = position
        self.url = url
    }
}

/// 学習したランキングモデル。新しいものほど version が大きい
final class RankingModelRecord: Model, @unchecked Sendable {
    static let schema = "ranking_models"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "version")
    var version: Int

    @Field(key: "model")
    var model: RankingModel

    /// 学習に使った（クリックされた, されなかった）ペアの数
    @Field(key: "trained_pairs")
    var trainedPairs: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(version: Int, model: RankingModel, trainedPairs: Int) {
        self.version = version
        self.model = model
        self.trainedPairs = trainedPairs
    }
}
