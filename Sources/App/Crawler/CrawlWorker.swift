import Fluent
import Foundation
import SQLKit
import Vapor

/// ワーカーの処理件数
struct CrawlCounters: Codable, Sendable, Equatable {
    var fetched = 0
    var indexed = 0
    var notModified = 0
    var duplicates = 0
    var skipped = 0
    var gone = 0
    var errors = 0
    var retried = 0
    var enqueued = 0
    var sitemaps = 0
}

/// ワーカーの処理件数を数える（複数のタスクから同時に数えるので actor にしている）
actor CrawlStatsRecorder {
    enum Event: Sendable {
        case fetched, indexed, notModified, duplicate, skipped, gone, error, retried, enqueued, sitemap
    }

    private(set) var counters = CrawlCounters()

    func record(_ event: Event) {
        switch event {
        case .fetched: counters.fetched += 1
        case .indexed: counters.indexed += 1
        case .notModified: counters.notModified += 1
        case .duplicate: counters.duplicates += 1
        case .skipped: counters.skipped += 1
        case .gone: counters.gone += 1
        case .error: counters.errors += 1
        case .retried: counters.retried += 1
        case .enqueued: counters.enqueued += 1
        case .sitemap: counters.sitemaps += 1
        }
    }
}

/// 巡回範囲（シードのホスト一覧が管理 API から変わるので、actor で持って定期的に読み込み直す）
actor CrawlScopeState {
    private(set) var scope: CrawlScope

    init(scope: CrawlScope) {
        self.scope = scope
    }

    func update(seedHosts: Set<String>) {
        scope.seedHosts = seedHosts
    }
}

/// クロールワーカー。
///
/// 分散フロンティアから URL を取り出し、取得・解析・保存して、見つけたリンクをフロンティアに戻す。
/// ワーカーは状態を持たない（フロンティアは Redis、ページはデータベースにある）ので、
/// 台数を増やすだけで巡回の速度を上げられる。
///
/// ```text
///          ┌────────────── 分散フロンティア（Redis）◀───────────────┐
///          │ ① ホストを借りて URL を取り出す                        │ ⑤ 見つけたリンクを追加
///          ▼                                                     │
///   robots.txt の確認 ─▶ ② 取得（条件付きリクエスト）─▶ ③ 解析 ─▶ ④ 重複の判定・保存（Postgres）
///          │                                                     │
///          └──────── ⑥ Crawl-delay 後の時刻を付けてホストを返す ◀───┘
/// ```
///
/// 1台のワーカーの中でも、`concurrency` 個のタスクが別々のホストを並行して処理する。
/// （同じホストには同時に1つのタスクしかアクセスしない。ホストの貸し出しはフロンティアが管理する）
///
/// HTML の解析などの重い処理を並行して行えるよう、actor ではなく状態を持たない struct にしている。
/// 変化する状態（処理件数・巡回範囲）はそれぞれ actor に分けている。
struct CrawlWorker: Sendable {
    let settings: CrawlerSettings
    let frontier: any Frontier
    let fetcher: any PageFetcher
    let database: any Database
    let duplicates: any DuplicateDetector
    let robots: RobotsService
    let scope: CrawlScopeState
    let logger: Logger
    /// 待ち時間の処理（テストでは待たないように差し替える）
    let sleep: @Sendable (Duration) async throws -> Void

    let stats = CrawlStatsRecorder()

    init(
        settings: CrawlerSettings,
        frontier: any Frontier,
        fetcher: any PageFetcher,
        database: any Database,
        duplicates: any DuplicateDetector,
        scope: CrawlScopeState,
        logger: Logger,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settings = settings
        self.frontier = frontier
        self.fetcher = fetcher
        self.database = database
        self.duplicates = duplicates
        self.robots = RobotsService(database: database, fetcher: fetcher, settings: settings, logger: logger)
        self.scope = scope
        self.logger = logger
        self.sleep = sleep
    }

    // MARK: - ループ

