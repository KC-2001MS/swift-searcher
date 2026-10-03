import Foundation
import NIOCore
import Redis
import Vapor

/// Redis にアクセスするための小さなラッパー。
///
/// Redis のコマンドは文字列の配列として送る。複数のコマンドをまとめて実行したいときは
/// Lua スクリプト（EVAL）を使う。Redis はスクリプトを1つずつ実行するので、
/// スクリプトの中の処理は他のクライアントに割り込まれない（アトミックになる）。
struct RedisCommands: Sendable {
    let app: Application

    func send(_ command: String, _ arguments: [String]) async throws -> RESPValue {
        try await app.redis.send(command: command, with: arguments.map { $0.convertedToRESPValue() }).get()
    }

    /// Lua スクリプトを実行する
    func eval(_ script: String, keys: [String], arguments: [String]) async throws -> RESPValue {
        try await send("EVAL", [script, String(keys.count)] + keys + arguments)
    }
}

extension RESPValue {
    /// 文字列の配列として読み出す
    var stringArray: [String]? {
        array?.compactMap(\.string)
    }
}

/// 検索結果のキャッシュ
protocol QueryCache: Sendable {
    func get(_ key: String) async -> Data?
    func set(_ key: String, value: Data, ttl: Duration) async
}

/// キャッシュしない（テスト・開発用）
struct NoQueryCache: QueryCache {
    func get(_ key: String) async -> Data? { nil }
    func set(_ key: String, value: Data, ttl: Duration) async {}
}

/// Redis に検索結果を保存するキャッシュ。
///
/// 検索される語には大きな偏りがある（人気の語が何度も検索される）ので、
/// 同じ検索の結果を少しの間保存しておくだけで、シャードへの問い合わせを大きく減らせる。
struct RedisQueryCache: QueryCache {
    let redis: RedisCommands
    var prefix = "searcher:cache:"

    func get(_ key: String) async -> Data? {
        guard let value = try? await redis.send("GET", [prefix + key]), let string = value.string else { return nil }
        return Data(string.utf8)
    }

    func set(_ key: String, value: Data, ttl: Duration) async {
        guard ttl > .zero, let string = String(data: value, encoding: .utf8) else { return }
        // 失敗しても検索結果は返せるので、エラーは無視する
        _ = try? await redis.send("SET", [prefix + key, string, "PX", String(ttl.milliseconds)])
    }
}
