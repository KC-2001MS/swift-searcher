import Fluent
import Foundation

/// ページ間のリンク。PageRank・HostRank の計算と、アンカーテキストによる検索に使う
final class Link: Model, @unchecked Sendable {
    static let schema = "links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "source_url")
    var sourceURL: String

    @Field(key: "source_host")
    var sourceHost: String

    @Field(key: "target_url")
    var targetURL: String

    @Field(key: "target_host")
    var targetHost: String

    @Field(key: "anchor_text")
    var anchorText: String

    init() {}

    init(sourceURL: String, sourceHost: String, targetURL: String, targetHost: String, anchorText: String) {
        self.sourceURL = sourceURL
        self.sourceHost = sourceHost
        self.targetURL = targetURL
        self.targetHost = targetHost
        self.anchorText = anchorText
    }
}
