import Fluent
import Foundation
import Vapor

/// 巡回に使う共有のサービス（Redis があれば Redis、無ければメモリ上の実装を使う）
struct CrawlServices: Sendable {
    var frontier: any Frontier
    var duplicates: any DuplicateDetector
    var workers: any WorkerRegistry
    /// Redis を使っているか（使っていなければ1プロセスでしか巡回できない）
    var distributed: Bool
}

extension Application {
    private struct CrawlServicesKey: StorageKey {
        typealias Value = CrawlServices
    }

    private struct PageFetcherKey: StorageKey {
        typealias Value = any PageFetcher
    }

    private struct CrawlerSleepKey: StorageKey {
        typealias Value = @Sendable (Duration) async throws -> Void
    }

    private struct SearchLoggerKey: StorageKey {
        typealias Value = SearchLogger
    }

    private struct RankingModelStoreKey: StorageKey {
        typealias Value = RankingModelStore
    }

    private struct CrawlWorkerKey: StorageKey {
        typealias Value = CrawlWorker
    }

    var crawlServices: CrawlServices {
        get {
            guard let services = storage[CrawlServicesKey.self] else {
                fatalError("CrawlServices が設定されていません。configure(_:) で設定してください。")
            }
            return services
        }
        set { storage[CrawlServicesKey.self] = newValue }
    }

    /// ページの取得に使う実装（テストで差し替えられるようにしている）
    var pageFetcher: any PageFetcher {
        get {
            storage[PageFetcherKey.self] ?? HTTPPageFetcher(
                client: client,
                userAgent: searcherConfiguration.crawler.userAgent,
                maxBodyBytes: searcherConfiguration.crawler.maxBodyBytes
            )
        }
        set { storage[PageFetcherKey.self] = newValue }
    }

    /// 待ち時間の処理（テストで差し替えられるようにしている）
    var crawlerSleep: @Sendable (Duration) async throws -> Void {
        get { storage[CrawlerSleepKey.self] ?? { try await Task.sleep(for: $0) } }
        set { storage[CrawlerSleepKey.self] = newValue }
    }

    var searchLogger: SearchLogger {
        SearchLogger(database: db, logger: logger)
    }

    var rankingModels: RankingModelStore {
        get {
            if let store = storage[RankingModelStoreKey.self] { return store }
            let store = RankingModelStore()
            storage[RankingModelStoreKey.self] = store
            return store
        }
        set { storage[RankingModelStoreKey.self] = newValue }
    }

    /// このプロセスのクロールワーカー（role が worker / all のとき）
    var crawlWorker: CrawlWorker? {
        get { storage[CrawlWorkerKey.self] }
        set { storage[CrawlWorkerKey.self] = newValue }
    }

    /// クロールワーカーを作る
    func makeCrawlWorker() async throws -> CrawlWorker {
        let config = searcherConfiguration
        let seedHosts = try await Seed.query(on: db).filter(\.$enabled == true).all()
            .compactMap { URL(string: $0.url)?.host?.lowercased() }
        let scope = CrawlScope(settings: config.crawler, seedHosts: Set(seedHosts + config.seeds.compactMap { $0.host?.lowercased() }))
        return CrawlWorker(
            settings: config.crawler,
            frontier: crawlServices.frontier,
            fetcher: pageFetcher,
            database: db,
            duplicates: crawlServices.duplicates,
            scope: CrawlScopeState(scope: scope),
            logger: logger,
            sleep: crawlerSleep
        )
    }
}

/// バックグラウンドで動かしている処理（終了時にまとめて止める）
actor BackgroundTasks {
    private var tasks: [Task<Void, Never>] = []

    func add(_ operation: @escaping @Sendable () async -> Void) {
        tasks.append(Task { await operation() })
    }

    func cancelAll() async {
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        tasks.removeAll()
    }
}

