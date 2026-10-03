import Fluent
import SQLKit

/// テーブルを作るマイグレーション。
///
/// マイグレーションはデータベースの構造（スキーマ）の変更履歴。
/// 後からカラムを追加したいときは、このファイルを書き換えずに新しいマイグレーションを追加する。
struct CreateHost: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Host.schema)
            .id()
            .field("origin", .string, .required)
            .field("host", .string, .required)
            .field("robots_txt", .string)
            .field("robots_status", .string, .required)
            .field("robots_fetched_at", .datetime)
            .field("page_count", .int, .required)
            .field("host_rank", .double, .required)
            .field("blocked", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "origin")
            .create()
        try await createIndex(on: database, name: "hosts_host_idx", table: Host.schema, columns: ["host"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Host.schema).delete()
    }
}

struct CreatePage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Page.schema)
            .id()
            .field("url", .string, .required)
            .field("url_hash", .int64, .required)
            .field("shard_bucket", .int, .required)
            .field("host", .string, .required)
            .field("status", .string, .required)
            .field("title", .string, .required)
            .field("description", .string, .required)
            .field("headings", .string, .required)
            .field("content", .string, .required)
            .field("language", .string)
            .field("content_hash", .string, .required)
            .field("simhash", .int64, .required)
            .field("duplicate_of", .string)
            .field("etag", .string)
            .field("last_modified", .string)
            .field("depth", .int, .required)
            .field("page_rank", .double, .required)
            .field("impressions", .int, .required)
            .field("clicks", .int, .required)
            .field("fetched_at", .datetime, .required)
            .field("changed_at", .datetime, .required)
            .field("next_crawl_at", .datetime, .required)
            .field("revisit_interval", .double, .required)
            .field("fetch_count", .int, .required)
            .field("change_count", .int, .required)
            .field("updated_at", .datetime)
            // 同じ URL のページが二重に保存されないよう、データベース側でも一意にする
            .unique(on: "url")
            .create()
        // よく使う検索条件にはインデックスを付ける（無いと全行を読むことになる）
        try await createIndex(on: database, name: "pages_url_hash_idx", table: Page.schema, columns: ["url_hash"])
        try await createIndex(on: database, name: "pages_next_crawl_at_idx", table: Page.schema, columns: ["next_crawl_at"])
        try await createIndex(on: database, name: "pages_shard_updated_idx", table: Page.schema, columns: ["shard_bucket", "updated_at"])
        try await createIndex(on: database, name: "pages_host_idx", table: Page.schema, columns: ["host"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Page.schema).delete()
    }
}

struct CreateLink: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Link.schema)
            .id()
            .field("source_url", .string, .required)
            .field("source_host", .string, .required)
            .field("target_url", .string, .required)
            .field("target_host", .string, .required)
            .field("anchor_text", .string, .required)
            .create()
        try await createIndex(on: database, name: "links_source_idx", table: Link.schema, columns: ["source_url"])
        try await createIndex(on: database, name: "links_target_idx", table: Link.schema, columns: ["target_url"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Link.schema).delete()
    }
}

struct CreateSeed: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Seed.schema)
            .id()
            .field("url", .string, .required)
            .field("enabled", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "url")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Seed.schema).delete()
    }
}

struct CreateSearchLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SearchImpression.schema)
            .id()
            .field("query", .string, .required)
            .field("normalized_query", .string, .required)
            .field("page", .int, .required)
            .field("payload", .json, .required)
            .field("model_version", .int, .required)
            .field("created_at", .datetime)
            .create()
        try await createIndex(on: database, name: "impressions_query_idx", table: SearchImpression.schema, columns: ["normalized_query"])
        try await createIndex(on: database, name: "impressions_created_idx", table: SearchImpression.schema, columns: ["created_at"])

        try await database.schema(SearchClick.schema)
            .id()
            .field("impression_id", .uuid, .required, .references(SearchImpression.schema, .id, onDelete: .cascade))
            .field("position", .int, .required)
            .field("url", .string, .required)
            .field("created_at", .datetime)
            .create()
        try await createIndex(on: database, name: "clicks_impression_idx", table: SearchClick.schema, columns: ["impression_id"])

        try await database.schema(RankingModelRecord.schema)
            .id()
            .field("version", .int, .required)
            .field("model", .json, .required)
            .field("trained_pairs", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "version")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(RankingModelRecord.schema).delete()
        try await database.schema(SearchClick.schema).delete()
        try await database.schema(SearchImpression.schema).delete()
    }
}

/// 検索を速くするためのインデックス（データベースの索引）を作る
private func createIndex(on database: any Database, name: String, table: String, columns: [String]) async throws {
    guard let sql = database as? any SQLDatabase else { return }
    var builder = sql.create(index: name).on(table)
    for column in columns {
        builder = builder.column(column)
    }
    try await builder.run()
}
