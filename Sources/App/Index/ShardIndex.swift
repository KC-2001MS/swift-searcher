import Foundation

/// 全シャードを合わせた統計値。
///
/// BM25 の IDF（その語を含む文書がどれだけ珍しいか）や文書の平均の長さを、各シャードが自分の分だけで
/// 計算すると、シャードごとに点数の基準がずれてしまう（あるシャードでは珍しい語が、全体ではありふれているなど）。
/// そこでブローカーが先に全シャードの統計値を集めて合計し、それを使って各シャードに点数を計算させる。
struct CorpusStats: Codable, Sendable, Equatable {
    /// 文書数
    var documentCount: Int = 0
    /// 語 → その語を含む文書の数
    var documentFrequencies: [String: Int] = [:]
    /// フィールドごとのトークン数の合計
    var fieldLengthTotals: [Int] = Array(repeating: 0, count: SearchField.allCases.count)
    var maxPageRank: Double = 0
    var maxHostRank: Double = 0

    /// 複数のシャードの統計値を足し合わせる
    mutating func merge(_ other: CorpusStats) {
        documentCount += other.documentCount
        for (term, df) in other.documentFrequencies {
            documentFrequencies[term, default: 0] += df
        }
        for i in fieldLengthTotals.indices where i < other.fieldLengthTotals.count {
            fieldLengthTotals[i] += other.fieldLengthTotals[i]
        }
        maxPageRank = max(maxPageRank, other.maxPageRank)
        maxHostRank = max(maxHostRank, other.maxHostRank)
    }

    func averageLength(_ field: SearchField) -> Double {
        guard documentCount > 0 else { return 1 }
        return max(Double(fieldLengthTotals[field.rawValue]) / Double(documentCount), 1)
    }

    /// IDF（逆文書頻度）: その語を含む文書が少ないほど大きくなる
    func idf(_ term: String) -> Double {
        let n = Double(documentCount)
        let df = Double(documentFrequencies[term] ?? 0)
        return log(1 + (n - df + 0.5) / (df + 0.5))
    }
}

/// シャードが返す検索結果の候補
struct SearchCandidate: Codable, Sendable, Equatable {
    var pageID: UUID
    var url: String
    var host: String
    var title: String
    var description: String
    var language: String?
    var changedAt: Date
    var matchedTerms: [String]
    var features: RankingFeatures
    /// シャードの中での仮の点数（候補を絞り込むために使う）
    var preliminaryScore: Double
}

/// 1つのシャードが持つインデックス（複数のセグメントの集まり）。
///
/// ```text
///  セグメント0（起動時に作成）   セグメント1（1分後の差分）   セグメント2（2分後の差分）
///  ┌──────────────────┐      ┌──────────────────┐       ┌──────────────────┐
///  │ 文書A 文書B ✕文書C │      │ 文書C（更新後）     │       │ 文書D              │
///  └──────────────────┘      └──────────────────┘       └──────────────────┘
///                  ✕ = 新しいセグメントに更新版があるので無視する（トゥームストーン）
/// ```
///
/// セグメントが増えすぎると検索が遅くなるので、一定数を超えたら1つにまとめ直す（マージ）。
struct ShardIndex: Sendable {
    private(set) var segments: [IndexSegment] = []
    /// セグメントごとの削除済み文書の番号
    private(set) var deleted: [Set<Int>] = []
    /// ページ ID → 最新版がある場所（セグメント番号, 文書番号）
    private(set) var locations: [UUID: (segment: Int, document: Int)] = [:]
    /// 有効な文書のフィールドごとのトークン数の合計
    private(set) var liveFieldLengthTotals = [Int](repeating: 0, count: SearchField.allCases.count)
    private(set) var maxPageRank: Double = 0
    private(set) var maxHostRank: Double = 0

    var documentCount: Int { locations.count }
    var segmentCount: Int { segments.count }
    var termCount: Int { segments.reduce(0) { $0 + $1.postings.count } }

    init() {}

    init(sources: [IndexSource]) {
        apply(upserts: sources, removals: [])
    }

