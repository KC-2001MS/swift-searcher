import Foundation
import Redis
import Vapor

/// Redis を使った分散フロンティア。
///
/// 何台ものワーカーが同じフロンティアを共有できるよう、待ち行列を Redis に置く。
/// 「取り出す」「ホストを借りる」といった処理は Lua スクリプトでアトミックに行うので、
/// 2台のワーカーが同じ URL を取り出したり、同じホストに同時にアクセスしたりすることはない。
///
/// | キー | 型 | 内容 |
/// | --- | --- | --- |
/// | `searcher:frontier:ready` | ソート済みセット | ホスト → 次にアクセスしてよい時刻（ミリ秒） |
/// | `searcher:frontier:q:<origin>` | ソート済みセット | ホストごとの待ち行列（スコアは優先度） |
/// | `searcher:frontier:bloom` | 文字列（ビット列） | 追加したことのある URL のブルームフィルター |
/// | `searcher:frontier:size` | 数値 | 待っている URL の総数 |
struct RedisFrontier: Frontier {
    let redis: RedisCommands
    let bloom: BloomFilterHasher
    let maxQueuePerHost: Int
    var prefix = "searcher:frontier:"

    private var readyKey: String { prefix + "ready" }
    private var bloomKey: String { prefix + "bloom" }
    private var sizeKey: String { prefix + "size" }
    private var queuePrefix: String { prefix + "q:" }

    func enqueue(_ entry: FrontierEntry, origin: String, force: Bool) async throws -> Bool {
        let member = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        let positions = bloom.positions(for: entry.url).map(String.init)
        let result = try await redis.eval(
            Self.enqueueScript,
            keys: [bloomKey, readyKey, queuePrefix + origin, sizeKey],
            arguments: [force ? "1" : "0", member, String(entry.priority), origin, String(maxQueuePerHost)] + positions
        )
        return result.int == 1
    }

    func claim(now: Date, lease: Duration) async throws -> FrontierLease? {
        // 待ち行列が空のホストに当たった場合は（スクリプトがそのホストを消すので）もう一度試す
        for _ in 0..<5 {
            let result = try await redis.eval(
                Self.claimScript,
                keys: [readyKey, sizeKey],
                arguments: [String(now.milliseconds), String(lease.milliseconds), queuePrefix]
            )
            guard let values = result.stringArray, let origin = values.first else { return nil }
            guard values.count >= 2 else { continue }
            let entry = try JSONDecoder().decode(FrontierEntry.self, from: Data(values[1].utf8))
            return FrontierLease(origin: origin, entry: entry)
        }
        return nil
    }

    func release(origin: String, nextAllowedAt: Date) async throws {
        _ = try await redis.eval(
            Self.releaseScript,
            keys: [readyKey, queuePrefix + origin],
            arguments: [origin, String(nextAllowedAt.milliseconds)]
        )
    }

    func stats(now: Date) async throws -> FrontierStats {
        let hosts = try await redis.send("ZCARD", [readyKey]).int ?? 0
        let ready = try await redis.send("ZCOUNT", [readyKey, "-inf", String(now.milliseconds)]).int ?? 0
        let size = try await redis.send("GET", [sizeKey]).string.flatMap(Int.init) ?? 0
        return FrontierStats(hosts: hosts, readyHosts: ready, queuedURLs: max(size, 0))
    }

    // MARK: - Lua スクリプト
    // （Redis Cluster で使う場合は、1つのスクリプトで触るキーを同じスロットに置くためにハッシュタグ {…} が必要）

    /// ブルームフィルターで追加済みか確かめてから、ホストの待ち行列に追加する
    static let enqueueScript = """
    local isNew = 0
    for i = 6, #ARGV do
      if redis.call('SETBIT', KEYS[1], ARGV[i], 1) == 0 then isNew = 1 end
    end
    if ARGV[1] == '0' and isNew == 0 then return 0 end
    if redis.call('ZCARD', KEYS[3]) >= tonumber(ARGV[5]) then return 0 end
    if redis.call('ZADD', KEYS[3], 'NX', ARGV[3], ARGV[2]) == 1 then
      redis.call('INCR', KEYS[4])
    end
    redis.call('ZADD', KEYS[2], 'NX', 0, ARGV[4])
    return 1
    """

    /// 時刻が来ているホストを1つ借り、優先度の最も高い URL を取り出す
    static let claimScript = """
    local hosts = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, 1)
    if #hosts == 0 then return false end
    local origin = hosts[1]
    local item = redis.call('ZPOPMIN', ARGV[3] .. origin)
    if #item == 0 then
      redis.call('ZREM', KEYS[1], origin)
      return {origin}
    end
    redis.call('DECR', KEYS[2])
    redis.call('ZADD', KEYS[1], tonumber(ARGV[1]) + tonumber(ARGV[2]), origin)
    return {origin, item[1]}
    """

    /// ホストを返す。待ち行列が空ならホストの一覧から消す
    static let releaseScript = """
    if redis.call('ZCARD', KEYS[2]) > 0 then
      redis.call('ZADD', KEYS[1], ARGV[2], ARGV[1])
    else
      redis.call('ZREM', KEYS[1], ARGV[1])
    end
    return 1
    """
}

/// ブルームフィルターのビット位置の計算。
///
/// ブルームフィルターは「その URL を追加したことがあるか」を、少ないメモリで判定する仕組み。
/// URL ごとに k 個のビット位置を計算して 1 にしておき、k 個すべてが 1 なら「追加済み（たぶん）」と判定する。
///
/// - 「追加していないのに追加済み」と判定する誤りは少しだけ起きる（偽陽性）が、その URL を取りこぼすだけで済む
/// - 「追加済みなのに未追加」と判定することは無い（同じ URL を何度も取得することは無い）
///
/// 1億 URL を Set に入れると数 GB 必要だが、ビット数 2^30（128MB）・k = 7 なら偽陽性は 1% 未満で済む。
struct BloomFilterHasher: Sendable {
    let bits: Int
    let hashes: Int

    /// ダブルハッシュ法: 2つのハッシュ値 h1, h2 から k 個の位置を h1 + i × h2 で作る
    func positions(for value: String) -> [Int] {
        let h1 = StableHash.mix(StableHash.fnv1a64(value))
        let h2 = StableHash.mix(StableHash.fnv1a64(value, seed: 0x84222325cbf29ce4)) | 1
        return (0..<hashes).map { i in
            Int((h1 &+ UInt64(i) &* h2) % UInt64(bits))
        }
    }
}

extension Date {
    /// UNIX 時刻（ミリ秒）
    var milliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
