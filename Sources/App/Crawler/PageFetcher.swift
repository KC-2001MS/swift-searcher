import Foundation
import NIOCore
import Vapor

/// ページ取得のリクエスト
struct FetchRequest: Sendable {
    var url: URL
    /// 前回取得時の ETag（変化が無ければサーバーは 304 を返す）
    var etag: String?
    /// 前回取得時の Last-Modified（変化が無ければサーバーは 304 を返す）
    var lastModified: String?
}

/// ページ取得の結果
struct FetchResponse: Sendable {
    var status: UInt
    var contentType: String?
    /// リダイレクト先（3xx の場合）
    var location: String?
    var etag: String?
    var lastModified: String?
    var body: String?

    var isRedirect: Bool { (300..<400).contains(status) && status != 304 }
    var isHTML: Bool {
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.hasPrefix("text/html") || contentType.hasPrefix("application/xhtml+xml")
    }
}

/// ページを取得する仕組み。テストではネットワークを使わない実装に差し替える。
///
/// クローラー本体はこのプロトコルにだけ依存しているので、本物の HTTP 通信（HTTPPageFetcher）と
/// テスト用の偽物（Tests/AppTests/CrawlerTests.swift の MockFetcher）を入れ替えられる。
/// このような設計を「依存性の注入（Dependency Injection）」と呼ぶ。
protocol PageFetcher: Sendable {
    func fetch(_ request: FetchRequest) async throws -> FetchResponse
}

/// Vapor の HTTP クライアントを使ってページを取得する
struct HTTPPageFetcher: PageFetcher {
    let client: any Client
    let userAgent: String
    let maxBodyBytes: Int
    var timeout: TimeAmount = .seconds(20)

    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        var headers = HTTPHeaders()
        // User-Agent でクローラーの名前と連絡先（リポジトリの URL）を名乗るのがマナー。
        // サイト運営者はアクセスログでこれを見て、robots.txt で制御したり連絡したりできる
        headers.add(name: .userAgent, value: userAgent)
        headers.add(name: .accept, value: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")
        headers.add(name: .acceptLanguage, value: "ja,en;q=0.8")
        // 条件付きリクエスト: 「前回取得したときから変わっていなければ本文はいらない」とサーバーに伝える。
        // 変わっていなければサーバーは本文なしの 304 Not Modified を返す
        if let etag = request.etag {
            headers.add(name: .ifNoneMatch, value: etag)
        }
        if let lastModified = request.lastModified {
            headers.add(name: .ifModifiedSince, value: lastModified)
        }

        let timeout = self.timeout
        let response = try await client.get(URI(string: request.url.absoluteString), headers: headers) { req in
            req.timeout = timeout
        }

        var body: String?
        // ByteBuffer は SwiftNIO のバイト列の型。文字列として読み出す（UTF-8 を想定）
        if var buffer = response.body {
            // 巨大なページでメモリを使い切らないよう、上限を超えたら捨てる
            if buffer.readableBytes > maxBodyBytes {
                throw CrawlError.bodyTooLarge(buffer.readableBytes)
            }
            body = buffer.readString(length: buffer.readableBytes)
        }

        return FetchResponse(
            status: response.status.code,
            contentType: response.headers.first(name: .contentType),
            location: response.headers.first(name: .location),
            etag: response.headers.first(name: .eTag),
            lastModified: response.headers.first(name: .lastModified),
            body: body
        )
    }
}

enum CrawlError: Error, CustomStringConvertible {
    case bodyTooLarge(Int)
    case alreadyRunning

    var description: String {
        switch self {
        case .bodyTooLarge(let size): "レスポンスが大きすぎます（\(size) bytes）"
        case .alreadyRunning: "すでに巡回中です"
        }
    }
}
