import Foundation
import NIOCore
import Vapor

// MARK: - シャードとのやり取りに使う型

struct ShardStatsRequest: Content {
    var terms: [String]
}

struct ShardSearchRequest: Content {
    var query: ParsedQuery
    /// 全シャードを合わせた統計値（BM25 の IDF などを全シャードでそろえるため）
    var corpus: CorpusStats
    var limit: Int
}

struct ShardSearchResponse: Content {
    var shardID: Int
    /// 条件に一致した文書の数（limit で切る前）
    var total: Int
    var candidates: [SearchCandidate]
}

struct SnippetRequest: Content {
    var pageIDs: [UUID]
    var terms: [String]
}

struct SnippetResponse: Content {
    /// ページ ID（文字列）→ 抜粋
    var snippets: [String: String]
}

struct ShardStatus: Content {
    var shardID: Int
    var shardCount: Int
    var documents: Int
    var segments: Int
    var terms: Int
    var builtAt: Date?
    var lastRefreshAt: Date?
    var watermark: Date?
}

// MARK: - シャードへの問い合わせ

/// 1つのシャードへの問い合わせ。
///
/// 同じプロセス内のシャード（LocalShardClient）と、別のサーバーのシャード（HTTPShardClient）を
/// 同じように扱えるようにしている。
protocol ShardClient: Sendable {
    var shardID: Int { get }
    func stats(_ request: ShardStatsRequest) async throws -> CorpusStats
    func search(_ request: ShardSearchRequest) async throws -> ShardSearchResponse
    func snippets(_ request: SnippetRequest) async throws -> SnippetResponse
    func status() async throws -> ShardStatus
}

/// 同じプロセス内のシャード（開発用の role=all とテストで使う）
struct LocalShardClient: ShardClient {
    let service: ShardService
    var shardID: Int { service.shardID }

    func stats(_ request: ShardStatsRequest) async throws -> CorpusStats {
        await service.stats(terms: request.terms)
    }

    func search(_ request: ShardSearchRequest) async throws -> ShardSearchResponse {
        await service.search(request)
    }

    func snippets(_ request: SnippetRequest) async throws -> SnippetResponse {
        await service.snippets(request)
    }

    func status() async throws -> ShardStatus {
        await service.status
    }
}

/// 別のサーバーで動いているシャードに HTTP で問い合わせる。
///
/// 同じシャードのレプリカが複数あれば、問い合わせごとに順番を変えて負荷を分散し（ラウンドロビン）、
/// 1台が応答しなければ次のレプリカに問い合わせる（フェイルオーバー）。
struct HTTPShardClient: ShardClient {
    let shardID: Int
    let replicas: [String]
    let client: any Client
    let timeout: Duration
    let token: String?
    private let counter = RoundRobinCounter()

    init(shardID: Int, replicas: [String], client: any Client, timeout: Duration, token: String?) {
        self.shardID = shardID
        self.replicas = replicas
        self.client = client
        self.timeout = timeout
        self.token = token
    }

    func stats(_ request: ShardStatsRequest) async throws -> CorpusStats {
        try await post("/internal/shard/stats", request, as: CorpusStats.self)
    }

    func search(_ request: ShardSearchRequest) async throws -> ShardSearchResponse {
        try await post("/internal/shard/search", request, as: ShardSearchResponse.self)
    }

    func snippets(_ request: SnippetRequest) async throws -> SnippetResponse {
        try await post("/internal/shard/snippets", request, as: SnippetResponse.self)
    }

    func status() async throws -> ShardStatus {
        try await send(.GET, "/internal/shard/status", body: Optional<ShardStatsRequest>.none, as: ShardStatus.self)
    }

    private func post<Body: Content, Result: Content>(_ path: String, _ body: Body, as type: Result.Type) async throws -> Result {
        try await send(.POST, path, body: body, as: type)
    }

    private func send<Body: Content, Result: Content>(_ method: HTTPMethod, _ path: String, body: Body?, as type: Result.Type) async throws -> Result {
        guard !replicas.isEmpty else { throw Abort(.serviceUnavailable, reason: "シャード\(shardID)のレプリカがありません") }
        let start = await counter.next()
        var lastError: (any Error)?
        for offset in 0..<replicas.count {
            let base = replicas[(start + offset) % replicas.count]
            do {
                var headers = HTTPHeaders()
                if let token { headers.bearerAuthorization = BearerAuthorization(token: token) }
                let timeout = TimeAmount.milliseconds(self.timeout.milliseconds)
                let response = try await client.send(method, headers: headers, to: URI(string: base + path)) { request in
                    request.timeout = timeout
                    if let body { try request.content.encode(body) }
                }
                guard response.status == .ok else {
                    throw Abort(.badGateway, reason: "シャード\(shardID)（\(base)）が \(response.status.code) を返しました")
                }
                return try response.content.decode(Result.self)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Abort(.serviceUnavailable)
    }
}

/// ラウンドロビンの順番を数える
actor RoundRobinCounter {
    private var value = 0

    func next() -> Int {
        defer { value &+= 1 }
        return value & Int.max
    }
}
