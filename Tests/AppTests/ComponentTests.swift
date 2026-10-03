@testable import App
import Foundation
import Testing

@Suite("クエリの解析")
struct QueryParserTests {
    @Test("フレーズ・除外・site:・lang: を取り出す")
    func operators() {
        let query = QueryParser.parse(#"Swift "server side" -python site:iroiro.dev lang:ja"#)
        #expect(query.terms == ["swift", "server", "side"])
        #expect(query.phrases == ["server side"])
        #expect(query.excluded == ["python"])
        #expect(query.site == "iroiro.dev")
        #expect(query.language == "ja")
    }

    @Test("同義語を展開する")
    func synonyms() {
        let query = QueryParser.parse("JS tutorial")
        #expect(query.synonyms["js"] == ["javascript"])
        #expect(query.synonyms["tutorial"] == nil)
    }

    @Test("表記ゆれがあっても同じキャッシュキーになる")
    func cacheKey() {
        #expect(QueryParser.parse("Swift  Vapor").cacheKey == QueryParser.parse("swift vapor").cacheKey)
    }
}

@Suite("巡回範囲と再訪問")
struct CrawlPolicyTests {
    var settings = CrawlerSettings.default

    @Test("シードのホストだけを巡回する")
    func seedHosts() {
        let scope = CrawlScope(settings: settings, seedHosts: ["iroiro.dev"])
        #expect(scope.allows(URL(string: "https://iroiro.dev/a")!, depth: 1))
        #expect(!scope.allows(URL(string: "https://example.com/")!, depth: 1))
        #expect(!scope.allows(URL(string: "https://iroiro.dev/a")!, depth: settings.maxDepth + 1))
        #expect(!scope.allows(URL(string: "https://iroiro.dev/image.png")!, depth: 1))
    }

    @Test("許可リストはサブドメインも含み、ブロックリストが優先される")
    func allowlist() {
        var settings = settings
        settings.scope = .allowlist
        settings.allowedHosts = ["example.com"]
        settings.blockedHosts = ["private.example.com"]
        let scope = CrawlScope(settings: settings, seedHosts: [])
        #expect(scope.allows(URL(string: "https://blog.example.com/")!, depth: 0))
        #expect(!scope.allows(URL(string: "https://private.example.com/")!, depth: 0))
        #expect(!scope.allows(URL(string: "https://notexample.com/")!, depth: 0))
    }

    @Test("クローラートラップを避ける")
    func traps() {
        #expect(CrawlScope.looksLikeTrap(URL(string: "https://a.example/x/y/x/y/x/y/x/y")!))
        #expect(!CrawlScope.looksLikeTrap(URL(string: "https://a.example/blog/2026/10/post")!))
    }

    @Test("内容が変われば間隔を短く、変わらなければ長くする")
    func revisit() {
        let day = 86_400.0
        #expect(RevisitPolicy.nextInterval(previous: nil, changed: false, settings: settings) == 7 * day)
        #expect(RevisitPolicy.nextInterval(previous: 8 * day, changed: true, settings: settings) == 4 * day)
        #expect(RevisitPolicy.nextInterval(previous: 4 * day, changed: false, settings: settings) == 6 * day)
        // 最小・最大の範囲に収める
        #expect(RevisitPolicy.nextInterval(previous: 1 * day, changed: true, settings: settings) == 1 * day)
        #expect(RevisitPolicy.nextInterval(previous: 80 * day, changed: false, settings: settings) == 90 * day)
    }
}

@Suite("重複の検出")
struct DuplicateTests {
    let base = String(repeating: "Swift は Apple が開発したプログラミング言語です。サーバーサイドでも使えます。", count: 10)

    @Test("似た文章ほど SimHash の距離が小さい")
    func simhash() {
        let a = SimHash.compute(base + " 2026年10月1日")
        let b = SimHash.compute(base + " 2026年10月2日")
        let c = SimHash.compute("Rust is a systems programming language focused on safety and performance.")
        #expect(SimHash.distance(a, b) < SimHash.distance(a, c))
        #expect(SimHash.distance(a, a) == 0)
    }

