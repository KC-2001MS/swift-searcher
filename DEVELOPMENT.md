# 開発について

💧 A project built with the Vapor web framework.

## Getting Started

```bash
swift build      # ビルド
swift test       # テスト（Postgres・Redis・ネットワークは使わない）
```

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)

## ローカルで1プロセスで動かす（role=all）

Postgres だけ用意すれば、Redis 無しでも1プロセスで全部の役割を動かせます（フロンティアなどはメモリに置かれます）。

```bash
docker compose up -d db
swift run App serve --port 8080
```

起動するとシード（既定は https://iroiro.dev/ ）から巡回を始めます。巡回したくない場合は
`CRAWLER_WORKER_CONCURRENCY` を小さくするか、`APP_ROLE=api` で起動してください。

```bash
curl http://localhost:8080/status
curl -G http://localhost:8080/search --data-urlencode "q=Swift"
```

設定はリポジトリ直下に `.env`（または `.env.development`）を作ると読み込まれます。

```bash
# .env の例
SEARCHER_SEEDS=https://iroiro.dev/
SEARCHER_ADMIN_TOKEN=local-secret
CRAWLER_MAX_PAGES_PER_HOST=100
INDEX_SHARD_COUNT=2
LOG_LEVEL=debug
```

## Docker Compose で分散構成を動かす

`docker-compose.yml` は、api・shard×2・worker×2・scheduler・Postgres・Redis を別々のコンテナで動かします。

```bash
docker compose build
docker compose up -d db redis
docker compose run --rm migrate
docker compose up api shard-0 shard-1 worker scheduler
```

バッチ処理は必要なときに実行します。

```bash
docker compose run --rm link-analysis   # PageRank・HostRank を計算する
docker compose run --rm train-ranker    # 検索ログからランキングモデルを学習する
```

計算した PageRank は、シャードが次にインデックスを作り直したときに反映されます。すぐに反映したい場合は次のようにします。

```bash
curl -X POST -H "Authorization: Bearer $SEARCHER_ADMIN_TOKEN" http://shard-0:8080/internal/shard/rebuild
```

## 本番に近い構成にする場合

| 部品 | 例 |
| --- | --- |
| api / shard / worker / scheduler | Kubernetes の Deployment（shard はシャードごとに StatefulSet にするとよい） |
| Postgres | Cloud SQL・Amazon RDS など。pages と links は数億行になるので、パーティショニングを検討する |
| Redis | Memorystore・ElastiCache など。フロンティアを失わないよう永続化する |
| link-analysis / train-ranker | Kubernetes の CronJob・Cloud Run Jobs など |

## テスト

テストは [Swift Testing](https://developer.apple.com/documentation/testing) と `VaporTesting` で書いています。

- データベースはメモリ上の SQLite、フロンティア・重複検出はメモリ上の実装を使います
- ページの取得は `MockFetcher`（`Tests/AppTests/CrawlerTests.swift`）が用意した小さなサイトを返します
- シャードは同じプロセスの中で動かし、ブローカーから問い合わせます

## プロジェクトの構成

```text
Sources/App
├── entrypoint.swift             起動処理
├── configure.swift              データベース・Redis・役割ごとのサービスの設定
├── routes.swift                 ルーティング
├── Config
│   └── SearcherConfiguration.swift  役割と設定（環境変数から読み込む）
├── Crawler
│   ├── CrawlWorker.swift        クロールワーカー（取得・解析・保存）
│   ├── Frontier.swift           フロンティアのプロトコルとメモリ上の実装
│   ├── RedisFrontier.swift      Redis の分散フロンティアとブルームフィルター
│   ├── RecrawlScheduler.swift   再訪問スケジューラー
│   ├── CrawlPolicy.swift        巡回範囲・クローラートラップ・再訪問の間隔
│   ├── RobotsService.swift      robots.txt の取得と共有
│   ├── DuplicateDetector.swift  重複ページの検出
│   ├── SimHash.swift            SimHash
│   ├── WorkerRegistry.swift     ワーカーの生存確認
│   ├── PageFetcher.swift        HTTP でのページ取得
│   ├── HTMLExtractor.swift      HTML とサイトマップの解析
│   ├── RobotsTxt.swift          robots.txt の解析と判定
│   └── URLNormalizer.swift      URL の正規化
├── Index
│   ├── Tokenizer.swift          文章を検索語に分割
│   ├── InvertedIndex.swift      転置インデックスのセグメント
│   ├── ShardIndex.swift         シャードのインデックス（セグメント・トゥームストーン・BM25F）
│   ├── ShardService.swift       シャードの構築と差分の取り込み
│   └── Snippet.swift            検索結果の抜粋
├── Search
│   ├── Query.swift              クエリの解析と同義語
│   ├── RankingModel.swift       特徴量とランキングモデル
│   ├── SearchBroker.swift       全シャードへの問い合わせと順位付け
│   ├── ShardClient.swift        シャードとの通信（同じプロセス / HTTP）
│   └── SearchLogger.swift       検索ログ・クリック・サジェスト
├── Ranking
│   ├── PageRank.swift           PageRank（CSR 形式）
│   ├── LinkAnalysisJob.swift    PageRank・HostRank のバッチ処理
│   └── RankerTrainer.swift      クリックからの学習（Learning to Rank）
├── Support                      ハッシュ・Redis・サービスの登録と起動
├── Commands                     link-analysis / train-ranker / seed
├── Controllers                  API（検索・シャード・管理・状態）
├── Models                       Page / Link / Host / Seed / 検索ログ
└── Migrations                   テーブルの作成
```
