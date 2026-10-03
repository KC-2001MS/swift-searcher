import Foundation
import Redis
import Vapor

/// 動いているワーカーの情報
struct WorkerInfo: Codable, Sendable, Equatable {
    var id: String
    var hostname: String
    var concurrency: Int
    var startedAt: Date
    var lastSeenAt: Date
    var counters: CrawlCounters
}

/// ワーカーの生存確認（ハートビート）。
///
/// 各ワーカーは数秒ごとに「生きている」ことと処理件数を書き込む。
/// 一定時間書き込みが無いワーカーは止まったとみなして一覧から外す。
protocol WorkerRegistry: Sendable {
    func heartbeat(_ info: WorkerInfo) async throws
    func activeWorkers(now: Date) async throws -> [WorkerInfo]
}

actor InMemoryWorkerRegistry: WorkerRegistry {
    private var workers: [String: WorkerInfo] = [:]
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func heartbeat(_ info: WorkerInfo) {
        workers[info.id] = info
    }

    func activeWorkers(now: Date) -> [WorkerInfo] {
        workers.values.filter { now.timeIntervalSince($0.lastSeenAt) < timeout }.sorted { $0.id < $1.id }
    }
}

struct RedisWorkerRegistry: WorkerRegistry {
    let redis: RedisCommands
    var timeout: TimeInterval = 30
    var prefix = "searcher:workers"

    func heartbeat(_ info: WorkerInfo) async throws {
        let json = String(decoding: try JSONEncoder.iso8601.encode(info), as: UTF8.self)
        // 生存時刻のソート済みセットと、詳細のハッシュに分けて保存する
        _ = try await redis.send("ZADD", [prefix, String(info.lastSeenAt.milliseconds), info.id])
        _ = try await redis.send("HSET", [prefix + ":info", info.id, json])
    }

    func activeWorkers(now: Date) async throws -> [WorkerInfo] {
        let threshold = now.addingTimeInterval(-timeout).milliseconds
        // 古いワーカーを消してから一覧を取る
        let stale = try await redis.send("ZRANGEBYSCORE", [prefix, "-inf", "(\(threshold)"]).stringArray ?? []
        if !stale.isEmpty {
            _ = try await redis.send("ZREM", [prefix] + stale)
            _ = try await redis.send("HDEL", [prefix + ":info"] + stale)
        }
        let ids = try await redis.send("ZRANGEBYSCORE", [prefix, String(threshold), "+inf"]).stringArray ?? []
        guard !ids.isEmpty else { return [] }
        let values = try await redis.send("HMGET", [prefix + ":info"] + ids).array ?? []
        return values.compactMap { value in
            guard let string = value.string else { return nil }
            return try? JSONDecoder.iso8601.decode(WorkerInfo.self, from: Data(string.utf8))
        }
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
