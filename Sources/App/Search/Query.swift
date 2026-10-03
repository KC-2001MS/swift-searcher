import Foundation

/// 解析済みの検索クエリ。
///
/// 次の書き方に対応する。
///
/// | 書き方 | 意味 |
/// | --- | --- |
/// | `swift vapor` | 両方を含むページを優先する |
/// | `"server side swift"` | この並びのまま含むページだけ |
/// | `-python` | この語を含むページを除く |
/// | `site:iroiro.dev` | このホスト（サブドメインを含む）のページだけ |
/// | `lang:ja` | この言語のページだけ |
struct ParsedQuery: Codable, Sendable, Equatable {
    /// 検索語（重複なし・出現順）
    var terms: [String]
    /// 検索語ごとの言い換え（同義語）。元の語が無くても、言い換えを含めば一致とみなす（点数は少し下げる）
    var synonyms: [String: [String]]
    /// 引用符で囲まれたフレーズ（正規化済み）。すべて含むページだけを返す
    var phrases: [String]
    /// 除外する語
    var excluded: [String]
    var site: String?
    var language: String?
    /// 検索語を正規化してつなげたもの（フレーズ一致の加点に使う）
    var normalizedText: String

    /// クエリに日本語（漢字・かな）を含むか
    var containsCJK: Bool {
        normalizedText.unicodeScalars.contains { (0x3041...0x9FFF).contains($0.value) }
    }

    /// キャッシュのキーなどに使う、表記ゆれをそろえた文字列
    var cacheKey: String {
        var parts = terms
        parts += phrases.map { "\"\($0)\"" }
        parts += excluded.map { "-\($0)" }
        if let site { parts.append("site:\(site)") }
        if let language { parts.append("lang:\(language)") }
        return parts.joined(separator: " ")
    }
}

enum QueryParser {
    static func parse(_ raw: String, synonyms dictionary: SynonymDictionary = .default) -> ParsedQuery {
        var freeText: [String] = []
        var phrases: [String] = []
        var excluded: [String] = []
        var site: String?
        var language: String?

        // 引用符で囲まれた部分を取り出す
        var remaining = ""
        var inQuote = false
        var current = ""
        for character in raw {
            if character == "\"" || character == "”" || character == "“" {
                if inQuote {
                    let phrase = normalizePhrase(current)
                    if !phrase.isEmpty { phrases.append(phrase) }
                    current = ""
                }
                inQuote.toggle()
            } else if inQuote {
                current.append(character)
            } else {
                remaining.append(character)
            }
        }
        // 閉じていない引用符は普通の語として扱う
        if inQuote { remaining += " " + current }

        for word in remaining.split(whereSeparator: \.isWhitespace) {
            let lowered = word.lowercased()
            if lowered.hasPrefix("site:"), lowered.count > 5 {
                site = String(lowered.dropFirst(5))
            } else if lowered.hasPrefix("lang:"), lowered.count > 5 {
                language = String(lowered.dropFirst(5))
            } else if word.hasPrefix("-"), word.count > 1 {
                // `-SwiftUI` で `swift` まで除外しないよう、英単語は単語全体だけを除外する
                // （日本語はバイグラムの全部を除外する）
                let excludedWord = String(word.dropFirst())
                let tokens = Tokenizer.tokenize(excludedWord)
                let whole = Tokenizer.normalize(excludedWord)
                excluded += tokens.contains(whole) ? [whole] : tokens
            } else {
                freeText.append(String(word))
            }
        }

        // フレーズの語も検索語に含める（転置インデックスで候補を探すため）
        var seen = Set<String>()
        let tokens = Tokenizer.tokenize((freeText + phrases).joined(separator: " "))
        let terms = tokens.filter { !excluded.contains($0) && seen.insert($0).inserted }

        var synonyms: [String: [String]] = [:]
        for term in terms {
            let alternatives = dictionary.alternatives(for: term).filter { !terms.contains($0) }
            if !alternatives.isEmpty { synonyms[term] = alternatives }
        }

        let normalizedText = normalizePhrase((freeText + phrases).joined(separator: " "))
        return ParsedQuery(
            terms: terms,
            synonyms: synonyms,
            phrases: phrases,
            excluded: Array(Set(excluded)).sorted(),
            site: site,
            language: language,
            normalizedText: normalizedText
        )
    }

    /// フレーズを正規化し、連続する空白を1つにまとめる
    static func normalizePhrase(_ text: String) -> String {
        Tokenizer.normalize(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// 同義語の辞書。
///
/// 大規模な検索エンジンでは、検索ログから「同じ意味で使われる語」を自動で集めるが、
/// ここでは小さな辞書を用意している（`SEARCH_SYNONYMS` 環境変数で追加できる）。
struct SynonymDictionary: Sendable {
    /// 語 → 言い換え（双方向に登録する）
    private var table: [String: Set<String>] = [:]

    init(groups: [[String]]) {
        for group in groups {
            // 転置インデックスの語と比べるので、1つの語（トークン）になるものだけを登録する。
            // 日本語はバイグラムで複数の語に分かれるため、ここでは扱わない（フレーズ検索で代用する）
            let normalized = group.compactMap { word -> String? in
                let tokens = Tokenizer.tokenize(word)
                return tokens.count == 1 ? tokens[0] : nil
            }
            for word in normalized {
                table[word, default: []].formUnion(normalized.filter { $0 != word })
            }
        }
    }

    func alternatives(for term: String) -> [String] {
        (table[term] ?? []).sorted()
    }

    /// `"js,javascript;ios,iphone"` の形式（; で組、, で語を区切る）を読み込む
    static func parse(_ text: String) -> [[String]] {
        text.split(separator: ";").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    static let defaultGroups: [[String]] = [
        ["js", "javascript"],
        ["ts", "typescript"],
        ["k8s", "kubernetes"],
        ["db", "database"],
        ["mac", "macos"],
        ["postgres", "postgresql"],
        ["golang", "go"],
    ]

    static let `default` = SynonymDictionary(groups: defaultGroups)
}
