import Fluent

struct CreateProposesTable: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("proposes")
            .id()
            .field("content_hash", .string, .required)
            .field("creator_public_key", .string, .required)
            .field("creator_signature", .string, .required)
            .field("honor_creator_signature", .string)
            .field("part_creator_signature", .string)
            .field("status", .string, .required)
            .field("created_at", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("proposes").delete()
    }
}
