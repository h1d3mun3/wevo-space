import Fluent

struct CreateSyncCheckpointsTable: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sync_checkpoints")
            .id()
            .field("peer_url", .string, .required)
            .field("last_sync_at", .datetime, .required)
            .unique(on: "peer_url")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sync_checkpoints").delete()
    }
}
