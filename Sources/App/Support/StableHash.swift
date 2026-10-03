import Foundation
import Vapor

/// プロセスや実行環境が変わっても同じ値になるハッシュ関数。
///
/// Swift の `Hasher`（`hashValue`）は起動のたびに値が変わる（ハッシュ衝突攻撃を防ぐため）ので、
/// シャードの割り当てやブルームフィルターのように「どのサーバーで計算しても同じ値」が必要な場面では使えない。
enum StableHash {
    /// FNV-1a（64 ビット）。高速で、短い文字列のハッシュに向いている
    static func fnv1a64(_ string: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    /// 64 ビットの値をよく混ぜる（SplitMix64 の最終段）。偏りの少ない値にしたいときに使う
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// URL のハッシュ値（データベースの検索・シャードの割り当てに使う）
    static func url(_ url: String) -> Int64 {
        Int64(bitPattern: mix(fnv1a64(url)))
    }

    /// 内容のハッシュ値（完全一致の重複検出用）
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).hex
    }
}

/// シャードの割り当て。
///
/// ページを直接「シャード番号」に割り当てると、シャードを増やしたときに全ページの番号を振り直すことになる。
/// そこでページはまず固定数（1024）の「バケット」に割り当て、バケットをシャードに割り当てる。
/// シャードを増減するときは、バケットとシャードの対応を変えるだけで済む（データベースの書き換えが不要）。
enum ShardRouting {
    static let bucketCount = 1024

    static func bucket(forURLHash hash: Int64) -> Int {
        Int(UInt64(bitPattern: hash) % UInt64(bucketCount))
    }

    static func shard(forBucket bucket: Int, shardCount: Int) -> Int {
        bucket % shardCount
    }

    static func shard(forURLHash hash: Int64, shardCount: Int) -> Int {
        shard(forBucket: bucket(forURLHash: hash), shardCount: shardCount)
    }
}
