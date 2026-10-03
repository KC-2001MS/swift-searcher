import Foundation

/// 文章を検索用の「語（トークン）」に分割する。
///
/// - 英数字: 単語単位に分割し、小文字化する。`NavigationStack` のような
///   キャメルケースは `navigationstack` に加えて `navigation` と `stack` も出力する。
/// - 日本語（漢字・ひらがな・カタカナ）: 単語の区切りが無いので、
///   2文字ずつずらして切り出す「バイグラム（N-gram）」を使う。
///   例: `検索エンジン` → `検索` `索エ` `エン` `ンジ` `ジン`
///
/// 形態素解析（MeCab など）を使えばより自然な単語に分けられるが、
/// 辞書が必要になるため、このプロジェクトでは仕組みが単純な N-gram を採用している。
enum Tokenizer {
    /// 検索に役立たない、ありふれた英単語（ストップワード）
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it",
        "of", "on", "or", "that", "the", "this", "to", "was", "with",
    ]

    private enum CharacterClass {
        case word
        case cjk
        case other
    }

    /// 文字列を正規化する（全角英数字→半角、半角カナ→全角、小文字化など）
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// 文章をトークンの配列に変換する（出現順・重複あり）
    static func tokenize(_ text: String) -> [String] {
        // キャメルケースの判定のため、小文字化の前の文字列で走査する
        let source = text.precomposedStringWithCompatibilityMapping
        var tokens: [String] = []
        var buffer = String.UnicodeScalarView()
        var bufferClass = CharacterClass.other

        func flush() {
            defer {
                buffer.removeAll()
                bufferClass = .other
            }
            guard !buffer.isEmpty else { return }
            let chunk = String(buffer)
            switch bufferClass {
            case .word:
                appendWordTokens(chunk, to: &tokens)
            case .cjk:
                appendBigrams(chunk, to: &tokens)
            case .other:
                break
            }
        }

        // 1文字ずつ見て、同じ種類の文字が続く間はバッファにためる。
        // 種類が変わったところ（例: "Swiftで" の "t" と "で" の間）で区切ってトークンにする
        for scalar in source.unicodeScalars {
            let cls = classify(scalar)
            if cls != bufferClass {
                flush()
                bufferClass = cls
            }
            if cls != .other {
                buffer.append(scalar)
            }
        }
        flush()
        return tokens
    }

    /// 文字の種類を判定する（Unicode のコードポイントの範囲で判断する）
    private static func classify(_ scalar: Unicode.Scalar) -> CharacterClass {
        switch scalar.value {
        case 0x30FB: // 中黒「・」は区切り文字として扱う
            return .other
        case 0x3041...0x309F, // ひらがな
             0x30A0...0x30FF, // カタカナ（長音記号「ー」を含む）
             0x31F0...0x31FF, // カタカナ拡張
             0x3400...0x4DBF, // CJK 統合漢字拡張 A
             0x4E00...0x9FFF, // CJK 統合漢字
             0xF900...0xFAFF, // CJK 互換漢字
             0x3005, 0x3006:  // 々 〆
            return .cjk
        default:
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                return .word
            }
            return .other
        }
    }

    private static func appendWordTokens(_ word: String, to tokens: inout [String]) {
        let lowered = word.lowercased()
        if !stopWords.contains(lowered) {
            tokens.append(lowered)
        }
        // キャメルケースを分解（例: NavigationStack → navigation, stack）
        let parts = splitCamelCase(word)
        if parts.count > 1 {
            for part in parts {
                let p = part.lowercased()
                if p.count > 1 && !stopWords.contains(p) {
                    tokens.append(p)
                }
            }
        }
    }

    /// キャメルケースの単語を分割する（`URLSession` → `URL`, `Session`）
    static func splitCamelCase(_ word: String) -> [String] {
        let chars = Array(word)
        guard chars.count > 1 else { return [word] }
        var parts: [String] = []
        var current = String(chars[0])
        for i in 1..<chars.count {
            let prev = chars[i - 1]
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let boundary =
                (prev.isLowercase && c.isUppercase)
                || (prev.isUppercase && c.isUppercase && next?.isLowercase == true)
                || (prev.isLetter && c.isNumber)
                || (prev.isNumber && c.isLetter)
            if boundary {
                parts.append(current)
                current = ""
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    /// 日本語の連続部分をバイグラムにする。
    /// 「検索」で検索すると、文書側の「検索エンジン」から作られた `検索` と一致する
    private static func appendBigrams(_ run: String, to tokens: inout [String]) {
        let chars = Array(run)
        if chars.count == 1 {
            tokens.append(String(chars[0]))
            return
        }
        for i in 0..<(chars.count - 1) {
            tokens.append(String(chars[i...i + 1]))
        }
    }
}
