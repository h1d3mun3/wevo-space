import Fluent

struct AddDissolveSignatureToPropose: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("proposes")
            .field("dissolve_signature", .string)
            .update()
        try await database.schema("proposes")
            .field("dissolve_public_key", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("proposes")
            .deleteField("dissolve_signature")
            .update()
        try await database.schema("proposes")
            .deleteField("dissolve_public_key")
            .update()
    }
}
