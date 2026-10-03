import Foundation
import Vapor

/// インデックスシャードの内部 API（role が shard のとき）。
///
/// ブローカーからだけ呼ばれる想定なので、インターネットには公開しない（内部ネットワークのみ）。
/// トークンが設定されていれば、それも確認する。
struct ShardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let shard = routes.grouped("internal", "shard").grouped(InternalAuthMiddleware())
        shard.post("stats", use: stats)
        shard.post("search", use: search)
        shard.post("snippets", use: snippets)
        shard.get("status", use: status)
        shard.post("rebuild", use: rebuild)
    }

    private func service(_ req: Request) throws -> ShardService {
        guard let service = req.application.shardServices.first else {
            throw Abort(.notFound, reason: "このサーバーはシャードではありません")
        }
        return service
    }

    @Sendable
    func stats(req: Request) async throws -> CorpusStats {
        let body = try req.content.decode(ShardStatsRequest.self)
        return try await service(req).stats(terms: body.terms)
    }

    @Sendable
    func search(req: Request) async throws -> ShardSearchResponse {
        let body = try req.content.decode(ShardSearchRequest.self)
        return try await service(req).search(body)
    }

    @Sendable
    func snippets(req: Request) async throws -> SnippetResponse {
        let body = try req.content.decode(SnippetRequest.self)
        return try await service(req).snippets(body)
    }

    @Sendable
    func status(req: Request) async throws -> ShardStatus {
        try await service(req).status
    }

    /// インデックスをデータベースから作り直す（リンク解析の後などに使う）
    @Sendable
    func rebuild(req: Request) async throws -> ShardStatus {
        let shard = try service(req)
        try await shard.rebuild()
        return await shard.status
    }
}

/// 内部 API・管理 API の認証。`Authorization: Bearer <SEARCHER_ADMIN_TOKEN>` を確認する
struct InternalAuthMiddleware: AsyncMiddleware {
    /// トークンが未設定のときにリクエストを通すか（シャードの内部 API は内部ネットワーク前提なので通す）
    var allowWithoutToken = true

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let expected = request.application.searcherConfiguration.adminToken else {
            if allowWithoutToken { return try await next.respond(to: request) }
            throw Abort(.notFound)
        }
        guard let token = request.headers.bearerAuthorization?.token, Self.constantTimeEquals(token, expected) else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: request)
    }

    /// 比較にかかる時間からトークンを推測されないよう、ハッシュ同士を最後まで比較する（タイミング攻撃対策）
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = SHA256.hash(data: Data(lhs.utf8))
        let b = SHA256.hash(data: Data(rhs.utf8))
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
