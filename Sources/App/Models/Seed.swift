import Fluent
import Foundation

/// 巡回を始める URL（シード）。管理 API から追加・削除できる
final class Seed: Model, @unchecked Sendable {
    static let schema = "seeds"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "url")
    var url: String

    @Field(key: "enabled")
    var enabled: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(url: String, enabled: Bool = true) {
        self.url = url
        self.enabled = enabled
    }
}
