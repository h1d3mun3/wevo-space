import Fluent

struct AddPerPartyDissolveSignatures: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // proposes: add per-party creator dissolve fields
        try await database.schema("proposes")
            .field("creator_dissolve_signature", .string)
            .update()
        try await database.schema("proposes")
            .field("creator_dissolve_timestamp", .string)
            .update()
        // proposes: remove old single-field dissolve storage
        try await database.schema("proposes")
            .deleteField("dissolve_signature")
            .update()
        try await database.schema("proposes")
            .deleteField("dissolve_public_key")
            .update()
        // counterparties: add dissolve fields
        try await database.schema("propose_counterparties")
            .field("dissolve_signature", .string)
            .update()
        try await database.schema("propose_counterparties")
            .field("dissolve_timestamp", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("proposes")
            .deleteField("creator_dissolve_signature")
            .update()
        try await database.schema("proposes")
            .deleteField("creator_dissolve_timestamp")
            .update()
        try await database.schema("proposes")
            .field("dissolve_signature", .string)
            .update()
        try await database.schema("proposes")
            .field("dissolve_public_key", .string)
            .update()
        try await database.schema("propose_counterparties")
            .deleteField("dissolve_signature")
            .update()
        try await database.schema("propose_counterparties")
            .deleteField("dissolve_timestamp")
            .update()
    }
}
