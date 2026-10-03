import Fluent
import Foundation
import SQLKit
import Vapor

/// 検索ログ（表示・クリック）の記録と、検索語の候補（サジェスト）
struct SearchLogger: Sendable {
    let database: any Database
    let logger: Logger

    /// 表示した検索結果を記録し、クリックの記録に使う ID を返す。
    ///
    /// 書き込みを待つと検索の応答が遅くなるので、ID を先に決めてバックグラウンドで保存する。
    func logImpression(query raw: String, parsed: ParsedQuery, page: Int, per: Int, items: [RankedItem], modelVersion: Int) -> UUID {
        let id = UUID()
        let offset = (page - 1) * per
        let payload = ImpressionPayload(results: items.enumerated().map { index, item in
            ImpressionResult(url: item.url, position: offset + index + 1, features: item.features.vector)
        })
        let impression = SearchImpression(
            query: String(raw.prefix(200)),
            normalizedQuery: QueryParser.normalizePhrase(raw),
            page: page,
            payload: payload,
            modelVersion: modelVersion
        )
        impression.id = id
        let database = self.database
        let logger = self.logger
        Task {
            do {
                try await impression.create(on: database)
            } catch {
                logger.warning("検索ログの保存に失敗しました: \(error)")
            }
        }
        return id
    }

    /// クリックを記録し、リダイレクト先の URL を返す。
    ///
    /// 任意の URL にリダイレクトできると、このサイトを経由したフィッシングに悪用される（オープンリダイレクト）。
    /// そのため、実際にその検索結果に表示した URL か、保存済みのページの URL のときだけリダイレクトする。
    func logClick(impressionID: UUID?, position: Int, url: String) async throws -> String? {
        if let impressionID, let impression = try await SearchImpression.find(impressionID, on: database) {
            guard impression.payload.results.contains(where: { $0.url == url && $0.position == position }) else { return nil }
            try await SearchClick(impressionID: impressionID, position: position, url: url).create(on: database)
            return url
        }
        // 記録がまだ保存されていない（または古くて消えた）場合は、保存済みのページかどうかだけ確かめる
        let exists = try await Page.query(on: database)
            .filter(\.$urlHash == StableHash.url(url))
            .filter(\.$url == url)
            .count() > 0
        return exists ? url : nil
    }

    /// 入力途中の文字列から、よく検索されている検索語を返す。
    ///
    /// 個人が特定できる検索語が表示されないよう、`minimumCount` 回以上検索されたものだけを返す。
    func suggest(prefix: String, limit: Int = 10, minimumCount: Int = 5) async throws -> [String] {
        guard let sql = database as? any SQLDatabase else { return [] }
        let normalized = QueryParser.normalizePhrase(prefix)
        guard !normalized.isEmpty else { return [] }
        // LIKE の特殊文字（% と _）をエスケープする
        let escaped = normalized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        struct Row: Decodable { var normalized_query: String }
        let rows = try await sql.raw("""
            SELECT normalized_query FROM search_impressions
            WHERE normalized_query LIKE \(bind: escaped + "%") ESCAPE '\\'
            GROUP BY normalized_query
            HAVING COUNT(*) >= \(bind: minimumCount)
            ORDER BY COUNT(*) DESC, normalized_query
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        return rows.map(\.normalized_query)
    }
}
