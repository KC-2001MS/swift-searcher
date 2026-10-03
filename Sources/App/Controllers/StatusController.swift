import Fluent
import Foundation
import Vapor

/// 全体の状態とページの参照
struct StatusController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("status", use: status)
        let pages = routes.grouped("pages")
        pages.get(use: listPages)
        pages.get(":pageID", use: showPage)
    }

    /// `GET /status` フロンティア・ワーカー・シャード・ページ数
    @Sendable
    func status(req: Request) async throws -> SystemStatus {
        let app = req.application
        let config = app.searcherConfiguration
        let now = Date()

        var shards: [SystemStatus.ShardStatusItem] = []
        if config.role.runsAPI {
            for shard in app.searchBroker.shards {
                let status = try? await shard.status()
                shards.append(.init(shardID: shard.shardID, available: status != nil, status: status))
            }
        } else {
            for shard in app.shardServices {
                shards.append(.init(shardID: shard.shardID, available: true, status: await shard.status))
            }
        }

        func count(_ status: PageStatus) async throws -> Int {
            try await Page.query(on: req.db).filter(\.$status == status).count()
        }

        return SystemStatus(
            role: config.role.rawValue,
            distributed: app.crawlServices.distributed,
            frontier: try? await app.crawlServices.frontier.stats(now: now),
            workers: (try? await app.crawlServices.workers.activeWorkers(now: now)) ?? [],
            shards: shards,
            pages: .init(
                total: try await Page.query(on: req.db).count(),
                ok: try await count(.ok),
                gone: try await count(.gone),
                noindex: try await count(.noindex),
                duplicate: try await count(.duplicate),
                dueForRecrawl: try await Page.query(on: req.db).filter(\.$nextCrawlAt <= now).count()
            ),
            hosts: try await Host.query(on: req.db).count(),
            links: try await Link.query(on: req.db).count(),
            rankingModelVersion: await app.rankingModels.model.version
        )
    }

    /// `GET /pages?host=iroiro.dev&page=1&per=20` 保存済みのページを PageRank の高い順に返す
    @Sendable
    func listPages(req: Request) async throws -> PagedList<PageSummary> {
        let pagination = try Pagination(req, defaultPer: 20, maxPer: 100)
        var query = Page.query(on: req.db)
        if let host: String = req.query["host"] {
            query = query.filter(\.$host == host.lowercased())
        }
        let total = try await query.copy().count()
        let pages = try await query
            .sort(\.$pageRank, .descending)
            .sort(\.$url)
            .range(lower: (pagination.page - 1) * pagination.per, upper: pagination.page * pagination.per)
            .all()
        return PagedList(total: total, page: pagination.page, per: pagination.per, items: pages.map(PageSummary.init))
    }

    /// `GET /pages/:pageID` ページの詳細（本文・リンク）
    @Sendable
    func showPage(req: Request) async throws -> PageDetail {
        guard let id = req.parameters.get("pageID", as: UUID.self), let page = try await Page.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let outgoing = try await Link.query(on: req.db).filter(\.$sourceURL == page.url).limit(200).all()
        let incoming = try await Link.query(on: req.db).filter(\.$targetURL == page.url).limit(200).all()
        return PageDetail(
            page: PageSummary(page),
            language: page.language,
            headings: page.headings.split(separator: "\n").map(String.init),
            content: page.content,
            shard: ShardRouting.shard(forBucket: page.shardBucket, shardCount: req.application.searcherConfiguration.index.shardCount),
            outgoingLinks: outgoing.map { .init(url: $0.targetURL, anchorText: $0.anchorText) },
            incomingLinks: incoming.map { .init(url: $0.sourceURL, anchorText: $0.anchorText) }
        )
    }
}
