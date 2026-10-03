import Foundation

/// 検索対象のフィールド。フィールドごとに重みを変えることで
/// 「タイトルに含まれる語は本文に含まれる語より重要」といった判断を表現する。
enum SearchField: Int, CaseIterable, Sendable {
    case title
    case headings
    case description
    case anchor
    case url
    case body

    /// フィールドの重み（BM25F の w）
    var weight: Double {
        switch self {
        case .title: 5.0
        case .headings: 2.5
        case .description: 2.0
        case .anchor: 3.0
        case .url: 1.5
        case .body: 1.0
        }
    }

    /// 文書長による正規化の強さ（BM25F の b）。0 で正規化しない、1 で完全に正規化する
    var lengthNormalization: Double {
        switch self {
        case .title, .url: 0.5
        case .headings, .description, .anchor: 0.6
        case .body: 0.75
        }
    }
}

/// インデックスを作るための入力
struct IndexSource: Sendable {
    var pageID: UUID
    var url: String
    var host: String
    var title: String
    var description: String
    var headings: String
    var content: String
    /// このページを指すリンクのアンカーテキスト（他のページがこのページをどう呼んでいるか）
    var anchorText: String
    var language: String?
    var pageRank: Double
    var hostRank: Double
    var clicks: Int
    var impressions: Int
    var changedAt: Date
}

/// インデックスに登録された文書
struct IndexedDocument: Sendable {
    var pageID: UUID
    var url: String
    var host: String
    var title: String
    var description: String
    /// 抜粋（スニペット）を作るための本文
    var content: String
    var language: String?
    var pageRank: Double
    var hostRank: Double
    var clicks: Int
    var impressions: Int
    var changedAt: Date
    /// URL のパスの深さ（`/a/b/` なら 2）
    var pathDepth: Int
    /// フレーズ一致の判定用に正規化したタイトル
    var normalizedTitle: String
    /// フレーズ一致の判定用に正規化した本文など
    var normalizedText: String
    /// フィールドごとのトークン数
    var fieldLengths: [Int]
}

/// 転置インデックスの1項目（ある語が、ある文書の各フィールドに何回出現したか）
struct Posting: Sendable {
    var document: Int
    var termFrequencies: [Int]
}

/// 転置インデックスの「セグメント」。
///
/// 「文書 → 含まれる語」ではなく「語 → その語を含む文書の一覧」の形で持つことで、
/// 検索語を含む文書を全文書を走査せずに高速に見つけられる。
///
/// ```text
/// "swift"  → [文書0 (title:1, body:5), 文書3 (body:2)]
/// "検索"   → [文書1 (title:1, body:3)]
/// ```
///
/// セグメントは一度作ったら変更しない（イミュータブル）。ページが追加・更新されたら
/// 新しいセグメントを作り、古いセグメントの該当文書は「削除済み」の印（トゥームストーン）を付けて無視する。
/// これは Lucene（Elasticsearch の中身）と同じ考え方で、インデックス全体を作り直さずに更新を反映できる。
struct IndexSegment: Sendable {
    private(set) var documents: [IndexedDocument] = []
    private(set) var postings: [String: [Posting]] = [:]
    /// フィールドごとのトークン数の合計
    private(set) var fieldLengthTotals: [Int] = Array(repeating: 0, count: SearchField.allCases.count)

    init(sources: [IndexSource]) {
        let fieldCount = SearchField.allCases.count

        for source in sources {
            let docIndex = documents.count
            let fieldTexts: [SearchField: String] = [
                .title: source.title,
                .headings: source.headings,
                .description: source.description,
                .anchor: source.anchorText,
                .url: Self.urlText(source.url),
                .body: source.content,
            ]

            // この文書での「語 → フィールドごとの出現回数」を数える
            var frequencies: [String: [Int]] = [:]
            var lengths = [Int](repeating: 0, count: fieldCount)
            for field in SearchField.allCases {
                let tokens = Tokenizer.tokenize(fieldTexts[field] ?? "")
                lengths[field.rawValue] = tokens.count
                for token in tokens {
                    frequencies[token, default: [Int](repeating: 0, count: fieldCount)][field.rawValue] += 1
                }
            }
            // 「文書 → 語」の集計を「語 → 文書」の向きにひっくり返して登録する。これが「転置」の意味
            for (term, tf) in frequencies {
                postings[term, default: []].append(Posting(document: docIndex, termFrequencies: tf))
            }
            for i in 0..<fieldCount { fieldLengthTotals[i] += lengths[i] }

            documents.append(IndexedDocument(
                pageID: source.pageID,
                url: source.url,
                host: source.host,
                title: source.title,
                description: source.description,
                content: source.content,
                language: source.language,
                pageRank: source.pageRank,
                hostRank: source.hostRank,
                clicks: source.clicks,
                impressions: source.impressions,
                changedAt: source.changedAt,
                pathDepth: URLComponents(string: source.url)?.path.split(separator: "/").count ?? 0,
                normalizedTitle: Tokenizer.normalize(source.title),
                normalizedText: Tokenizer.normalize([source.headings, source.description, source.content].joined(separator: "\n")),
                fieldLengths: lengths
            ))
        }
    }

    /// URL を検索対象の文字列にする（ホストとパスの区切りを空白に置き換える）
    ///
    /// 例: `https://iroiro.dev/blog/swift-concurrency/` → `iroiro dev  blog swift concurrency `
    static func urlText(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        let path = components.path.removingPercentEncoding ?? components.path
        return ((components.host ?? "") + path).map { "/-_.".contains($0) ? " " : String($0) }.joined()
    }
}
