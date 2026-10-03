@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// ネットワークを使わずに、用意したページを返す PageFetcher
struct MockFetcher: PageFetcher {
    actor Log {
        var requests: [FetchRequest] = []
        func append(_ request: FetchRequest) { requests.append(request) }
    }

    let pages: [String: FetchResponse]
    let log = Log()

    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        await log.append(request)
        guard let response = pages[request.url.absoluteString] else {
            return FetchResponse(status: 404, contentType: "text/html", body: "not found")
        }
        // ETag が一致すれば 304 を返す（条件付きリクエスト）
        if let etag = request.etag, etag == response.etag {
            return FetchResponse(status: 304, etag: etag)
        }
        return response
    }

    var requestedURLs: [String] {
        get async { await log.requests.map(\.url.absoluteString) }
    }

    static func html(_ body: String, etag: String? = nil) -> FetchResponse {
        FetchResponse(status: 200, contentType: "text/html; charset=utf-8", etag: etag, body: body)
    }
}

/// 小さなテスト用サイト
let testSite: [String: FetchResponse] = [
    "https://iroiro.dev/robots.txt": FetchResponse(status: 200, contentType: "text/plain", body: """
        User-agent: *
        Disallow: /private/
        Sitemap: https://iroiro.dev/sitemap.xml
        """),
    "https://iroiro.dev/sitemap.xml": FetchResponse(status: 200, contentType: "application/xml", body: """
        <urlset><url><loc>https://iroiro.dev/sitemap-only</loc></url></urlset>
        """),
    "https://iroiro.dev/": MockFetcher.html("""
        <html><head><title>iroiro.dev</title><meta name="description" content="トップページ"></head>
        <body><main>
          <h1>ようこそ</h1>
          <a href="/swift">Swift の記事</a>
          <a href="/vapor">Vapor で API</a>
          <a href="/private/secret">秘密</a>
          <a href="/old">古いページ</a>
          <a href="/noindex">noindex</a>
          <a href="/duplicate">重複</a>
          <a href="https://example.com/">外部サイト</a>
        </main></body></html>
        """, etag: "\"top\""),
    "https://iroiro.dev/swift": MockFetcher.html("""
        <html><head><title>Swift 入門</title></head>
        <body><main><h1>Swift 入門</h1><p>Swift は Apple が開発したプログラミング言語です。SwiftUI で画面を作ります。</p>
        <a href="/">ホーム</a> <a href="/vapor">Vapor</a></main></body></html>
        """, etag: "\"swift\""),
    "https://iroiro.dev/vapor": MockFetcher.html("""
        <html><head><title>Vapor でクローラーを作る</title></head>
        <body><main><h1>Vapor</h1><p>Swift のサーバーサイドフレームワーク Vapor で検索エンジンのクローラーを作ります。</p>
        <a href="/">ホーム</a> <a href="/swift">Swift 入門</a></main></body></html>
        """, etag: "\"vapor\""),
    "https://iroiro.dev/old": FetchResponse(status: 301, location: "/swift"),
    "https://iroiro.dev/noindex": MockFetcher.html("""
        <html><head><title>非公開</title><meta name="robots" content="noindex"></head>
        <body><a href="/hidden-link">隠しリンク</a></body></html>
        """),
    "https://iroiro.dev/hidden-link": MockFetcher.html("<html><head><title>隠しリンク先</title></head><body>hidden</body></html>"),
    "https://iroiro.dev/duplicate": MockFetcher.html("""
        <html><head><title>Swift 入門</title></head>
        <body><main><h1>Swift 入門</h1><p>Swift は Apple が開発したプログラミング言語です。SwiftUI で画面を作ります。</p>
        <a href="/">ホーム</a> <a href="/vapor">Vapor</a></main></body></html>
        """),
    "https://iroiro.dev/sitemap-only": MockFetcher.html("<html><head><title>サイトマップだけにあるページ</title></head><body>sitemap</body></html>"),
    "https://iroiro.dev/private/secret": MockFetcher.html("<html><head><title>秘密</title></head><body>secret</body></html>"),
]

/// テスト用のアプリを用意する（Redis は使わず、メモリ上のフロンティアで動かす）
func withSearcherApp(site: [String: FetchResponse] = testSite, _ test: (Application, MockFetcher) async throws -> Void) async throws {
    try await withApp(configure: configure) { app in
        let fetcher = MockFetcher(pages: site)
        app.pageFetcher = fetcher
        app.crawlerSleep = { _ in }
        try await test(app, fetcher)
    }
}

