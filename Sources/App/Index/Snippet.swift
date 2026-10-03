import Foundation

/// 検索結果に表示する抜粋（スニペット）を作る。
///
/// 本文の中で検索語が最初に現れる位置の前後を切り出す。
enum Snippet {
    static func make(content: String, fallback: String, terms: [String], length: Int = 160) -> String {
        let original = Array(content)
        guard !original.isEmpty else { return fallback }

        // 検索語は正規化（小文字化・全角→半角）されているので、本文も正規化して探す必要がある。
        // ただし正規化すると文字数が変わることがあるため、1文字ずつ正規化して
        // 「元の文字列の i 文字目」と「正規化後の i 文字目」が対応するようにしている
        let folded = original.map { Tokenizer.normalize(String($0)).first ?? $0 }

        var bestPosition: Int?
        for term in terms {
            let needle = Array(term)
            guard !needle.isEmpty, needle.count <= folded.count else { continue }
            if let position = firstIndex(of: needle, in: folded) {
                bestPosition = min(bestPosition ?? position, position)
            }
        }

        guard let position = bestPosition else {
            if !fallback.isEmpty { return fallback }
            return String(original.prefix(length)) + (original.count > length ? "…" : "")
        }

        // 検索語が抜粋の前の方（1/4 あたり）に来るように切り出す
        let start = max(0, min(position - length / 4, original.count - length))
        let end = min(original.count, start + length)
        var snippet = String(original[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { snippet = "…" + snippet }
        if end < original.count { snippet += "…" }
        return snippet
    }

    /// `haystack` の中で `needle` が最初に現れる位置（単純な文字列探索）
    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard let first = needle.first else { return nil }
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first && Array(haystack[i..<(i + needle.count)]) == needle {
                return i
            }
            i += 1
        }
        return nil
    }
}