    @Test("完全一致とほぼ一致を見つける")
    func detector() async throws {
        let detector = InMemoryDuplicateDetector(maxDistance: 3)
        let hash = SimHash.compute(base)
        #expect(try await detector.registerOrFindOriginal(url: "https://a.example/1", contentHash: "h1", simhash: hash) == nil)
        // 同じ内容の別 URL
        #expect(try await detector.registerOrFindOriginal(url: "https://a.example/2", contentHash: "h1", simhash: hash) == "https://a.example/1")
        // SimHash が1ビットだけ違う別 URL
        #expect(try await detector.registerOrFindOriginal(url: "https://a.example/3", contentHash: "h3", simhash: hash ^ 1) == "https://a.example/1")
        // 自分自身は重複にならない
        #expect(try await detector.registerOrFindOriginal(url: "https://a.example/1", contentHash: "h1", simhash: hash) == nil)
        // 消したら重複ではなくなる
        try await detector.forget(url: "https://a.example/1", contentHash: "h1", simhash: hash)
        #expect(try await detector.registerOrFindOriginal(url: "https://a.example/2", contentHash: "h1", simhash: hash) == nil)
    }
}

@Suite("フロンティア")
struct FrontierTests {
    @Test("同じホストは貸し出し中に取り出せず、返すまで待つ")
    func politeness() async throws {
        let frontier = InMemoryFrontier()
        let now = Date()
        try await frontier.enqueue(FrontierEntry(url: "https://a.example/1", depth: 1), origin: "https://a.example")
        try await frontier.enqueue(FrontierEntry(url: "https://a.example/0", depth: 0), origin: "https://a.example")
        try await frontier.enqueue(FrontierEntry(url: "https://b.example/", depth: 0), origin: "https://b.example")

        let first = try #require(try await frontier.claim(now: now, lease: .seconds(60)))
        let second = try #require(try await frontier.claim(now: now, lease: .seconds(60)))
        // 2つ目は別のホストになる（同じホストに同時にアクセスしない）
        #expect(first.origin != second.origin)
        #expect(try await frontier.claim(now: now, lease: .seconds(60)) == nil)

        // a.example を返すと、1秒後から取り出せる
        let a = first.origin == "https://a.example" ? first : second
        #expect(a.entry.url == "https://a.example/0")  // 浅いページが先
        try await frontier.release(origin: a.origin, nextAllowedAt: now.addingTimeInterval(1))
        #expect(try await frontier.claim(now: now, lease: .seconds(60)) == nil)
        let next = try await frontier.claim(now: now.addingTimeInterval(1), lease: .seconds(60))
        #expect(next?.entry.url == "https://a.example/1")
    }

    @Test("一度入れた URL は force でなければ入れ直さない")
    func dedupe() async throws {
        let frontier = InMemoryFrontier()
        let entry = FrontierEntry(url: "https://a.example/", depth: 0)
        #expect(try await frontier.enqueue(entry, origin: "https://a.example"))
        _ = try await frontier.claim(now: Date(), lease: .seconds(1))
        #expect(try await !frontier.enqueue(entry, origin: "https://a.example"))
        #expect(try await frontier.enqueue(entry, origin: "https://a.example", force: true))
    }

    @Test("ブルームフィルターのビット位置は決定的で範囲内")
    func bloom() {
        let hasher = BloomFilterHasher(bits: 1 << 20, hashes: 7)
        let a = hasher.positions(for: "https://a.example/")
        #expect(a == hasher.positions(for: "https://a.example/"))
        #expect(a.count == 7)
        #expect(a.allSatisfy { (0..<(1 << 20)).contains($0) })
        #expect(a != hasher.positions(for: "https://b.example/"))
    }

    @Test("シャードの割り当てはプロセスが変わっても同じ")
    func routing() {
        let hash = StableHash.url("https://iroiro.dev/")
        #expect(hash == StableHash.url("https://iroiro.dev/"))
        let bucket = ShardRouting.bucket(forURLHash: hash)
        #expect((0..<ShardRouting.bucketCount).contains(bucket))
        #expect(ShardRouting.shard(forBucket: bucket, shardCount: 4) == bucket % 4)
    }
}

@Suite("シャードのインデックス")
struct ShardIndexTests {
    func source(_ path: String, title: String, content: String, pageRank: Double = 0.1, host: String = "iroiro.dev", language: String? = "ja") -> IndexSource {
        IndexSource(
            pageID: UUID(), url: "https://\(host)\(path)", host: host, title: title, description: "", headings: "",
            content: content, anchorText: "", language: language, pageRank: pageRank, hostRank: 0,
            clicks: 0, impressions: 0, changedAt: Date()
        )
    }

    @Test("更新すると古い版は検索されなくなる（トゥームストーン）")
    func update() {
        let page = source("/a", title: "Swift 入門", content: "Swift の基本")
        var index = ShardIndex(sources: [page, source("/b", title: "Vapor", content: "サーバー")])
        #expect(index.documentCount == 2)

        var updated = page
        updated.title = "Rust 入門"
        updated.content = "Rust の基本"
        index.apply(upserts: [updated], removals: [])
        #expect(index.documentCount == 2)
        #expect(index.segmentCount == 2)

        let corpus = index.stats(for: ["swift", "rust"])
        #expect(corpus.documentFrequencies["swift"] == nil)
        #expect(corpus.documentFrequencies["rust"] == 1)
        #expect(index.search(QueryParser.parse("swift"), corpus: corpus, limit: 10).total == 0)
        #expect(index.search(QueryParser.parse("rust"), corpus: corpus, limit: 10).candidates.map(\.url) == ["https://iroiro.dev/a"])

        index.apply(upserts: [], removals: [page.pageID])
        #expect(index.documentCount == 1)
    }

