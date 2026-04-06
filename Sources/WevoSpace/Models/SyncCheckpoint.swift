import Fluent
import Vapor

final class SyncCheckpoint: Model, @unchecked Sendable {
    static let schema = "sync_checkpoints"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "peer_url")
    var peerURL: String

    @Field(key: "last_sync_at")
    var lastSyncAt: Date

    init() {}

    init(peerURL: String, lastSyncAt: Date) {
        self.peerURL = peerURL
        self.lastSyncAt = lastSyncAt
    }
}
