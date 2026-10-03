import Foundation

/// SimHash（ほぼ同じ内容の文書の検出）。
///
/// SHA-256 のような普通のハッシュ値は、1文字違うだけでまったく別の値になる。
/// SimHash は「似た文書ほど、ハッシュ値のビットが多く一致する」ように作るハッシュ値で、
/// 日付や広告の部分だけが違うページ（ほぼ重複）を見つけるのに使う。
///
/// 1. 本文を3語ずつの並び（シングル）に区切り、それぞれを 64 ビットのハッシュ値にする
/// 2. 各ビット位置について、1 なら +1、0 なら -1 を全シングルぶん足し合わせる
/// 3. 合計がプラスのビットを 1、それ以外を 0 にした 64 ビットが SimHash
///
/// 2つの文書の SimHash で異なるビットの数（ハミング距離）が小さいほど、内容が似ている。
enum SimHash {
    static func compute(_ text: String, shingleSize: Int = 3) -> UInt64 {
        let tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return 0 }

        var weights = [Int](repeating: 0, count: 64)
        let size = min(shingleSize, tokens.count)
        for start in 0...(tokens.count - size) {
            let shingle = tokens[start..<(start + size)].joined(separator: " ")
            let hash = StableHash.mix(StableHash.fnv1a64(shingle))
            for bit in 0..<64 {
                weights[bit] += (hash >> UInt64(bit)) & 1 == 1 ? 1 : -1
            }
        }

        var result: UInt64 = 0
        for bit in 0..<64 where weights[bit] > 0 {
            result |= 1 << UInt64(bit)
        }
        return result
    }

    /// 異なるビットの数
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 近いものを素早く探すために、64 ビットを 16 ビットずつ4つの「帯」に分ける。
    ///
    /// ハミング距離が3以下なら、4つの帯のうち少なくとも1つは完全に一致する（鳩の巣原理）。
    /// そこで「帯の値 → その帯を持つ文書」の索引を作っておけば、
    /// 全文書と比べなくても、どれか1つの帯が一致する文書だけを候補として調べればよい。
    static func bands(_ hash: UInt64) -> [UInt16] {
        (0..<4).map { UInt16(truncatingIfNeeded: hash >> UInt64($0 * 16)) }
    }
}