    @Test("シャードに分けても、統計値を合計すれば1つのインデックスと同じ点数になる")
    func distributedIDF() {
        let sources = [
            source("/1", title: "Swift", content: "Swift と Vapor"),
            source("/2", title: "Swift", content: "Swift と SwiftUI"),
            source("/3", title: "Rust", content: "Rust と Tokio"),
            source("/4", title: "Vapor", content: "Vapor の使い方"),
        ]
        let whole = ShardIndex(sources: sources)
        let shards = [ShardIndex(sources: Array(sources[0..<2])), ShardIndex(sources: Array(sources[2..<4]))]
        let query = QueryParser.parse("vapor")

        var corpus = CorpusStats()
        for shard in shards { corpus.merge(shard.stats(for: query.terms)) }
        #expect(corpus == whole.stats(for: query.terms))

        let expected = Dictionary(uniqueKeysWithValues: whole.search(query, corpus: corpus, limit: 10).candidates.map { ($0.url, $0.features.bm25) })
        let actual = Dictionary(uniqueKeysWithValues: shards.flatMap { $0.search(query, corpus: corpus, limit: 10).candidates }.map { ($0.url, $0.features.bm25) })
        #expect(actual == expected)
    }

    @Test("フィルターと除外")
    func filters() {
        let index = ShardIndex(sources: [
            source("/1", title: "Swift Concurrency", content: "async await と actor"),
            source("/2", title: "Swift と Python", content: "Python との比較"),
            source("/3", title: "Swift Guide", content: "English article", host: "example.com", language: "en"),
        ])
        func urls(_ text: String) -> [String] {
            let query = QueryParser.parse(text)
            return index.search(query, corpus: index.stats(for: query.terms), limit: 10).candidates.map(\.url).sorted()
        }
        #expect(urls("swift -python") == ["https://example.com/3", "https://iroiro.dev/1"])
        #expect(urls("swift site:iroiro.dev") == ["https://iroiro.dev/1", "https://iroiro.dev/2"])
        #expect(urls("swift lang:en") == ["https://example.com/3"])
        #expect(urls(#"swift "async await""#) == ["https://iroiro.dev/1"])
    }
}

@Suite("ランキング")
struct RankingTests {
    func item(_ url: String, host: String, score: Double) -> RankedItem {
        RankedItem(pageID: UUID(), shardID: 0, url: url, host: host, title: "", description: "", language: nil,
                   changedAt: Date(), matchedTerms: [], features: RankingFeatures(), score: score)
    }

    @Test("同じホストが上位に並びすぎないようにする")
    func diversify() {
        let items = [
            item("https://a/1", host: "a", score: 5),
            item("https://a/2", host: "a", score: 4),
            item("https://a/3", host: "a", score: 3),
            item("https://b/1", host: "b", score: 2),
        ]
        let result = SearchBroker.diversify(items, maxPerHost: 2).map(\.url)
        #expect(result == ["https://a/1", "https://a/2", "https://b/1", "https://a/3"])
    }

    @Test("Skip Above でペアを作る")
    func pairs() {
        let results = (1...4).map { ImpressionResult(url: "u\($0)", position: $0, features: [Double($0)]) }
        // 3位がクリックされた → (3 > 1), (3 > 2), (3 > 4)
        let pairs = RankerTrainer.makePairs(results: results, clicked: [3])
        #expect(pairs.map(\.difference).sorted { $0[0] < $1[0] } == [[-1], [1], [2]])
    }

    @Test("クリックされやすい特徴量の重みが大きくなるように学習する")
    func training() {
        // クリック率の特徴量だけが高い結果がクリックされ続けたとする
        var good = RankingFeatures()
        good.clickThroughRate = 1
        var bad = RankingFeatures()
        bad.bm25 = 0.5
        let pairs = (0..<200).map { _ in RankerTrainer.Pair(difference: zip(good.vector, bad.vector).map { $0 - $1 }) }

        let before = RankerTrainer.accuracy(.default, pairs)
        let model = RankerTrainer.train(pairs: pairs, initial: .default, epochs: 10, learningRate: 0.1, regularization: 0.001)
        let after = RankerTrainer.accuracy(model, pairs)
        #expect(after >= before)
        #expect(after == 1)
        let ctr = RankingFeatures.names.firstIndex(of: "clickThroughRate")!
        #expect(model.weights[ctr] > RankingModel.default.weights[ctr])
    }
}

@Suite("除外の解析")
struct ExclusionTests {
    @Test("キャメルケースの語は単語全体だけを除外する")
    func camelCase() {
        let query = QueryParser.parse("Swift -SwiftUI")
        #expect(query.terms == ["swift"])
        #expect(query.excluded == ["swiftui"])
    }

    @Test("日本語はバイグラムで除外する")
    func japanese() {
        #expect(QueryParser.parse("Swift -入門書").excluded == ["入門", "門書"])
    }
}
