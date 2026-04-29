import Fluent
import Vapor

// Pulls Proposes from peer nodes and merges them into the local database.
// Actor isolation protects in-flight state; sync checkpoints are persisted in DB.
actor SyncService {
    private let app: Application
    let peers: [String]
    let syncSecret: String?
    private let peerClient: any SyncPeerFetching
    private let verifier: any SignatureVerifier
    private let pageSize = 500

    init(app: Application, peers: [String], syncSecret: String?, verifier: any SignatureVerifier = P256SignatureVerifier()) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = VaporSyncPeerClient(app: app, syncSecret: syncSecret)
        self.verifier = verifier
    }

    /// Initializer for testing: accepts injected SyncPeerFetching and SignatureVerifier implementations.
    init(app: Application, peers: [String], syncSecret: String?, peerClient: some SyncPeerFetching, verifier: any SignatureVerifier = P256SignatureVerifier()) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = peerClient
        self.verifier = verifier
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
                    try await SyncService.upsertPropose(propose, on: app.db, logger: app.logger, verifier: self.verifier)
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

    static func upsertPropose(_ incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier = P256SignatureVerifier()) async throws {
        if let existing = try await Propose.query(on: db)
            .filter(\.$id == incoming.id)
            .with(\.$counterparties)
            .first() {
            try await mergeInto(existing: existing, incoming: incoming, on: db, logger: logger, verifier: verifier)
        } else {
            try await createFrom(incoming: incoming, on: db, logger: logger, verifier: verifier)
        }
    }

    private static func mergeInto(existing: Propose, incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier) async throws {
        var changed = false
        let idStr = incoming.id.uuidString
        let hash = incoming.contentHash
        let creatorKey = incoming.creatorPublicKey

        // Verifies an incoming signature+timestamp pair against the local value.
        // Returns (sig, ts) to adopt when local is nil and the incoming signature is valid.
        // When both local and peer have a value, verifies the peer and logs the outcome — but always keeps local.
        func adopt(
            localSig: String?, localTs: String?,
            peerSig: String?, peerTs: String?,
            message: (String) -> String,
            publicKey: String,
            field: String
        ) -> (sig: String, ts: String)? {
            guard let peerSig else { return nil }
            guard localSig == nil else {
                if localSig != peerSig {
                    if let ts = peerTs {
                        if verifier.verify(signature: peerSig, message: message(ts), publicKey: publicKey) {
                            logger.warning("[Sync] propose \(idStr) '\(field)': both valid — keeping local (first-writer wins)")
                        } else {
                            logger.warning("[Sync] propose \(idStr) '\(field)': peer signature invalid — keeping local")
                        }
                    } else {
                        logger.warning("[Sync] propose \(idStr) '\(field)': peer signature has no timestamp — keeping local")
                    }
                }
                return nil
            }
            guard let ts = peerTs else {
                logger.warning("[Sync] propose \(idStr) '\(field)': signature present but timestamp missing — rejected")
                return nil
            }
            if verifier.verify(signature: peerSig, message: message(ts), publicKey: publicKey) {
                return (peerSig, ts)
            }
            logger.warning("[Sync] propose \(idStr) '\(field)': invalid signature from peer — rejected")
            return nil
        }

        if let a = adopt(
            localSig: existing.honorCreatorSignature, localTs: existing.honorCreatorTimestamp,
            peerSig: incoming.honorCreatorSignature, peerTs: incoming.honorCreatorTimestamp,
            message: { ts in "honored.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "honorCreatorSignature"
        ) {
            existing.honorCreatorSignature = a.sig
            existing.honorCreatorTimestamp = a.ts
            changed = true
        }

        if let a = adopt(
            localSig: existing.partCreatorSignature, localTs: existing.partCreatorTimestamp,
            peerSig: incoming.partCreatorSignature, peerTs: incoming.partCreatorTimestamp,
            message: { ts in "parted.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "partCreatorSignature"
        ) {
            existing.partCreatorSignature = a.sig
            existing.partCreatorTimestamp = a.ts
            changed = true
        }

        if existing.dissolvedAt == nil, let v = incoming.dissolvedAt {
            existing.dissolvedAt = v; changed = true
        }

        if let a = adopt(
            localSig: existing.creatorDissolveSignature, localTs: existing.creatorDissolveTimestamp,
            peerSig: incoming.creatorDissolveSignature, peerTs: incoming.creatorDissolveTimestamp,
            message: { ts in "dissolved.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "creatorDissolveSignature"
        ) {
            existing.creatorDissolveSignature = a.sig
            existing.creatorDissolveTimestamp = a.ts
            changed = true
        }

        for incomingCP in incoming.counterparties {
            if let existingCP = existing.counterparties.first(where: { $0.publicKey == incomingCP.publicKey }) {
                var cpChanged = false
                let cpKey = incomingCP.publicKey
                let cpPrefix = String(cpKey.prefix(16))

                func adoptCP(
                    localSig: String?, localTs: String?,
                    peerSig: String?, peerTs: String?,
                    message: (String) -> String,
                    field: String
                ) -> (sig: String, ts: String)? {
                    adopt(
                        localSig: localSig, localTs: localTs,
                        peerSig: peerSig, peerTs: peerTs,
                        message: message, publicKey: cpKey,
                        field: "counterparty[\(cpPrefix)].\(field)"
                    )
                }

                if let a = adoptCP(
                    localSig: existingCP.signSignature, localTs: existingCP.signTimestamp,
                    peerSig: incomingCP.signSignature, peerTs: incomingCP.signTimestamp,
                    message: { ts in "signed.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "signSignature"
                ) { existingCP.signSignature = a.sig; existingCP.signTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.honorSignature, localTs: existingCP.honorTimestamp,
                    peerSig: incomingCP.honorSignature, peerTs: incomingCP.honorTimestamp,
                    message: { ts in "honored.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "honorSignature"
                ) { existingCP.honorSignature = a.sig; existingCP.honorTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.partSignature, localTs: existingCP.partTimestamp,
                    peerSig: incomingCP.partSignature, peerTs: incomingCP.partTimestamp,
                    message: { ts in "parted.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "partSignature"
                ) { existingCP.partSignature = a.sig; existingCP.partTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.dissolveSignature, localTs: existingCP.dissolveTimestamp,
                    peerSig: incomingCP.dissolveSignature, peerTs: incomingCP.dissolveTimestamp,
                    message: { ts in "dissolved.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "dissolveSignature"
                ) { existingCP.dissolveSignature = a.sig; existingCP.dissolveTimestamp = a.ts; cpChanged = true }

                if cpChanged {
                    try await existingCP.save(on: db)
                    changed = true
                }
            } else {
                // Counterparty exists on peer but not locally — create and verify each signature
                let cpKey = incomingCP.publicKey
                let cpPrefix = String(cpKey.prefix(16))
                let newCP = ProposeCounterparty(proposeID: try existing.requireID(), publicKey: cpKey)

                func adoptNewCP(sig: String?, ts: String?, prefix: String, message: (String) -> String) -> (sig: String, ts: String)? {
                    guard let sig, let ts else { return nil }
                    let msg = message(ts)
                    if verifier.verify(signature: sig, message: msg, publicKey: cpKey) { return (sig, ts) }
                    logger.warning("[Sync] propose \(idStr): invalid \(prefix) for new counterparty \(cpPrefix) — rejected")
                    return nil
                }

                if let a = adoptNewCP(sig: incomingCP.signSignature, ts: incomingCP.signTimestamp, prefix: "signSignature",
                                      message: { ts in "signed.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                    newCP.signSignature = a.sig; newCP.signTimestamp = a.ts
                }
                if let a = adoptNewCP(sig: incomingCP.honorSignature, ts: incomingCP.honorTimestamp, prefix: "honorSignature",
                                      message: { ts in "honored.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                    newCP.honorSignature = a.sig; newCP.honorTimestamp = a.ts
                }
                if let a = adoptNewCP(sig: incomingCP.partSignature, ts: incomingCP.partTimestamp, prefix: "partSignature",
                                      message: { ts in "parted.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                    newCP.partSignature = a.sig; newCP.partTimestamp = a.ts
                }
                if let a = adoptNewCP(sig: incomingCP.dissolveSignature, ts: incomingCP.dissolveTimestamp, prefix: "dissolveSignature",
                                      message: { ts in "dissolved.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                    newCP.dissolveSignature = a.sig; newCP.dissolveTimestamp = a.ts
                }

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

    private static func createFrom(incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier) async throws {
        let idStr = incoming.id.uuidString
        let hash = incoming.contentHash
        let creatorKey = incoming.creatorPublicKey

        // Verify creation signature before persisting anything
        let sortedKeys = incoming.counterparties.map { $0.publicKey }.sorted().joined()
        let createMsg = "proposed.\(idStr)\(hash)\(creatorKey)\(sortedKeys)\(incoming.createdAt)"
        guard verifier.verify(signature: incoming.creatorSignature, message: createMsg, publicKey: creatorKey) else {
            logger.warning("[Sync] propose \(idStr): invalid creatorSignature — skipped")
            return
        }

        let propose = Propose(
            id: incoming.id,
            contentHash: hash,
            creatorPublicKey: creatorKey,
            creatorSignature: incoming.creatorSignature,
            createdAt: incoming.createdAt,
            signatureVersion: incoming.signatureVersion
        )

        func verifyAndSet(sig: String?, ts: String?, message: (String) -> String, field: String) -> (sig: String, ts: String)? {
            guard let sig, let ts else { return nil }
            if verifier.verify(signature: sig, message: message(ts), publicKey: creatorKey) { return (sig, ts) }
            logger.warning("[Sync] propose \(idStr): invalid \(field) — skipped")
            return nil
        }

        if let a = verifyAndSet(sig: incoming.honorCreatorSignature, ts: incoming.honorCreatorTimestamp,
                                message: { ts in "honored.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "honorCreatorSignature") {
            propose.honorCreatorSignature = a.sig; propose.honorCreatorTimestamp = a.ts
        }
        if let a = verifyAndSet(sig: incoming.partCreatorSignature, ts: incoming.partCreatorTimestamp,
                                message: { ts in "parted.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "partCreatorSignature") {
            propose.partCreatorSignature = a.sig; propose.partCreatorTimestamp = a.ts
        }
        if let a = verifyAndSet(sig: incoming.creatorDissolveSignature, ts: incoming.creatorDissolveTimestamp,
                                message: { ts in "dissolved.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "creatorDissolveSignature") {
            propose.creatorDissolveSignature = a.sig; propose.creatorDissolveTimestamp = a.ts
        }
        propose.dissolvedAt = incoming.dissolvedAt

        var counterparties: [ProposeCounterparty] = []
        for cp in incoming.counterparties {
            let cpKey = cp.publicKey
            let counterparty = ProposeCounterparty(proposeID: incoming.id, publicKey: cpKey)

            func verifyCP(sig: String?, ts: String?, prefix: String, message: (String) -> String) -> (sig: String, ts: String)? {
                guard let sig, let ts else { return nil }
                if verifier.verify(signature: sig, message: message(ts), publicKey: cpKey) { return (sig, ts) }
                logger.warning("[Sync] propose \(idStr): invalid counterparty \(prefix) for \(String(cpKey.prefix(16))) — skipped")
                return nil
            }

            if let a = verifyCP(sig: cp.signSignature, ts: cp.signTimestamp, prefix: "signSignature",
                                message: { ts in "signed.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.signSignature = a.sig; counterparty.signTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.honorSignature, ts: cp.honorTimestamp, prefix: "honorSignature",
                                message: { ts in "honored.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.honorSignature = a.sig; counterparty.honorTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.partSignature, ts: cp.partTimestamp, prefix: "partSignature",
                                message: { ts in "parted.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.partSignature = a.sig; counterparty.partTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.dissolveSignature, ts: cp.dissolveTimestamp, prefix: "dissolveSignature",
                                message: { ts in "dissolved.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.dissolveSignature = a.sig; counterparty.dissolveTimestamp = a.ts
            }

            counterparties.append(counterparty)
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

    /// Verifier used by the batch sync endpoint. Defaults to P256SignatureVerifier.
    /// Override in tests to inject a permissive verifier for synthetic payloads.
    var syncVerifier: any SignatureVerifier {
        get { storage[SyncVerifierKey.self] ?? P256SignatureVerifier() }
        set { storage[SyncVerifierKey.self] = newValue }
    }

    private struct SyncVerifierKey: StorageKey {
        typealias Value = any SignatureVerifier
    }
}