/// シードを登録し、フロンティアが空になるまでワーカーを動かして、シャードのインデックスを作る
@discardableResult
func crawlEverything(_ app: Application) async throws -> CrawlCounters {
    if try await Seed.query(on: app.db).count() == 0 {
        try await Seed(url: "https://iroiro.dev/").create(on: app.db)
    }
    let scheduler = RecrawlScheduler(
        settings: app.searcherConfiguration.crawler,
        frontier: app.crawlServices.frontier,
        database: app.db,
        logger: app.logger
    )
    _ = try await scheduler.tick()

    let worker = try await app.makeCrawlWorker()
    var steps = 0
    // ホストの待ち時間を気にせず取り出せるよう、遠い未来の時刻で取り出す
    while try await worker.step(now: .distantFuture), steps < 500 {
        steps += 1
    }
    for shard in app.shardServices {
        try await shard.refresh()
    }
    return await worker.stats.counters
}

@Suite("巡回", .serialized)
struct CrawlerTests {
    @Test("サイトを巡回してページを保存する")
    func crawl() async throws {
        try await withSearcherApp { app, fetcher in
            let counters = try await crawlEverything(app)
            #expect(counters.sitemaps == 1)
            #expect(counters.duplicates == 1)

            let ok = Set(try await Page.query(on: app.db).filter(\.$status == .ok).all().map(\.url))
            #expect(ok == [
                "https://iroiro.dev/",
                "https://iroiro.dev/swift",
                "https://iroiro.dev/vapor",
                "https://iroiro.dev/hidden-link",
                "https://iroiro.dev/sitemap-only",
            ])
            let duplicate = try #require(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/duplicate").first())
            #expect(duplicate.status == .duplicate)
            #expect(duplicate.duplicateOf == "https://iroiro.dev/swift")
            let noindex = try #require(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/noindex").first())
            #expect(noindex.status == .noindex)

            let requested = await fetcher.requestedURLs
            // robots.txt で禁止されたページと外部サイトは取得しない
            #expect(!requested.contains("https://iroiro.dev/private/secret"))
            #expect(!requested.contains("https://example.com/"))
            // 同じページは1回だけ取得する
            #expect(requested.filter { $0 == "https://iroiro.dev/swift" }.count == 1)
            // 最初に robots.txt を取得する
            #expect(requested.first == "https://iroiro.dev/robots.txt")

            // robots.txt はホストのテーブルに保存して共有する
            let host = try #require(try await Host.query(on: app.db).filter(\.$origin == "https://iroiro.dev").first())
            #expect(host.robotsStatus == "ok")
            #expect(host.pageCount == 7)
        }
    }

    @Test("再訪問では ETag を送り、変化が無ければ 304 で済ませる")
    func revisit() async throws {
        try await withSearcherApp { app, _ in
            try await crawlEverything(app)
            let top = try #require(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/").first())
            #expect(top.fetchCount == 1)
            #expect(top.revisitInterval == 7 * 86_400)

            // 全ページの再訪問の時期を来させてから、もう一度スケジューラーとワーカーを動かす
            var site = testSite
            site["https://iroiro.dev/vapor"] = nil
            let fetcher = MockFetcher(pages: site)
            app.pageFetcher = fetcher
            for page in try await Page.query(on: app.db).all() {
                page.nextCrawlAt = Date().addingTimeInterval(-1)
                try await page.save(on: app.db)
            }
            let counters = try await crawlEverything(app)
            #expect(counters.notModified >= 2)
            #expect(counters.gone == 1)

            let requests = await fetcher.log.requests
            let topRequest = try #require(requests.first { $0.url.absoluteString == "https://iroiro.dev/" })
            #expect(topRequest.etag == "\"top\"")

            let vapor = try #require(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/vapor").first())
            #expect(vapor.status == .gone)
            // 変化が無かったページは再訪問の間隔が長くなる
            let revisited = try #require(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/").first())
            #expect(revisited.revisitInterval > 7 * 86_400)
        }
    }

    @Test("一時的なエラーのページは後で再試行する")
    func retry() async throws {
        /// 最初の何回かだけ失敗するページを返す PageFetcher
        actor FlakyFetcher: PageFetcher {
            let base: MockFetcher
            var failures: [String: Int]
            init(base: MockFetcher, failures: [String: Int]) {
                self.base = base
                self.failures = failures
            }
            func fetch(_ request: FetchRequest) async throws -> FetchResponse {
                let key = request.url.absoluteString
                if let remaining = failures[key], remaining > 0 {
                    failures[key] = remaining - 1
                    if remaining == 2 { throw URLError(.networkConnectionLost) }
                    return FetchResponse(status: 503)
                }
                return try await base.fetch(request)
            }
        }

        try await withSearcherApp { app, _ in
            app.pageFetcher = FlakyFetcher(base: MockFetcher(pages: testSite), failures: ["https://iroiro.dev/swift": 2])
            let counters = try await crawlEverything(app)
            #expect(counters.retried == 2)
            #expect(try await Page.query(on: app.db).filter(\.$url == "https://iroiro.dev/swift").count() == 1)
        }
    }
}

