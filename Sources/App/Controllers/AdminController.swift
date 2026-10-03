import Fluent
import Foundation
import Vapor

/// 管理 API（`Authorization: Bearer <SEARCHER_ADMIN_TOKEN>` が必要。トークンが未設定なら無効）
struct AdminController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin").grouped(InternalAuthMiddleware(allowWithoutToken: false))
        admin.get("seeds", use: listSeeds)
        admin.post("seeds", use: addSeed)
        admin.delete("seeds", ":seedID", use: deleteSeed)
        admin.post("recrawl", use: recrawl)
        admin.post("hosts", ":host", "block", use: blockHost)
        admin.post("hosts", ":host", "unblock", use: unblockHost)
    }

    /// `GET /admin/seeds`
    @Sendable
    func listSeeds(req: Request) async throws -> [SeedItem] {
        try await Seed.query(on: req.db).sort(\.$createdAt).all().map(SeedItem.init)
    }

    /// `POST /admin/seeds` `{"url": "https://example.com/"}` シードを追加し、すぐにフロンティアへ入れる
    @Sendable
    func addSeed(req: Request) async throws -> SeedItem {
        let body = try req.content.decode(SeedRequest.self)
        guard let url = URLNormalizer.normalize(body.url), let origin = URLNormalizer.origin(of: url) else {
            throw Abort(.badRequest, reason: "URL が不正です")
        }
        let seed = try await Seed.query(on: req.db).filter(\.$url == url.absoluteString).first() ?? Seed(url: url.absoluteString)
        seed.enabled = true
        try await seed.save(on: req.db)
        try await req.application.crawlServices.frontier.enqueue(FrontierEntry(url: url.absoluteString, depth: 0), origin: origin, force: true)
        return SeedItem(seed)
    }

    /// `DELETE /admin/seeds/:seedID`
    @Sendable
    func deleteSeed(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("seedID", as: UUID.self), let seed = try await Seed.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        try await seed.delete(on: req.db)
        return .noContent
    }

    /// `POST /admin/recrawl` `{"url": "..."}` 指定した URL をすぐに取得し直す
    @Sendable
    func recrawl(req: Request) async throws -> MessageResponse {
        let body = try req.content.decode(RecrawlRequest.self)
        guard let url = URLNormalizer.normalize(body.url), let origin = URLNormalizer.origin(of: url) else {
            throw Abort(.badRequest, reason: "URL が不正です")
        }
        let depth = try await Page.query(on: req.db)
            .filter(\.$urlHash == StableHash.url(url.absoluteString))
            .filter(\.$url == url.absoluteString)
            .first()?.depth ?? 0
        try await req.application.crawlServices.frontier.enqueue(FrontierEntry(url: url.absoluteString, depth: depth), origin: origin, force: true)
        return MessageResponse(message: "フロンティアに追加しました: \(url.absoluteString)")
    }

    /// `POST /admin/hosts/:host/block` ホストの巡回を止める（サイト運営者から依頼があった場合など）
    @Sendable
    func blockHost(req: Request) async throws -> MessageResponse {
        try await setBlocked(req, blocked: true)
    }

    @Sendable
    func unblockHost(req: Request) async throws -> MessageResponse {
        try await setBlocked(req, blocked: false)
    }

    private func setBlocked(_ req: Request, blocked: Bool) async throws -> MessageResponse {
        guard let host = req.parameters.get("host")?.lowercased() else { throw Abort(.badRequest) }
        let hosts = try await Host.query(on: req.db).filter(\.$host == host).all()
        guard !hosts.isEmpty else { throw Abort(.notFound, reason: "まだ巡回していないホストです") }
        for record in hosts {
            record.blocked = blocked
            // robots.txt の期限を切って取得し直させる（各ワーカーのメモリのキャッシュは最大5分で切れる）
            record.robotsFetchedAt = nil
            try await record.save(on: req.db)
        }
        return MessageResponse(message: blocked ? "\(host) の巡回を止めました" : "\(host) の巡回を再開しました")
    }
}
