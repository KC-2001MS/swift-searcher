import Foundation

/// PageRank の計算。
///
/// 「多くのページから、そして重要なページからリンクされているページほど重要」という考え方で、
/// リンク構造だけからページの重要度を求める。
///
/// ランダムにリンクをたどり続けるユーザー（ランダムサーファー）が、各ページに滞在している確率として計算する。
/// - 確率 `damping`（通常 0.85）で、今いるページのリンクのどれかをたどる
/// - 確率 `1 - damping` で、ランダムなページに移動する
///
/// 何百万ページもあるグラフを扱えるよう、URL ではなく番号（Int32）でノードを表し、
/// 隣接リストを CSR 形式（全リンクを1本の配列に詰め、ノードごとの開始位置を別の配列に持つ）で持つ。
/// 1リンクあたり 4 バイトで済むので、1億リンクでも 400MB 程度に収まる。
enum PageRank {
    /// - Parameters:
    ///   - nodeCount: ノード（ページ）の数
    ///   - edges: リンク（リンク元の番号, リンク先の番号）
    /// - Returns: 各ノードの PageRank（合計が 1 になる）
    static func compute(
        nodeCount n: Int,
        edges: [(source: Int32, target: Int32)],
        damping: Double = 0.85,
        maxIterations: Int = 100,
        tolerance: Double = 1e-9
    ) -> [Double] {
        guard n > 0 else { return [] }

        // 自己リンクを除き、同じリンクの重複を取り除く
        var unique = Set<Int64>()
        var outDegree = [Int32](repeating: 0, count: n)
        var incomingCount = [Int32](repeating: 0, count: n)
        var filtered: [(Int32, Int32)] = []
        filtered.reserveCapacity(edges.count)
        for edge in edges where edge.source != edge.target {
            guard edge.source >= 0, edge.target >= 0, Int(edge.source) < n, Int(edge.target) < n else { continue }
            let key = Int64(edge.source) << 32 | Int64(edge.target)
            guard unique.insert(key).inserted else { continue }
            filtered.append((edge.source, edge.target))
            outDegree[Int(edge.source)] += 1
            incomingCount[Int(edge.target)] += 1
        }

        // CSR 形式の「リンク元の一覧」: offsets[t]..<offsets[t+1] が t にリンクしているページ
        var offsets = [Int](repeating: 0, count: n + 1)
        for t in 0..<n { offsets[t + 1] = offsets[t] + Int(incomingCount[t]) }
        var cursor = offsets
        var sources = [Int32](repeating: 0, count: filtered.count)
        for (s, t) in filtered {
            sources[cursor[Int(t)]] = s
            cursor[Int(t)] += 1
        }
        let danglingNodes = (0..<n).filter { outDegree[$0] == 0 }

        // べき乗法: 値が変化しなくなるまで更新を繰り返す
        //
        //   PR(t) = (1 - d) / n + d × Σ PR(s) / (s のリンク数)    ← s は t にリンクしているページ
        var rank = [Double](repeating: 1.0 / Double(n), count: n)
        var next = [Double](repeating: 0, count: n)
        for _ in 0..<maxIterations {
            // リンクを持たないページ（dangling node）の分は全ページに均等に配る
            let danglingSum = danglingNodes.reduce(0.0) { $0 + rank[$1] }
            let base = (1 - damping) / Double(n) + damping * danglingSum / Double(n)
            var delta = 0.0
            for t in 0..<n {
                var sum = 0.0
                for i in offsets[t]..<offsets[t + 1] {
                    let s = Int(sources[i])
                    sum += rank[s] / Double(outDegree[s])
                }
                next[t] = base + damping * sum
                delta += abs(next[t] - rank[t])
            }
            swap(&rank, &next)
            if delta < tolerance { break }
        }
        return rank
    }

    /// URL（文字列）で表したグラフの PageRank（テストや小さなグラフ用）
    static func compute(nodes: [String], edges: [(source: String, target: String)], damping: Double = 0.85) -> [String: Double] {
        var indexOf: [String: Int32] = [:]
        for (i, node) in nodes.enumerated() { indexOf[node] = Int32(i) }
        let numbered = edges.compactMap { edge -> (source: Int32, target: Int32)? in
            guard let s = indexOf[edge.source], let t = indexOf[edge.target] else { return nil }
            return (s, t)
        }
        let ranks = compute(nodeCount: nodes.count, edges: numbered, damping: damping)
        var result: [String: Double] = [:]
        for (i, node) in nodes.enumerated() { result[node] = ranks[i] }
        return result
    }
}
