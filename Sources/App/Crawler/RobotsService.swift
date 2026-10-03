import Fluent
import Foundation
import Vapor

/// robots.txt の取得とキャッシュ。
///
/// robots.txt はデータベース（hosts テーブル）に保存して全ワーカーで共有し、
/// さらに各ワーカーのメモリにもキャッシュする。期限（既定で24時間）が切れたら取得し直す。
actor RobotsService {
    struct Result: Sendable {
        var robots: RobotsTxt
        /// 今回ネットワークから取得したか（取得した直後はページの取得の前に待ち時間を入れる）
        var fetchedNow: Bool
    }

    let database: any Database
    let fetcher: any PageFetcher
    let settings: CrawlerSettings
    let logger: Logger
    private var cache: [String: (robots: RobotsTxt, expiresAt: Date)] = [:]
    /// メモリのキャッシュの最大の有効期間。管理 API でホストを止めたとき、この時間以内に全ワーカーへ反映される
    private let memoryTTL: TimeInterval = 5 * 60
    /// メモリのキャッシュの上限（超えたら全部捨てる。単純だが十分）
    private let maxCacheEntries = 50_000

    init(database: any Database, fetcher: any PageFetcher, settings: CrawlerSettings, logger: Logger) {
        self.database = database
        self.fetcher = fetcher
        self.settings = settings
        self.logger = logger
    }

    func robots(for origin: String, now: Date = Date()) async throws -> Result {
        if let cached = cache[origin], cached.expiresAt > now {
            return Result(robots: cached.robots, fetchedNow: false)
        }

        let host = try await Host.query(on: database).filter(\.$origin == origin).first()
            ?? Host(origin: origin, host: URL(string: origin)?.host?.lowercased() ?? origin)

        if host.blocked {
            remember(origin, .disallowAll, until: now.addingTimeInterval(settings.robotsTTL.timeInterval))
            return Result(robots: .disallowAll, fetchedNow: false)
        }

        // データベースに新しい robots.txt があればそれを使う
        if let fetchedAt = host.robotsFetchedAt, now.timeIntervalSince(fetchedAt) < ttl(for: host.robotsStatus) {
            let robots = parse(host)
            remember(origin, robots, until: fetchedAt.addingTimeInterval(ttl(for: host.robotsStatus)))
            return Result(robots: robots, fetchedNow: false)
        }

        // 取得し直す
        guard let robotsURL = URL(string: origin + "/robots.txt") else {
            return Result(robots: .disallowAll, fetchedNow: false)
        }
        do {
            let response = try await fetcher.fetch(FetchRequest(url: robotsURL))
            switch response.status {
            case 200..<300:
                host.robotsStatus = "ok"
                host.robotsTxt = response.body ?? ""
            case 400..<500:
                // robots.txt が無い場合はすべて許可（RFC 9309）
                host.robotsStatus = "missing"
                host.robotsTxt = nil
            default:
                // サーバーエラーで読めない場合はすべて禁止とみなす（RFC 9309）
                host.robotsStatus = "error"
                host.robotsTxt = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("robots.txt の取得に失敗: \(robotsURL) \(error)")
            host.robotsStatus = "error"
            host.robotsTxt = nil
        }
        host.robotsFetchedAt = now
        try await host.save(on: database)

        let robots = parse(host)
        remember(origin, robots, until: now.addingTimeInterval(ttl(for: host.robotsStatus)))
        return Result(robots: robots, fetchedNow: true)
    }

    /// エラーのときは早めに取得し直す
    private func ttl(for status: String) -> TimeInterval {
        status == "error" ? 60 * 60 : settings.robotsTTL.timeInterval
    }

    private func parse(_ host: Host) -> RobotsTxt {
        switch host.robotsStatus {
        case "ok": RobotsTxt(parsing: host.robotsTxt ?? "", userAgent: settings.robotsToken)
        case "missing": .allowAll
        default: .disallowAll
        }
    }

    private func remember(_ origin: String, _ robots: RobotsTxt, until expiresAt: Date) {
        if cache.count >= maxCacheEntries { cache.removeAll(keepingCapacity: true) }
        cache[origin] = (robots, min(expiresAt, Date().addingTimeInterval(memoryTTL)))
    }
}
