# Swift Searcher
Web を巡回して検索インデックスを作り、検索結果を JSON で返す API です。
[swift-crawler](https://github.com/KC-2001MS/swift-crawler) と同じ仕組みを土台に、
**大規模な検索エンジンと同じ構成（フルスペック）** で作り直したものです。

> [!NOTE]
> 実装を試すためのプロジェクトです。実際に動かすとサーバー代がかかるので、どこにもデプロイしていません。
> `docker compose` で手元に同じ構成を再現できるようにしてあります。

## Description

swift-crawler は「1つのサイトを1台で巡回し、SQLite とメモリで検索する」学習用の構成でした。
Swift Searcher では、swift-crawler の README の「大規模なクローラーとの違い」で簡略化していた部分を実装しています。

| | swift-crawler | Swift Searcher |
| --- | --- | --- |
| 巡回範囲 | iroiro.dev だけ | シードのホスト / 許可リスト / Web 全体（`CRAWLER_SCOPE`） |
| 巡回する台数 | 1台・1件ずつ順番に | 何台でも。各ワーカーの中でも数十件を並行に取得 |
| フロンティア | メモリ上の配列 | Redis の分散フロンティア（ホストごとの待ち行列 + ホストの貸し出し） |
| URL の重複除去 | `Set<String>` | Redis 上のブルームフィルター（1億 URL でも 128MB） |
| 重複ページ | SHA-256 の完全一致 | SHA-256 + SimHash による「ほぼ同じ内容」の検出 |
| 再巡回 | 3ヶ月ごとにサイト全体 | ページごとに更新頻度を学習して間隔を変える（適応的な再訪問） |
| 保存先 | SQLite | Postgres（ページ・リンク・ホスト・検索ログ） |
| インデックス | 1つのメモリ上のインデックス | 複数のシャードに分割・レプリカで冗長化。差分はセグメントで追加 |
| IDF | 1つのインデックスの値 | 全シャードの統計値を集めてからスコアを計算（分散 IDF） |
| ランキング | BM25F + PageRank | BM25F・PageRank・HostRank・新しさ・クリック率など 12 の特徴量を線形モデルで合成 |
| 学習 | なし | クリックログから重みを学習（Learning to Rank） |
| クエリ | 語の並び | `"フレーズ"`・`-除外`・`site:`・`lang:`・同義語 |
| その他 | | 検索結果のキャッシュ、ホストクラウディング、サジェスト、クリック計測 |

### 全体の構成

同じ実行ファイルを、環境変数 `APP_ROLE` で役割を切り替えて起動します。役割ごとに必要な台数だけ増やせます。

```text
                       ┌───────────────────────────────┐
  Cloud Scheduler 等 ─▶ │ scheduler（1台）                │  シード・再訪問の時期が来たページを入れる
                       └──────────────┬────────────────┘
                                      ▼
                       ┌───────────────────────────────┐
                       │ Redis                          │  分散フロンティア・ブルームフィルター
                       │                                │  重複検出（SimHash の帯）・検索結果のキャッシュ
                       └──────┬─────────────────▲──────┘
                    ① URL を借りる│                 │⑤ 見つけたリンク
                       ┌──────▼─────────────────┴──────┐
  インターネット ◀──②──│ worker（N台 × 並行数）          │  robots.txt・取得・解析・重複判定
                       └──────────────┬────────────────┘
                                      │③ 保存
                       ┌──────────────▼────────────────┐
                       │ Postgres                       │  pages / links / hosts / seeds / 検索ログ
                       └───┬───────────────────────▲───┘
           ④ 差分を取り込む  │                       │ link-analysis（PageRank・HostRank）
          ┌────────────────┼──────────────┐        │ train-ranker（クリックから学習）
          ▼                ▼              ▼        │
   ┌───────────┐   ┌───────────┐   ┌───────────┐   │
   │ shard-0   │   │ shard-1   │   │ shard-N   │   │  担当するページの転置インデックス（レプリカ可）
   └─────▲─────┘   └─────▲─────┘   └─────▲─────┘   │
         └───────────────┼───────────────┘         │
                  ┌──────┴──────┐                   │
  ユーザー ───────▶│ api（N台）   │───────────────────┘  検索ログを記録
                  └─────────────┘
```

| 役割（`APP_ROLE`） | 内容 | 台数 |
| --- | --- | --- |
| `api` | 検索 API（ブローカー）。全シャードに問い合わせ、結果をまとめて順位を決める | 何台でも |
| `shard` | インデックスシャード。`INDEX_SHARD_ID` 番のシャードを担当する | シャード数 × レプリカ数 |
| `worker` | クロールワーカー。フロンティアから URL を取り出して巡回する | 何台でも |
| `scheduler` | 再訪問スケジューラー | 1台 |
| `all` | 開発用。上のすべてを1プロセスで動かす（Redis が無ければメモリ上で動く） | 1台 |

バッチ処理はコマンドで実行します（cron などで定期的に実行する想定）。

| コマンド | 内容 |
| --- | --- |
| `App migrate` | テーブルを作る |
| `App link-analysis` | 全ページ・全リンクから PageRank と HostRank を計算する |
| `App train-ranker` | 検索ログからランキングモデルを学習し、新しいバージョンとして保存する |
| `App seed <url>` | シードを追加する |

### クローラー

| 処理 | 内容 | 実装 |
| --- | --- | --- |
| 分散フロンティア | Redis に「ホストごとの待ち行列」と「次にアクセスしてよい時刻順のホスト一覧」を置く（Mercator 方式）。ワーカーはホストを借りて URL を取り出し、Crawl-delay 後の時刻を付けて返す。取り出し・貸し出しは Lua スクリプトでアトミックに行う | `Crawler/Frontier.swift`, `Crawler/RedisFrontier.swift` |
| 礼儀正しさ | 同じホストには同時に1つのワーカーしかアクセスしない。待ち時間は設定値と robots.txt の Crawl-delay の長い方。429・5xx が続くホストは間隔を広げる | `Crawler/CrawlWorker.swift` |
| ワーカーの障害 | ホストの貸し出しには期限があり、ワーカーが落ちても他のワーカーが引き継ぐ | `Crawler/RedisFrontier.swift` |
| URL の重複除去 | ブルームフィルター（ダブルハッシュ法で k 個のビット位置を計算）。偽陽性 1% 未満で、URL を保存するよりはるかに少ないメモリで済む | `Crawler/RedisFrontier.swift` |
| robots.txt | ホストごとに Postgres に保存して全ワーカーで共有し、24時間キャッシュする | `Crawler/RobotsService.swift` |
| サイトマップ | robots.txt を取得し直すたびにサイトマップをフロンティアに入れ、新しいページを見つける | `Crawler/CrawlWorker.swift` |
| 重複ページ | SHA-256 で完全一致、SimHash のハミング距離 3 以下で「ほぼ同じ」と判定する。SimHash は 16 ビットずつ4つの帯に分けて Redis に索引を作り、全ページと比べずに候補を探す | `Crawler/SimHash.swift`, `Crawler/DuplicateDetector.swift` |
| 適応的な再訪問 | 取得し直すたびに、内容が変わっていれば間隔を半分に、変わっていなければ 1.5 倍にする（1日〜90日） | `Crawler/CrawlPolicy.swift` |
| クローラートラップ | 同じパスの繰り返し・深すぎるパス・多すぎるクエリパラメータ・長すぎる URL を避ける | `Crawler/CrawlPolicy.swift` |
| ホストの上限 | 1つのホストから取得するページ数と、待ち行列に溜める URL 数に上限を設ける | `Crawler/CrawlWorker.swift` |

### インデックス

- **シャーディング**: URL のハッシュ値でページを 1024 個のバケットに分け、`バケット % シャード数` でシャードを決めます。シャード数を変えてもデータベースを書き換える必要はありません（`Support/StableHash.swift`）
- **セグメント**: シャードは1分ごとに `updated_at` が新しいページだけを読み、新しいセグメントとして追加します。古いセグメントの同じページには「削除済み」の印（トゥームストーン）を付けます。セグメントが増えたら1つにまとめ直します（`Index/ShardIndex.swift`）
- **レプリカ**: 同じシャードを複数台で動かすと、ブローカーが順番に問い合わせ（ラウンドロビン）、応答しなければ次のレプリカに切り替えます（`Search/ShardClient.swift`）

### 検索とランキング

```text
① 統計値を集める   全シャードから「検索語を含む文書の数」などを集めて合計する（分散 IDF）
② 候補を集める     合計した統計値を渡し、各シャードに BM25F と特徴量を計算させ、上位 200 件を返させる
③ 順位を決める     ランキングモデルで点数を付け、同じホストが上位に並びすぎないよう調整する
④ 抜粋を作る       表示する結果を持っているシャードにだけ抜粋を問い合わせる
```

応答しないシャードがあっても、残りのシャードの結果で返します（`partial: true`）。

ランキングモデルは次の 12 個の特徴量の重み付きの和です（`Search/RankingModel.swift`）。

| 特徴量 | 内容 |
| --- | --- |
| `bm25` | 検索語との関連度（BM25F。タイトル・見出し・説明・被リンクのアンカーテキスト・URL・本文の重み付き） |
| `coverage` / `titleCoverage` / `anchorCoverage` | 検索語のうち、ページ・タイトル・アンカーテキストに含まれていた割合 |
| `phraseInTitle` / `phraseInBody` | 検索文字列がそのまま含まれていたか |
| `pageRank` / `hostRank` | リンク構造から求めたページ・サイトの重要度 |
| `freshness` | 内容が最後に変わってからの日数で減衰する新しさ |
| `shallowness` | URL の浅さ |
| `clickThroughRate` | クリック率（表示回数が少ないうちは事前の値に寄せる） |
| `languageMatch` | 検索語とページの言語が合っているか |

重みは最初は手で決めた値を使い、検索ログが溜まったら `App train-ranker` で学習し直します。
「クリックされた結果は、その上にあるのに飛ばされた結果より良い」（Skip Above）というペアを作り、
ロジスティック回帰で重みを調整します（`Ranking/RankerTrainer.swift`）。
検索 API は新しいモデルを 10 分ごとに読み込みます。

### API

すべて JSON を返します。

| メソッド | パス | 内容 |
| --- | --- | --- |
| GET | `/` | API の情報 |
| GET | `/search?q={検索語}&page=1&per=10&explain=false` | 検索（`per` は最大 50、`page` は最大 100） |
| GET | `/click?i={impressionID}&p={順位}&u={URL}` | クリックを記録して移動する（表示した URL にだけ移動する） |
| GET | `/suggest?q={入力途中の文字列}` | よく検索されている検索語の候補（5回以上検索されたものだけ） |
| GET | `/status` | フロンティア・ワーカー・シャード・ページ数 |
| GET | `/pages?host={host}&page=1&per=20` | 保存済みのページを PageRank の高い順に返す |
| GET | `/pages/{id}` | ページの詳細（本文・リンク元・リンク先・担当シャード） |
| GET / POST / DELETE | `/admin/seeds` | シードの一覧・追加・削除（Bearer トークンが必要） |
| POST | `/admin/recrawl` | URL をすぐに取得し直す（Bearer トークンが必要） |
| POST | `/admin/hosts/{host}/block` | ホストの巡回を止める（Bearer トークンが必要） |
| POST | `/internal/shard/*` | シャードの内部 API（ブローカーが使う） |
| GET | `/health` | ヘルスチェック |

```console
$ curl -G "http://localhost:8080/search" --data-urlencode 'q=Swift "async await" -python site:iroiro.dev' --data-urlencode "explain=true"
```

```json
{
  "query": "Swift \"async await\" -python site:iroiro.dev",
  "terms": ["swift", "async", "await"],
  "phrases": ["async await"],
  "excluded": ["python"],
  "site": "iroiro.dev",
  "total": 3,
  "page": 1,
  "per": 10,
  "partial": false,
  "cached": false,
  "modelVersion": 0,
  "impressionID": "6F1C…",
  "tookMs": 1.23,
  "results": [
    {
      "rank": 1,
      "url": "https://iroiro.dev/...",
      "clickURL": "/click?i=6F1C…&p=1&u=https://iroiro.dev/...",
      "title": "...",
      "description": "...",
      "snippet": "…async await で…",
      "score": 2.871,
      "changedAt": "2026-10-03T18:00:00Z",
      "explain": {
        "shardID": 1,
        "matchedTerms": ["swift", "async", "await"],
        "features": { "bm25": 1.42, "coverage": 1, "titleCoverage": 0.33, "pageRank": 0.41, "...": 0 }
      }
    }
  ]
}
```

### 設定

| 環境変数 | 既定値 | 内容 |
| --- | --- | --- |
| `APP_ROLE` | `all` | 役割（`api` / `shard` / `worker` / `scheduler` / `all`） |
| `DATABASE_URL` | なし | Postgres の接続先（無ければ `DATABASE_HOST` などを使う） |
| `REDIS_URL` | なし | Redis の接続先。無ければフロンティアなどをメモリに置く（1台でしか巡回できない） |
| `AUTO_MIGRATE` | role が `all` なら `true` | 起動時にマイグレーションするか |
| `SEARCHER_SEEDS` | `https://iroiro.dev/` | 最初のシード（カンマ区切り） |
| `SEARCHER_ADMIN_TOKEN` | なし | 管理 API・シャードの内部 API のトークン |
| `CRAWLER_SCOPE` | `seed-hosts` | 巡回範囲（`seed-hosts` / `allowlist` / `web`） |
| `CRAWLER_ALLOWED_HOSTS` / `CRAWLER_BLOCKED_HOSTS` | なし | 巡回してよい・いけないホスト（サブドメインを含む） |
| `CRAWLER_MAX_DEPTH` | `16` | シードからたどる最大の深さ |
| `CRAWLER_MAX_PAGES_PER_HOST` | `50000` | 1つのホストから取得する最大ページ数 |
| `CRAWLER_MIN_HOST_DELAY_MS` | `1000` | 同じホストへのリクエストの最小間隔 |
| `CRAWLER_WORKER_CONCURRENCY` | `32` | 1台のワーカーで並行して処理する数 |
| `CRAWLER_REVISIT_MAX_DAYS` | `90` | 再訪問の最大間隔（日） |
| `CRAWLER_BLOOM_BITS` | `1073741824` | ブルームフィルターのビット数 |
| `INDEX_SHARD_COUNT` | `2` | シャード数 |
| `INDEX_SHARD_ID` | `0` | 担当するシャード（role が `shard` のとき） |
| `INDEX_REFRESH_SECONDS` | `60` | 変更されたページを取り込む間隔 |
| `SEARCH_SHARDS` | なし | シャードの URL（`;` でシャード、`,` でレプリカを区切る）。無ければ同じプロセスでシャードを動かす |
| `SEARCH_SHARD_TIMEOUT_MS` | `800` | シャードへの問い合わせのタイムアウト |
| `SEARCH_MAX_RESULTS_PER_HOST` | `2` | 同じホストを上位に並べる最大数 |
| `SEARCH_CACHE_SECONDS` | `300` | 検索結果のキャッシュ時間（Redis があるとき） |
| `SEARCH_LOG_QUERIES` | `true` | 検索ログ（表示・クリック）を記録するか |
| `SEARCH_SYNONYMS` | なし | 追加の同義語（例: `ios,iphone;swift,スウィフト`） |

### まだ実装していないこと

フルスペックといっても、実際の検索エンジンとは次の点が異なります。

- **日本語の分割**: バイグラムのままです（形態素解析には辞書が必要なため）。そのため日本語の同義語も扱えません
- **インデックスの保存**: シャードは起動時に Postgres から作り直します。数億ページになると、ディスク上のインデックス（転置インデックスのファイル）が必要です
- **リンク解析の分散**: PageRank は1台のメモリで計算します（CSR 形式で1リンク 4 バイト）。Web 全体なら Spark などで分散計算します
- **Redis Cluster**: Lua スクリプトで複数のキーを触るので、Redis Cluster で使うにはキーにハッシュタグ（`{...}`）が必要です
- **その他**: DNS のキャッシュ、JavaScript で描画されるページの取得、スパム判定、画像検索などはありません

## Requirement

- Swift 6.3 以降（Docker イメージは Swift 6.4 でビルド）
- macOS 14 以降、または Linux（Ubuntu 24.04 など）
- Postgres 16 / Redis 7
- [Vapor](https://vapor.codes) 4 / [Fluent](https://github.com/vapor/fluent) / [Redis](https://github.com/vapor/redis) / [SwiftSoup](https://github.com/scinfu/SwiftSoup)

ビルド・実行・テストの方法は [DEVELOPMENT.md](DEVELOPMENT.md) にまとめています。

## Licence

## Supporting

## Author
[KC-2001MS](https://github.com/KC-2001MS)
