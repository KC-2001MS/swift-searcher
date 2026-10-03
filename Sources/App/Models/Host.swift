import Fluent
import Foundation

/// 巡回対象のホスト（サイト）。
///
/// robots.txt はホストごとに1つなので、ここに保存してワーカー間で共有する
/// （ワーカーが何台あっても robots.txt の取得は1日1回程度で済む）。
final class Host: Model, @unchecked Sendable {
    static let schema = "hosts"

    @ID(key: .id)
    var id: UUID?

    /// オリジン（例: `https://iroiro.dev`）
    @Field(key: "origin")
    var origin: String

    /// ホスト名（例: `iroiro.dev`）
    @Field(key: "host")
    var host: String

    /// robots.txt の本文（取得できなかった場合は nil）
    @OptionalField(key: "robots_txt")
    var robotsTxt: String?

    /// robots.txt を取得したときの状態（ok / missing / error）
    @Field(key: "robots_status")
    var robotsStatus: String

    @OptionalField(key: "robots_fetched_at")
    var robotsFetchedAt: Date?

    /// 保存しているページ数（ホストごとの上限の判定に使う）
    @Field(key: "page_count")
    var pageCount: Int

    /// ホスト単位のリンク構造から求めた重要度（HostRank）
    @Field(key: "host_rank")
    var hostRank: Double

    /// 管理者が巡回を止めたホスト
    @Field(key: "blocked")
    var blocked: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(origin: String, host: String) {
        self.origin = origin
        self.host = host
        self.robotsStatus = "unknown"
        self.pageCount = 0
        self.hostRank = 0
        self.blocked = false
    }
}
