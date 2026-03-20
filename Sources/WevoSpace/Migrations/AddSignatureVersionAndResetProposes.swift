import Fluent
import SQLKit

/// Resets all Propose and ProposeCounterparty data (alpha data incompatible with v1 signature format),
/// then adds the `signature_version` column to the proposes table.
struct AddSignatureVersionAndResetProposes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("AddSignatureVersionAndResetProposes requires a SQL database")
        }

        // Delete counterparty rows first (foreign key dependency)
        try await sql.raw("DELETE FROM propose_counterparties").run()
        // Delete all propose rows
        try await sql.raw("DELETE FROM proposes").run()

        // Add signature_version column (table is now empty, default only needed for ALTER TABLE syntax)
        try await database.schema("proposes")
            .field("signature_version", .int, .required, .custom("DEFAULT 1"))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("proposes")
            .deleteField("signature_version")
            .update()
    }
}