    /// 追加・更新されたページで新しいセグメントを作り、削除されたページに印を付ける
    mutating func apply(upserts: [IndexSource], removals: [UUID]) {
        for pageID in removals + upserts.map(\.pageID) {
            tombstone(pageID)
        }
        guard !upserts.isEmpty else { return }

        let segment = IndexSegment(sources: upserts)
        let segmentIndex = segments.count
        segments.append(segment)
        deleted.append([])
        for (i, document) in segment.documents.enumerated() {
            // 同じページが1回の差分に2回含まれていた場合は後の方を使う
            if let previous = locations[document.pageID], previous.segment == segmentIndex {
                deleted[segmentIndex].insert(previous.document)
                subtractLengths(segment.documents[previous.document])
            }
            locations[document.pageID] = (segmentIndex, i)
            for field in SearchField.allCases {
                liveFieldLengthTotals[field.rawValue] += document.fieldLengths[field.rawValue]
            }
            maxPageRank = max(maxPageRank, document.pageRank)
            maxHostRank = max(maxHostRank, document.hostRank)
        }
    }

    private mutating func tombstone(_ pageID: UUID) {
        guard let location = locations.removeValue(forKey: pageID) else { return }
        deleted[location.segment].insert(location.document)
        subtractLengths(segments[location.segment].documents[location.document])
    }

    private mutating func subtractLengths(_ document: IndexedDocument) {
        for field in SearchField.allCases {
            liveFieldLengthTotals[field.rawValue] -= document.fieldLengths[field.rawValue]
        }
    }

    private func isLive(segment: Int, document: Int) -> Bool {
        !deleted[segment].contains(document)
    }

    /// 有効な文書（マージで1つのセグメントにまとめ直すときに使う）
    var liveDocuments: [IndexedDocument] {
        locations.values.map { segments[$0.segment].documents[$0.document] }
    }

    // MARK: - 統計値

    /// 検索語ごとの文書頻度など、このシャードの統計値
    func stats(for terms: [String]) -> CorpusStats {
        var stats = CorpusStats()
        stats.documentCount = documentCount
        stats.fieldLengthTotals = liveFieldLengthTotals
        stats.maxPageRank = maxPageRank
        stats.maxHostRank = maxHostRank
        for term in Set(terms) {
            var df = 0
            for (s, segment) in segments.enumerated() {
                guard let postings = segment.postings[term] else { continue }
                df += deleted[s].isEmpty ? postings.count : postings.filter { isLive(segment: s, document: $0.document) }.count
            }
            if df > 0 { stats.documentFrequencies[term] = df }
        }
        return stats
    }

    // MARK: - 検索