@Suite("API", .serialized)
struct APITests {
    @Test("GET / は API の情報を返す")
    func info() async throws {
        try await withSearcherApp { app, _ in
            try await app.testing().test(.GET, "/") { res in
                #expect(res.status == .ok)
                let info = try res.content.decode(APIInfo.self)
                #expect(info.name == "Swift Searcher")
                #expect(info.role == "all")
            }
        }
    }

    @Test("全シャードの結果をまとめて、関連度順に返す")
    func search() async throws {
        try await withSearcherApp { app, _ in
            try await crawlEverything(app)
            #expect(app.shardServices.count == app.searcherConfiguration.index.shardCount)

            try await app.testing().test(.GET, "/search?q=クローラー&explain=true") { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(SearchResponse.self)
                #expect(body.results.first?.url == "https://iroiro.dev/vapor")
                #expect(body.results.first?.explain != nil)
                #expect(body.results.first?.snippet.contains("クローラー") == true)
                #expect(!body.partial)
            }

            try await app.testing().test(.GET, "/search?q=Swift%20入門") { res in
                let body = try res.content.decode(SearchResponse.self)
                #expect(body.results.first?.url == "https://iroiro.dev/swift")
                // 重複ページは検索結果に出さない
                #expect(!body.results.contains { $0.url == "https://iroiro.dev/duplicate" })
            }

            try await app.testing().test(.GET, "/search?q=Swift%20-SwiftUI") { res in
                let body = try res.content.decode(SearchResponse.self)
                #expect(body.excluded == ["swiftui"])
                #expect(!body.results.isEmpty)
                #expect(!body.results.contains { $0.url == "https://iroiro.dev/swift" })
            }
        }
    }

    @Test("クリックは表示した URL にだけリダイレクトする")
    func click() async throws {
        try await withSearcherApp { app, _ in
            try await crawlEverything(app)
            var clickURL: String?
            try await app.testing().test(.GET, "/search?q=Vapor") { res in
                let body = try res.content.decode(SearchResponse.self)
                clickURL = body.results.first?.clickURL
            }
            let url = try #require(clickURL)
            // 検索ログはバックグラウンドで保存されるので、保存されるまで待つ
            var attempts = 0
            while try await SearchImpression.query(on: app.db).count() == 0, attempts < 50 {
                try await Task.sleep(for: .milliseconds(10))
                attempts += 1
            }
            try await app.testing().test(.GET, url) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "https://iroiro.dev/vapor")
            }
            #expect(try await SearchClick.query(on: app.db).count() == 1)

            // 表示していない URL へのリダイレクトは拒否する（オープンリダイレクト対策）
            try await app.testing().test(.GET, "/click?p=1&u=https://evil.example/") { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("管理 API はトークンが必要")
    func admin() async throws {
        try await withSearcherApp { app, _ in
            try await app.testing().test(.GET, "/admin/seeds") { res in
                #expect(res.status == .notFound)
            }
            app.searcherConfiguration.adminToken = "secret"
            try await app.testing().test(.GET, "/admin/seeds", headers: ["Authorization": "Bearer wrong"]) { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.POST, "/admin/seeds", headers: ["Authorization": "Bearer secret"], beforeRequest: { req in
                try req.content.encode(SeedRequest(url: "https://iroiro.dev/swift"))
            }) { res in
                #expect(res.status == .ok)
            }
            #expect(try await Seed.query(on: app.db).count() == 1)
        }
    }

    @Test("状態を返す")
    func status() async throws {
        try await withSearcherApp { app, _ in
            try await crawlEverything(app)
            try await app.testing().test(.GET, "/status") { res in
                let status = try res.content.decode(SystemStatus.self)
                #expect(!status.distributed)
                #expect(status.pages.ok == 5)
                #expect(status.shards.allSatisfy(\.available))
                #expect(status.shards.reduce(0) { $0 + ($1.status?.documents ?? 0) } == 5)
            }
        }
    }
}
