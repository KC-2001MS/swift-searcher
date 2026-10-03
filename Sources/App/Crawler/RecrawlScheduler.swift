import Fluent
import Foundation
import Vapor

/// 再訪問スケジューラー。
///
/// 一定間隔で次の処理を行う（全体で1台だけ動かす）。
///
/// 1. 有効なシードをフロンティアに入れる（初めてのものだけがブルームフィルターを通過する）
/// 2. 再訪問の時期（`next_crawl_at`）が来たページをフロンティアに入れ直す
/// 3. 長い間無くなったままのページを削除する
struct RecrawlScheduler: Sendable {
    struct TickResult: Sendable, Equatable {
        var seeds = 0
        var due = 0
        var purged = 0
    }

    let settings: CrawlerSettings
    let frontier: any Frontier
    let database: any Database
    let logger: Logger
    /// 1回に再訪問へ回す最大ページ数
    var batchSize = 5_000
    /// 無くなってからこの期間が過ぎたページは削除する
    var purgeAfter: TimeInterval = 180 * 24 * 60 * 60

    func run(interval: Duration) async {
        while !Task.isCancelled {
            do {
                let result = try await tick()
                if result != TickResult() {
                    logger.info("スケジューラー: seeds=\(result.seeds) due=\(result.due) purged=\(result.purged)")
                }
                try await Task.sleep(for: interval)
            } catch is CancellationError {
                return
            } catch {
                logger.error("スケジューラーでエラーが発生しました: \(error)")
                try? await Task.sleep(for: interval)
            }
        }
    }

    func tick(now: Date = Date()) async throws -> TickResult {
        var result = TickResult()

        // ① シード
        for seed in try await Seed.query(on: database).filter(\.$enabled == true).all() {
            guard let url = URLNormalizer.normalize(seed.url), let origin = URLNormalizer.origin(of: url) else { continue }
            if try await frontier.enqueue(FrontierEntry(url: url.absoluteString, depth: 0), origin: origin, force: false) {
                result.seeds += 1
            }
        }

        // ② 再訪問の時期が来たページ（取得し直すと、ワーカーが次の時期を決め直す）
        let due = try await Page.query(on: database)
            .filter(\.$nextCrawlAt <= now)
            .sort(\.$nextCrawlAt)
            .limit(batchSize)
            .all()
        for page in due {
            guard let url = URL(string: page.url), let origin = URLNormalizer.origin(of: url) else { continue }
            try await frontier.enqueue(FrontierEntry(url: page.url, depth: page.depth), origin: origin, force: true)
            // ワーカーが取得するまでの間に、もう一度フロンティアへ入れてしまわないよう先に延ばしておく
            let interval = page.revisitInterval > 0 ? page.revisitInterval : settings.revisitInitial.timeInterval
            page.nextCrawlAt = now.addingTimeInterval(interval)
            try await page.save(on: database)
            result.due += 1
        }

        // ③ 無くなったまま長い時間が経ったページを削除する
        let threshold = now.addingTimeInterval(-purgeAfter)
        let stale = try await Page.query(on: database)
            .filter(\.$status == .gone)
            .filter(\.$updatedAt < threshold)
            .limit(batchSize)
            .all()
        for page in stale {
            try await Link.query(on: database).filter(\.$sourceURL == page.url).delete()
            try await page.delete(on: database)
            result.purged += 1
        }
        return result
    }
}
