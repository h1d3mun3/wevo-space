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
            version: "0.2.0",
            peers: app.syncService?.peers ?? []
        )
    }

    // v1 API
    let v1 = app.grouped("v1")
    try v1.register(collection: ProposeController())

    let syncSecret = Environment.get("SYNC_SECRET")
    try v1.register(collection: SyncController(syncSecret: syncSecret))
}
