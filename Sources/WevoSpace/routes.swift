import Fluent
import Vapor

struct InfoResponse: Content {
    let protocolName: String
    let version: String
    let peers: [String]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version
        case peers
    }
}

func routes(_ app: Application) throws {
    // Health check endpoint (for monitoring)
    app.get("health") { req async -> [String: String] in
        return [
            "status": "ok",
            "timestamp": "\(Date().timeIntervalSince1970)"
        ]
    }

    // Server info: version and known peer URLs.
    // peers is empty in single-server mode (PEER_NODES not set).
    app.get("info") { req async -> InfoResponse in
        return InfoResponse(
            protocolName: "wevo",
            version: "0.4.1",
            peers: app.syncService?.peers ?? []
        )
    }

    // v1 API
    let v1 = app.grouped("v1")
    try v1.register(collection: ProposeController())

    // Sync API: only mounted when a non-empty SYNC_SECRET is configured.
    // Without a secret the sync endpoints would expose a full-ledger read (GET
    // /v1/sync/proposes) and a batch-upsert write (POST /v1/sync/proposes/batch) with no
    // authentication, so we fail closed by not registering them at all in single-node mode.
    let syncSecret = Environment.get("SYNC_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let syncSecret, !syncSecret.isEmpty {
        try v1.register(collection: SyncController(syncSecret: syncSecret))
    } else {
        app.logger.notice("SYNC_SECRET is not set — /v1/sync endpoints are disabled (single-node mode).")
    }
}
