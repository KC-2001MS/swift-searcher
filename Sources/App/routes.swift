import Fluent
import Vapor

func routes(_ app: Application) throws {
    let config = app.searcherConfiguration

    //このAPIに関する詳細を表示
    app.get { req async -> APIInfo in
        APIInfo(
            name: "Swift Searcher",
            description: "Web を巡回して作った検索インデックスを検索できる API です。大規模な検索エンジンの仕組みを学ぶためのプロジェクトです。",
            role: req.application.searcherConfiguration.role.rawValue,
            repository: "https://github.com/KC-2001MS/swift-searcher",
            endpoints: [
                .init(method: "GET", path: "/search?q={query}&page={page}&per={per}&explain={bool}", description: "検索（\"フレーズ\"・-除外・site:・lang: に対応）"),
                .init(method: "GET", path: "/suggest?q={prefix}", description: "よく検索されている検索語の候補"),
                .init(method: "GET", path: "/click?i={impression}&p={position}&u={url}", description: "クリックを記録して移動する"),
                .init(method: "GET", path: "/status", description: "フロンティア・ワーカー・シャード・ページ数"),
                .init(method: "GET", path: "/pages?host={host}&page={page}&per={per}", description: "保存済みのページ"),
                .init(method: "GET", path: "/pages/{id}", description: "ページの詳細"),
                .init(method: "POST", path: "/admin/seeds", description: "シードを追加する（Bearer トークンが必要）"),
                .init(method: "POST", path: "/admin/recrawl", description: "URL を取得し直す（Bearer トークンが必要）"),
                .init(method: "POST", path: "/admin/hosts/{host}/block", description: "ホストの巡回を止める（Bearer トークンが必要）"),
                .init(method: "GET", path: "/health", description: "ヘルスチェック"),
            ]
        )
    }
    //ヘルスチェック
    app.get("health") { _ async in
        HTTPStatus.ok
    }

    try app.register(collection: StatusController())
    try app.register(collection: AdminController())
    if config.role.runsAPI {
        try app.register(collection: SearchController())
    }
    if config.role == .shard {
        try app.register(collection: ShardController())
    }
}
