import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import NIOSSL
import Redis
public import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    //設定を環境変数から読み込む
    let config = SearcherConfiguration.fromEnvironment(app.environment)
    app.searcherConfiguration = config

    //クローラーが使う HTTP クライアントの設定
    //リダイレクトはクローラー自身でたどるため、自動では追従しない
    app.http.client.configuration.redirectConfiguration = .disallow
    app.http.client.configuration.timeout = .init(connect: .seconds(10), read: .seconds(20))

    //データベースの設定（テスト時はメモリ上の SQLite を使う）
    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else if let url = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: url), as: .psql)
    } else {
        app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
            database: Environment.get("DATABASE_NAME") ?? "vapor_database",
            tls: .prefer(try .init(configuration: .clientDefault)))
        ), as: .psql)
    }
    app.migrations.add(CreateHost())
    app.migrations.add(CreatePage())
    app.migrations.add(CreateLink())
    app.migrations.add(CreateSeed())
    app.migrations.add(CreateSearchLog())
    //複数台で同時にマイグレーションしないよう、本番では `App migrate` を別に実行する
    //（開発用の role=all とテストでは起動時に実行する）
    let autoMigrate = Environment.get("AUTO_MIGRATE").map { ["1", "true", "yes"].contains($0.lowercased()) }
        ?? (config.role == .all || app.environment == .testing)
    if autoMigrate {
        try await app.autoMigrate()
    }

    //Redis があれば、フロンティアなどを Redis に置いて複数台で共有する。無ければ1台だけで動かす
    let redis = RedisCommands(app: app)
    if let url = Environment.get("REDIS_URL"), app.environment != .testing {
        app.redis.configuration = try RedisConfiguration(url: url)
        app.crawlServices = CrawlServices(
            frontier: RedisFrontier(
                redis: redis,
                bloom: BloomFilterHasher(bits: config.crawler.bloomBits, hashes: config.crawler.bloomHashes),
                maxQueuePerHost: config.crawler.maxQueuePerHost
            ),
            duplicates: RedisDuplicateDetector(redis: redis, maxDistance: config.crawler.nearDuplicateDistance),
            workers: RedisWorkerRegistry(redis: redis),
            distributed: true
        )
    } else {
        app.crawlServices = CrawlServices(
            frontier: InMemoryFrontier(maxQueuePerHost: config.crawler.maxQueuePerHost),
            duplicates: InMemoryDuplicateDetector(maxDistance: config.crawler.nearDuplicateDistance),
            workers: InMemoryWorkerRegistry(),
            distributed: false
        )
    }

    //日付は ISO 8601 形式の JSON で返す（URL のスラッシュも "\/" とエスケープしない）
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.withoutEscapingSlashes]
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    //ブラウザから直接 API を呼べるように CORS を許可する
    let cors = CORSMiddleware(configuration: .init(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin]
    ))
    app.middleware.use(cors, at: .beginning)

    //インデックスシャード（role=shard なら担当の1つ、role=all か SEARCH_SHARDS 未設定の api なら全シャード）
    let localShards = config.role.runsShard || (config.role.runsAPI && config.search.shardEndpoints == nil)
    if localShards {
        let ids = config.role == .shard ? [config.index.shardID] : Array(0..<config.index.shardCount)
        app.shardServices = ids.map {
            ShardService(shardID: $0, shardCount: config.index.shardCount, database: app.db, settings: config.index, logger: app.logger)
        }
    }

    //検索 API（ブローカー）
    app.rankingModels = RankingModelStore()
    if config.role.runsAPI {
        let shardClients: [any ShardClient]
        if let endpoints = config.search.shardEndpoints {
            shardClients = endpoints.enumerated().map { id, replicas in
                HTTPShardClient(shardID: id, replicas: replicas, client: app.client, timeout: config.search.shardTimeout, token: config.adminToken)
            }
        } else {
            shardClients = app.shardServices.map { LocalShardClient(service: $0) }
        }
        var synonymGroups = SynonymDictionary.defaultGroups
        if let extra = Environment.get("SEARCH_SYNONYMS") {
            synonymGroups += SynonymDictionary.parse(extra)
        }
        app.searchBroker = SearchBroker(
            shards: shardClients,
            settings: config.search,
            candidatesPerShard: config.index.candidatesPerShard,
            models: app.rankingModels,
            cache: (Environment.get("REDIS_URL") != nil && app.environment != .testing) ? RedisQueryCache(redis: redis) : NoQueryCache(),
            synonyms: SynonymDictionary(groups: synonymGroups),
            logger: app.logger
        )
    }

    //役割に応じたバックグラウンド処理（巡回・インデックスの更新など）を起動後に開始する
    app.lifecycle.use(RoleLifecycle())

    //バッチ処理のコマンド
    app.asyncCommands.use(LinkAnalysisCommand(), as: "link-analysis")
    app.asyncCommands.use(TrainRankerCommand(), as: "train-ranker")
    app.asyncCommands.use(SeedCommand(), as: "seed")

    // register routes
    try routes(app)
}