    /// キャンセルされるまで巡回を続ける
    func run(concurrency: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    await self.loop()
                }
            }
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                if try await step() == false {
                    // 今すぐアクセスできるホストが無ければ少し待つ
                    try await sleep(.milliseconds(500))
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("ワーカーでエラーが発生しました: \(error)")
                try? await sleep(.seconds(1))
            }
        }
    }

    /// フロンティアから1件取り出して処理する。取り出せなければ false
    @discardableResult
    func step(now: Date = Date()) async throws -> Bool {
        guard let lease = try await frontier.claim(now: now, lease: settings.hostLease) else { return false }
        var delay = settings.minHostDelay
        do {
            delay = try await process(lease)
        } catch is CancellationError {
            // 終了時はすぐにホストを返して、他のワーカーが続きを処理できるようにする
            try? await frontier.release(origin: lease.origin, nextAllowedAt: Date())
            throw CancellationError()
        } catch {
            await stats.record(.error)
            logger.warning("処理に失敗: \(lease.entry.url) \(error)")
        }
        try await frontier.release(origin: lease.origin, nextAllowedAt: Date().addingTimeInterval(delay.timeInterval))
        return true
    }

    // MARK: - 1件の処理

    /// URL を1件処理し、次にそのホストにアクセスしてよいまでの待ち時間を返す
    func process(_ lease: FrontierLease) async throws -> Duration {
        let entry = lease.entry
        guard let url = URL(string: entry.url) else {
            await stats.record(.skipped)
            return .zero
        }

        // ① robots.txt（ホストごとに共有・キャッシュされている）
        let robotsResult = try await robots.robots(for: lease.origin)
        var delay = settings.minHostDelay
        if let crawlDelay = robotsResult.robots.crawlDelay {
            delay = min(max(delay, .milliseconds(Int(crawlDelay * 1000))), settings.maxHostDelay)
        }
        if robotsResult.fetchedNow {
            // robots.txt を取得し直したときは、サイトマップも読み直して新しいページを見つける
            for sitemap in sitemapURLs(robotsResult.robots, origin: lease.origin) {
                try await frontier.enqueue(FrontierEntry(url: sitemap, depth: 0, kind: .sitemap), origin: lease.origin, force: true)
            }
            // 直前に robots.txt を取得しているので、続けてアクセスする前に待つ
            try await sleep(delay)
        }
        guard robotsResult.robots.isAllowed(url) else {
            await stats.record(.skipped)
            if let existing = try await existingPage(entry.url) {
                try await markGone(existing)
            }
            return delay
        }

        if entry.kind == .sitemap {
            try await processSitemap(entry, url: url, origin: lease.origin)
            return delay
        }

        let existing = try await existingPage(entry.url)
        if existing == nil, try await hostIsFull(lease.origin) {
            await stats.record(.skipped)
            return delay
        }

        // ② 取得。前回の ETag / Last-Modified を送り、変化が無ければ 304 で済ませる
        let response: FetchResponse
        do {
            response = try await fetcher.fetch(FetchRequest(url: url, etag: existing?.etag, lastModified: existing?.lastModified))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 接続できない・タイムアウトなど。サーバーが不調かもしれないので、そのホストへの間隔を広げる
            logger.info("取得に失敗: \(entry.url) \(error)")
            await stats.record(.error)
            try await retryLater(entry, origin: lease.origin, existing: existing)
            return min(delay * 4, settings.maxHostDelay)
        }
        await stats.record(.fetched)

        switch response.status {
        case 200..<300:
            try await handleSuccess(entry, url: url, origin: lease.origin, response: response, existing: existing)
        case 304:
            // 変化なし。前回保存したリンクは有効なままなので、ここでは何もたどらない
            if let existing {
                await stats.record(.notModified)
                try await markFetched(existing, changed: false)
            } else {
                await stats.record(.skipped)
            }
        case _ where response.isRedirect:
            // リダイレクト先を同じ深さでフロンティアに入れる（自動では追従しない）
            if let location = response.location, let target = URLNormalizer.normalize(location, relativeTo: url) {
                try await enqueue(target, depth: entry.depth)
            }
            if let existing { try await markGone(existing) }
            await stats.record(.skipped)
        case 429, 500..<600:
            // 混雑・一時的なエラー。少し後で再試行し、そのホストへの間隔を大きく広げる（バックオフ）
            await stats.record(.error)
            try await retryLater(entry, origin: lease.origin, existing: existing)
            return min(delay * 8, settings.maxHostDelay)
        default:
            // 404 / 410 などはページが無くなったとみなす
            await stats.record(.gone)
            if let existing { try await markGone(existing) }
        }
        return delay
    }

    /// 200 番台で取得できたページを解析して保存する
    private func handleSuccess(_ entry: FrontierEntry, url: URL, origin: String, response: FetchResponse, existing: Page?) async throws {
        guard response.isHTML, let body = response.body else {
            await stats.record(.skipped)
            if let existing { try await markGone(existing) }
            return
        }

        // ③ 解析
        let extracted = try HTMLExtractor.extract(html: body, baseURL: url)
        let links = extracted.nofollow ? [] : Array(extracted.links.filter { !$0.nofollow }.prefix(500))
        for link in links {
            try await enqueue(link.url, depth: entry.depth + 1)
        }

        // canonical が別の URL を指していれば、そちらを正として扱う
        let currentScope = await scope.scope
        if let canonical = extracted.canonicalURL, canonical != url, currentScope.allows(canonical, depth: entry.depth) {
            try await enqueue(canonical, depth: entry.depth)
            await stats.record(.skipped)
            if let existing { try await markGone(existing) }
            return
        }

        let now = Date()
        let page = existing ?? Page(url: entry.url, host: url.host?.lowercased() ?? "", depth: entry.depth, now: now)
        let isNew = existing == nil
        let contentHash = StableHash.sha256Hex(extracted.title + "\n" + extracted.content)
        let simhash = SimHash.compute(extracted.title + "\n" + extracted.content)
        let changed = isNew || page.contentHash != contentHash

        // ④ 重複の判定。内容が変わっていれば古い登録を消してから登録し直す
        if let existing, changed, !existing.contentHash.isEmpty {
            try await duplicates.forget(url: existing.url, contentHash: existing.contentHash, simhash: UInt64(bitPattern: existing.simhash))
        }
        var status = PageStatus.ok
        var duplicateOf: String?
        if extracted.noindex {
            status = .noindex
        } else if let original = try await duplicates.registerOrFindOriginal(url: entry.url, contentHash: contentHash, simhash: simhash) {
            status = .duplicate
            duplicateOf = original
            await stats.record(.duplicate)
        }

        page.status = status
        page.duplicateOf = duplicateOf
        page.title = extracted.title
        page.description = extracted.description
        page.headings = extracted.headings.joined(separator: "\n")
        page.content = extracted.content
        page.language = extracted.language
        page.contentHash = contentHash
        page.simhash = Int64(bitPattern: simhash)
        page.etag = response.etag
        page.lastModified = response.lastModified
        page.depth = min(page.depth, entry.depth)
        try await markFetched(page, changed: changed, now: now)

        if isNew {
            try await incrementHostPageCount(origin)
        }
        if status == .ok { await stats.record(.indexed) }

        // リンクを保存し直す（PageRank・HostRank とアンカーテキストに使う）
        try await Link.query(on: database).filter(\.$sourceURL == page.url).delete()
        let sourceHost = page.host
        let models = links.filter { $0.url != url }.map {
            Link(sourceURL: page.url, sourceHost: sourceHost, targetURL: $0.url.absoluteString,
                 targetHost: $0.url.host?.lowercased() ?? "", anchorText: String($0.text.prefix(200)))
        }
        if !models.isEmpty {
            try await models.create(on: database)
        }
    }

    /// サイトマップを読み、載っている URL をフロンティアに追加する
    private func processSitemap(_ entry: FrontierEntry, url: URL, origin: String) async throws {
        let response = try await fetcher.fetch(FetchRequest(url: url))
        guard (200..<300).contains(response.status), let body = response.body else { return }
        await stats.record(.sitemap)
        let (urls, isIndex) = try HTMLExtractor.extractSitemap(xml: body)
        for string in urls.prefix(50_000) {
            guard let target = URLNormalizer.normalize(string) else { continue }
            if isIndex {
                // サイトマップインデックスなら、中身は子サイトマップ（同じホストのものだけ読む）
                guard URLNormalizer.origin(of: target) == origin else { continue }
                try await frontier.enqueue(FrontierEntry(url: target.absoluteString, depth: entry.depth, kind: .sitemap), origin: origin, force: false)
            } else {
                try await enqueue(target, depth: max(entry.depth, 1))
            }
        }
    }

    // MARK: - フロンティア

    /// 巡回範囲内なら URL をフロンティアに追加する
    private func enqueue(_ url: URL, depth: Int) async throws {
        guard await scope.scope.allows(url, depth: depth), let origin = URLNormalizer.origin(of: url) else { return }
        if try await frontier.enqueue(FrontierEntry(url: url.absoluteString, depth: depth), origin: origin, force: false) {
            await stats.record(.enqueued)
        }
    }

    /// 一時的なエラーのとき、回数の上限まで後で再試行する
    private func retryLater(_ entry: FrontierEntry, origin: String, existing: Page?) async throws {
        if entry.retries < settings.maxRetries {
            var retry = entry
            retry.retries += 1
            try await frontier.enqueue(retry, origin: origin, force: true)
            await stats.record(.retried)
        } else if let existing {
            // 再試行しても取得できなかった。ページは残し、次の再訪問の時期に改めて取得する
            existing.nextCrawlAt = Date().addingTimeInterval(settings.revisitMin.timeInterval)
            try await existing.save(on: database)
        }
    }

    private func sitemapURLs(_ robots: RobotsTxt, origin: String) -> [String] {
        let listed = robots.sitemaps.compactMap { URLNormalizer.normalize($0)?.absoluteString }
        return listed.isEmpty ? [origin + "/sitemap.xml"] : Array(listed.prefix(10))
    }

    // MARK: - データベース

    private func existingPage(_ url: String) async throws -> Page? {
        try await Page.query(on: database)
            .filter(\.$urlHash == StableHash.url(url))
            .filter(\.$url == url)
            .first()
    }

    /// 取得できた（または 304 で変化が無いと確認できた）ことを記録し、次の再訪問の時期を決める
    private func markFetched(_ page: Page, changed: Bool, now: Date = Date()) async throws {
        let interval = RevisitPolicy.nextInterval(
            previous: page.revisitInterval > 0 ? page.revisitInterval : nil,
            changed: changed && page.fetchCount > 0,
            settings: settings
        )
        page.fetchedAt = now
        page.fetchCount += 1
        if changed {
            page.changedAt = now
            page.changeCount += 1
        }
        page.revisitInterval = interval
        page.nextCrawlAt = now.addingTimeInterval(RevisitPolicy.jittered(interval))
        try await page.save(on: database)
    }

    /// ページが無くなったことを記録する（インデックスシャードは次の取り込みで検索結果から外す）
    private func markGone(_ page: Page) async throws {
        if page.status != .gone, !page.contentHash.isEmpty {
            try await duplicates.forget(url: page.url, contentHash: page.contentHash, simhash: UInt64(bitPattern: page.simhash))
        }
        page.status = .gone
        page.nextCrawlAt = Date().addingTimeInterval(settings.revisitMax.timeInterval)
        try await page.save(on: database)
        try await Link.query(on: database).filter(\.$sourceURL == page.url).delete()
    }

    private func hostIsFull(_ origin: String) async throws -> Bool {
        guard let host = try await Host.query(on: database).filter(\.$origin == origin).first() else { return false }
        return host.pageCount >= settings.maxPagesPerHost
    }

    /// ホストのページ数を1増やす。複数のワーカーが同時に増やしても数え漏れが無いよう、
    /// 「読んでから書く」のではなく SQL の `page_count + 1` で増やす
    private func incrementHostPageCount(_ origin: String) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE hosts SET page_count = page_count + 1 WHERE origin = \(bind: origin)").run()
    }
}
