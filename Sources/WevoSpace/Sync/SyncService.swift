import Fluent
import Vapor

// Pulls Proposes from peer nodes and merges them into the local database.
// Actor isolation protects lastSyncAt per-peer state.
actor SyncService {
    private let app: Application
    let peers: [String]
    let syncSecret: String?
    private var lastSyncAt: [String: Date] = [:]

    init(app: Application, peers: [String], syncSecret: String?) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
    }

    func pullFromAllPeers() async {
        for peer in peers {
            await pullFromPeer(peer)
        }
    }

    private let pageSize = 500

    private func pullFromPeer(_ peerURL: String) async {
        let syncStartedAt = Date()
        // Buffer by 1 minute to handle clock skew between nodes
        let after = lastSyncAt[peerURL].map { $0.addingTimeInterval(-60) }

        var offset = 0
        var totalMerged = 0

        do {
            while true {
                let page = try await fetchProposes(from: peerURL, after: after, offset: offset)
                for propose in page {
                    try await SyncService.upsertPropose(propose, on: app.db)
                }
                totalMerged += page.count
                // If fewer results than page size, we've reached the last page
                if page.count < pageSize { break }
                offset += pageSize
            }
            // Record start time (not completion time) so any Proposes created
            // during this pull are captured in the next cycle
            lastSyncAt[peerURL] = syncStartedAt
            if totalMerged > 0 {
                app.logger.info("[Sync] \(peerURL): merged \(totalMerged) propose(s)")
            }
        } catch {
            // Unreachable peers are silently skipped; they will be retried next cycle
            app.logger.warning("[Sync] \(peerURL) skipped: \(error.localizedDescription)")
        }
    }

    private func fetchProposes(from peerURL: String, after: Date?, offset: Int) async throws -> [ProposeResponse] {
        var components = URLComponents(string: "\(peerURL)/v1/sync/proposes")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(pageSize)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        if let after {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            queryItems.append(URLQueryItem(name: "after", value: formatter.string(from: after)))
        }
        components.queryItems = queryItems
        let urlString = components.url!.absoluteString

        var headers = HTTPHeaders()
        if let secret = syncSecret {
            headers.bearerAuthorization = BearerAuthorization(token: secret)
        }

        let response = try await app.client.get(URI(string: urlString), headers: headers)
        guard response.status == .ok else {
            throw Abort(.serviceUnavailable, reason: "Peer \(peerURL) returned \(response.status)")
        }
        return try response.content.decode([ProposeResponse].self)
    }

    // MARK: - Merge (static: no actor isolation needed, safe to call from anywhere)

    static func upsertPropose(_ incoming: ProposeResponse, on db: any Database) async throws {
        if let existing = try await Propose.query(on: db)
            .filter(\.$id == incoming.id)
            .with(\.$counterparties)
            .first() {
            try await mergeInto(existing: existing, incoming: incoming, on: db)
        } else {
            try await createFrom(incoming: incoming, on: db)
        }
    }

    private static func mergeInto(existing: Propose, incoming: ProposeResponse, on db: any Database) async throws {
        var changed = false

        // For each nullable field: adopt received value only when local is nil.
        // If both are non-nil but differ, this indicates a cryptographic inconsistency;
        // we keep the local value and log nothing — the data will not converge, which
        // is intentional (two distinct signatures for the same operation is a fraud signal).
        if existing.honorCreatorSignature == nil, let v = incoming.honorCreatorSignature {
            existing.honorCreatorSignature = v; changed = true
        }
        if existing.honorCreatorTimestamp == nil, let v = incoming.honorCreatorTimestamp {
            existing.honorCreatorTimestamp = v; changed = true
        }
        if existing.partCreatorSignature == nil, let v = incoming.partCreatorSignature {
            existing.partCreatorSignature = v; changed = true
        }
        if existing.partCreatorTimestamp == nil, let v = incoming.partCreatorTimestamp {
            existing.partCreatorTimestamp = v; changed = true
        }
        if existing.dissolvedAt == nil, let v = incoming.dissolvedAt {
            existing.dissolvedAt = v; changed = true
        }
        if existing.creatorDissolveSignature == nil, let v = incoming.creatorDissolveSignature {
            existing.creatorDissolveSignature = v; changed = true
        }
        if existing.creatorDissolveTimestamp == nil, let v = incoming.creatorDissolveTimestamp {
            existing.creatorDissolveTimestamp = v; changed = true
        }

        for incomingCP in incoming.counterparties {
            guard let existingCP = existing.counterparties.first(where: { $0.publicKey == incomingCP.publicKey }) else {
                continue
            }
            var cpChanged = false

            if existingCP.signSignature == nil, let v = incomingCP.signSignature {
                existingCP.signSignature = v; cpChanged = true
            }
            if existingCP.signTimestamp == nil, let v = incomingCP.signTimestamp {
                existingCP.signTimestamp = v; cpChanged = true
            }
            if existingCP.honorSignature == nil, let v = incomingCP.honorSignature {
                existingCP.honorSignature = v; cpChanged = true
            }
            if existingCP.honorTimestamp == nil, let v = incomingCP.honorTimestamp {
                existingCP.honorTimestamp = v; cpChanged = true
            }
            if existingCP.partSignature == nil, let v = incomingCP.partSignature {
                existingCP.partSignature = v; cpChanged = true
            }
            if existingCP.partTimestamp == nil, let v = incomingCP.partTimestamp {
                existingCP.partTimestamp = v; cpChanged = true
            }
            if existingCP.dissolveSignature == nil, let v = incomingCP.dissolveSignature {
                existingCP.dissolveSignature = v; cpChanged = true
            }
            if existingCP.dissolveTimestamp == nil, let v = incomingCP.dissolveTimestamp {
                existingCP.dissolveTimestamp = v; cpChanged = true
            }

            if cpChanged {
                try await existingCP.save(on: db)
                changed = true
            }
        }

        if changed {
            existing.proposeStatus = computeStatus(propose: existing, counterparties: existing.counterparties)
            try await existing.save(on: db)
        }
    }

    private static func createFrom(incoming: ProposeResponse, on db: any Database) async throws {
        let propose = Propose(
            id: incoming.id,
            contentHash: incoming.contentHash,
            creatorPublicKey: incoming.creatorPublicKey,
            creatorSignature: incoming.creatorSignature,
            createdAt: incoming.createdAt,
            signatureVersion: incoming.signatureVersion
        )
        propose.honorCreatorSignature = incoming.honorCreatorSignature
        propose.honorCreatorTimestamp = incoming.honorCreatorTimestamp
        propose.partCreatorSignature = incoming.partCreatorSignature
        propose.partCreatorTimestamp = incoming.partCreatorTimestamp
        propose.dissolvedAt = incoming.dissolvedAt
        propose.creatorDissolveSignature = incoming.creatorDissolveSignature
        propose.creatorDissolveTimestamp = incoming.creatorDissolveTimestamp

        let counterparties = incoming.counterparties.map { cp -> ProposeCounterparty in
            let counterparty = ProposeCounterparty(proposeID: incoming.id, publicKey: cp.publicKey)
            counterparty.signSignature = cp.signSignature
            counterparty.signTimestamp = cp.signTimestamp
            counterparty.honorSignature = cp.honorSignature
            counterparty.honorTimestamp = cp.honorTimestamp
            counterparty.partSignature = cp.partSignature
            counterparty.partTimestamp = cp.partTimestamp
            counterparty.dissolveSignature = cp.dissolveSignature
            counterparty.dissolveTimestamp = cp.dissolveTimestamp
            return counterparty
        }

        propose.proposeStatus = computeStatus(propose: propose, counterparties: counterparties)
        try await propose.save(on: db)
        for cp in counterparties {
            try await cp.save(on: db)
        }
    }

    // Recomputes status from the signatures actually present.
    // Never trusts the status field received from a peer.
    static func computeStatus(propose: Propose, counterparties: [ProposeCounterparty]) -> ProposeStatus {
        if propose.honorCreatorSignature != nil,
           !counterparties.isEmpty,
           counterparties.allSatisfy({ $0.honorSignature != nil }) {
            return .honored
        }
        if propose.partCreatorSignature != nil || counterparties.contains(where: { $0.partSignature != nil }) {
            return .parted
        }
        if propose.dissolvedAt != nil {
            return .dissolved
        }
        if !counterparties.isEmpty, counterparties.allSatisfy({ $0.signSignature != nil }) {
            return .signed
        }
        return .proposed
    }
}

// MARK: - Application Storage

extension Application {
    var syncService: SyncService? {
        get { storage[SyncServiceKey.self] }
        set { storage[SyncServiceKey.self] = newValue }
    }

    private struct SyncServiceKey: StorageKey {
        typealias Value = SyncService
    }
}
