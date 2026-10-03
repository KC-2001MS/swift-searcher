import Foundation
import Vapor

// DTO（Data Transfer Object）: API のレスポンスの形を表す型。
// Content に準拠させると、Vapor が JSON との変換を自動で行う。

/// `GET /` のレスポンス
struct APIInfo: Content {
    struct Endpoint: Content {
        var method: String
        var path: String
        var description: String
    }

    var name: String
    var description: String
    var role: String
    var repository: String
    var endpoints: [Endpoint]
}

/// `GET /search` のレスポンス
struct SearchResponse: Content {
    var query: String
    /// 検索文字列から取り出した検索語
    var terms: [String]
    var phrases: [String]
    var excluded: [String]
    var site: String?
    var language: String?
    var total: Int
    var page: Int
    var per: Int
    /// 応答しなかったシャードがあり、結果が一部欠けているか
    var partial: Bool
    var cached: Bool
    var modelVersion: Int
    /// クリックの記録に使う ID（検索ログを記録しない設定なら nil）
    var impressionID: UUID?
    var tookMs: Double
    var results: [SearchResultItem]
}

/// 検索結果の項目
struct SearchResultItem: Content {
    var rank: Int
    var url: String
    /// クリックを記録してから url に移動するための URL
    var clickURL: String?
    var title: String
    var description: String
    var snippet: String
    var score: Double
    var changedAt: Date
    /// スコアの内訳（`explain=true` の場合のみ）
    var explain: Explanation?

    struct Explanation: Content {
        var features: RankingFeatures
        var matchedTerms: [String]
        var shardID: Int
    }
}

/// `GET /suggest` のレスポンス
struct SuggestResponse: Content {
    var query: String
    var suggestions: [String]
}

/// `GET /status` のレスポンス
struct SystemStatus: Content {
    var role: String
    var distributed: Bool
    var frontier: FrontierStats?
    var workers: [WorkerInfo]
    var shards: [ShardStatusItem]
    var pages: PageCounts
    var hosts: Int
    var links: Int
    var rankingModelVersion: Int

    struct PageCounts: Content {
        var total: Int
        var ok: Int
        var gone: Int
        var noindex: Int
        var duplicate: Int
        var dueForRecrawl: Int
    }

    struct ShardStatusItem: Content {
        var shardID: Int
        var available: Bool
        var status: ShardStatus?
    }
}

/// `GET /pages` の項目
struct PageSummary: Content {
    var id: UUID?
    var url: String
    var host: String
    var status: PageStatus
    var title: String
    var description: String
    var depth: Int
    var pageRank: Double
    var fetchedAt: Date
    var changedAt: Date
    var nextCrawlAt: Date
    var revisitIntervalHours: Double
    var duplicateOf: String?

    init(_ page: Page) {
        id = page.id
        url = page.url
        host = page.host
        status = page.status
        title = page.title
        description = page.description
        depth = page.depth
        pageRank = page.pageRank
        fetchedAt = page.fetchedAt
        changedAt = page.changedAt
        nextCrawlAt = page.nextCrawlAt
        revisitIntervalHours = page.revisitInterval / 3600
        duplicateOf = page.duplicateOf
    }
}

/// `GET /pages/:id` のレスポンス
struct PageDetail: Content {
    struct LinkItem: Content {
        var url: String
        var anchorText: String
    }

    var page: PageSummary
    var language: String?
    var headings: [String]
    var content: String
    var shard: Int
    var outgoingLinks: [LinkItem]
    var incomingLinks: [LinkItem]
}

/// ページ分割したリスト
struct PagedList<Item: Content>: Content {
    var total: Int
    var page: Int
    var per: Int
    var items: [Item]
}

/// `POST /admin/seeds` のリクエスト
struct SeedRequest: Content {
    var url: String
}

/// `POST /admin/recrawl` のリクエスト
struct RecrawlRequest: Content {
    var url: String
}

struct SeedItem: Content {
    var id: UUID?
    var url: String
    var enabled: Bool
    var createdAt: Date?

    init(_ seed: Seed) {
        id = seed.id
        url = seed.url
        enabled = seed.enabled
        createdAt = seed.createdAt
    }
}

struct MessageResponse: Content {
    var message: String
}

/// ページ分割のクエリ（`?page=1&per=10`）
struct Pagination {
    var page: Int
    var per: Int

    init(_ req: Request, defaultPer: Int = 10, maxPer: Int = 50, maxPage: Int = 100) throws {
        page = req.query["page"] ?? 1
        per = req.query["per"] ?? defaultPer
        guard (1...maxPage).contains(page) else { throw Abort(.badRequest, reason: "page は 1〜\(maxPage) を指定してください") }
        guard (1...maxPer).contains(per) else { throw Abort(.badRequest, reason: "per は 1〜\(maxPer) を指定してください") }
    }
}
