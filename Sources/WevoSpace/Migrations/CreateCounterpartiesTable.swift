import Fluent

struct CreateCounterpartiesTable: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("propose_counterparties")
            .id()
            .field("propose_id", .uuid, .required, .references("proposes", "id", onDelete: .cascade))
            .field("public_key", .string, .required)
            .field("sign_signature", .string)
            .field("sign_timestamp", .string)
            .field("honor_signature", .string)
            .field("honor_timestamp", .string)
            .field("part_signature", .string)
            .field("part_timestamp", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("propose_counterparties").delete()
    }
}
