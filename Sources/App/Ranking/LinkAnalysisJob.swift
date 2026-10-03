import Fluent
import Foundation
import SQLKit
import Vapor

/// リンク解析のバッチ処理（PageRank と HostRank の計算）。
///
/// 全ページ・全リンクを読む重い処理なので、検索や巡回とは別に `App link-analysis` で定期的に実行する。
/// 計算した値はデータベースに書き込み、インデックスシャードは次の作り直し（マージ）のときに取り込む。
struct LinkAnalysisJob: Sendable {
    struct Result: Sendable, Equatable {
        var pages = 0
        var links = 0
        var hosts = 0
        var updatedPages = 0
    }

    let database: any Database
    let logger: Logger
    var batchSize = 20_000

    func run() async throws -> Result {
        var result = try await computePageRank()
        result.hosts = try await computeHostRank()
        return result
    }

    // MARK: - PageRank

    private func computePageRank() async throws -> Result {
        var result = Result()

        // URL → 番号。メモリを節約するため、URL のハッシュ値（Int64）で対応付ける
        var indexOf: [Int64: Int32] = [:]
        var ids: [UUID] = []
        var oldRanks: [Double] = []
        var lastID: UUID?
        while true {
            var query = Page.query(on: database)
                .filter(\.$status != .gone)
                .sort(\.$id)
                .limit(batchSize)
            if let lastID { query = query.filter(\.$id > lastID) }
            let pages = try await query.all()
            guard let last = pages.last else { break }
            lastID = last.id
            for page in pages {
                guard let id = page.id else { continue }
                indexOf[page.urlHash] = Int32(ids.count)
                ids.append(id)
                oldRanks.append(page.pageRank)
            }
        }
        result.pages = ids.count
        logger.info("PageRank: \(ids.count) ページを読み込みました")

        var edges: [(source: Int32, target: Int32)] = []
        var lastLinkID: UUID?
        while true {
            var query = Link.query(on: database).sort(\.$id).limit(batchSize)
            if let lastLinkID { query = query.filter(\.$id > lastLinkID) }
            let links = try await query.all()
            guard let last = links.last else { break }
            lastLinkID = last.id
            for link in links {
                guard let s = indexOf[StableHash.url(link.sourceURL)], let t = indexOf[StableHash.url(link.targetURL)] else { continue }
                edges.append((s, t))
            }
        }
        result.links = edges.count
        logger.info("PageRank: \(edges.count) 本のリンクで計算します")

        let ranks = PageRank.compute(nodeCount: ids.count, edges: edges)

        // 変化したページだけを書き込む
        guard let sql = database as? any SQLDatabase else { return result }
        for i in ids.indices where abs(ranks[i] - oldRanks[i]) > 1e-12 {
            try await sql.raw("UPDATE pages SET page_rank = \(bind: ranks[i]) WHERE id = \(bind: ids[i])").run()
            result.updatedPages += 1
        }
        return result
    }

    // MARK: - HostRank

    /// ホスト同士のリンクから、ホスト（サイト）の重要度を求める。
    ///
    /// ページ単位の PageRank は、同じサイト内のリンク（メニューなど）の影響を強く受ける。
    /// サイトをまたぐリンクだけで計算した HostRank は「他のサイトからどれだけ参照されているか」を表すので、
    /// 新しいページ（まだ被リンクが無い）でも、信頼できるサイトのページなら上位に出せる。
    private func computeHostRank() async throws -> Int {
        guard let sql = database as? any SQLDatabase else { return 0 }

        struct HostRow: Decodable { var host: String }
        struct EdgeRow: Decodable {
            var source_host: String
            var target_host: String
        }
        let hosts = try await sql.raw("SELECT DISTINCT host FROM hosts").all(decoding: HostRow.self).map(\.host)
        var indexOf: [String: Int32] = [:]
        for (i, host) in hosts.enumerated() { indexOf[host] = Int32(i) }

        let rows = try await sql.raw("""
            SELECT DISTINCT source_host, target_host FROM links WHERE source_host <> target_host
            """).all(decoding: EdgeRow.self)
        let edges = rows.compactMap { row -> (source: Int32, target: Int32)? in
            guard let s = indexOf[row.source_host], let t = indexOf[row.target_host] else { return nil }
            return (s, t)
        }
        let ranks = PageRank.compute(nodeCount: hosts.count, edges: edges)
        for (i, host) in hosts.enumerated() {
            try await sql.raw("UPDATE hosts SET host_rank = \(bind: ranks[i]) WHERE host = \(bind: host)").run()
        }
        return hosts.count
    }
}
