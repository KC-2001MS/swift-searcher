import Foundation
import Redis
import Vapor

/// 重複ページの検出。
///
/// - 完全一致: 本文の SHA-256 が同じ
/// - ほぼ一致: SimHash のハミング距離が小さい（日付や広告だけが違うページなど）
///
/// 同じ内容が別の URL で公開されていることは非常に多い（`?sort=new` のようなパラメータ違い、
/// ミラーサイト、印刷用ページなど）。重複を検索結果に並べても役に立たないので、最初に見つけたものだけを残す。
protocol DuplicateDetector: Sendable {
    /// 重複していれば元のページの URL を返す。重複していなければこのページを登録して nil を返す
    func registerOrFindOriginal(url: String, contentHash: String, simhash: UInt64) async throws -> String?

    /// ページの内容が変わった・無くなったときに、古い登録を消す
    func forget(url: String, contentHash: String, simhash: UInt64) async throws
}

/// メモリ上の重複検出（テスト用）
actor InMemoryDuplicateDetector: DuplicateDetector {
    private var exact: [String: String] = [:]
    private var bands: [String: Set<String>] = [:]
    let maxDistance: Int

    init(maxDistance: Int = 3) {
        self.maxDistance = maxDistance
    }

    func registerOrFindOriginal(url: String, contentHash: String, simhash: UInt64) -> String? {
        if let original = exact[contentHash], original != url { return original }
        for (i, band) in SimHash.bands(simhash).enumerated() {
            for member in bands["\(i):\(band)", default: []] {
                guard let parsed = DuplicateMember.parse(member), parsed.url != url else { continue }
                if SimHash.distance(parsed.simhash, simhash) <= maxDistance { return parsed.url }
            }
        }
        exact[contentHash] = url
        let member = DuplicateMember.make(simhash: simhash, url: url)
        for (i, band) in SimHash.bands(simhash).enumerated() {
            bands["\(i):\(band)", default: []].insert(member)
        }
        return nil
    }

    func forget(url: String, contentHash: String, simhash: UInt64) {
        if exact[contentHash] == url { exact[contentHash] = nil }
        let member = DuplicateMember.make(simhash: simhash, url: url)
        for (i, band) in SimHash.bands(simhash).enumerated() {
            bands["\(i):\(band)"]?.remove(member)
        }
    }
}

/// Redis を使った重複検出（全ワーカーで共有する）
struct RedisDuplicateDetector: DuplicateDetector {
    let redis: RedisCommands
    let maxDistance: Int
    var prefix = "searcher:dup:"

    func registerOrFindOriginal(url: String, contentHash: String, simhash: UInt64) async throws -> String? {
        // 完全一致: SET NX は「キーが無ければ設定する」。設定できなければ先に登録したページがある
        let exactKey = prefix + "exact:" + contentHash
        let set = try await redis.send("SET", [exactKey, url, "NX"])
        if set.string != "OK" {
            if let original = try await redis.send("GET", [exactKey]).string, original != url {
                return original
            }
        }

        // ほぼ一致: 4つの帯のどれかが一致するページだけを候補として調べる
        let bandKeys = SimHash.bands(simhash).enumerated().map { prefix + "band:\($0.offset):\($0.element)" }
        for key in bandKeys {
            let members = try await redis.send("SMEMBERS", [key]).stringArray ?? []
            for member in members {
                guard let parsed = DuplicateMember.parse(member), parsed.url != url else { continue }
                if SimHash.distance(parsed.simhash, simhash) <= maxDistance {
                    // 完全一致の登録は取り消しておく（このページは重複として扱うので）
                    _ = try await redis.eval(Self.deleteIfEqualScript, keys: [exactKey], arguments: [url])
                    return parsed.url
                }
            }
        }
        let member = DuplicateMember.make(simhash: simhash, url: url)
        for key in bandKeys {
            _ = try await redis.send("SADD", [key, member])
        }
        return nil
    }

    func forget(url: String, contentHash: String, simhash: UInt64) async throws {
        _ = try await redis.eval(Self.deleteIfEqualScript, keys: [prefix + "exact:" + contentHash], arguments: [url])
        let member = DuplicateMember.make(simhash: simhash, url: url)
        for (i, band) in SimHash.bands(simhash).enumerated() {
            _ = try await redis.send("SREM", [prefix + "band:\(i):\(band)", member])
        }
    }

    /// 値が自分の URL のときだけキーを消す（他のページの登録を消さないように）
    static let deleteIfEqualScript = """
    if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
    return 0
    """
}

/// 帯の索引に入れる値（"SimHash の16進数|URL"）
enum DuplicateMember {
    static func make(simhash: UInt64, url: String) -> String {
        String(simhash, radix: 16) + "|" + url
    }

    static func parse(_ member: String) -> (simhash: UInt64, url: String)? {
        guard let bar = member.firstIndex(of: "|"), let hash = UInt64(member[..<bar], radix: 16) else { return nil }
        return (hash, String(member[member.index(after: bar)...]))
    }
}
