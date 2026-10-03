import Fluent

struct CreateDomain: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("domains")
            .id()
            .field("domain", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("domains").delete()
    }
}
