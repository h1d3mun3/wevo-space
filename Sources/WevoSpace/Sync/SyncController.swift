import Fluent
import Vapor

struct SyncController: RouteCollection {
    let syncSecret: String?

    func boot(routes: any RoutesBuilder) throws {
        let sync = routes.grouped("sync")
        sync.get("proposes", use: listProposes)
        sync.post("proposes", "batch", use: batchUpsert)
    }

    // GET /v1/sync/proposes
    // GET /v1/sync/proposes?after=<ISO8601>&limit=<int>&offset=<int>
    //
    // Returns Proposes updated after the given timestamp, in ascending updatedAt order.
    // Supports pagination via limit (default 500, max 1000) and offset.
    // Omit `after` to return all Proposes (used for initial pull / full recovery).
    func listProposes(req: Request) async throws -> [ProposeResponse] {
        try checkAuth(req)

        let rawLimit = req.query[Int.self, at: "limit"] ?? 500
        let limit = max(1, min(rawLimit, 1000))
        let offset = max(0, req.query[Int.self, at: "offset"] ?? 0)

        var query = Propose.query(on: req.db)
            .with(\.$counterparties)
            .sort(\.$updatedAt, .ascending)

        if let afterString = req.query[String.self, at: "after"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let afterDate = formatter.date(from: afterString) else {
                throw Abort(.badRequest, reason: "Invalid 'after' value. Expected ISO8601 (e.g. 2026-01-01T00:00:00Z).")
            }
            query = query.filter(\.$updatedAt > afterDate)
        }

        let proposes = try await query.range(offset..<(offset + limit)).all()
        return try proposes.map { try ProposeResponse(from: $0) }
    }

    // POST /v1/sync/proposes/batch
    //
    // Upserts an array of Proposes received from a peer.
    // Each Propose is merged into the local database using append-only logic.
    func batchUpsert(req: Request) async throws -> HTTPStatus {
        try checkAuth(req)

        let incoming = try req.content.decode([ProposeResponse].self)
        for propose in incoming {
            try await SyncService.upsertPropose(propose, on: req.db)
        }
        return .ok
    }

    private func checkAuth(_ req: Request) throws {
        guard let secret = syncSecret else { return }
        guard req.headers.bearerAuthorization?.token == secret else {
            throw Abort(.unauthorized, reason: "Invalid or missing sync secret")
        }
    }
}
