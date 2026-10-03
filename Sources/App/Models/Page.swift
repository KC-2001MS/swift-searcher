import Fluent
import Foundation

/// ページの状態
enum PageStatus: String, Codable, Sendable {
    /// 検索結果に出してよいページ
    case ok
    /// 404 / 410 などで無くなったページ（インデックスから削除する）
    case gone
    /// noindex が指定されているページ
    case noindex
    /// 他のページと（ほぼ）同じ内容のページ
    case duplicate
}

/// クロールして保存したページ
final class Page: Model, @unchecked Sendable {
    static let schema = "pages"

    @ID(key: .id)
    var id: UUID?

    /// 正規化済みの URL（一意）
    @Field(key: "url")
    var url: String

    /// URL のハッシュ値（シャードの割り当てに使う）
    @Field(key: "url_hash")
    var urlHash: Int64

    /// シャードの割り当てに使うバケット番号（0〜1023）
    @Field(key: "shard_bucket")
    var shardBucket: Int

    @Field(key: "host")
    var host: String

    @Enum(key: "status")
    var status: PageStatus

    @Field(key: "title")
    var title: String

    @Field(key: "description")
    var description: String

    /// h1〜h3 の見出し（改行区切り）
    @Field(key: "headings")
    var headings: String

    /// 本文テキスト
    @Field(key: "content")
    var content: String

    @OptionalField(key: "language")
    var language: String?

    /// 本文の SHA-256（完全一致の重複検出用）
    @Field(key: "content_hash")
    var contentHash: String

    /// 本文の SimHash（ほぼ同じ内容のページの検出用）
    @Field(key: "simhash")
    var simhash: Int64

    /// 重複と判定した場合の、元のページの URL
    @OptionalField(key: "duplicate_of")
    var duplicateOf: String?

    @OptionalField(key: "etag")
    var etag: String?

    @OptionalField(key: "last_modified")
    var lastModified: String?

    /// シードからのリンクの深さ
    @Field(key: "depth")
    var depth: Int

    /// リンク構造から計算した PageRank
    @Field(key: "page_rank")
    var pageRank: Double

    /// 検索結果に表示された回数・クリックされた回数（ランキングの特徴量に使う）
    @Field(key: "impressions")
    var impressions: Int

    @Field(key: "clicks")
    var clicks: Int

    /// 最後に取得（または 304 で確認）した日時
    @Field(key: "fetched_at")
    var fetchedAt: Date

    /// 内容が最後に変化した日時
    @Field(key: "changed_at")
    var changedAt: Date

    /// 次に取得する予定の日時（再訪問スケジューラーが使う）
    @Field(key: "next_crawl_at")
    var nextCrawlAt: Date

    /// 現在の再訪問の間隔（秒）。内容が変わるたびに短く、変わらなければ長くする
    @Field(key: "revisit_interval")
    var revisitInterval: Double

    @Field(key: "fetch_count")
    var fetchCount: Int

    @Field(key: "change_count")
    var changeCount: Int

    /// 最後に更新された日時。インデックスシャードは、これを見て変更されたページだけを取り込む
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    /// 新しいページを作る（中身は呼び出し側で設定する）
    init(url: String, host: String, depth: Int, now: Date) {
        let hash = StableHash.url(url)
        self.url = url
        self.urlHash = hash
        self.shardBucket = ShardRouting.bucket(forURLHash: hash)
        self.host = host
        self.status = .ok
        self.title = ""
        self.description = ""
        self.headings = ""
        self.content = ""
        self.contentHash = ""
        self.simhash = 0
        self.depth = depth
        self.pageRank = 0
        self.impressions = 0
        self.clicks = 0
        self.fetchedAt = now
        self.changedAt = now
        self.nextCrawlAt = now
        self.revisitInterval = 0
        self.fetchCount = 0
        self.changeCount = 0
    }
}