/// 役割（APP_ROLE）に応じて、起動後にバックグラウンドの処理を始め、終了時に止める
struct RoleLifecycle: LifecycleHandler {
    let tasks = BackgroundTasks()

    func didBootAsync(_ app: Application) async throws {
        // `migrate` や `routes` などのコマンド実行時は何もしない
        guard Self.isServeCommand(app.environment.arguments) else { return }
        // テストでは、巡回やインデックスの更新をテストのコードから順番に実行する
        guard app.environment != .testing else { return }
        let config = app.searcherConfiguration
        let role = config.role
        app.logger.info("役割: \(role.rawValue)")

        // シャード: 担当するページでインデックスを作り、その後は差分を取り込み続ける
        for shard in app.shardServices {
            try await shard.rebuild()
            await shard.startRefreshing()
        }

        // 検索 API: 学習済みのランキングモデルを定期的に読み込む
        if role.runsAPI {
            await app.rankingModels.startReloading(on: app.db, interval: config.search.modelReloadInterval, logger: app.logger)
        }

        // スケジューラー: 設定のシードを登録し、定期的にフロンティアへ入れる
        if role.runsScheduler {
            try await registerSeeds(config.seeds, on: app.db)
            let scheduler = RecrawlScheduler(settings: config.crawler, frontier: app.crawlServices.frontier, database: app.db, logger: app.logger)
            await tasks.add { await scheduler.run(interval: .seconds(30)) }
        }

        // ワーカー: フロンティアから URL を取り出して巡回し続ける
        if role.runsWorker {
            let worker = try await app.makeCrawlWorker()
            app.crawlWorker = worker
            let concurrency = config.crawler.workerConcurrency
            await tasks.add { await worker.run(concurrency: concurrency) }
            await tasks.add { await Self.reportHeartbeats(app: app, worker: worker, concurrency: concurrency) }
            await tasks.add { await Self.refreshScope(app: app, worker: worker) }
        }
    }

    func shutdownAsync(_ app: Application) async {
        await tasks.cancelAll()
        for shard in app.shardServices { await shard.shutdown() }
        await app.rankingModels.shutdown()
    }

    /// サーバーとして起動したか（引数なしは serve とみなされる）
    static func isServeCommand(_ arguments: [String]) -> Bool {
        guard let command = arguments.dropFirst().first else { return true }
        return command == "serve" || command.hasPrefix("-")
    }

    private func registerSeeds(_ seeds: [URL], on database: any Database) async throws {
        for seed in seeds {
            guard let url = URLNormalizer.normalize(seed)?.absoluteString else { continue }
            if try await Seed.query(on: database).filter(\.$url == url).count() == 0 {
                try await Seed(url: url).create(on: database)
            }
        }
    }

    /// 処理件数を定期的に書き込む（GET /status でワーカーの一覧を確認できる）
    private static func reportHeartbeats(app: Application, worker: CrawlWorker, concurrency: Int) async {
        let id = UUID().uuidString.prefix(8).lowercased()
        let hostname = ProcessInfo.processInfo.hostName
        let startedAt = Date()
        while !Task.isCancelled {
            let info = WorkerInfo(
                id: "\(hostname)-\(id)",
                hostname: hostname,
                concurrency: concurrency,
                startedAt: startedAt,
                lastSeenAt: Date(),
                counters: await worker.stats.counters
            )
            try? await app.crawlServices.workers.heartbeat(info)
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// シードが追加・削除されたときのために、巡回範囲を定期的に読み込み直す
    private static func refreshScope(app: Application, worker: CrawlWorker) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard let seeds = try? await Seed.query(on: app.db).filter(\.$enabled == true).all() else { continue }
            let hosts = Set(seeds.compactMap { URL(string: $0.url)?.host?.lowercased() })
                .union(app.searcherConfiguration.seeds.compactMap { $0.host?.lowercased() })
            await worker.scope.update(seedHosts: hosts)
        }
    }
}