    /// 検索語を含む文書を探し、特徴量を計算して上位 `limit` 件を返す
    func search(_ query: ParsedQuery, corpus: CorpusStats, limit: Int, now: Date = Date(), k1: Double = 1.2) -> (total: Int, candidates: [SearchCandidate]) {
        guard !query.terms.isEmpty, documentCount > 0 else { return (0, []) }

        struct Accumulator {
            var bm25 = 0.0
            var matched: [String] = []
            var titleMatches = 0
            var anchorMatches = 0
        }
        /// (セグメント, 文書) → 集計
        var accumulators: [Int: [Int: Accumulator]] = [:]

        // 除外する語を含む文書
        var excluded: [Int: Set<Int>] = [:]
        for term in query.excluded {
            for (s, segment) in segments.enumerated() {
                for posting in segment.postings[term] ?? [] {
                    excluded[s, default: []].insert(posting.document)
                }
            }
        }

        for term in query.terms {
            // 元の語と同義語のうち、文書ごとに最も点数の高いものを使う（同義語は 0.7 倍）
            let variants = [(term, 1.0)] + (query.synonyms[term] ?? []).map { ($0, 0.7) }
            var best: [Int: [Int: (score: Double, title: Bool, anchor: Bool)]] = [:]
            for (variant, factor) in variants {
                let idf = corpus.idf(variant)
                for (s, segment) in segments.enumerated() {
                    guard let postings = segment.postings[variant] else { continue }
                    for posting in postings where isLive(segment: s, document: posting.document) {
                        let document = segment.documents[posting.document]
                        // BM25F: フィールドごとに長さで正規化した出現回数を重み付きで合計する
                        //
                        //   weightedTF = Σ weight × tf / (1 - b + b × 長さ / 平均の長さ)
                        //   score      = idf × weightedTF / (k1 + weightedTF)
                        var weightedTF = 0.0
                        for field in SearchField.allCases {
                            let tf = Double(posting.termFrequencies[field.rawValue])
                            guard tf > 0 else { continue }
                            let b = field.lengthNormalization
                            let length = Double(document.fieldLengths[field.rawValue])
                            weightedTF += field.weight * tf / (1 - b + b * length / corpus.averageLength(field))
                        }
                        let score = factor * idf * weightedTF / (k1 + weightedTF)
                        if score > best[s]?[posting.document]?.score ?? -1 {
                            best[s, default: [:]][posting.document] = (
                                score,
                                posting.termFrequencies[SearchField.title.rawValue] > 0,
                                posting.termFrequencies[SearchField.anchor.rawValue] > 0
                            )
                        }
                    }
                }
            }
            for (s, documents) in best {
                for (d, value) in documents {
                    var accumulator = accumulators[s]?[d] ?? Accumulator()
                    accumulator.bm25 += value.score
                    accumulator.matched.append(term)
                    if value.title { accumulator.titleMatches += 1 }
                    if value.anchor { accumulator.anchorMatches += 1 }
                    accumulators[s, default: [:]][d] = accumulator
                }
            }
        }

        let termCount = Double(query.terms.count)
        var candidates: [SearchCandidate] = []
        for (s, documents) in accumulators {
            for (d, accumulator) in documents {
                if excluded[s]?.contains(d) == true { continue }
                let document = segments[s].documents[d]
                // フィルター: site: / lang: / 引用符のフレーズ
                if let site = query.site, !URLNormalizer.host(document.host, isWithin: site) { continue }
                if let language = query.language, !(document.language?.lowercased().hasPrefix(language) ?? false) { continue }
                if !query.phrases.allSatisfy({ document.normalizedTitle.contains($0) || document.normalizedText.contains($0) }) { continue }

                let features = Self.features(
                    document: document,
                    accumulator: (accumulator.bm25, accumulator.matched.count, accumulator.titleMatches, accumulator.anchorMatches),
                    termCount: termCount,
                    query: query,
                    corpus: corpus,
                    now: now
                )
                // 仮の点数: 関連度を主役に、全語を含むものとフレーズ一致を優遇する
                let preliminary = accumulator.bm25 * features.coverage * features.coverage
                    * (1 + 0.5 * features.phraseInTitle + 0.2 * features.phraseInBody)
                    * (1 + 0.5 * features.pageRank)
                candidates.append(SearchCandidate(
                    pageID: document.pageID,
                    url: document.url,
                    host: document.host,
                    title: document.title,
                    description: document.description,
                    language: document.language,
                    changedAt: document.changedAt,
                    matchedTerms: accumulator.matched,
                    features: features,
                    preliminaryScore: preliminary
                ))
            }
        }

        let total = candidates.count
        // 上位 limit 件だけを返す（ブローカーで全シャードの候補をまとめて最終的な順位を決める）
        candidates.sort { $0.preliminaryScore != $1.preliminaryScore ? $0.preliminaryScore > $1.preliminaryScore : $0.url < $1.url }
        return (total, Array(candidates.prefix(limit)))
    }

    static func features(
        document: IndexedDocument,
        accumulator: (bm25: Double, matched: Int, title: Int, anchor: Int),
        termCount: Double,
        query: ParsedQuery,
        corpus: CorpusStats,
        now: Date
    ) -> RankingFeatures {
        var features = RankingFeatures()
        features.bm25 = log(1 + accumulator.bm25)
        features.coverage = Double(accumulator.matched) / termCount
        features.titleCoverage = Double(accumulator.title) / termCount
        features.anchorCoverage = Double(accumulator.anchor) / termCount
        if !query.normalizedText.isEmpty {
            features.phraseInTitle = document.normalizedTitle.contains(query.normalizedText) ? 1 : 0
            features.phraseInBody = document.normalizedText.contains(query.normalizedText) ? 1 : 0
        }
        features.pageRank = corpus.maxPageRank > 0 ? document.pageRank / corpus.maxPageRank : 0
        features.hostRank = corpus.maxHostRank > 0 ? document.hostRank / corpus.maxHostRank : 0
        let ageDays = max(0, now.timeIntervalSince(document.changedAt) / 86_400)
        features.freshness = exp(-ageDays / 365)
        features.shallowness = 1 / Double(1 + document.pathDepth)
        // 表示回数が少ないうちは、事前の値（10回中1回 = 0.1）に引き寄せる（ベイズ平均）
        features.clickThroughRate = (Double(document.clicks) + 1) / (Double(document.impressions) + 10)
        if let language = document.language?.lowercased() {
            features.languageMatch = (query.containsCJK == language.hasPrefix("ja")) ? 1 : 0
        } else {
            features.languageMatch = 0.5
        }
        return features
    }

    // MARK: - 抜粋

    /// 検索結果に表示する抜粋を作る
    func snippet(pageID: UUID, terms: [String]) -> String? {
        guard let location = locations[pageID] else { return nil }
        let document = segments[location.segment].documents[location.document]
        return Snippet.make(content: document.content, fallback: document.description, terms: terms)
    }
}
