import Fluent
import Vapor

struct InfoResponse: Content {
    let protocolName: String
    let version: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version
        case capabilities
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

    // Server info and capabilities (immutable)
    app.get("info") { req async -> InfoResponse in
        return InfoResponse(
            protocolName: "wevo",
            version: "0.1.0",
            capabilities: [
                "proposes.create",
                "proposes.read",
                "proposes.sign"
            ]
        )
    }

    // v1 API
    let v1 = app.grouped("v1")
    try v1.register(collection: ProposeController())
}
