import Foundation
import Vapor

/// 検索 API（role が api / all のとき）
struct SearchController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("search", use: search)
        routes.get("click", use: click)
        routes.get("suggest", use: suggest)
    }

    /// `GET /search?q=検索語&page=1&per=10&explain=false`
    @Sendable
    func search(req: Request) async throws -> SearchResponse {
        let rawQuery: String? = req.query["q"]
        guard let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw Abort(.badRequest, reason: "検索語をクエリパラメータ q で指定してください（例: /search?q=Swift）")
        }
        guard query.count <= 200 else {
            throw Abort(.badRequest, reason: "検索語は200文字以内で指定してください")
        }
        let pagination = try Pagination(req)
        let explain: Bool = req.query["explain"] ?? false

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await req.application.searchBroker.search(query, page: pagination.page, per: pagination.per)

        // 表示した結果を記録する（クリックの記録と合わせてランキングの学習に使う）
        let config = req.application.searcherConfiguration
        var impressionID: UUID?
        if config.search.logQueries, !result.items.isEmpty {
            impressionID = req.application.searchLogger.logImpression(
                query: query, parsed: result.query, page: pagination.page, per: pagination.per,
                items: result.items, modelVersion: result.modelVersion
            )
        }

        let offset = (pagination.page - 1) * pagination.per
        let results = result.items.enumerated().map { index, item in
            let rank = offset + index + 1
            return SearchResultItem(
                rank: rank,
                url: item.url,
                clickURL: impressionID.map { Self.clickURL(impressionID: $0, position: rank, url: item.url) },
                title: item.title,
                description: item.description,
                snippet: result.snippets[item.pageID] ?? item.description,
                score: (item.score * 1000).rounded() / 1000,
                changedAt: item.changedAt,
                explain: explain ? .init(features: item.features, matchedTerms: item.matchedTerms, shardID: item.shardID) : nil
            )
        }
        let elapsed = clock.now - start

        return SearchResponse(
            query: query,
            terms: result.query.terms,
            phrases: result.query.phrases,
            excluded: result.query.excluded,
            site: result.query.site,
            language: result.query.language,
            total: result.total,
            page: pagination.page,
            per: pagination.per,
            partial: result.partial,
            cached: result.fromCache,
            modelVersion: result.modelVersion,
            impressionID: impressionID,
            tookMs: (elapsed.timeInterval * 1_000_000).rounded() / 1000,
            results: results
        )
    }

    static func clickURL(impressionID: UUID, position: Int, url: String) -> String {
        var components = URLComponents()
        components.path = "/click"
        components.queryItems = [
            URLQueryItem(name: "i", value: impressionID.uuidString),
            URLQueryItem(name: "p", value: String(position)),
            URLQueryItem(name: "u", value: url),
        ]
        return components.string ?? "/click"
    }

    /// `GET /click?i={impressionID}&p={position}&u={url}` クリックを記録して移動する
    @Sendable
    func click(req: Request) async throws -> Response {
        guard let url: String = req.query["u"], let position: Int = req.query["p"] else {
            throw Abort(.badRequest, reason: "u と p を指定してください")
        }
        let impressionID: UUID? = req.query["i"]
        guard let destination = try await req.application.searchLogger.logClick(impressionID: impressionID, position: position, url: url) else {
            throw Abort(.badRequest, reason: "検索結果に表示していない URL には移動できません")
        }
        return req.redirect(to: destination, redirectType: .normal)
    }

    /// `GET /suggest?q=swi` よく検索されている検索語の候補
    @Sendable
    func suggest(req: Request) async throws -> SuggestResponse {
        let query: String = req.query["q"] ?? ""
        guard query.count <= 100 else { throw Abort(.badRequest, reason: "q は100文字以内で指定してください") }
        let suggestions = try await req.application.searchLogger.suggest(prefix: query)
        return SuggestResponse(query: query, suggestions: suggestions)
    }
}
