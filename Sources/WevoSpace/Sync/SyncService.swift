import Fluent
import Vapor

// Pulls Proposes from peer nodes and merges them into the local database.
// Actor isolation protects in-flight state; sync checkpoints are persisted in DB.
actor SyncService {
    private let app: Application
    let peers: [String]
    let syncSecret: String?
    private let peerClient: any SyncPeerFetching
    private let pageSize = 500

    init(app: Application, peers: [String], syncSecret: String?) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = VaporSyncPeerClient(app: app, syncSecret: syncSecret)
    }

    /// Initializer for testing: accepts an injected SyncPeerFetching implementation.
    init(app: Application, peers: [String], syncSecret: String?, peerClient: some SyncPeerFetching) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = peerClient
    }

    func pullFromAllPeers() async {
        for peer in peers {
            await pullFromPeer(peer)
        }
    }

    private func pullFromPeer(_ peerURL: String) async {
        let syncStartedAt = Date()

        // Load last checkpoint from DB; buffer by 1 minute to handle clock skew
        let checkpoint: SyncCheckpoint?
        do {
            checkpoint = try await SyncCheckpoint.query(on: app.db)
                .filter(\.$peerURL == peerURL)
                .first()
        } catch {
            app.logger.error("[Sync] \(peerURL): failed to load checkpoint — \(error)")
            return
        }
        let after = checkpoint?.lastSyncAt.addingTimeInterval(-60)

        var offset = 0
        var totalMerged = 0

        do {
            while true {
                let page = try await peerClient.fetchProposes(
                    from: peerURL,
                    after: after,
                    limit: pageSize,
                    offset: offset
                )
                for propose in page {
                    try await SyncService.upsertPropose(propose, on: app.db, logger: app.logger)
                }
                totalMerged += page.count
                // If fewer results than page size, we've reached the last page
                if page.count < pageSize { break }
                offset += pageSize
            }
        } catch {
            // Peer unreachable or returned invalid data — skip and retry next cycle
            app.logger.warning("[Sync] \(peerURL) skipped: \(error)")
            return
        }

        // Persist checkpoint using start time so any Proposes created
        // during this pull are captured in the next cycle
        do {
            if let existing = checkpoint {
                existing.lastSyncAt = syncStartedAt
                try await existing.save(on: app.db)
            } else {
                try await SyncCheckpoint(peerURL: peerURL, lastSyncAt: syncStartedAt).save(on: app.db)
            }
        } catch {
            app.logger.error("[Sync] \(peerURL): failed to persist checkpoint — \(error)")
        }

        if totalMerged > 0 {
            app.logger.info("[Sync] \(peerURL): merged \(totalMerged) propose(s)")
        }
    }

    // MARK: - Merge (static: no actor isolation needed, safe to call from anywhere)

    static func upsertPropose(_ incoming: ProposeResponse, on db: any Database, logger: Logger) async throws {
        if let existing = try await Propose.query(on: db)
            .filter(\.$id == incoming.id)
            .with(\.$counterparties)
            .first() {
            try await mergeInto(existing: existing, incoming: incoming, on: db, logger: logger)
        } else {
            try await createFrom(incoming: incoming, on: db)
        }
    }

    private static func mergeInto(existing: Propose, incoming: ProposeResponse, on db: any Database, logger: Logger) async throws {
        var changed = false
        let proposeID = existing.id?.uuidString ?? "unknown"

        // For each nullable field: adopt received value only when local is nil.
        // If both are non-nil but differ, this indicates a cryptographic inconsistency (fraud signal);
        // we keep the local value — the data will not converge intentionally.
        func checkConflict(field: String, local: String?, peer: String?) {
            if let local, let peer, local != peer {
                logger.warning("[Sync] Conflict detected — propose \(proposeID) field '\(field)': local and peer values differ (fraud signal)")
            }
        }

        checkConflict(field: "honorCreatorSignature", local: existing.honorCreatorSignature, peer: incoming.honorCreatorSignature)
        checkConflict(field: "partCreatorSignature", local: existing.partCreatorSignature, peer: incoming.partCreatorSignature)
        checkConflict(field: "dissolvedAt", local: existing.dissolvedAt, peer: incoming.dissolvedAt)
        checkConflict(field: "creatorDissolveSignature", local: existing.creatorDissolveSignature, peer: incoming.creatorDissolveSignature)

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
            if let existingCP = existing.counterparties.first(where: { $0.publicKey == incomingCP.publicKey }) {
                var cpChanged = false
                let cpKey = String(incomingCP.publicKey.prefix(16))

                checkConflict(field: "counterparty[\(cpKey)].signSignature", local: existingCP.signSignature, peer: incomingCP.signSignature)
                checkConflict(field: "counterparty[\(cpKey)].honorSignature", local: existingCP.honorSignature, peer: incomingCP.honorSignature)
                checkConflict(field: "counterparty[\(cpKey)].partSignature", local: existingCP.partSignature, peer: incomingCP.partSignature)
                checkConflict(field: "counterparty[\(cpKey)].dissolveSignature", local: existingCP.dissolveSignature, peer: incomingCP.dissolveSignature)

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
            } else {
                // Counterparty exists on peer but not locally — create from peer data
                let newCP = ProposeCounterparty(proposeID: try existing.requireID(), publicKey: incomingCP.publicKey)
                newCP.signSignature = incomingCP.signSignature
                newCP.signTimestamp = incomingCP.signTimestamp
                newCP.honorSignature = incomingCP.honorSignature
                newCP.honorTimestamp = incomingCP.honorTimestamp
                newCP.partSignature = incomingCP.partSignature
                newCP.partTimestamp = incomingCP.partTimestamp
                newCP.dissolveSignature = incomingCP.dissolveSignature
                newCP.dissolveTimestamp = incomingCP.dissolveTimestamp
                try await newCP.save(on: db)
                existing.counterparties.append(newCP)
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
